// UNVERIFIED v13 output-prefetch candidate; select instead of the v10 file.
// Original module and ports retained. New chip edges: zero. AI uses NICE only.
// All memory requests below use the CPU's original NICE LSU path. Local ICB/DLD
// signals never leave this u_core; no AI System Bus slave or shared-private port.
// W10/W12, O16 only: ordinary two-INT16 word32 output, no compression.
module kwt_nice_linear_v10 #(parameter integer WBITS=10) (
    input wire nice_clk,nice_rst_n,
    input wire nice_req_valid,
    output wire nice_req_ready,
    input wire [31:0] nice_req_inst,nice_req_rs1,nice_req_rs2,
    output wire nice_rsp_multicyc_valid,
    input wire nice_rsp_multicyc_ready,
    output wire [31:0] nice_rsp_multicyc_dat,
    output wire nice_rsp_multicyc_err,
    output wire nice_icb_cmd_valid,
    input wire nice_icb_cmd_ready,
    output wire [31:0] nice_icb_cmd_addr,
    output wire nice_icb_cmd_read,
    output wire [31:0] nice_icb_cmd_wdata,
    output wire [1:0] nice_icb_cmd_size,
    input wire nice_icb_rsp_valid,
    output wire nice_icb_rsp_ready,
    input wire [31:0] nice_icb_rsp_rdata,
    input wire nice_icb_rsp_err,
    output wire nice_mem_holdup,nice_active
);
    localparam integer WW=512*WBITS,PW=WW+320,LW=PW+3168,NO=12672;
    localparam [32:0] LOAD_BYTES=LW*4;
    localparam [4:0] IDLE=0,TASK_RESET=1,STAGE_RCMD=2,STAGE_RRSP=3,
        STAGE_WCMD=4,STAGE_WRSP=5,LOAD_CMD=6,LOAD_RSP=7,LOAD_DLD=8,
        LAYER_CMD=9,LAYER_RSP=10,START_CMD=11,START_RSP=12,
        OUTPUT_CMD=13,OUTPUT_RSP=14,OUTPUT_WCMD=15,OUTPUT_WRSP=16,
        FINAL_CMD=17,FINAL_RSP=18,RESPONSE=19;
    reg [4:0] state;
    reg [3:0] layer,next_layer;
    reg [13:0] index;
    reg [13:0] stage_acks,load_delivered,result_acks;
    reg [31:0] flash_base,held_word;
    reg response_error,memory_owned;
    reg [31:0] response_data;
    // One local output read may overlap an already ACCEPTED NICE write.
    // No extra payload register/array: held_word is reusable only after that
    // write command handshake transfers ownership to the original LSU/BIU.
    localparam [1:0] PRE_NONE=0,PRE_CMD=1,PRE_RSP=2,PRE_READY=3;
    reg [1:0] prefetch;
    reg write_done;
    // funct7=0x32, custom3, xd/xs1/xs2 all asserted by funct3=111.
    wire encoding_ok=nice_req_inst[6:0]==7'h7b &&
        nice_req_inst[14:12]==3'b111 && nice_req_inst[31:25]==7'h32;
    wire [32:0] flash_end={1'b0,nice_req_rs1}+LOAD_BYTES-33'd1;
    wire request_ok=(WBITS==10 || WBITS==12) && encoding_ok && nice_req_rs1[1:0]==0 &&
        nice_req_rs1>=32'h20000000 && flash_end<=33'h03fffffff &&
        nice_req_rs2<12 && nice_req_rs2=={28'd0,next_layer};
    wire task_reset=state==TASK_RESET;
    wire local_cmd_ready,local_rsp_valid,local_rsp_err;
    wire [31:0] local_rsp_data;
    wire local_cmd_valid=(state==LAYER_CMD || state==START_CMD ||
        state==OUTPUT_CMD || state==FINAL_CMD ||
        (state==OUTPUT_WRSP && prefetch==PRE_CMD));
    wire local_rsp_ready=(state==LAYER_RSP || state==START_RSP ||
        state==OUTPUT_RSP || state==FINAL_RSP ||
        (state==OUTPUT_WRSP && prefetch==PRE_RSP));
    wire [11:0] local_addr=state==LAYER_CMD ? 12'h008 :
        state==START_CMD ? 12'h000 :
        (state==OUTPUT_CMD || state==OUTPUT_WRSP) ? 12'h018 : 12'h004;
    wire dld_ready;
    wire [17:0] dld_addr=index<PW ?
        (index<WW ? {4'd0,index} : (18'd8192+index-WW)) : (index-PW);
    // This instance contains every AI data macro. Its ICB is LOCAL control,
    // not a connection to the chip System Bus or the shared-memory adapter.
    kwt_accel_core_if_wide #(.WBITS(WBITS),.OBITS(16)) u_wide(
        .clk(nice_clk),.rst_n(nice_rst_n),.quiesce(response_error),.task_reset(task_reset),
        .acc_icb_cmd_valid(local_cmd_valid),.acc_icb_cmd_ready(local_cmd_ready),
        .acc_icb_cmd_read(state==OUTPUT_CMD || state==OUTPUT_WRSP || state==FINAL_CMD),
        .acc_icb_cmd_addr(local_addr),
        .acc_icb_cmd_wdata(state==LAYER_CMD ? {28'd0,layer} : 32'd1),
        .acc_icb_cmd_wmask(4'hf),.acc_icb_rsp_valid(local_rsp_valid),
        .acc_icb_rsp_ready(local_rsp_ready),.acc_icb_rsp_err(local_rsp_err),
        .acc_icb_rsp_rdata(local_rsp_data),
        .dld_valid(state==LOAD_DLD),.dld_ready(dld_ready),
        .dld_is_in(index>=PW),.dld_addr(dld_addr),.dld_data(held_word),.irq()
    );
    wire [31:0] shared_load_addr=index<PW ?
        32'ha1000000+({18'd0,index}<<2) :
        32'ha2000000+(({18'd0,index}-PW)<<2);
    assign nice_req_ready=nice_rst_n && state==IDLE;
    assign nice_rsp_multicyc_valid=nice_rst_n && state==RESPONSE;
    assign nice_rsp_multicyc_dat=response_error ? 32'd0 : response_data;
    assign nice_rsp_multicyc_err=response_error;
    assign nice_mem_holdup=nice_rst_n && memory_owned;
    assign nice_active=nice_rst_n && (state!=IDLE || nice_req_valid);
    assign nice_icb_cmd_valid=nice_rst_n && (state==STAGE_RCMD || state==STAGE_WCMD ||
        state==LOAD_CMD || state==OUTPUT_WCMD);
    assign nice_icb_cmd_read=(state==STAGE_RCMD || state==LOAD_CMD);
    assign nice_icb_cmd_addr=state==STAGE_RCMD ? flash_base+({18'd0,index}<<2) :
        state==OUTPUT_WCMD ? 32'ha3000000+({18'd0,index}<<2) : shared_load_addr;
    assign nice_icb_cmd_wdata=held_word;
    assign nice_icb_cmd_size=2'b10;
    assign nice_icb_rsp_ready=nice_rst_n && (state==STAGE_RRSP || state==STAGE_WRSP ||
        state==LOAD_RSP || (state==OUTPUT_WRSP && !write_done));
    wire write_return=state==OUTPUT_WRSP && !write_done && nice_icb_rsp_valid;
    wire prefetch_return=state==OUTPUT_WRSP && prefetch==PRE_RSP && local_rsp_valid;
    wire output_fault=(write_return && nice_icb_rsp_err) ||
                      (prefetch_return && local_rsp_err);
    wire [13:0] confirmed_writes=result_acks+
        ((write_return && !nice_icb_rsp_err) ? 14'd1 : 14'd0);
    // All interface VALID/READY outputs above depend only on registers, reset,
    // and state. Neither response acceptance waits on another channel's READY.
    // A fault drains BOTH already offered operations before instruction return.
    always @(posedge nice_clk or negedge nice_rst_n) begin
        if(!nice_rst_n) begin
            state<=IDLE;layer<=0;next_layer<=0;index<=0;
            stage_acks<=0;load_delivered<=0;result_acks<=0;
            flash_base<=0;held_word<=0;response_error<=0;memory_owned<=0;response_data<=0;
            prefetch<=PRE_NONE;write_done<=0;
        end else begin
            case(state)
                IDLE:if(nice_req_valid && nice_req_ready) begin
                    response_data<=0;response_error<=0;memory_owned<=0;
                    prefetch<=PRE_NONE;write_done<=0;
                    if(request_ok) begin
                        layer<=nice_req_rs2[3:0];flash_base<=nice_req_rs1;index<=0;
                        stage_acks<=0;load_delivered<=0;result_acks<=0;
                        memory_owned<=1;state<=TASK_RESET;
                    end else begin response_error<=1;state<=RESPONSE;end
                end
                TASK_RESET:state<=STAGE_RCMD;
                STAGE_RCMD:if(nice_icb_cmd_ready) state<=STAGE_RRSP;
                STAGE_RRSP:if(nice_icb_rsp_valid) begin
                    if(nice_icb_rsp_err) begin response_error<=1;state<=RESPONSE;end
                    else begin held_word<=nice_icb_rsp_rdata;state<=STAGE_WCMD;end
                end
                STAGE_WCMD:if(nice_icb_cmd_ready) state<=STAGE_WRSP;
                STAGE_WRSP:if(nice_icb_rsp_valid) begin
                    if(nice_icb_rsp_err) begin response_error<=1;state<=RESPONSE;end
                    else begin
                        stage_acks<=stage_acks+14'd1;
                        if(index==LW-1) begin index<=0;state<=LOAD_CMD;end
                        else begin index<=index+14'd1;state<=STAGE_RCMD;end
                    end
                end
                LOAD_CMD:if(nice_icb_cmd_ready) state<=LOAD_RSP;
                LOAD_RSP:if(nice_icb_rsp_valid) begin
                    if(nice_icb_rsp_err) begin response_error<=1;state<=RESPONSE;end
                    else begin held_word<=nice_icb_rsp_rdata;state<=LOAD_DLD;end
                end
                LOAD_DLD:if(dld_ready) begin
                    load_delivered<=load_delivered+14'd1;
                    if(index==LW-1) begin index<=0;state<=LAYER_CMD;end
                    else begin index<=index+14'd1;state<=LOAD_CMD;end
                end
                LAYER_CMD:if(local_cmd_ready) state<=LAYER_RSP;
                LAYER_RSP:if(local_rsp_valid) begin
                    if(local_rsp_err) begin response_error<=1;state<=RESPONSE;end
                    else state<=START_CMD;
                end
                START_CMD:if(local_cmd_ready) state<=START_RSP;
                START_RSP:if(local_rsp_valid) begin
                    if(local_rsp_err) begin response_error<=1;state<=RESPONSE;end
                    // Start draining immediately; waiting for core_done here
                    // would deadlock once the finite output macros fill.
                    else begin index<=0;state<=OUTPUT_CMD;end
                end
                OUTPUT_CMD:if(local_cmd_ready) state<=OUTPUT_RSP;
                OUTPUT_RSP:if(local_rsp_valid) begin
                    if(local_rsp_err) begin response_error<=1;response_data<={18'd0,result_acks};state<=RESPONSE;end
                    else begin held_word<=local_rsp_data;state<=OUTPUT_WCMD;end
                end
                OUTPUT_WCMD:if(nice_icb_cmd_ready) begin
                    // No local prefetch is offered while the current NICE write
                    // is backpressured. Its address/data stay unchanged then.
                    write_done<=0;
                    prefetch<=index==NO-1 ? PRE_NONE : PRE_CMD;
                    state<=OUTPUT_WRSP;
                end
                OUTPUT_WRSP:begin
                    if(write_return) begin
                        write_done<=1;
                        if(!nice_icb_rsp_err) result_acks<=result_acks+14'd1;
                    end
                    // Keep an offered local command valid even after a NICE
                    // error. quiesce makes that output read return an error;
                    // PRE_RSP still consumes it, so no response is abandoned.
                    if(prefetch==PRE_CMD && local_cmd_ready) prefetch<=PRE_RSP;
                    if(prefetch_return) begin
                        prefetch<=local_rsp_err ? PRE_NONE : PRE_READY;
                        if(!local_rsp_err) held_word<=local_rsp_data;
                    end
                    if(output_fault) response_error<=1;
                    if((write_done || write_return) &&
                       (prefetch==PRE_NONE || prefetch==PRE_READY || prefetch_return)) begin
                        if(response_error || output_fault) begin
                            response_error<=1;
                            response_data<={18'd0,confirmed_writes};
                            state<=RESPONSE;
                        end else if(index==NO-1) state<=FINAL_CMD;
                        else begin
                            // A successful local response was accepted earlier
                            // or is accepted on this same edge. Its word becomes
                            // stable for the next WRITE_CMD cycle after the edge.
                            index<=index+14'd1;
                            state<=OUTPUT_WCMD;
                        end
                    end
                end
                FINAL_CMD:if(local_cmd_ready) state<=FINAL_RSP;
                FINAL_RSP:if(local_rsp_valid) begin
                    if(local_rsp_err || local_rsp_data[4] ||
                       stage_acks!=LW || load_delivered!=LW || result_acks!=NO) begin
                        response_error<=1;response_data<={18'd0,result_acks};state<=RESPONSE;
                    end else if((local_rsp_data & 32'hf3)==32'he2) begin
                        response_data<=NO;
                        // A completed twelve-layer sequence is reusable without
                        // resetting the CPU/LSU or the entire chip.
                        next_layer<=layer==4'd11 ? 4'd0 : layer+4'd1;
                        state<=RESPONSE;
                    end else state<=FINAL_CMD;
                end
                RESPONSE:if(nice_rsp_multicyc_ready) begin memory_owned<=0;state<=IDLE;end
                default:begin response_error<=1;response_data<={18'd0,result_acks};state<=RESPONSE;end
            endcase
        end
    end
endmodule

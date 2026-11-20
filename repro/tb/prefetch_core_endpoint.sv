`timescale 1ns/1fs
// CONTROLLER-ONLY endpoint. Never compile with the real module of this name.
// Delayed one-response local port; no arithmetic or SRAM model is claimed.
module kwt_accel_core_if_wide #(parameter integer WBITS=10,OBITS=16)(
    input wire clk,rst_n,quiesce,task_reset,
    input wire acc_icb_cmd_valid,output wire acc_icb_cmd_ready,
    input wire acc_icb_cmd_read,input wire [11:0] acc_icb_cmd_addr,
    input wire [31:0] acc_icb_cmd_wdata,input wire [3:0] acc_icb_cmd_wmask,
    output reg acc_icb_rsp_valid,input wire acc_icb_rsp_ready,
    output reg acc_icb_rsp_err,output reg [31:0] acc_icb_rsp_rdata,
    input wire dld_valid,output wire dld_ready,input wire dld_is_in,
    input wire [17:0] dld_addr,input wire [31:0] dld_data,output wire irq
);
    localparam integer PW=512*WBITS+320,LW=PW+3168,NO=12672;
    // Test controls are assigned only by the component TB, outside transactions.
    integer test_mode=0,error_word=0;
    integer delivered=0,out_count=0,layer=0,wait_left=0,command_stall=0;
    bit started=0,pending=0,pending_error=0;
    reg [31:0] pending_data=0;
    wire is_out=acc_icb_cmd_read && acc_icb_cmd_addr==12'h018;
    // Mode4 holds an ALREADY offered prefetch command until the write error
    // quiesces the core. An invalid/aborted read then terminates, as real regs do.
    wire hold_output=is_out && out_count==error_word+1 && test_mode==4 &&
        command_stall<40 && !quiesce;
    assign acc_icb_cmd_ready=rst_n && !pending && !acc_icb_rsp_valid && !hold_output;
    assign dld_ready=rst_n && !quiesce && delivered<LW;
    assign irq=1'b0;
    function automatic [31:0] output_word(input integer l,input integer n);
        output_word=32'h5a000000 ^ (l<<20) ^ (n*32'h00010003);
    endfunction
    task automatic fail(input string why);
        $display("NICE_PREFETCH_V13_ENDPOINT_FAIL %s",why);$fatal(1,"endpoint");
    endtask
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            delivered<=0;out_count<=0;layer<=0;wait_left<=0;command_stall<=0;
            started<=0;pending<=0;pending_error<=0;pending_data<=0;
            acc_icb_rsp_valid<=0;acc_icb_rsp_err<=0;acc_icb_rsp_rdata<=0;
        end else begin
            if(task_reset) begin
                if(pending || acc_icb_rsp_valid) fail("task reset abandoned local response");
                delivered<=0;out_count<=0;layer<=0;started<=0;command_stall<=0;
            end
            if(acc_icb_cmd_valid && hold_output) command_stall<=command_stall+1;
            if(dld_valid && dld_ready) begin
                if(dld_data!==0 || dld_is_in!==(delivered>=PW)) fail("DLD owner/data/order");
                if(dld_addr!==(delivered<PW ? (delivered<512*WBITS ? delivered : 8192+delivered-512*WBITS) : delivered-PW)) fail("DLD address");
                delivered<=delivered+1;
            end
            if(acc_icb_rsp_valid && acc_icb_rsp_ready) acc_icb_rsp_valid<=0;
            if(pending) begin
                if(wait_left==0) begin
                    pending<=0;acc_icb_rsp_valid<=1;
                    acc_icb_rsp_err<=pending_error;acc_icb_rsp_rdata<=pending_data;
                end else wait_left<=wait_left-1;
            end
            if(acc_icb_cmd_valid && acc_icb_cmd_ready) begin
                if(task_reset || pending || acc_icb_rsp_valid) fail("local overlap/reset");
                if(acc_icb_cmd_wmask!==4'hf) fail("local mask");
                pending<=1;wait_left<=0;pending_data<=0;pending_error<=0;
                if(is_out) begin
                    if(!started || out_count>=NO) fail("extra or premature output read");
                    // Index1 can be before, after, or simultaneous with the
                    // response to write0. Later words exercise the same schedule.
                    wait_left<=(test_mode==1 || test_mode==4) ? 30 :
                               ((test_mode==2 || test_mode==7) ? 3 : 0);
                    pending_error<=quiesce ||
                        ((test_mode==5 || test_mode==6 || test_mode==7) && out_count==error_word+1);
                    pending_data<=output_word(layer,out_count);
                    out_count<=out_count+1;
                end else if(!acc_icb_cmd_read && acc_icb_cmd_addr==12'h008) begin
                    layer<=acc_icb_cmd_wdata;
                end else if(!acc_icb_cmd_read && acc_icb_cmd_addr==12'h000) begin
                    if(delivered!=LW || acc_icb_cmd_wdata!==1 || started) fail("START before complete DLD");
                    started<=1;
                end else if(acc_icb_cmd_read && acc_icb_cmd_addr==12'h004) begin
                    if(out_count!=NO) fail("final status before complete output");
                    pending_data<=32'he2;
                end else fail("unexpected local control operation");
            end
        end
    end
endmodule

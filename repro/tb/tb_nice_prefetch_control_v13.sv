`timescale 1ns/1fs
`ifndef NICE_LINEAR_WBITS
`define NICE_LINEAR_WBITS 10
`endif
// Only protocol scheduling is modeled here. Real wide core / physical QSPI /
// shared macros / TF accuracy require the separate UG125-derived integration.
module tb_nice_prefetch_control_v13;
    localparam integer WBITS=`NICE_LINEAR_WBITS,PW=512*WBITS+320,LW=PW+3168,NO=12672;
    reg clk=0,rst_n=0;always #(10.0/3.0) clk=~clk;
    reg req_valid=0,rsp_ready=0;
    reg [31:0] inst=32'h64c5f57b,rs1=32'h20000100,rs2=0;
    wire req_ready,rsp_valid,rsp_err,cmd_valid,cmd_read,mem_ready,holdup;
    wire [31:0] rsp_data,cmd_addr,cmd_data;
    wire [1:0] cmd_size;
    reg command_ready=0,response_valid=0,response_error=0,pending=0;
    reg [31:0] response_data=0;
    integer test_mode=0,error_word=0,wait_left=0,role=0;
    integer accepted=0,returned=0,flash_reads=0,stage_writes=0,reloads=0;
    integer writes=0,write_acks=0,local_reads=0,local_returns=0;
    integer stall_ticks=0,seen_stalls=0,overlaps=0,same_edges=0;
    integer local_first=0,write_first=0,passes=0,error_cases=0,resets=0,tick=0;
    integer local_errors=0,write_errors=0;
    integer accepted_write_word=0,last_local_return=-1,last_write_return=-1;
    bit command_held=0,local_held=0,final_held=0,local_response_held=0;
    reg [66:0] held_command;
    reg [48:0] held_local;
    reg [32:0] held_final,held_local_response;
    kwt_nice_linear_v10 #(.WBITS(WBITS)) dut(
        .nice_clk(clk),.nice_rst_n(rst_n),.nice_req_valid(req_valid),.nice_req_ready(req_ready),
        .nice_req_inst(inst),.nice_req_rs1(rs1),.nice_req_rs2(rs2),
        .nice_rsp_multicyc_valid(rsp_valid),.nice_rsp_multicyc_ready(rsp_ready),
        .nice_rsp_multicyc_dat(rsp_data),.nice_rsp_multicyc_err(rsp_err),
        .nice_icb_cmd_valid(cmd_valid),.nice_icb_cmd_ready(command_ready),
        .nice_icb_cmd_addr(cmd_addr),.nice_icb_cmd_read(cmd_read),.nice_icb_cmd_wdata(cmd_data),.nice_icb_cmd_size(cmd_size),
        .nice_icb_rsp_valid(response_valid),.nice_icb_rsp_ready(mem_ready),
        .nice_icb_rsp_rdata(response_data),.nice_icb_rsp_err(response_error),
        .nice_mem_holdup(holdup),.nice_active());
    wire local_cmd_fire=dut.u_wide.acc_icb_cmd_valid && dut.u_wide.acc_icb_cmd_ready;
    wire local_out_fire=local_cmd_fire && dut.u_wide.acc_icb_cmd_read && dut.u_wide.acc_icb_cmd_addr==12'h018;
    wire local_rsp_fire=dut.u_wide.acc_icb_rsp_valid && dut.u_wide.acc_icb_rsp_ready;
    wire local_output_response=local_rsp_fire && local_returns<local_reads;
    task automatic fail(input string why);
        $display("NICE_FINAL_V43_PROTOCOL_CONTROL_FAIL W=%0d mode=%0d tick=%0d writes=%0d ack=%0d local=%0d returned=%0d reason=%s",WBITS,test_mode,tick,writes,write_acks,local_reads,local_returns,why);
        $fatal(1,"NICE_FINAL_V43_PROTOCOL_CONTROL_FAIL");
    endtask
    function automatic [31:0] output_word(input integer l,input integer n);
        output_word=32'h5a000000 ^ (l<<20) ^ (n*32'h00010003);
    endfunction
    function automatic [31:0] stage_address(input integer n);
        stage_address=n<PW ? 32'ha1000000+4*n : 32'ha2000000+4*(n-PW);
    endfunction
    // The endpoint takes one NICE request at a time. This candidate does not
    // depend on simultaneous old response / next NICE command support.
    always @(negedge clk) if(rst_n) begin
        command_ready=!pending && !response_valid &&
            !(test_mode==3 && cmd_valid && !cmd_read && cmd_addr==32'ha3000000 && stall_ticks<40);
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            command_ready<=0;pending<=0;response_valid<=0;response_error<=0;response_data<=0;
            wait_left<=0;role<=0;tick<=0;command_held<=0;local_held<=0;final_held<=0;local_response_held<=0;
            accepted<=0;returned<=0;flash_reads<=0;stage_writes<=0;reloads<=0;writes<=0;write_acks<=0;
            local_reads<=0;local_returns<=0;stall_ticks<=0;seen_stalls<=0;overlaps<=0;same_edges<=0;
            local_first<=0;write_first<=0;last_local_return<=-1;last_write_return<=-1;
            local_errors<=0;write_errors<=0;
        end else begin
            tick<=tick+1;
            if(command_held && (cmd_valid!==1 || {cmd_addr,cmd_read,cmd_data,cmd_size}!==held_command)) fail("NICE command changed while stalled");
            command_held<=cmd_valid && !command_ready;
            if(cmd_valid && !command_ready) begin
                held_command<={cmd_addr,cmd_read,cmd_data,cmd_size};
                if(!cmd_read && cmd_addr>=32'ha3000000) begin stall_ticks<=stall_ticks+1;seen_stalls<=seen_stalls+1;end
            end
            if(local_held && (dut.u_wide.acc_icb_cmd_valid!==1 ||
                {dut.u_wide.acc_icb_cmd_read,dut.u_wide.acc_icb_cmd_addr,dut.u_wide.acc_icb_cmd_wdata,dut.u_wide.acc_icb_cmd_wmask}!==held_local)) fail("offered local command withdrawn or changed");
            local_held<=dut.u_wide.acc_icb_cmd_valid && !dut.u_wide.acc_icb_cmd_ready;
            if(dut.u_wide.acc_icb_cmd_valid && !dut.u_wide.acc_icb_cmd_ready)
                held_local<={dut.u_wide.acc_icb_cmd_read,dut.u_wide.acc_icb_cmd_addr,dut.u_wide.acc_icb_cmd_wdata,dut.u_wide.acc_icb_cmd_wmask};
            if(local_response_held && (dut.u_wide.acc_icb_rsp_valid!==1 ||
                {dut.u_wide.acc_icb_rsp_err,dut.u_wide.acc_icb_rsp_rdata}!==held_local_response)) fail("local response changed while stalled");
            local_response_held<=dut.u_wide.acc_icb_rsp_valid && !dut.u_wide.acc_icb_rsp_ready;
            if(dut.u_wide.acc_icb_rsp_valid && !dut.u_wide.acc_icb_rsp_ready)
                held_local_response<={dut.u_wide.acc_icb_rsp_err,dut.u_wide.acc_icb_rsp_rdata};
            if(final_held && (rsp_valid!==1 || {rsp_err,rsp_data}!==held_final)) fail("NICE instruction response changed while stalled");
            final_held<=rsp_valid && !rsp_ready;
            if(rsp_valid && !rsp_ready) held_final<={rsp_err,rsp_data};
            if(local_out_fire) begin
                // Before write0 acceptance, only the initial output read is
                // legal. Thereafter at most one next word may be prefetched.
                if(local_reads>writes || local_reads>=NO) fail("prefetch before current write acceptance or beyond final word");
                if(local_reads!=0 && (pending || response_valid) && role==4) overlaps<=overlaps+1;
                local_reads<=local_reads+1;
            end
            if(local_output_response) begin
                local_returns<=local_returns+1;
                if(dut.u_wide.acc_icb_rsp_err) local_errors<=local_errors+1;
                last_local_return<=tick;
                if(local_returns>0 && pending && role==4) local_first<=local_first+1;
            end
            if(response_valid && mem_ready) begin
                response_valid<=0;returned<=returned+1;
                if(role==4) begin
                    if(!response_error) write_acks<=write_acks+1;
                    else write_errors<=write_errors+1;
                    last_write_return<=tick;
                    if(accepted_write_word<NO-1 && local_returns<writes+1) write_first<=write_first+1;
                    if(local_output_response) same_edges<=same_edges+1;
                end
            end
            if(pending) begin
                if(role==4 && (test_mode==2 || test_mode==7)) begin
                    // For all but the final word both endpoint responses are
                    // registered on this edge, and accepted together next edge.
                    if(accepted_write_word==NO-1 || (dut.u_wide.pending && dut.u_wide.wait_left==0)) begin
                        pending<=0;response_valid<=1;
                    end
                end else if(wait_left==0) begin pending<=0;response_valid<=1;end
                else wait_left<=wait_left-1;
            end
            if(cmd_valid && command_ready) begin
                if(pending || response_valid || cmd_size!==2 || holdup!==1) fail("NICE overlap/size/holdup");
                accepted<=accepted+1;pending<=1;response_error<=0;response_data<=0;wait_left<=0;
                if(cmd_read && cmd_addr>=32'h20000000 && cmd_addr<32'h40000000) begin
                    if(cmd_addr!==rs1+4*flash_reads || flash_reads!=stage_writes) fail("Flash read sequence");
                    flash_reads<=flash_reads+1;role<=1;
                end else if(!cmd_read && cmd_addr<32'ha3000000) begin
                    if(cmd_addr!==stage_address(stage_writes) || cmd_data!==0 || flash_reads!=stage_writes+1) fail("shared staging sequence/data");
                    stage_writes<=stage_writes+1;role<=2;
                end else if(cmd_read) begin
                    if(stage_writes!=LW || cmd_addr!==stage_address(reloads)) fail("shared reload sequence");
                    reloads<=reloads+1;role<=3;
                end else begin
                    if(cmd_addr!==32'ha3000000+4*writes || cmd_data!==output_word(rs2,writes) || writes>=NO) fail("prefetched write address/data/count");
                    if(local_returns!=writes+1) fail("write without exactly one owned output word");
                    accepted_write_word<=writes;writes<=writes+1;role<=4;
                    wait_left<=(test_mode==1 || test_mode==4) ? 0 : 12;
                    response_error<=((test_mode==4 || test_mode==5 || test_mode==7) && writes==error_word);
                end
            end
            if(rsp_valid && (pending || response_valid || dut.u_wide.pending || dut.u_wide.acc_icb_rsp_valid ||
                dut.u_wide.acc_icb_cmd_valid || local_reads!=local_returns)) fail("instruction returned before both operations drained");
        end
    end
    task automatic reset_all;
        @(negedge clk);rst_n=0;req_valid=0;rsp_ready=0;
        repeat(4) @(negedge clk);rst_n=1;repeat(2) @(negedge clk);
        resets=resets+1;
    endtask
    task automatic issue(input integer mode,input integer l,input integer failed_word);
        @(negedge clk);
        if(!req_ready || pending || response_valid) fail("issue while previous transaction remains");
        test_mode=mode;error_word=failed_word;dut.u_wide.test_mode=mode;dut.u_wide.error_word=failed_word;
        accepted=0;returned=0;flash_reads=0;stage_writes=0;reloads=0;writes=0;write_acks=0;
        local_reads=0;local_returns=0;stall_ticks=0;seen_stalls=0;overlaps=0;same_edges=0;local_first=0;write_first=0;
        local_errors=0;write_errors=0;
        rs1=32'h20000100+4*LW*l;rs2=l;req_valid=1;
        do @(posedge clk);while(!req_ready);
        @(negedge clk);req_valid=0;
    endtask
    task automatic finish_case(input bit expected_error,input integer expected_count);
        wait(rsp_valid===1);repeat(9) @(negedge clk);
        if(rsp_err!==expected_error || rsp_data!==(expected_error ? 32'd0 : expected_count) || holdup!==1 || accepted!=returned) fail("final error/count/holdup");
        if(!expected_error) begin
            if(flash_reads!=LW || stage_writes!=LW || reloads!=LW || writes!=NO || write_acks!=NO || local_reads!=NO || local_returns!=NO) fail("full component counts");
            if(overlaps==0) fail("no next output command overlapped a write");
            if(test_mode==0 && local_first==0) fail("local response did not arrive before write response");
            if(test_mode==1 && write_first==0) fail("write response did not arrive before local response");
            if(test_mode==2 && same_edges==0) fail("both responses did not arrive on same edge");
            if(test_mode==3 && seen_stalls<40) fail("long write command backpressure not exercised");
            passes=passes+1;
        end else begin
            if(write_acks!=expected_count || dut.result_acks!=expected_count) fail("internal confirmed write count differs");
            if(local_errors!=1 || write_errors!=(test_mode==6 ? 0 : 1)) fail("required error combination did not occur");
            if(test_mode==4 && dut.u_wide.command_stall==0) fail("error while prefetch command stalled not exercised");
            if(test_mode==7 && same_edges==0) fail("simultaneous double error not exercised");
            error_cases=error_cases+1;
        end
        rsp_ready=1;@(negedge clk);rsp_ready=0;
        if(holdup || !req_ready) fail("finished instruction retained ownership");
    endtask
    initial begin
        if(!(WBITS==10 || WBITS==12)) fail("unsupported W");
        reset_all();
        // Full twelve-layer sequence, including the three response orderings.
        // Mode3 additionally keeps write0 VALID under forty cycles backpressure.
        for(integer l=0;l<12;l=l+1) begin
            issue(l%4,l,0);finish_case(0,NO);
        end
        // Same-layer retries need no global reset; successful layer11 wraps0.
        issue(4,0,0);finish_case(1,0);
        issue(5,0,5);finish_case(1,5);
        issue(6,0,5);finish_case(1,6);
        issue(7,0,5);finish_case(1,5);
        issue(0,0,0);finish_case(0,NO);
        // Reset while NICE write and accepted local prefetch are both pending.
        issue(1,1,0);
        wait((pending || response_valid) && role==4 && dut.u_wide.pending);
        reset_all();repeat(12) @(negedge clk);
        if(cmd_valid || rsp_valid || holdup || dut.u_wide.pending || dut.u_wide.acc_icb_rsp_valid) fail("global reset retained an operation");
        issue(0,0,0);finish_case(0,NO);
        if(passes!=14 || error_cases!=4 || resets!=2) fail("case totals");
        $display("NICE_FINAL_V43_PROTOCOL_CONTROL_PASS W=%0d O=16 full_pattern_tasks=14 error_cases=4 simultaneous_responses=1 held_write_command=1 offered_local_error_drain=1 sequence_wrap=1 same_layer_retry=1 reset_pending_both=1 physical_loading=0 arithmetic_checked=0",WBITS);
        $finish;
    end
    initial begin #1000000000.0;fail("component timeout");end
endmodule

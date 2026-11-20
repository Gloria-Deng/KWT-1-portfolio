`timescale 1ns/1ps
module tb_frame_repro;
  reg clk=0; always #5 clk=~clk;
  reg rst_n=0,task_reset=0,start=0;
  reg ld_valid=0,ld_space=0; wire ld_ready;
  reg [12:0] ld_addr=0; reg [31:0] ld_data=0;
  reg i_valid=0; wire i_ready; reg signed [15:0] i_data=0;
  wire o_valid; reg o_ready=0; wire [31:0] o_pair;
  wire o_row_last,o_frame_last,busy,done,error,params_valid;
  kwt_ffn_wide #(.WBITS(12),.OBITS(16)) dut(.*);
  reg [31:0] weights[0:6143], params[0:319], expected[0:12671];
  reg [15:0] inputs[0:6335];
  integer k, cycle=0, start_cycle=-1, nout=0, last_cycle=-1;
  always @(posedge clk) begin
    cycle=cycle+1;
    if (start) start_cycle=cycle;
    if (error) $fatal(1,"core reported error at cycle=%0d out=%0d",cycle,nout);
    if(o_valid && o_ready) begin
      if(nout>=12672 || o_pair!==expected[nout])
        $fatal(1,"output mismatch pair=%0d got=%x expected=%x",nout,o_pair,expected[nout]);
      if(o_row_last!==(nout%128==127) || o_frame_last!==(nout==12671))
        $fatal(1,"output last flag mismatch pair=%0d",nout);
      nout=nout+1;
      last_cycle=cycle;
    end
  end
  always @(negedge clk) o_ready <= (cycle%11 != 0 && cycle%11 != 1);
  task automatic load_word(input bit sp,input integer a,input reg [31:0] data);
    ld_valid=1; ld_space=sp; ld_addr=a; ld_data=data;
    @(posedge clk); while(ld_ready!==1'b1) @(posedge clk);
    @(negedge clk);
  endtask
  initial begin
    $readmemh("frame_weights.hex",weights);
    $readmemh("frame_params.hex",params);
    $readmemh("frame_inputs.hex",inputs);
    $readmemh("frame_expected.hex",expected);
    repeat(3) @(negedge clk);
    rst_n=1;
    for(k=0;k<6144;k=k+1) load_word(0,k,weights[k]);
    for(k=0;k<320;k=k+1) load_word(1,k,params[k]);
    ld_valid=0; @(negedge clk);
    if(params_valid!==1'b1) $fatal(1,"parameters did not become valid");
    start=1; @(negedge clk); start=0;
    for(k=0;k<6336;k=k+1) begin
      i_valid=1; i_data=inputs[k];
      @(posedge clk); while(i_ready!==1'b1) @(posedge clk);
      @(negedge clk);
    end
    i_valid=0;
    wait(done===1'b1); @(negedge clk);
    if(error!==1'b0 || nout!=12672 || last_cycle<start_cycle)
      $fatal(1,"invalid terminal state");
    $display("FRAME_PASS W=12 O=16 inputs=6336 pairs=%0d values=%0d start_cycle=%0d final_cycle=%0d elapsed_edges=%0d",nout,2*nout,start_cycle,last_cycle,last_cycle-start_cycle);
    $finish;
  end
  initial begin #3000000; $fatal(1,"frame timeout"); end
endmodule

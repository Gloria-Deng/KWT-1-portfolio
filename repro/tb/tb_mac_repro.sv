`timescale 1ns/1ps
module tb_mac_repro #(parameter W=12);
  reg clk=0; always #5 clk=~clk;
  reg rst_n=0, task_reset=0, en=0, wr_bank=0;
  reg clr=0, clr_bank=0, clr_row=0;
  reg [4:0] clr_addr=0;
  reg signed [15:0] xa=0, xb=0;
  reg [64*W-1:0] w_flat=0;
  reg rd_bank=0, rd_row=0;
  reg [4:0] rd_addr=0;
  wire [65:0] rd_pair;
  wire overflow;
  kwt_mac128_wide #(.W(W)) dut(.*);
  integer f,bank,a,b,k,i,j,r,t,lo,hi;
  reg [64*W-1:0] w;
  initial begin
    f=$fopen(W==10 ? "mac10.txt" : "mac12.txt","r");
    if(!f) $fatal(1,"vector file missing");
    repeat(2) @(negedge clk);
    rst_n=1;
    for(i=0;i<128;i=i+1) begin
      k=$fscanf(f,"%d %d %d %h",bank,a,b,w);
      if(k!=4) $fatal(1,"bad input record");
      wr_bank=bank; xa=a; xb=b; w_flat=w; en=1;
      @(negedge clk);
      if(overflow!==1'b0) $fatal(1,"unexpected overflow");
    end
    en=0;
    for(j=0;j<2;j=j+1) for(r=0;r<2;r=r+1) for(t=0;t<32;t=t+1) begin
      k=$fscanf(f,"%d %d",lo,hi);
      if(k!=2) $fatal(1,"bad expected record");
      rd_bank=j; rd_row=r; rd_addr=t; #1;
      if(rd_pair!=={hi[31],hi[31:0],lo[31],lo[31:0]})
        $fatal(1,"MAC mismatch bank=%0d row=%0d pair=%0d",j,r,t);
    end
    $fclose(f);
    $display("MAC_PASS W=%0d enabled_beats=%0d lane_comparisons=256",W,i);
    $finish;
  end
endmodule

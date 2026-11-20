`timescale 1ns/1ps
module tb_requant_repro;
  reg signed [31:0] acc,bias;
  reg signed [7:0] sh;
  wire signed [15:0] y11,y12,y16;
  kwt_requant_target #(.OUT_BITS(11)) u11(acc,bias,sh,y11);
  kwt_requant_target #(.OUT_BITS(12)) u12(acc,bias,sh,y12);
  kwt_requant_target #(.OUT_BITS(16)) u16(acc,bias,sh,y16);
  integer f,a,b,s,e11,e12,e16,n,k;
  initial begin
    f=$fopen("requant.txt","r");
    if(!f) $fatal(1,"vector file missing");
    n=0;
    while(n<5913) begin
      k=$fscanf(f,"%d %d %d %d %d %d",a,b,s,e11,e12,e16);
      if(k==6) begin
        acc=a; bias=b; sh=s; #1;
        if($signed(y11)!==e11 || $signed(y12)!==e12 || $signed(y16)!==e16)
          $fatal(1,"requant mismatch vector %0d / got %0d %0d %0d",n,y11,y12,y16);
        n=n+1;
      end else $fatal(1,"bad vector record");
    end
    $fclose(f);
    if(n!=5913) $fatal(1,"unexpected vector count %0d",n);
    $display("REQUANT_PASS vectors=%0d widths=3 comparisons=%0d",n,3*n);
    $finish;
  end
endmodule

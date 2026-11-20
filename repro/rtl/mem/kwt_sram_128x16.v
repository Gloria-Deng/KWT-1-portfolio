// Simulation-only single-port memory model. Not a physical SRAM model.
`timescale 1ns/1ps
module kwt_sram_128x16(
  input wire CLK, CEN, WEN,
  input wire [6:0] A,
  input wire [15:0] D,
  output reg [15:0] Q
);
  reg [15:0] words [0:127];
  always @(posedge CLK)
    if (!CEN) begin
      if (!WEN) words[A] <= D;
      else Q <= words[A];
    end
endmodule

// Independent u_core postprocess: INT32 + INT32, RHU, target saturation.
// No system-facing port or memory connection is added by this module.
`timescale 1ns/1ps
module kwt_requant_target #(
    parameter integer OUT_BITS = 12
)(
    input  wire signed [31:0] acc,
    input  wire signed [31:0] bias,
    input  wire signed [7:0]  sh,
    output wire signed [15:0] out
);
    generate
        if ((OUT_BITS == 11) || (OUT_BITS == 12) || (OUT_BITS == 16)) begin : g_valid
            localparam signed [33:0] TARGET_MIN = -(34'sd1 <<< (OUT_BITS-1));
            localparam signed [33:0] TARGET_MAX =  (34'sd1 <<< (OUT_BITS-1)) - 34'sd1;
            wire signed [33:0] sum = {{2{acc[31]}}, acc} + {{2{bias[31]}}, bias};
            wire signed [8:0] sh_extended = {sh[7], sh};
            // Nine bits are necessary: negating signed8 -128 in eight bits
            // would leave -128. The widened negation represents +128 exactly.
            wire [8:0] left_count = -sh_extended;
            reg signed [33:0] half, rounded, right_value;
            reg signed [33:0] left_min, left_max;
            reg signed [OUT_BITS-1:0] narrow_value;
            reg signed [15:0] result;
            assign out = result;

            always @* begin
                half = 34'sd0;
                rounded = sum;
                right_value = sum;
                left_min = TARGET_MIN;
                left_max = TARGET_MAX;
                narrow_value = {OUT_BITS{1'b0}};
                result = 16'sd0;
                if (sh >= 8'sd0) begin
                    // sum is in [-2^32, 2^32-2]. At sh>=33, RHU is zero
                    // including the negative half-tie at sum=-2^32, sh=33.
                    if (sh >= 8'sd33)
                        right_value = 34'sd0;
                    else if (sh > 8'sd0) begin
                        // sh<=32: sum+2^(sh-1) is strictly inside signed34.
                        half = 34'sd1 <<< (sh - 8'sd1);
                        rounded = sum + half;
                        right_value = rounded >>> sh;
                    end
                    if (right_value < TARGET_MIN)
                        result = TARGET_MIN[15:0];
                    else if (right_value > TARGET_MAX)
                        result = TARGET_MAX[15:0];
                    else
                        result = right_value[15:0];
                end else if (left_count >= OUT_BITS) begin
                    // A nonzero integer shifted by >=B cannot fit signed B.
                    if (sum == 34'sd0) result = 16'sd0;
                    else result = sum[33] ? TARGET_MIN[15:0] : TARGET_MAX[15:0];
                end else begin
                    // 1<=L<=B-1: TARGET_MIN=-2^(B-1) is exactly divisible
                    // by 2^L, so arithmetic right shift gives the correct
                    // lower bound (ceil), as well as the upper bound (floor).
                    left_min = TARGET_MIN >>> left_count;
                    left_max = TARGET_MAX >>> left_count;
                    if (sum < left_min)
                        result = TARGET_MIN[15:0];
                    else if (sum > left_max)
                        result = TARGET_MAX[15:0];
                    else begin
                        // Range was checked BEFORE narrowing or left shift.
                        // This B-bit shift is exact; it cannot overflow B bits.
                        narrow_value = $signed(sum[OUT_BITS-1:0]) <<< left_count;
                        result = {{(16-OUT_BITS){narrow_value[OUT_BITS-1]}}, narrow_value};
                    end
                end
            end
        end else begin : g_invalid
            assign out = 16'hxxxx;
            initial $fatal(1, "REQUANT_TARGET_UNSUPPORTED_OUT_BITS");
        end
    endgenerate
endmodule

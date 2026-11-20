// Independent arithmetic state in u_core, not a weight/input/output memory.
// 2 rows x 2 accumulator banks x 64 lanes. W is fixed to 10 or 12.
// Clear wins for its two lanes even if accumulation targets the same bank.
// The first overflowing edge writes the ordinary low 32 bits and raises
// overflow; all later en updates stop until reset. Read and clear remain active.
module kwt_mac128_wide #(
    parameter integer W=10
)(
    input wire clk,
    input wire rst_n,
    input wire task_reset,
    input wire en,
    input wire wr_bank,
    input wire clr,
    input wire clr_bank,
    input wire clr_row,
    input wire [4:0] clr_addr,
    input wire signed [15:0] xa,
    input wire signed [15:0] xb,
    input wire [64*W-1:0] w_flat,
    input wire rd_bank,
    input wire rd_row,
    input wire [4:0] rd_addr,
    output wire [65:0] rd_pair,
    output reg overflow
);
    localparam integer SUPPORTED=(W==10 || W==12);
    reg signed [31:0] acc_a0 [0:63];
    reg signed [31:0] acc_a1 [0:63];
    reg signed [31:0] acc_b0 [0:63];
    reg signed [31:0] acc_b1 [0:63];
    wire [5:0] rlo={rd_addr,1'b0}, rhi={rd_addr,1'b1};
    reg signed [31:0] rd_lo,rd_hi;
    always @* begin
        case({rd_row,rd_bank})
            2'b00: begin rd_lo=acc_a0[rlo];rd_hi=acc_a0[rhi];end
            2'b01: begin rd_lo=acc_a1[rlo];rd_hi=acc_a1[rhi];end
            2'b10: begin rd_lo=acc_b0[rlo];rd_hi=acc_b0[rhi];end
            default: begin rd_lo=acc_b1[rlo];rd_hi=acc_b1[rhi];end
        endcase
    end
    assign rd_pair={rd_hi[31],rd_hi,rd_lo[31],rd_lo};
    wire run=en && !overflow && SUPPORTED;
    wire [63:0] lane_overflow;
    genvar gi;
    generate for(gi=0;gi<64;gi=gi+1) begin: g_pe
        localparam [4:0] PAIR_INDEX=(gi >> 1);
        wire signed [W-1:0] weight=w_flat[gi*W +: W];
        wire signed [16+W-1:0] prod_a=$signed(xa)*$signed(weight);
        wire signed [16+W-1:0] prod_b=$signed(xb)*$signed(weight);
        wire signed [31:0] selected_a=wr_bank ? acc_a1[gi] : acc_a0[gi];
        wire signed [31:0] selected_b=wr_bank ? acc_b1[gi] : acc_b0[gi];
        wire signed [32:0] sum_a=$signed({selected_a[31],selected_a}) +
            $signed({{(17-W){prod_a[15+W]}},prod_a});
        wire signed [32:0] sum_b=$signed({selected_b[31],selected_b}) +
            $signed({{(17-W){prod_b[15+W]}},prod_b});
        wire clear_lane=clr && clr_addr==PAIR_INDEX;
        wire clear_selected_a=clear_lane && !clr_row && clr_bank==wr_bank;
        wire clear_selected_b=clear_lane &&  clr_row && clr_bank==wr_bank;
        assign lane_overflow[gi]=run &&
            ((!clear_selected_a && (sum_a[32]!=sum_a[31])) ||
             (!clear_selected_b && (sum_b[32]!=sum_b[31])));
        always @(posedge clk or negedge rst_n) begin
            if(!rst_n) begin
                acc_a0[gi]<=0;acc_a1[gi]<=0;acc_b0[gi]<=0;acc_b1[gi]<=0;
            end else if(task_reset) begin
                acc_a0[gi]<=0;acc_a1[gi]<=0;acc_b0[gi]<=0;acc_b1[gi]<=0;
            end else begin
                if(clear_lane && !clr_row && !clr_bank) acc_a0[gi]<=0;
                else if(run && !wr_bank) acc_a0[gi]<=sum_a[31:0];
                if(clear_lane && !clr_row && clr_bank) acc_a1[gi]<=0;
                else if(run && wr_bank) acc_a1[gi]<=sum_a[31:0];
                if(clear_lane && clr_row && !clr_bank) acc_b0[gi]<=0;
                else if(run && !wr_bank) acc_b0[gi]<=sum_b[31:0];
                if(clear_lane && clr_row && clr_bank) acc_b1[gi]<=0;
                else if(run && wr_bank) acc_b1[gi]<=sum_b[31:0];
            end
        end
    end endgenerate
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) overflow<=!SUPPORTED;
        else if(task_reset) overflow<=!SUPPORTED;
        else if(|lane_overflow) overflow<=1'b1;
    end
endmodule

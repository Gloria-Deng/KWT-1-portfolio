// Fixed NC=256, private to u_core. No shared-SRAM or external-chip interface.
// 0..255: INT32 bias by channel. 256..319: four INT8 shifts per word.
// A non-conflicting address 0 starts/restarts a COMPLETE 320-word image.
module kwt_param_store (
    input wire clk,
    input wire rst_n,
    input wire task_reset,
    input wire ld_valid,
    output wire ld_ready,
    input wire [8:0] ld_addr,
    input wire [31:0] ld_data,
    input wire rd_req_valid,
    output wire rd_req_ready,
    input wire [8:0] rd_req_pair,
    output wire [31:0] bias_lo32,
    output wire [31:0] bias_hi32,
    output wire [7:0] shift_lo8,
    output wire [7:0] shift_hi8,
    output reg [6:0] rd_pair,
    output reg rd_valid,
    input wire rd_ready,
    output reg params_valid,
    output reg loading,
    output wire error
);
    reg [8:0] expected_addr;
    reg shift_bank_q, error_q;
    assign error=error_q;
    assign ld_ready=rst_n && !task_reset;
    wire conflict=ld_valid && (rd_req_valid || (rd_valid && !rd_ready));
    wire load_attempt=ld_valid && ld_ready;
    wire zero_start=(ld_addr==9'd0);
    wire order_ok=zero_start || (loading && !error_q && ld_addr==expected_addr && ld_addr<9'd320);
    wire write_fire=load_attempt && !conflict && order_ok;
    assign rd_req_ready=rst_n && !task_reset && params_valid && !error_q && !ld_valid &&
                        (rd_req_pair[8:7]==2'b00) && (!rd_valid || rd_ready);
    wire read_fire=rd_req_valid && rd_req_ready;
    wire bad_read=rd_req_valid && !ld_valid &&
                  (!params_valid || error_q || rd_req_pair[8:7]!=2'b00);
    wire bias_write=write_fire && !ld_addr[8];
    wire shift_write=write_fire && ld_addr[8];
    wire even_write=bias_write && !ld_addr[0];
    wire odd_write=bias_write && ld_addr[0];
    wire [6:0] bias_addr=write_fire ? ld_addr[7:1] : rd_req_pair[6:0];
    wire [6:0] shift_addr=write_fire ? {1'b0,ld_addr[5:0]} : {1'b0,rd_req_pair[6:1]};
    wire shift_read0=read_fire && !rd_req_pair[0];
    wire shift_read1=read_fire && rd_req_pair[0];
    wire [15:0] q_b0lo,q_b0hi,q_b1lo,q_b1hi,q_s0,q_s1;
    kwt_sram_128x16 u_bias_even_lo(
        .CLK(clk),.CEN(!(even_write || read_fire)),.WEN(!even_write),
        .A(bias_addr),.D(ld_data[15:0]),.Q(q_b0lo));
    kwt_sram_128x16 u_bias_even_hi(
        .CLK(clk),.CEN(!(even_write || read_fire)),.WEN(!even_write),
        .A(bias_addr),.D(ld_data[31:16]),.Q(q_b0hi));
    kwt_sram_128x16 u_bias_odd_lo(
        .CLK(clk),.CEN(!(odd_write || read_fire)),.WEN(!odd_write),
        .A(bias_addr),.D(ld_data[15:0]),.Q(q_b1lo));
    kwt_sram_128x16 u_bias_odd_hi(
        .CLK(clk),.CEN(!(odd_write || read_fire)),.WEN(!odd_write),
        .A(bias_addr),.D(ld_data[31:16]),.Q(q_b1hi));
    kwt_sram_128x16 u_shift_lo(
        .CLK(clk),.CEN(!(shift_write || shift_read0)),.WEN(!shift_write),
        .A(shift_addr),.D(ld_data[15:0]),.Q(q_s0));
    kwt_sram_128x16 u_shift_hi(
        .CLK(clk),.CEN(!(shift_write || shift_read1)),.WEN(!shift_write),
        .A(shift_addr),.D(ld_data[31:16]),.Q(q_s1));
    wire [15:0] shift_pair=shift_bank_q ? q_s1 : q_s0;
    assign bias_lo32={q_b0hi,q_b0lo};
    assign bias_hi32={q_b1hi,q_b1lo};
    assign shift_lo8=shift_pair[7:0];
    assign shift_hi8=shift_pair[15:8];

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            expected_addr<=0; shift_bank_q<=0; error_q<=0;
            params_valid<=0; loading<=0; rd_pair<=0; rd_valid<=0;
        end else if(task_reset) begin
            expected_addr<=0; shift_bank_q<=0; error_q<=0;
            params_valid<=0; loading<=0; rd_pair<=0; rd_valid<=0;
        end else begin
            if(rd_valid && rd_ready) rd_valid<=0;
            if(read_fire) begin
                shift_bank_q<=rd_req_pair[0]; rd_pair<=rd_req_pair[6:0]; rd_valid<=1;
            end
            if(load_attempt) begin
                if(conflict || !order_ok) begin
                    params_valid<=0; loading<=0; error_q<=1;
                end else if(zero_start) begin
                    params_valid<=0; loading<=1; error_q<=0; expected_addr<=1;
                end else if(ld_addr==9'd319) begin
                    params_valid<=1; loading<=0; expected_addr<=9'd320;
                end else expected_addr<=expected_addr+9'd1;
            end else if(bad_read) begin
                params_valid<=0; loading<=0; error_q<=1;
            end
        end
    end
endmodule

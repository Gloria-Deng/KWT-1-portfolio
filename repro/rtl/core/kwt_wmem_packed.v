// Fixed NC=256, KD=64. u_core-private weights only; no shared-SRAM port.
// Load order: k, group, packed 32-bit word. Zero address starts a full reload.
// Read row is {group[1:0], k[5:0]}, never a linear load-word address.
module kwt_wmem_packed #(
    parameter integer W=10
)(
    input wire clk,
    input wire rst_n,
    input wire task_reset,
    input wire ld_valid,
    output wire ld_ready,
    input wire [12:0] ld_addr,
    input wire [31:0] ld_data,
    input wire rd_req_valid,
    output wire rd_req_ready,
    input wire [9:0] rd_req_addr,
    output wire [64*W-1:0] rd_data,
    output reg rd_valid,
    input wire rd_ready,
    output reg [7:0] rd_row,
    output reg params_valid,
    output reg loading,
    output wire error
);
    localparam integer SUPPORTED=(W==10 || W==12);
    localparam integer WW=(W==12) ? 12 : 10;
    localparam integer SLICES=4*WW;
    localparam integer WORDS_PER_GROUP=2*WW;
    localparam integer TOTAL_WORDS=512*WW;
    reg [12:0] expected_addr;
    reg [5:0] load_k;
    reg [1:0] load_group;
    reg [4:0] load_word;
    reg bank_q, error_q;
    assign error=error_q || !SUPPORTED;
    assign ld_ready=rst_n && !task_reset && SUPPORTED;
    // A blocked read result owns its macro outputs until consumed/reset.
    wire conflict=ld_valid && (rd_req_valid || (rd_valid && !rd_ready));
    wire load_attempt=ld_valid && ld_ready;
    wire zero_start=(ld_addr==13'd0);
    wire load_order_ok=zero_start ||
        (loading && !error && ld_addr==expected_addr && ld_addr<TOTAL_WORDS);
    wire write_fire=load_attempt && !conflict && load_order_ok;
    assign rd_req_ready=rst_n && !task_reset && params_valid && !error &&
                        !ld_valid && (rd_req_addr[9:8]==2'b00) &&
                        (!rd_valid || rd_ready);
    wire read_fire=rd_req_valid && rd_req_ready;
    wire invalid_read=rd_req_valid && !ld_valid &&
                      (!params_valid || error || rd_req_addr[9:8]!=2'b00);
    wire [5:0] write_k=zero_start ? 6'd0 : load_k;
    wire [1:0] write_group=zero_start ? 2'd0 : load_group;
    wire [4:0] write_word=zero_start ? 5'd0 : load_word;
    wire [7:0] write_row={write_group,write_k};
    wire [6:0] macro_addr=write_fire ? write_row[6:0] : rd_req_addr[6:0];
    wire [15:0] q0 [0:SLICES-1];
    wire [15:0] q1 [0:SLICES-1];
    genvar slice;
    generate
        for (slice=0; slice<SLICES; slice=slice+1) begin: g_slice
            // All indices and half-word choices below are elaboration constants.
            wire selected=write_fire && (write_word==(slice >> 1));
            wire wr0=selected && !write_row[7];
            wire wr1=selected && write_row[7];
            wire rr0=read_fire && !rd_req_addr[7];
            wire rr1=read_fire && rd_req_addr[7];
            wire [15:0] data_half;
            if ((slice & 1)==0) begin: g_low
                assign data_half=ld_data[15:0];
            end else begin: g_high
                assign data_half=ld_data[31:16];
            end
            kwt_sram_128x16 u_b0(
                .CLK(clk), .CEN(!(wr0 || rr0)), .WEN(!wr0),
                .A(macro_addr), .D(data_half), .Q(q0[slice]));
            kwt_sram_128x16 u_b1(
                .CLK(clk), .CEN(!(wr1 || rr1)), .WEN(!wr1),
                .A(macro_addr), .D(data_half), .Q(q1[slice]));
            assign rd_data[16*slice +: 16]=bank_q ? q1[slice] : q0[slice];
        end
    endgenerate

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            expected_addr<=0; load_k<=0; load_group<=0; load_word<=0;
            params_valid<=0; loading<=0; error_q<=0;
            bank_q<=0; rd_row<=0; rd_valid<=0;
        end else if (task_reset) begin
            expected_addr<=0; load_k<=0; load_group<=0; load_word<=0;
            params_valid<=0; loading<=0; error_q<=0;
            bank_q<=0; rd_row<=0; rd_valid<=0;
        end else begin
            if (rd_valid && rd_ready) rd_valid<=0;
            if (read_fire) begin
                bank_q<=rd_req_addr[7]; rd_row<=rd_req_addr[7:0]; rd_valid<=1;
            end
            if (load_attempt) begin
                if (conflict || !load_order_ok) begin
                    params_valid<=0; loading<=0; error_q<=1;
                end else if (zero_start) begin
                    params_valid<=0; loading<=1; error_q<=0;
                    expected_addr<=1; load_k<=0; load_group<=0; load_word<=1;
                end else if (ld_addr==TOTAL_WORDS-1) begin
                    params_valid<=1; loading<=0;
                    expected_addr<=TOTAL_WORDS;
                end else begin
                    expected_addr<=expected_addr+13'd1;
                    if (load_word==WORDS_PER_GROUP-1) begin
                        load_word<=0;
                        if (load_group==2'd3) begin
                            load_group<=0; load_k<=load_k+6'd1;
                        end else load_group<=load_group+2'd1;
                    end else load_word<=load_word+5'd1;
                end
            end else if (invalid_read) begin
                // Incomplete/out-of-range access cannot advertise an old row.
                params_valid<=0; loading<=0; error_q<=1;
            end
        end
    end
endmodule

// u_core-private four-row cache: 4 x prescribed 128x16 single-port macros.
// Sequential input: 99 rows x 64 INT16. Explicit pair ownership and repeated reads.
// No shared-SRAM interface; no behavior-level input data array.
module kwt_input_rows4(
    input wire clk,
    input wire rst_n,
    input wire task_reset,
    input wire in_valid,
    output wire in_ready,
    input wire signed [15:0] in_data,
    output wire pair_available,
    input wire pair_start,
    input wire pair_release,
    output reg pair_active,
    output wire [6:0] pair_row,
    output reg pair_has_b,
    input wire rd_req_valid,
    output wire rd_req_ready,
    input wire [5:0] rd_req_k,
    output reg rd_valid,
    input wire rd_ready,
    output wire signed [15:0] rd_xa,
    output wire signed [15:0] rd_xb,
    output reg [5:0] rd_k,
    output reg [6:0] rd_row,
    output wire frame_done,
    output reg error
);
    reg [3:0] full;
    reg [6:0] written_rows,released_rows;
    reg [5:0] write_k;
    reg cursor,read_cursor_q,read_b_q;
    wire [1:0] bank_a={cursor,1'b0},bank_b={cursor,1'b1};
    wire need_b=(released_rows<7'd98);
    assign pair_row=released_rows;
    assign frame_done=(released_rows==7'd99);
    assign pair_available=rst_n && !task_reset && !error && !frame_done && !pair_active &&
                          full[bank_a] && (!need_b || full[bank_b]);
    // Start/release are one-cycle control commands, not ready/valid streams.
    // No combined start+read, start+release, or release+new-read operation.
    wire bad_start=pair_start && (!pair_available || pair_release || rd_req_valid);
    wire bad_release=pair_release && (!pair_active || pair_start || rd_req_valid ||
                                    (rd_valid && !rd_ready));
    wire bad_read=rd_req_valid && !pair_active;
    wire protocol_bad=bad_start || bad_release || bad_read;
    wire usable=rst_n && !task_reset && !error && !protocol_bad;
    assign in_ready=usable && written_rows<7'd99 && !full[written_rows[1:0]];
    wire input_fire=in_valid && in_ready;
    assign rd_req_ready=usable && pair_active && !pair_start && !pair_release &&
                        (!rd_valid || rd_ready);
    wire read_fire=rd_req_valid && rd_req_ready;
    wire start_fire=usable && pair_start;
    wire release_fire=usable && pair_release;
    wire [15:0] q [0:3];
    genvar i;
    generate for(i=0;i<4;i=i+1) begin: g_row
        wire wr=input_fire && written_rows[1:0]==i;
        wire rr=read_fire && (bank_a==i || (pair_has_b && bank_b==i));
        wire [6:0] address=wr ? {1'b0,write_k} : {1'b0,rd_req_k};
        kwt_sram_128x16 u_macro(
            .CLK(clk),.CEN(!(wr || rr)),.WEN(!wr),.A(address),.D(in_data),.Q(q[i]));
    end endgenerate
    assign rd_xa=$signed(q[{read_cursor_q,1'b0}]);
    assign rd_xb=read_b_q ? $signed(q[{read_cursor_q,1'b1}]) : 16'sd0;

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            full<=0;written_rows<=0;released_rows<=0;write_k<=0;cursor<=0;
            pair_active<=0;pair_has_b<=0;rd_valid<=0;rd_k<=0;rd_row<=0;
            read_cursor_q<=0;read_b_q<=0;error<=0;
        end else if(task_reset) begin
            full<=0;written_rows<=0;released_rows<=0;write_k<=0;cursor<=0;
            pair_active<=0;pair_has_b<=0;rd_valid<=0;rd_k<=0;rd_row<=0;
            read_cursor_q<=0;read_b_q<=0;error<=0;
        end else begin
            if(rd_valid && rd_ready) rd_valid<=0;
            if(read_fire) begin
                rd_valid<=1;rd_k<=rd_req_k;rd_row<=released_rows;
                read_cursor_q<=cursor;read_b_q<=pair_has_b;
            end
            if(protocol_bad) error<=1;
            if(input_fire) begin
                if(write_k==6'd63) begin
                    full[written_rows[1:0]]<=1;
                    written_rows<=written_rows+7'd1;write_k<=0;
                end else write_k<=write_k+6'd1;
            end
            if(start_fire) begin
                pair_active<=1;pair_has_b<=need_b;
            end
            if(release_fire) begin
                full[bank_a]<=0;
                if(pair_has_b) full[bank_b]<=0;
                released_rows<=released_rows+(pair_has_b ? 7'd2 : 7'd1);
                pair_active<=0;pair_has_b<=0;cursor<=~cursor;
            end
        end
    end
endmodule

// Independent 99x64 -> 99x256 first-linear core. Output remains INT16 containers.
// Three 256x32 result banks use 12 prescribed 128x16 macros, no data arrays.
module kwt_ffn_wide #(
    parameter integer WBITS=10, OBITS=12
)(
    input wire clk,rst_n,task_reset,start,
    input wire ld_valid,
    output wire ld_ready,
    input wire ld_space,
    input wire [12:0] ld_addr,
    input wire [31:0] ld_data,
    input wire i_valid,
    output wire i_ready,
    input wire signed [15:0] i_data,
    output wire o_valid,
    input wire o_ready,
    output wire [31:0] o_pair,
    output wire o_row_last,o_frame_last,
    output wire busy,
    output reg done,
    output wire error,params_valid
);
    reg running,error_q;
    reg [12:0] received_inputs;
    reg [14:0] emitted_pairs,captured_pairs;
    wire engine_error,engine_params,engine_ld_ready,engine_i_ready;
    assign error=error_q || engine_error;
    assign params_valid=engine_params && !error;
    assign busy=rst_n && !task_reset && running && !error;
    wire bad_start=start && (running || done || !params_valid || ld_valid || i_valid);
    wire bad_load=ld_valid && (running || done || start || error);
    wire go=rst_n && !task_reset && start && !bad_start && !error;
    assign ld_ready=!running && !done && !start && !error && engine_ld_ready;
    assign i_ready=busy && engine_i_ready && received_inputs<13'd6336;
    wire input_fire=i_valid && i_ready;
    wire raw_valid,raw_ready,raw_pair_end,engine_finished;
    wire [31:0] raw_pair;
    wire [6:0] raw_row,raw_channel_pair;
    kwt_lineng_wide #(.WBITS(WBITS),.OBITS(OBITS)) u_engine(
        .clk(clk),.rst_n(rst_n),.task_reset(task_reset),.start(go),.halt(error_q),
        .ld_valid(ld_valid && !bad_load && !error),.ld_ready(engine_ld_ready),
        .ld_space(ld_space),.ld_addr(ld_addr),.ld_data(ld_data),
        .i_valid(i_valid && busy && received_inputs<13'd6336),.i_ready(engine_i_ready),.i_data(i_data),
        .o_valid(raw_valid),.o_ready(raw_ready),.o_pair(raw_pair),
        .o_row(raw_row),.o_channel_pair(raw_channel_pair),.o_pair_end(raw_pair_end),
        .params_valid(engine_params),.error(engine_error),.finished(engine_finished));

    reg [2:0] full;
    reg [2:0] bank_has_b;
    reg [6:0] bank_row [0:2]; // Control metadata only, never output payload.
    reg [1:0] writer,reader;
    reg [6:0] expected_pair_row;
    wire write_fire=raw_valid && raw_ready;
    assign raw_ready=busy && !full[writer];
    wire [7:0] write_pos={raw_row[0],raw_channel_pair};
    reg read_active,a_valid;
    reg [8:0] read_next,read_length;
    reg [1:0] a_bank;
    reg [7:0] a_pos;
    reg [6:0] a_row_base;
    wire output_fire=o_valid && o_ready;
    wire start_read=!read_active && full[reader] && !a_valid;
    wire continue_read=read_active && read_next<read_length && (!a_valid || output_fire);
    wire read_issue=rst_n && !task_reset && !error && running && (start_read || continue_read);
    wire [7:0] read_pos=start_read ? 8'd0 : read_next[7:0];
    wire [15:0] q_lo0 [0:2],q_hi0 [0:2],q_lo1 [0:2],q_hi1 [0:2];
    genvar b;
    generate for(b=0;b<3;b=b+1) begin: g_result
        wire wr=write_fire && writer==b;
        wire rr=read_issue && reader==b;
        wire [7:0] address=wr ? write_pos : read_pos;
        wire en0=(wr || rr) && !address[7];
        wire en1=(wr || rr) && address[7];
        kwt_sram_128x16 u_lo0(.CLK(clk),.CEN(!en0),.WEN(!wr),.A(address[6:0]),.D(raw_pair[15:0]),.Q(q_lo0[b]));
        kwt_sram_128x16 u_hi0(.CLK(clk),.CEN(!en0),.WEN(!wr),.A(address[6:0]),.D(raw_pair[31:16]),.Q(q_hi0[b]));
        kwt_sram_128x16 u_lo1(.CLK(clk),.CEN(!en1),.WEN(!wr),.A(address[6:0]),.D(raw_pair[15:0]),.Q(q_lo1[b]));
        kwt_sram_128x16 u_hi1(.CLK(clk),.CEN(!en1),.WEN(!wr),.A(address[6:0]),.D(raw_pair[31:16]),.Q(q_hi1[b]));
    end endgenerate
    // The macro Q itself is the holding stage. A sealed bank remains owned
    // until its LAST RETURN is consumed, not merely until its last read issues.
    assign o_valid=a_valid && rst_n && !task_reset;
    assign o_pair=a_pos[7] ? {q_hi1[a_bank],q_lo1[a_bank]} : {q_hi0[a_bank],q_lo0[a_bank]};
    wire [6:0] absolute_row=a_row_base+{6'd0,a_pos[7]};
    assign o_row_last=o_valid && a_pos[6:0]==7'd127;
    assign o_frame_last=o_row_last && absolute_row==7'd98;
    wire bank_return_last=output_fire &&
        (a_pos==(bank_has_b[a_bank] ? 8'd255 : 8'd127));
    wire raw_position_bad=write_fire &&
        (raw_row[6:1]!=expected_pair_row[6:1] || raw_row>98 ||
         captured_pairs>=15'd12672 ||
         (raw_pair_end && (raw_channel_pair!=127 || !(raw_row[0] || raw_row==98))));
    wire output_position_bad=output_fire &&
        (emitted_pairs>=15'd12672 || absolute_row!=emitted_pairs[14:7] ||
         a_pos[6:0]!=emitted_pairs[6:0]);
    // A newly detected fault wins even when the final output is accepted on
    // this edge. Looking only at registered error would allow done to win.
    wire fault_now=bad_start || bad_load || engine_error || raw_position_bad || output_position_bad ||
                   (busy && i_valid && received_inputs==6336) ||
                   (write_fire && read_issue && writer==reader);
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            running<=0;error_q<=0;done<=0;received_inputs<=0;emitted_pairs<=0;captured_pairs<=0;
            full<=0;bank_has_b<=0;writer<=0;reader<=0;expected_pair_row<=0;
            bank_row[0]<=0;bank_row[1]<=0;bank_row[2]<=0;
            read_active<=0;a_valid<=0;read_next<=0;read_length<=0;
            a_bank<=0;a_pos<=0;a_row_base<=0;
        end else if(task_reset) begin
            running<=0;error_q<=0;done<=0;received_inputs<=0;emitted_pairs<=0;captured_pairs<=0;
            full<=0;bank_has_b<=0;writer<=0;reader<=0;expected_pair_row<=0;
            bank_row[0]<=0;bank_row[1]<=0;bank_row[2]<=0;
            read_active<=0;a_valid<=0;read_next<=0;read_length<=0;
            a_bank<=0;a_pos<=0;a_row_base<=0;
        end else begin
            if(fault_now) begin
                error_q<=1;running<=0;done<=0;
            end else if(go) running<=1;
            if(input_fire) received_inputs<=received_inputs+13'd1;
            if(write_fire) begin
                captured_pairs<=captured_pairs+15'd1;
                bank_row[writer]<={raw_row[6:1],1'b0};
                if(raw_pair_end) begin
                    full[writer]<=1;bank_has_b[writer]<=raw_row!=98;
                    writer<=writer==2 ? 2'd0 : writer+2'd1;
                    expected_pair_row<=expected_pair_row+7'd2;
                end
            end
            if(output_fire) begin
                a_valid<=0;emitted_pairs<=emitted_pairs+15'd1;
                if(o_frame_last && !error && !fault_now) begin
                    if(emitted_pairs!=12671 || received_inputs!=6336 || !engine_finished) begin
                        error_q<=1;running<=0;done<=0;
                    end else begin running<=0;done<=1;end
                end
            end
            if(read_issue) begin
                a_valid<=1;a_bank<=reader;a_pos<=read_pos;a_row_base<=bank_row[reader];
                read_next<={1'b0,read_pos}+9'd1;
                if(start_read) begin
                    read_active<=1;read_length<=bank_has_b[reader] ? 9'd256 : 9'd128;
                end
            end
            if(bank_return_last) begin
                full[a_bank]<=0;read_active<=0;
                reader<=reader==2 ? 2'd0 : reader+2'd1;
            end
        end
    end
endmodule

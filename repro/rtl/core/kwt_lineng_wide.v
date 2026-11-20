// Independent first-linear engine. All memories are prescribed macros below u_core.
// Output is group-interleaved; kwt_ffn_wide restores complete row order.
module kwt_lineng_wide #(
    parameter integer WBITS=10, OBITS=12
)(
    input wire clk,rst_n,task_reset,start,halt,
    input wire ld_valid,ld_space,
    output wire ld_ready,
    input wire [12:0] ld_addr,
    input wire [31:0] ld_data,
    input wire i_valid,
    output wire i_ready,
    input wire signed [15:0] i_data,
    output wire o_valid,
    input wire o_ready,
    output wire [31:0] o_pair,
    output wire [6:0] o_row,o_channel_pair,
    output wire o_pair_end,
    output wire params_valid,error,
    output reg finished
);
    localparam [1:0] WAIT_PAIR=0, PRIME=1, RUN=2, WAIT_SWAP=3;
    reg [1:0] state,group;
    reg running,error_q,mac_bank;
    reg [6:0] row_base,issue_k;
    reg [5:0] mac_k;
    reg has_b;
    wire wfull,pfull,werr,perr,xerr,overflow;
    wire config_ok=(WBITS==10 || WBITS==12) && (OBITS==11 || OBITS==12 || OBITS==16);
    assign error=error_q || werr || perr || xerr || overflow || !config_ok;
    assign params_valid=wfull && pfull && !error;
    wire allowed=rst_n && !task_reset && running && !halt && !error;
    wire param_address_bad=ld_valid && ld_space && ld_addr>13'd319;
    wire wld=ld_valid && !ld_space && !running && !error && !halt;
    wire pld=ld_valid && ld_space && !param_address_bad && !running && !error && !halt;
    wire wld_ready,pld_ready;
    // u_parameters.ld_ready is exactly rst_n && !task_reset, already required
    // here. Bad parameter addresses remain accepted and reported below.
    assign ld_ready=rst_n && !task_reset && !running && !halt && !error &&
                    (ld_space ? 1'b1 : wld_ready);

    wire wreq_ready,wvalid,wconsume;
    wire [64*WBITS-1:0] weights;
    wire [7:0] wrow;
    wire xreq_ready,xvalid,xconsume,pair_available,pair_active,pair_has_b;
    wire [6:0] pair_row,xrow;
    wire [5:0] xk;
    wire signed [15:0] xa,xb;
    wire pair_begin=allowed && state==WAIT_PAIR && pair_available;
    wire issue_want=allowed && (state==PRIME || state==RUN) && issue_k<7'd64;
    wire wreq=issue_want && xreq_ready;
    wire xreq=issue_want && wreq_ready;
    wire issue_fire=issue_want && wreq_ready && xreq_ready;
    wire tags_ok=(wrow=={group,mac_k}) && xk==mac_k && xrow==row_base;
    wire mac_allow=allowed && state==RUN && tags_ok;
    wire mac_fire=mac_allow && wvalid && xvalid;
    assign wconsume=mac_allow && xvalid;
    assign xconsume=mac_allow && wvalid;
    wire final_input=mac_fire && mac_k==6'd63 && group==2'd3;
    wire cache_in_ready;
    assign i_ready=allowed && cache_in_ready;

    kwt_wmem_packed #(.W(WBITS)) u_weights(
        .clk(clk),.rst_n(rst_n),.task_reset(task_reset),
        .ld_valid(wld),.ld_ready(wld_ready),.ld_addr(ld_addr),.ld_data(ld_data),
        .rd_req_valid(wreq),.rd_req_ready(wreq_ready),.rd_req_addr({2'b00,group,issue_k[5:0]}),
        .rd_data(weights),.rd_valid(wvalid),.rd_ready(wconsume),.rd_row(wrow),
        .params_valid(wfull),.loading(),.error(werr));
    kwt_input_rows4 u_inputs(
        .clk(clk),.rst_n(rst_n),.task_reset(task_reset),
        .in_valid(i_valid && allowed),.in_ready(cache_in_ready),.in_data(i_data),
        .pair_available(pair_available),.pair_start(pair_begin),.pair_release(final_input),
        .pair_active(pair_active),.pair_row(pair_row),.pair_has_b(pair_has_b),
        .rd_req_valid(xreq),.rd_req_ready(xreq_ready),.rd_req_k(issue_k[5:0]),
        .rd_valid(xvalid),.rd_ready(xconsume),.rd_xa(xa),.rd_xb(xb),.rd_k(xk),.rd_row(xrow),
        .frame_done(),.error(xerr));

    reg drain_active,drain_bank,drain_has_b;
    reg [1:0] drain_group;
    reg [6:0] drain_row;
    reg [5:0] drain_pos;
    wire drain_last=drain_pos==(drain_has_b ? 6'd63 : 6'd31);
    wire [6:0] drain_pair={drain_group,drain_pos[4:0]};
    wire pv,pready;
    wire [6:0] returned_pair;
    wire [31:0] blo,bhi;
    wire [7:0] slo,shi;
    wire drain_tag_ok=(returned_pair==drain_pair);
    // A stalled raw result remains presented while all producing state holds.
    assign o_valid=rst_n && !task_reset && drain_active && pv && drain_tag_ok;
    wire drain_fire=o_valid && o_ready && !halt && !error;
    wire want_swap=allowed && !drain_active &&
                   ((state==RUN && mac_fire && mac_k==6'd63) || state==WAIT_SWAP);
    wire do_swap=want_swap && pready;
    wire next_parameter=drain_fire && !drain_last;
    wire parameter_req=want_swap || next_parameter;
    wire [4:0] next_pair=(drain_pos[4:0]==31) ? 5'd0 : drain_pos[4:0]+5'd1;
    wire [6:0] parameter_addr=want_swap ? {group,5'd0} : {drain_group,next_pair};
    kwt_param_store u_parameters(
        .clk(clk),.rst_n(rst_n),.task_reset(task_reset),
        .ld_valid(pld),.ld_ready(pld_ready),.ld_addr(ld_addr[8:0]),.ld_data(ld_data),
        .rd_req_valid(parameter_req),.rd_req_ready(pready),.rd_req_pair({2'b00,parameter_addr}),
        .bias_lo32(blo),.bias_hi32(bhi),.shift_lo8(slo),.shift_hi8(shi),
        .rd_pair(returned_pair),.rd_valid(pv),.rd_ready(drain_fire),
        .params_valid(pfull),.loading(),.error(perr));
    wire [65:0] acc_pair;
    kwt_mac128_wide #(.W(WBITS)) u_mac(
        .clk(clk),.rst_n(rst_n),.task_reset(task_reset),.en(mac_fire),.wr_bank(mac_bank),
        .clr(drain_fire),.clr_bank(drain_bank),.clr_row(drain_pos[5]),.clr_addr(drain_pos[4:0]),
        .xa(xa),.xb(has_b ? xb : 16'sd0),.w_flat(weights),
        .rd_bank(drain_bank),.rd_row(drain_pos[5]),.rd_addr(drain_pos[4:0]),
        .rd_pair(acc_pair),.overflow(overflow));
    wire signed [15:0] rq_lo,rq_hi;
    kwt_requant_target #(.OUT_BITS(OBITS)) u_rq0(
        .acc(acc_pair[31:0]),.bias(blo),.sh($signed(slo)),.out(rq_lo));
    kwt_requant_target #(.OUT_BITS(OBITS)) u_rq1(
        .acc(acc_pair[64:33]),.bias(bhi),.sh($signed(shi)),.out(rq_hi));
    assign o_pair={rq_hi,rq_lo};
    assign o_row=drain_row+{6'd0,drain_pos[5]};
    assign o_channel_pair=drain_pair;
    assign o_pair_end=drain_group==2'd3 && drain_last;

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=WAIT_PAIR;group<=0;running<=0;error_q<=0;mac_bank<=0;
            row_base<=0;issue_k<=0;mac_k<=0;has_b<=0;finished<=0;
            drain_active<=0;drain_bank<=0;drain_has_b<=0;
            drain_group<=0;drain_row<=0;drain_pos<=0;
        end else if(task_reset) begin
            state<=WAIT_PAIR;group<=0;running<=0;error_q<=0;mac_bank<=0;
            row_base<=0;issue_k<=0;mac_k<=0;has_b<=0;finished<=0;
            drain_active<=0;drain_bank<=0;drain_has_b<=0;
            drain_group<=0;drain_row<=0;drain_pos<=0;
        end else begin
            if(param_address_bad || (ld_valid && running) ||
               (state==RUN && wvalid && xvalid && !tags_ok) ||
               (drain_active && pv && !drain_tag_ok) ||
               (mac_fire && drain_active && mac_bank==drain_bank) ||
               (drain_fire && (acc_pair[32]!=acc_pair[31] || acc_pair[65]!=acc_pair[64])))
                error_q<=1;
            if(start) begin
                if(running || !params_valid || finished) error_q<=1;
                else begin running<=1;state<=WAIT_PAIR;end
            end
            if(pair_begin) begin
                row_base<=pair_row;has_b<=pair_row<98;group<=0;
                issue_k<=0;mac_k<=0;state<=PRIME;
            end
            if(issue_fire) begin
                issue_k<=issue_k+7'd1;
                if(state==PRIME) state<=RUN;
            end
            if(mac_fire) begin
                if(mac_k==63) state<=WAIT_SWAP;
                else mac_k<=mac_k+6'd1;
            end
            if(drain_fire) begin
                if(drain_last) begin
                    drain_active<=0;
                    if(drain_row==98 && drain_group==3) begin running<=0;finished<=1;end
                end else drain_pos<=drain_pos+6'd1;
            end
            if(do_swap) begin
                drain_active<=1;drain_bank<=mac_bank;drain_has_b<=has_b;
                drain_group<=group;drain_row<=row_base;drain_pos<=0;
                mac_bank<=~mac_bank;issue_k<=0;mac_k<=0;
                if(group==3) state<=WAIT_PAIR;
                else begin group<=group+2'd1;state<=PRIME;end
            end
        end
    end
endmodule

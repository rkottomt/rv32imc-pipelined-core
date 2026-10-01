// rv_icache.v - 2-way set-associative instruction cache.
//
//  * 16-byte lines (4 words), LRU replacement, SETS sets  (default 4 KiB).
//  * Pipelined: a request is accepted every cycle; hits respond the next
//    cycle (tag RAM is async-read LUT RAM, data RAM is synchronous BRAM).
//  * Miss: blocks, refills the line word-by-word from the memory bus
//    (requested word captured on the way), responds, then resumes.
//  * `invalidate` (FENCE.I) clears every valid bit in one cycle. A refill
//    that is in flight when invalidate arrives is not installed, because it
//    may have read memory before the D-cache was flushed.
module rv_icache #(
    parameter SET_BITS = 7
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        invalidate,

    input  wire        req_valid,
    input  wire [31:0] req_addr,
    output wire        req_ready,
    output wire        resp_valid,
    output wire [31:0] resp_data,

    output wire        m_req_valid,
    output wire [31:0] m_req_addr,
    input  wire        m_req_ready,
    input  wire        m_resp_valid,
    input  wire [31:0] m_resp_data,

    output wire        stat_miss
);
    localparam SETS  = 1 << SET_BITS;
    localparam TAG_W = 32 - 4 - SET_BITS;

    // address fields
    function [SET_BITS-1:0] idx_of(input [31:0] a); idx_of = a[4 +: SET_BITS]; endfunction
    function [TAG_W-1:0]    tag_of(input [31:0] a); tag_of = a[31 -: TAG_W];   endfunction

    reg [TAG_W-1:0] tag0 [0:SETS-1];
    reg [TAG_W-1:0] tag1 [0:SETS-1];
    reg [SETS-1:0]  v0, v1;
    reg [SETS-1:0]  lru;           // 1: way 1 is least recently used

    localparam S_IDLE = 2'd0, S_REQ = 2'd1, S_WAIT = 2'd2, S_RESP = 2'd3;
    reg [1:0]  state;
    reg        s1_valid;
    reg [31:0] s1_addr;
    reg [1:0]  cnt;
    reg        victim;
    reg [31:0] crit;               // captured requested word
    reg        kill_refill;

    wire [SET_BITS-1:0] s1_idx = idx_of(s1_addr);
    wire hit0 = v0[s1_idx] && tag0[s1_idx] == tag_of(s1_addr);
    wire hit1 = v1[s1_idx] && tag1[s1_idx] == tag_of(s1_addr);
    wire hit  = hit0 || hit1;
    wire lookup_hit  = state == S_IDLE && s1_valid && hit;
    wire lookup_miss = state == S_IDLE && s1_valid && !hit;

    assign req_ready = state == S_IDLE && !lookup_miss;
    wire accept = req_valid && req_ready;

    // data RAMs: address = {set, word}
    wire [31:0] d0, d1;
    wire [SET_BITS+1:0] raddr = req_addr[2 +: SET_BITS + 2];
    wire [SET_BITS+1:0] waddr = {s1_idx, cnt};
    wire wr_line = state == S_WAIT && m_resp_valid;
    rv_sram #(.AW(SET_BITS + 2)) u_d0 (.clk(clk), .re(accept), .raddr(raddr), .rdata(d0),
        .we({4{wr_line && !victim}}), .waddr(waddr), .wdata(m_resp_data));
    rv_sram #(.AW(SET_BITS + 2)) u_d1 (.clk(clk), .re(accept), .raddr(raddr), .rdata(d1),
        .we({4{wr_line && victim}}), .waddr(waddr), .wdata(m_resp_data));

    assign resp_valid = lookup_hit || state == S_RESP;
    assign resp_data  = state == S_RESP ? crit : (hit0 ? d0 : d1);

    assign m_req_valid = state == S_REQ;
    assign m_req_addr  = {s1_addr[31:4], cnt, 2'b00};
    assign stat_miss   = lookup_miss;

    always @(posedge clk) begin
        if (rst) begin
            state    <= S_IDLE;
            s1_valid <= 1'b0;
            v0 <= 0; v1 <= 0; lru <= 0;
            kill_refill <= 1'b0;
        end else begin
            if (invalidate) begin
                v0 <= 0; v1 <= 0;
                if (state != S_IDLE) kill_refill <= 1'b1;
            end
            case (state)
            S_IDLE: begin
                if (lookup_hit)
                    lru[s1_idx] <= hit0;           // the other way becomes LRU
                if (lookup_miss) begin
                    state  <= S_REQ;
                    cnt    <= 2'd0;
                    victim <= !v0[s1_idx] ? 1'b0 : !v1[s1_idx] ? 1'b1 : lru[s1_idx];
                    kill_refill <= 1'b0;
                end else begin
                    s1_valid <= accept;
                    if (accept) s1_addr <= req_addr;
                end
            end
            S_REQ: if (m_req_ready) state <= S_WAIT;
            S_WAIT: if (m_resp_valid) begin
                if (cnt == s1_addr[3:2]) crit <= m_resp_data;
                cnt <= cnt + 2'd1;
                if (cnt == 2'd3) begin
                    state <= S_RESP;
                    if (!(kill_refill || invalidate)) begin
                        if (victim) begin tag1[s1_idx] <= tag_of(s1_addr); v1[s1_idx] <= 1'b1; end
                        else        begin tag0[s1_idx] <= tag_of(s1_addr); v0[s1_idx] <= 1'b1; end
                        lru[s1_idx] <= !victim;
                    end
                end else
                    state <= S_REQ;
            end
            S_RESP: begin
                state    <= S_IDLE;
                s1_valid <= 1'b0;
            end
            endcase
        end
    end
endmodule

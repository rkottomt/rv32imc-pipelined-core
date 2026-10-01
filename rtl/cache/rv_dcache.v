// rv_dcache.v - 2-way set-associative, write-back, write-allocate data cache.
//
//  * 16-byte lines, LRU, SETS sets (default 4 KiB). Hits take 1 cycle
//    (respond the cycle after the request is accepted) and the cache can
//    accept the next request in that same cycle.
//  * Store hits write the data RAM with byte enables and set the line dirty.
//    A load directly after a store to the same word would read stale data
//    from the RAM (read-during-write), so the last store is bypassed.
//  * Miss: if the victim line is dirty it is written back first, then the
//    line is refilled, then the lookup is replayed (and now hits).
//  * Addresses outside the cacheable region bypass the cache (MMIO).
//  * A `flush` request (issued by the core for FENCE.I) writes back every
//    dirty line; it is only accepted once the flush is complete, so the core
//    cannot fetch past the FENCE.I before memory is up to date.
module rv_dcache #(
    parameter SET_BITS = 7,
    parameter [31:0] CACHEABLE_MASK = 32'hFE00_0000,  // addr & MASK == BASE -> cacheable
    parameter [31:0] CACHEABLE_BASE = 32'h0000_0000
) (
    input  wire        clk,
    input  wire        rst,

    input  wire        req_valid,
    input  wire [31:0] req_addr,
    input  wire        req_we,
    input  wire [3:0]  req_be,
    input  wire [31:0] req_wdata,
    input  wire        req_flush,
    output wire        req_ready,
    output wire        resp_valid,
    output wire [31:0] resp_rdata,

    output reg         m_req_valid,
    output reg  [31:0] m_req_addr,
    output reg         m_req_we,
    output reg  [3:0]  m_req_be,
    output reg  [31:0] m_req_wdata,
    input  wire        m_req_ready,
    input  wire        m_resp_valid,
    input  wire [31:0] m_resp_rdata,

    output wire        stat_miss,
    output wire        stat_writeback
);
    localparam SETS  = 1 << SET_BITS;
    localparam TAG_W = 32 - 4 - SET_BITS;

    reg [TAG_W-1:0] tag0 [0:SETS-1];
    reg [TAG_W-1:0] tag1 [0:SETS-1];
    reg [SETS-1:0]  v0, v1, dirty0, dirty1, lru;

    localparam S_IDLE   = 4'd0,  // lookup stage lives here (s1_valid)
               S_WB_RD  = 4'd1,  // read victim word from data RAM
               S_WB_REQ = 4'd2,  // send it to memory
               S_WB_WT  = 4'd3,  // wait for write ack
               S_RF_REQ = 4'd4,  // request refill word
               S_RF_WT  = 4'd5,  // wait for refill word
               S_REPLAY = 4'd6,  // re-read arrays for the pending request
               S_UC_REQ = 4'd7,  // uncached access
               S_UC_WT  = 4'd8,
               S_UC_RSP = 4'd9,
               S_FLUSH  = 4'd10, // scan for dirty lines
               S_FL_DONE= 4'd11; // flush complete: accept the flush request
    reg [3:0]  state;

    // ---------------- lookup stage register
    reg        s1_valid, s1_we, s1_flush;
    reg [31:0] s1_addr, s1_wdata;
    reg [3:0]  s1_be;
    wire [SET_BITS-1:0] s1_idx = s1_addr[4 +: SET_BITS];
    wire [TAG_W-1:0]    s1_tag = s1_addr[31 -: TAG_W];
    wire s1_cacheable = (s1_addr & CACHEABLE_MASK) == CACHEABLE_BASE;

    // Tag match is computed when the data RAM read is issued (request accept
    // or replay) and registered, so the lookup cycle only has to select a
    // way. Tags/valid bits cannot change in between: they are only written
    // during refills, and a request is never accepted while one is pending.
    reg  hit0_q, hit1_q;
    wire hit0 = hit0_q;
    wire hit1 = hit1_q;
    wire hit  = hit0 || hit1;
    wire in_lookup   = state == S_IDLE && s1_valid;
    wire lookup_hit  = in_lookup && (s1_flush || (s1_cacheable && hit));
    wire lookup_miss = in_lookup && !s1_flush && s1_cacheable && !hit;
    wire lookup_unc  = in_lookup && !s1_flush && !s1_cacheable;

    // ---------------- miss handling registers
    reg        victim;
    reg [SET_BITS-1:0] m_idx;      // set being written back / refilled
    reg [TAG_W-1:0]    wb_tag;
    reg [1:0]  cnt;
    reg        fl_way;
    reg [SET_BITS-1:0] fl_set;
    reg        wb_to_flush;        // return to the flush scan after write-back
    reg [31:0] uc_rdata;

    // ---------------- request acceptance
    // flush requests are only accepted in S_FL_DONE
    wire idle_free = state == S_IDLE && (!s1_valid || lookup_hit);
    assign req_ready = (idle_free && !req_flush) || (state == S_FL_DONE && req_flush);
    wire accept = req_valid && req_ready;

    // ---------------- data RAMs
    wire [31:0] d0, d1;
    reg  [SET_BITS+1:0] ram_raddr;
    reg                 ram_re;
    reg  [3:0]          we0, we1;
    reg  [SET_BITS+1:0] ram_waddr;
    reg  [31:0]         ram_wdata;
    rv_sram #(.AW(SET_BITS + 2)) u_d0 (.clk(clk), .re(ram_re), .raddr(ram_raddr), .rdata(d0),
                                     .we(we0), .waddr(ram_waddr), .wdata(ram_wdata));
    rv_sram #(.AW(SET_BITS + 2)) u_d1 (.clk(clk), .re(ram_re), .raddr(ram_raddr), .rdata(d1),
                                     .we(we1), .waddr(ram_waddr), .wdata(ram_wdata));

    // store -> load bypass (write in cycle N, RAM read issued in cycle N)
    reg        byp_valid, byp_way;
    reg [SET_BITS+1:0] byp_addr;
    reg [3:0]  byp_be;
    reg [31:0] byp_data;
    function [31:0] merge(input [31:0] old, input [3:0] be, input [31:0] nw);
        merge = {be[3] ? nw[31:24] : old[31:24], be[2] ? nw[23:16] : old[23:16],
                 be[1] ? nw[15:8]  : old[15:8],  be[0] ? nw[7:0]   : old[7:0]};
    endfunction
    wire byp_hit = byp_valid && byp_addr == s1_addr[2 +: SET_BITS + 2];
    wire [31:0] d0m = (byp_hit && !byp_way) ? merge(d0, byp_be, byp_data) : d0;
    wire [31:0] d1m = (byp_hit &&  byp_way) ? merge(d1, byp_be, byp_data) : d1;

    assign resp_valid = (lookup_hit) || state == S_UC_RSP;
    assign resp_rdata = state == S_UC_RSP ? uc_rdata : (hit0 ? d0m : d1m);
    assign stat_miss  = lookup_miss;
    assign stat_writeback = state == S_WB_WT && m_resp_valid && cnt == 2'd3;

    wire [31:0] la = (state == S_REPLAY) ? s1_addr : req_addr;   // address being looked up
    wire [SET_BITS-1:0] la_idx = la[4 +: SET_BITS];
    wire [TAG_W-1:0]    la_tag = la[31 -: TAG_W];
    always @(posedge clk) begin
        if (ram_re) begin
            hit0_q <= v0[la_idx] && tag0[la_idx] == la_tag;
            hit1_q <= v1[la_idx] && tag1[la_idx] == la_tag;
        end
    end

    wire victim_sel = !v0[s1_idx] ? 1'b0 : !v1[s1_idx] ? 1'b1 : lru[s1_idx];
    wire victim_dirty = victim_sel ? (v1[s1_idx] && dirty1[s1_idx]) : (v0[s1_idx] && dirty0[s1_idx]);

    // ---------------- RAM port control (combinational)
    always @(*) begin
        ram_re    = 1'b0;
        ram_raddr = req_addr[2 +: SET_BITS + 2];
        we0 = 4'd0; we1 = 4'd0;
        ram_waddr = s1_addr[2 +: SET_BITS + 2];
        ram_wdata = s1_wdata;
        case (state)
            S_IDLE: begin
                ram_re = accept;
                if (lookup_hit && !s1_flush && s1_we) begin
                    we0 = hit0 ? s1_be : 4'd0;
                    we1 = hit1 ? s1_be : 4'd0;
                end
            end
            S_FL_DONE: ram_re = 1'b0;
            S_WB_RD:   begin ram_re = 1'b1; ram_raddr = {m_idx, cnt}; end
            S_RF_WT:   begin
                ram_waddr = {m_idx, cnt};
                ram_wdata = m_resp_rdata;
                if (m_resp_valid) begin
                    we0 = victim ? 4'd0 : 4'hf;
                    we1 = victim ? 4'hf : 4'd0;
                end
            end
            S_REPLAY:  begin ram_re = 1'b1; ram_raddr = s1_addr[2 +: SET_BITS + 2]; end
            default: ;
        endcase
    end

    // ---------------- memory-side request (combinational)
    always @(*) begin
        m_req_valid = 1'b0;
        m_req_we    = 1'b0;
        m_req_be    = 4'hf;
        m_req_addr  = {s1_addr[31:4], cnt, 2'b00};
        m_req_wdata = victim ? d1 : d0;
        case (state)
            S_WB_REQ: begin
                m_req_valid = 1'b1;
                m_req_we    = 1'b1;
                m_req_addr  = {wb_tag, m_idx, cnt, 2'b00};
            end
            S_RF_REQ: m_req_valid = 1'b1;
            S_UC_REQ: begin
                m_req_valid = 1'b1;
                m_req_addr  = {s1_addr[31:2], 2'b00};
                m_req_we    = s1_we;
                m_req_be    = s1_be;
                m_req_wdata = s1_wdata;
            end
            default: ;
        endcase
    end

    // ---------------- sequential control
    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            s1_valid <= 1'b0;
            v0 <= 0; v1 <= 0; dirty0 <= 0; dirty1 <= 0; lru <= 0;
            byp_valid <= 1'b0;
        end else begin
            byp_valid <= 1'b0;
            case (state)
            S_IDLE: begin
                if (lookup_hit && !s1_flush) begin
                    lru[s1_idx] <= hit0;
                    if (s1_we) begin
                        if (hit0) dirty0[s1_idx] <= 1'b1; else dirty1[s1_idx] <= 1'b1;
                        byp_valid <= 1'b1;
                        byp_way   <= hit1;
                        byp_addr  <= s1_addr[2 +: SET_BITS + 2];
                        byp_be    <= s1_be;
                        byp_data  <= s1_wdata;
                    end
                end
                if (lookup_miss) begin
                    victim <= victim_sel;
                    m_idx  <= s1_idx;
                    cnt    <= 2'd0;
                    wb_to_flush <= 1'b0;
                    wb_tag <= victim_sel ? tag1[s1_idx] : tag0[s1_idx];
                    state  <= victim_dirty ? S_WB_RD : S_RF_REQ;
                end else if (lookup_unc) begin
                    state <= S_UC_REQ;
                end else begin
                    s1_valid <= accept;
                    if (accept) begin
                        s1_addr  <= req_addr;
                        s1_we    <= req_we;
                        s1_be    <= req_be;
                        s1_wdata <= req_wdata;
                        s1_flush <= 1'b0;
                    end else if (req_valid && req_flush && !s1_valid) begin
                        state  <= S_FLUSH;
                        fl_set <= 0;
                        fl_way <= 1'b0;
                    end
                end
            end
            // ---- write-back of a dirty line (victim / flush)
            S_WB_RD:  state <= S_WB_REQ;
            S_WB_REQ: if (m_req_ready) state <= S_WB_WT;
            S_WB_WT:  if (m_resp_valid) begin
                cnt <= cnt + 2'd1;
                if (cnt == 2'd3) begin
                    if (victim) dirty1[m_idx] <= 1'b0; else dirty0[m_idx] <= 1'b0;
                    state <= wb_to_flush ? S_FLUSH : S_RF_REQ;
                end else
                    state <= S_WB_RD;
            end
            // ---- refill
            S_RF_REQ: if (m_req_ready) state <= S_RF_WT;
            S_RF_WT:  if (m_resp_valid) begin
                cnt <= cnt + 2'd1;
                if (cnt == 2'd3) begin
                    if (victim) begin tag1[m_idx] <= s1_tag; v1[m_idx] <= 1'b1; dirty1[m_idx] <= 1'b0; end
                    else        begin tag0[m_idx] <= s1_tag; v0[m_idx] <= 1'b1; dirty0[m_idx] <= 1'b0; end
                    state <= S_REPLAY;
                end else
                    state <= S_RF_REQ;
            end
            S_REPLAY: state <= S_IDLE;     // s1 still valid -> lookup hits now
            // ---- uncached
            S_UC_REQ: if (m_req_ready) state <= S_UC_WT;
            S_UC_WT:  if (m_resp_valid) begin uc_rdata <= m_resp_rdata; state <= S_UC_RSP; end
            S_UC_RSP: begin state <= S_IDLE; s1_valid <= 1'b0; end
            // ---- flush: scan every (set, way), write back dirty lines
            S_FLUSH: begin
                if (fl_way ? (v1[fl_set] && dirty1[fl_set]) : (v0[fl_set] && dirty0[fl_set])) begin
                    victim      <= fl_way;
                    m_idx       <= fl_set;
                    wb_tag      <= fl_way ? tag1[fl_set] : tag0[fl_set];
                    cnt         <= 2'd0;
                    wb_to_flush <= 1'b1;
                    state       <= S_WB_RD;
                end else begin
                    fl_way <= !fl_way;
                    if (fl_way) begin
                        fl_set <= fl_set + 1'b1;
                        if (fl_set == SETS - 1) state <= S_FL_DONE;
                    end
                end
            end
            S_FL_DONE: if (!(req_valid && req_flush)) begin
                // request was withdrawn (e.g. an interrupt took priority)
                state <= S_IDLE;
            end else begin
                // respond to the flush request through the normal lookup path
                state    <= S_IDLE;
                s1_valid <= 1'b1;
                s1_flush <= 1'b1;
                s1_we    <= 1'b0;
            end
            default: state <= S_IDLE;
            endcase
        end
    end
endmodule

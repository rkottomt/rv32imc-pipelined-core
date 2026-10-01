// rv_frontend.v - Decoupled instruction fetch unit.
//
//  IF stage: issues word-aligned fetch requests (one per cycle, pipelined,
//            up to FQ_DEPTH outstanding+buffered) and consults the branch
//            predictor (BTB + gshare BHT + return address stack) on the
//            fetch address to choose the next fetch address.
//  Fetch queue: holds fetched 32-bit words with their prediction metadata.
//  Aligner: carves the word stream into 16-bit (RVC) and 32-bit instructions,
//            including 32-bit instructions that straddle two words, and hands
//            one instruction per cycle to the decode stage.
//
// Prediction metadata travels with every instruction (`out_pred_npc`); the
// EX stage compares it with the real next PC and redirects on a mismatch,
// so the predictor can never affect correctness, only performance.
`include "rv_defs.vh"

module rv_frontend #(
    parameter        ENABLE_BP  = 1,
    parameter        BTB_BITS   = 6,    // 64-entry direct-mapped BTB
    parameter        BHT_BITS   = 8,    // 256 x 2-bit counters
    parameter        RAS_DEPTH  = 4
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [31:0] boot_addr,

    // Instruction bus
    output wire        ibus_req_valid,
    output wire [31:0] ibus_req_addr,
    input  wire        ibus_req_ready,
    input  wire        ibus_resp_valid,
    input  wire [31:0] ibus_resp_data,

    // Redirect from the back end (mispredict / trap / mret / fence.i)
    input  wire        redirect_valid,
    input  wire [31:0] redirect_pc,

    // Instruction to decode
    output wire        out_valid,
    input  wire        out_ready,
    output wire [31:0] out_pc,
    output wire [31:0] out_insn,      // RVC instructions in [15:0], upper half 0
    output wire        out_is_c,
    output wire        out_pred_taken,
    output wire [31:0] out_pred_npc,
    output wire [BHT_BITS-1:0] out_bht_idx,

    // Predictor training from EX
    input  wire        upd_valid,
    input  wire [31:0] upd_pc,
    input  wire        upd_is_c,
    input  wire [1:0]  upd_type,
    input  wire        upd_taken,
    input  wire [31:0] upd_target,
    input  wire [BHT_BITS-1:0] upd_bht_idx,

    output wire        stat_fixup     // aligner had to repair a stale prediction
);
    localparam FQ_DEPTH = 4;
    localparam PW = 2;                // pointer width (log2 FQ_DEPTH)

    // ------------------------------------------------------------------
    // Branch predictor storage
    localparam BTB_N = 1 << BTB_BITS;
    localparam BHT_N = 1 << BHT_BITS;
    localparam TAG_W = 30 - BTB_BITS;

    reg             btb_v   [0:BTB_N-1];
    reg [TAG_W-1:0] btb_tag [0:BTB_N-1];
    reg             btb_off [0:BTB_N-1];   // instruction starts at word+2
    reg             btb_xe  [0:BTB_N-1];   // 32-bit instruction that started in the
                                           // previous word and ends in this one
    reg [1:0]       btb_typ [0:BTB_N-1];
    reg             btb_c   [0:BTB_N-1];   // instruction is compressed
    reg [31:1]      btb_tgt [0:BTB_N-1];
    reg [1:0]       bht     [0:BHT_N-1];
    reg [BHT_BITS-1:0] ghr;
    reg [31:0]      ras [0:RAS_DEPTH-1];
    reg [$clog2(RAS_DEPTH)-1:0] ras_top;    // points at most recent entry

    // ------------------------------------------------------------------
    // Fetch queue
    reg [31:0] fq_data [0:FQ_DEPTH-1];
    reg [31:2] fq_addr [0:FQ_DEPTH-1];
    reg        fq_start[0:FQ_DEPTH-1];   // first valid halfword is the upper one
    reg        fq_pv   [0:FQ_DEPTH-1];   // carries a taken prediction
    reg        fq_poff [0:FQ_DEPTH-1];   // halfword offset of predicted instruction
    reg        fq_pxe  [0:FQ_DEPTH-1];   // prediction is for the instruction ending here
    reg [31:0] fq_ptgt [0:FQ_DEPTH-1];
    reg [BHT_BITS-1:0] fq_bidx [0:FQ_DEPTH-1];
    reg        fq_fill [0:FQ_DEPTH-1];   // data has arrived

    reg [PW:0] head, tail, fillp;
    reg [2:0]  inflight;                 // requests issued, response pending
    reg [2:0]  drop;                     // in-flight responses to discard
    reg [31:0] fpc;                      // next fetch address (bit 1 = start offset)
    reg        pos;                      // aligner position within head word

    wire [PW:0] count = tail - head;

    // ------------------------------------------------------------------
    // IF: request + prediction
    wire [BTB_BITS-1:0] f_bi  = fpc[2 +: BTB_BITS];
    wire [TAG_W-1:0]    f_tag = fpc[31 -: TAG_W];
    wire [BHT_BITS-1:0] f_hi  = fpc[2 +: BHT_BITS] ^ ghr;
    wire f_hit   = btb_v[f_bi] && (btb_tag[f_bi] == f_tag) && (btb_off[f_bi] >= fpc[1]);
    wire f_cond  = (btb_typ[f_bi] == `BT_COND);
    wire f_taken = (ENABLE_BP != 0) && f_hit && (!f_cond || bht[f_hi][1]);
    wire [31:0] f_target = (btb_typ[f_bi] == `BT_RET) ? ras[ras_top] : {btb_tgt[f_bi], 1'b0};
    // return address of a predicted call: for a straddling call (xe) the
    // instruction started 2 bytes before this word, so it ends at word+2
    wire [31:0] f_insn_pc = {fpc[31:2], btb_off[f_bi], 1'b0};
    wire [31:0] f_ret_addr = btb_xe[f_bi] ? {fpc[31:2], 2'b10} :
                             f_insn_pc + (btb_c[f_bi] ? 32'd2 : 32'd4);

    assign ibus_req_valid = (count < FQ_DEPTH);
    assign ibus_req_addr  = {fpc[31:2], 2'b00};
    wire req_fire = ibus_req_valid && ibus_req_ready;

    // ------------------------------------------------------------------
    // Aligner (combinational view of the queue head)
    wire [PW-1:0] h = head[PW-1:0];
    wire [PW-1:0] n = head[PW-1:0] + 1'b1;
    wire hv = (count >= 1) && fq_fill[h];
    wire nv = (count >= 2) && fq_fill[n];
    wire p  = pos | fq_start[h];
    wire [15:0] lo16 = p ? fq_data[h][31:16] : fq_data[h][15:0];
    wire is32     = (lo16[1:0] == 2'b11);
    wire straddle = p && is32;
    wire avail    = hv && (!straddle || nv);

    wire pv   = fq_pv[h];
    wire poff = fq_poff[h];
    wire pxe  = fq_pxe[h];
    // A straddling instruction takes its prediction from the *next* word
    // (where it ends), flagged "xe".
    wire xmatch    = straddle && nv && fq_pv[n] && fq_pxe[n];
    wire pmatch    = (pv && !pxe && (p == poff) && !straddle) || xmatch;
    // A stale/aliased prediction points at a halfword that is not the start of
    // an instruction (or at a straddling instruction), or an "xe" prediction
    // reached the head without the straddling instruction that owns it:
    // drop it and refetch sequentially.
    wire pmismatch = pv && (pxe || (p && !poff) || (p == poff && straddle) || (!p && poff && is32));
    wire fixup = hv && pmismatch && !redirect_valid;

    assign out_valid      = avail && !pmismatch;
    assign out_pc         = {fq_addr[h], p, 1'b0};
    assign out_insn       = !is32 ? {16'd0, lo16} :
                            straddle ? {fq_data[n][15:0], lo16} : fq_data[h];
    assign out_is_c       = !is32;
    assign out_pred_taken = pmatch;
    assign out_pred_npc   = xmatch ? fq_ptgt[n] : pmatch ? fq_ptgt[h] : out_pc + (is32 ? 32'd4 : 32'd2);
    assign out_bht_idx    = straddle ? fq_bidx[n] : fq_bidx[h];
    assign stat_fixup     = fixup;

    wire consume = out_valid && out_ready && !redirect_valid;
    // pop the head word after this instruction?
    wire pop     = consume && (pmatch || is32 || p);
    wire pop2    = consume && xmatch;          // straddling predicted-taken: drop both words
    wire pos_nxt = xmatch ? 1'b0 : straddle ? 1'b1 : (!is32 && !p && !pmatch) ? 1'b1 : 1'b0;

    wire [2:0] inflight_nxt = inflight + (req_fire ? 3'd1 : 3'd0) - (ibus_resp_valid ? 3'd1 : 3'd0);
    wire resp_keep = ibus_resp_valid && (drop == 3'd0);

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            head <= 0; tail <= 0; fillp <= 0;
            inflight <= 0; drop <= 0;
            fpc <= boot_addr;
            pos <= 1'b0;
            for (i = 0; i < FQ_DEPTH; i = i + 1) begin
                fq_fill[i] <= 1'b0;
                fq_pv[i]   <= 1'b0;
            end
        end else begin
            inflight <= inflight_nxt;
            if (ibus_resp_valid && drop != 3'd0) drop <= drop - 3'd1;

            if (redirect_valid) begin
                // Flush everything; all in-flight responses are now stale.
                head <= 0; tail <= 0; fillp <= 0;
                drop <= inflight_nxt;
                fpc  <= redirect_pc;
                pos  <= 1'b0;
            end else if (fixup) begin
                // Keep the head word, discard everything younger, clear the
                // bogus prediction and continue sequentially after the head.
                fq_pv[h] <= 1'b0;
                tail     <= head + 1'b1;
                fillp    <= head + 1'b1;
                drop     <= inflight_nxt;
                fpc      <= {fq_addr[h] + 30'd1, 2'b00};
            end else begin
                if (req_fire) begin
                    fq_addr [tail[PW-1:0]] <= fpc[31:2];
                    fq_start[tail[PW-1:0]] <= fpc[1];
                    fq_pv   [tail[PW-1:0]] <= f_taken;
                    fq_poff [tail[PW-1:0]] <= btb_off[f_bi];
                    fq_pxe  [tail[PW-1:0]] <= btb_xe[f_bi];
                    fq_ptgt [tail[PW-1:0]] <= f_target;
                    fq_bidx [tail[PW-1:0]] <= f_hi;
                    fq_fill [tail[PW-1:0]] <= 1'b0;
                    tail <= tail + 1'b1;
                    fpc  <= f_taken ? f_target : {fpc[31:2] + 30'd1, 2'b00};
                end
                if (resp_keep) begin
                    fq_data[fillp[PW-1:0]] <= ibus_resp_data;
                    fq_fill[fillp[PW-1:0]] <= 1'b1;
                    fillp <= fillp + 1'b1;
                end
                if (consume) begin
                    if (pop2)     head <= head + 2'd2;
                    else if (pop) head <= head + 1'b1;
                    pos <= pos_nxt;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // Return address stack (speculative, updated at fetch time)
    always @(posedge clk) begin
        if (rst) begin
            ras_top <= 0;
        end else if (req_fire && f_taken && !redirect_valid && !fixup) begin
            if (btb_typ[f_bi] == `BT_CALL) begin
                ras[ras_top + 1'b1] <= f_ret_addr;
                ras_top <= ras_top + 1'b1;
            end else if (btb_typ[f_bi] == `BT_RET) begin
                ras_top <= ras_top - 1'b1;
            end
        end
    end

    // ------------------------------------------------------------------
    // Predictor training (non-speculative, from EX)
    // A 32-bit instruction at word+2 straddles two fetch words: it is
    // installed under the word where it *ends* (pc+2), flagged "xe".
    wire        u_xe   = upd_pc[1] && !upd_is_c;
    wire [31:0] u_key  = u_xe ? upd_pc + 32'd2 : upd_pc;
    wire [BTB_BITS-1:0] u_bi = u_key[2 +: BTB_BITS];
    wire u_alloc = upd_taken;
    integer b;
    always @(posedge clk) begin
        if (rst) begin
            ghr <= 0;
            for (b = 0; b < BTB_N; b = b + 1) btb_v[b] <= 1'b0;
            for (b = 0; b < BHT_N; b = b + 1) bht[b] <= 2'b01;
        end else if (upd_valid) begin
            if (upd_type == `BT_COND) begin
                ghr <= {ghr[BHT_BITS-2:0], upd_taken};
                if (upd_taken && bht[upd_bht_idx] != 2'b11) bht[upd_bht_idx] <= bht[upd_bht_idx] + 2'd1;
                if (!upd_taken && bht[upd_bht_idx] != 2'b00) bht[upd_bht_idx] <= bht[upd_bht_idx] - 2'd1;
            end
            if (u_alloc) begin
                btb_v  [u_bi] <= 1'b1;
                btb_tag[u_bi] <= u_key[31 -: TAG_W];
                btb_off[u_bi] <= u_xe ? 1'b0 : upd_pc[1];
                btb_xe [u_bi] <= u_xe;
                btb_typ[u_bi] <= upd_type;
                btb_c  [u_bi] <= upd_is_c;
                btb_tgt[u_bi] <= upd_target[31:1];
            end
        end
    end
endmodule

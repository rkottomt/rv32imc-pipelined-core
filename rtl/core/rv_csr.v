// rv_csr.v - Machine-mode CSR file, trap / interrupt logic and counters.
//
// The CSR file is accessed from the MEM stage so that CSR side effects,
// traps and MRET are all applied in program order at a single commit point.
`include "rv_defs.vh"

module rv_csr #(
    parameter [31:0] HART_ID = 32'd0,
    parameter        NUM_HPM = 6          // mhpmcounter3 .. 3+NUM_HPM-1
) (
    input  wire        clk,
    input  wire        rst,

    // CSR instruction access (combinational read, write on `wr_en`)
    input  wire [11:0] addr,
    input  wire        access,    // a CSR instruction is in MEM
    input  wire        wr_intent, // instruction would write the CSR
    output reg  [31:0] rdata,
    output wire        illegal,   // nonexistent CSR / write to read-only CSR
    input  wire        wr_en,     // commit the write this cycle
    input  wire [31:0] wdata,     // final (post RW/RS/RC) value

    // Trap / return (applied on the commit cycle)
    input  wire        trap,
    input  wire        trap_is_irq,
    input  wire [4:0]  trap_cause,
    input  wire [31:0] trap_pc,
    input  wire [31:0] trap_tval,
    input  wire        mret,
    output wire [31:0] trap_vector,   // handler address for (trap_is_irq, trap_cause)
    output wire [31:0] mepc_o,

    // Interrupts
    input  wire        irq_software,
    input  wire        irq_timer,
    input  wire        irq_external,
    output wire        irq_pending,   // an enabled interrupt should be taken
    output reg  [4:0]  irq_cause,

    // Counters / events
    input  wire        retire,
    input  wire [NUM_HPM-1:0] hpm_events
);
    // ------------------------------------------------------------------
    // State
    reg        mstatus_mie, mstatus_mpie;
    reg [31:0] mtvec, mscratch, mepc, mcause, mtval;
    reg        mie_msie, mie_mtie, mie_meie;
    reg [63:0] mcycle, minstret;
    reg [63:0] hpm [0:NUM_HPM-1];

    wire [31:0] mstatus = {19'b0, 2'b11 /*MPP=M*/, 3'b0, mstatus_mpie, 3'b0, mstatus_mie, 3'b0};
    wire [31:0] misa    = 32'h40001104;   // RV32 I M C
    wire [31:0] mie     = {20'b0, mie_meie, 3'b0, mie_mtie, 3'b0, mie_msie, 3'b0};
    wire [31:0] mip     = {20'b0, irq_external, 3'b0, irq_timer, 3'b0, irq_software, 3'b0};

    assign mepc_o = mepc;

    // ------------------------------------------------------------------
    // Read mux + legality
    reg known;
    wire [4:0] hpm_idx = addr[4:0] - 5'd3;
    always @(*) begin
        known = 1'b1;
        rdata = 32'd0;
        case (addr)
            `CSR_MSTATUS:   rdata = mstatus;
            `CSR_MISA:      rdata = misa;
            `CSR_MIE:       rdata = mie;
            `CSR_MTVEC:     rdata = mtvec;
            `CSR_MSTATUSH:  rdata = 32'd0;
            `CSR_MCOUNTINH: rdata = 32'd0;
            `CSR_MSCRATCH:  rdata = mscratch;
            `CSR_MEPC:      rdata = mepc;
            `CSR_MCAUSE:    rdata = mcause;
            `CSR_MTVAL:     rdata = mtval;
            `CSR_MIP:       rdata = mip;
            `CSR_MCYCLE,   `CSR_CYCLE:    rdata = mcycle[31:0];
            `CSR_MCYCLEH,  `CSR_CYCLEH:   rdata = mcycle[63:32];
            `CSR_MINSTRET, `CSR_INSTRET:  rdata = minstret[31:0];
            `CSR_MINSTRETH,`CSR_INSTRETH: rdata = minstret[63:32];
            `CSR_MVENDORID, `CSR_MARCHID, `CSR_MIMPID: rdata = 32'd0;
            `CSR_MHARTID:   rdata = HART_ID;
            default: begin
                known = 1'b0;
                // mhpmcounter3..31 (0xB03-0xB1F), mhpmcounter3h.. (0xB83-0xB9F),
                // hpmcounter3.. (0xC03-0xC1F, 0xC83-0xC9F), mhpmevent3.. (0x323-0x33F)
                if (addr[11:5] == 7'b1011000 || addr[11:5] == 7'b1011100 ||
                    addr[11:5] == 7'b1100000 || addr[11:5] == 7'b1100100 ||
                    addr[11:5] == 7'b0011001) begin
                    if (addr[4:0] >= 5'd3) begin
                        known = 1'b1;
                        if (hpm_idx < NUM_HPM && addr[11:5] != 7'b0011001)
                            rdata = addr[7] ? hpm[hpm_idx][63:32] : hpm[hpm_idx][31:0];
                    end
                end
            end
        endcase
    end

    wire read_only = (addr[11:10] == 2'b11);
    assign illegal = access && (!known || (read_only && wr_intent));

    // ------------------------------------------------------------------
    // Interrupts: priority MEI > MSI > MTI
    wire meip_en = irq_external & mie_meie;
    wire msip_en = irq_software & mie_msie;
    wire mtip_en = irq_timer    & mie_mtie;
    assign irq_pending = mstatus_mie & (meip_en | msip_en | mtip_en);
    always @(*) begin
        if (meip_en)      irq_cause = 5'd11;
        else if (msip_en) irq_cause = 5'd3;
        else              irq_cause = 5'd7;
    end

    wire mtvec_vec = (mtvec[1:0] == 2'b01);
    assign trap_vector = (mtvec_vec && trap_is_irq) ? {mtvec[31:2], 2'b00} + {25'd0, trap_cause, 2'b00}
                                                   : {mtvec[31:2], 2'b00};

    // ------------------------------------------------------------------
    // Updates
    wire wr = wr_en && !illegal;
    integer j;
    always @(posedge clk) begin
        if (rst) begin
            mstatus_mie  <= 1'b0;
            mstatus_mpie <= 1'b0;
            mtvec        <= 32'd0;
            mscratch     <= 32'd0;
            mepc         <= 32'd0;
            mcause       <= 32'd0;
            mtval        <= 32'd0;
            mie_msie     <= 1'b0;
            mie_mtie     <= 1'b0;
            mie_meie     <= 1'b0;
            mcycle       <= 64'd0;
            minstret     <= 64'd0;
            for (j = 0; j < NUM_HPM; j = j + 1) hpm[j] <= 64'd0;
        end else begin
            // free-running counters (an explicit CSR write below takes priority)
            // (writes to either half suppress the increment for that cycle)
            if (!(wr && (addr == `CSR_MCYCLE || addr == `CSR_MCYCLEH)))
                mcycle <= mcycle + 64'd1;
            if (retire && !(wr && (addr == `CSR_MINSTRET || addr == `CSR_MINSTRETH)))
                minstret <= minstret + 64'd1;
            for (j = 0; j < NUM_HPM; j = j + 1)
                if (hpm_events[j]) hpm[j] <= hpm[j] + 64'd1;

            if (trap) begin
                mepc         <= {trap_pc[31:1], 1'b0};
                mcause       <= {trap_is_irq, 26'd0, trap_cause};
                mtval        <= trap_tval;
                mstatus_mpie <= mstatus_mie;
                mstatus_mie  <= 1'b0;
            end else if (mret) begin
                mstatus_mie  <= mstatus_mpie;
                mstatus_mpie <= 1'b1;
            end else if (wr) begin
                case (addr)
                    `CSR_MSTATUS: begin
                        mstatus_mie  <= wdata[3];
                        mstatus_mpie <= wdata[7];
                    end
                    `CSR_MIE: begin
                        mie_msie <= wdata[3];
                        mie_mtie <= wdata[7];
                        mie_meie <= wdata[11];
                    end
                    `CSR_MTVEC:    mtvec    <= {wdata[31:2], 1'b0, wdata[0]};
                    `CSR_MSCRATCH: mscratch <= wdata;
                    `CSR_MEPC:     mepc     <= {wdata[31:1], 1'b0};
                    `CSR_MCAUSE:   mcause   <= wdata;
                    `CSR_MTVAL:    mtval    <= wdata;
                    `CSR_MCYCLE:   mcycle[31:0]    <= wdata;
                    `CSR_MCYCLEH:  mcycle[63:32]   <= wdata;
                    `CSR_MINSTRET: minstret[31:0]  <= wdata;
                    `CSR_MINSTRETH:minstret[63:32] <= wdata;
                    default: begin
                        for (j = 0; j < NUM_HPM; j = j + 1) begin
                            if (addr == 12'hB03 + j) hpm[j][31:0]  <= wdata;
                            if (addr == 12'hB83 + j) hpm[j][63:32] <= wdata;
                        end
                    end
                endcase
            end
        end
    end
endmodule

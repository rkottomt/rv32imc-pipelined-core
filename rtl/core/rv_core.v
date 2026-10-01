// rv_core.v - RV32IMC_Zicsr 5-stage in-order pipelined core.
//
//   IF  : rv_frontend issues fetches, predicts, buffers words      (rv_frontend.v)
//   ID  : align / RVC-expand / decode / register read / hazards
//   EX  : ALU, branch resolution + mispredict redirect, MUL, DIV (iterative)
//   MEM : data-bus request, CSR access, trap / interrupt / MRET commit point
//   WB  : load data alignment, register write-back, retirement (RVFI)
//
// Forwarding: EX operands are bypassed from EX/MEM and MEM/WB.
// Hazards   : 1-cycle load-use (and CSR-use) stall in ID; divider stalls EX;
//             data-bus back-pressure stalls MEM/WB.
// Precise exceptions are taken in MEM; all older instructions are already in
// WB (and will complete), all younger ones are flushed.
`include "rv_defs.vh"

module rv_core #(
    parameter [31:0] HART_ID   = 32'd0,
    parameter        ENABLE_BP = 1
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [31:0] boot_addr,       // reset vector

    // Instruction bus (in-order, pipelined, >=1 cycle latency)
    output wire        ibus_req_valid,
    output wire [31:0] ibus_req_addr,
    input  wire        ibus_req_ready,
    input  wire        ibus_resp_valid,
    input  wire [31:0] ibus_resp_data,

    // Data bus (one outstanding request, >=1 cycle latency)
    output wire        dbus_req_valid,
    output wire [31:0] dbus_req_addr,
    output wire        dbus_req_we,
    output wire [3:0]  dbus_req_be,
    output wire [31:0] dbus_req_wdata,
    input  wire        dbus_req_ready,
    input  wire        dbus_resp_valid,
    input  wire [31:0] dbus_resp_rdata,

    output wire        fencei,          // pulse: invalidate I-cache

    input  wire        irq_software,
    input  wire        irq_timer,
    input  wire        irq_external,

    // RISC-V Formal Interface (retirement trace)
    output reg         rvfi_valid,
    output reg  [63:0] rvfi_order,
    output reg  [31:0] rvfi_insn,
    output reg         rvfi_trap,
    output reg         rvfi_halt,
    output reg         rvfi_intr,
    output reg  [1:0]  rvfi_mode,
    output reg  [1:0]  rvfi_ixl,
    output reg  [4:0]  rvfi_rs1_addr,
    output reg  [4:0]  rvfi_rs2_addr,
    output reg  [31:0] rvfi_rs1_rdata,
    output reg  [31:0] rvfi_rs2_rdata,
    output reg  [4:0]  rvfi_rd_addr,
    output reg  [31:0] rvfi_rd_wdata,
    output reg  [31:0] rvfi_pc_rdata,
    output reg  [31:0] rvfi_pc_wdata,
    output reg  [31:0] rvfi_mem_addr,
    output reg  [3:0]  rvfi_mem_rmask,
    output reg  [3:0]  rvfi_mem_wmask,
    output reg  [31:0] rvfi_mem_rdata,
    output reg  [31:0] rvfi_mem_wdata,
    // extra trace info (not part of RVFI): cause of the interrupt that was
    // taken just before this instruction (valid when rvfi_intr && dbg_irq)
    output reg         dbg_irq,
    output reg  [4:0]  dbg_irq_cause
);
    localparam BHT_BITS = 8;

    // ==================================================================
    // Pipeline control signals (defined further below)
    wire stall_wb, stall_mem, stall_ex, stall_id;
    wire mem_redirect, ex_redirect;
    wire [31:0] mem_redirect_pc, ex_redirect_pc;

    // ==================================================================
    // IF (front end)
    wire        fe_valid, fe_ready;
    wire [31:0] fe_pc, fe_insn, fe_pred_npc;
    wire        fe_is_c, fe_pred_taken;
    wire [BHT_BITS-1:0] fe_bht_idx;
    wire        fe_fixup;

    wire        bp_upd_valid;
    wire [1:0]  bp_upd_type;
    wire        bp_upd_taken;
    wire [31:0] bp_upd_target;

    // ID/EX / EX/MEM / MEM/WB registers are declared before use below
    reg         ex_valid;
    reg  [31:0] ex_pc, ex_insn, ex_pred_npc, ex_imm, ex_rs1_val, ex_rs2_val;
    reg         ex_is_c;
    reg  [BHT_BITS-1:0] ex_bht_idx;
    reg  [4:0]  ex_rd, ex_rs1, ex_rs2;
    reg         ex_rd_we, ex_rs1_used, ex_rs2_used;
    reg  [3:0]  ex_alu_op;
    reg  [1:0]  ex_a_sel;
    reg         ex_b_imm;
    reg         ex_branch, ex_jal, ex_jalr, ex_load, ex_store, ex_munsigned;
    reg  [1:0]  ex_msize;
    reg         ex_mul, ex_div;
    reg  [2:0]  ex_funct3;
    reg         ex_csr, ex_csr_imm, ex_csr_wr;
    reg  [1:0]  ex_csr_op;
    reg         ex_ecall, ex_ebreak, ex_mret, ex_fencei, ex_illegal;

    rv_frontend #(.ENABLE_BP(ENABLE_BP), .BHT_BITS(BHT_BITS)) u_fe (
        .clk(clk), .rst(rst), .boot_addr(boot_addr),
        .ibus_req_valid(ibus_req_valid), .ibus_req_addr(ibus_req_addr), .ibus_req_ready(ibus_req_ready),
        .ibus_resp_valid(ibus_resp_valid), .ibus_resp_data(ibus_resp_data),
        .redirect_valid(mem_redirect | ex_redirect),
        .redirect_pc(mem_redirect ? mem_redirect_pc : ex_redirect_pc),
        .out_valid(fe_valid), .out_ready(fe_ready), .out_pc(fe_pc), .out_insn(fe_insn),
        .out_is_c(fe_is_c), .out_pred_taken(fe_pred_taken), .out_pred_npc(fe_pred_npc),
        .out_bht_idx(fe_bht_idx),
        .upd_valid(bp_upd_valid), .upd_pc(ex_pc), .upd_is_c(ex_is_c), .upd_type(bp_upd_type),
        .upd_taken(bp_upd_taken), .upd_target(bp_upd_target), .upd_bht_idx(ex_bht_idx),
        .stat_fixup(fe_fixup)
    );

    // ==================================================================
    // ID
    wire [31:0] id_xinsn;
    wire        id_c_illegal;
    rv_rvc_expand u_rvc (.c(fe_insn[15:0]), .x(id_xinsn), .illegal(id_c_illegal));
    wire [31:0] id_insn32 = fe_is_c ? id_xinsn : fe_insn;

    wire        d_illegal, d_rd_we, d_rs1_used, d_rs2_used, d_b_imm;
    wire [4:0]  d_rd, d_rs1, d_rs2;
    wire [31:0] d_imm;
    wire [3:0]  d_alu_op;
    wire [1:0]  d_a_sel, d_msize, d_csr_op;
    wire        d_branch, d_jal, d_jalr, d_load, d_store, d_munsigned, d_mul, d_div;
    wire        d_csr, d_csr_imm, d_csr_wr, d_ecall, d_ebreak, d_mret, d_wfi, d_fencei;
    wire [2:0]  d_funct3;
    rv_decode u_dec (
        .insn(id_insn32), .illegal(d_illegal), .rd(d_rd), .rs1(d_rs1), .rs2(d_rs2),
        .rd_we(d_rd_we), .rs1_used(d_rs1_used), .rs2_used(d_rs2_used), .imm(d_imm),
        .alu_op(d_alu_op), .a_sel(d_a_sel), .b_imm(d_b_imm),
        .is_branch(d_branch), .is_jal(d_jal), .is_jalr(d_jalr),
        .is_load(d_load), .is_store(d_store), .msize(d_msize), .munsigned(d_munsigned),
        .is_mul(d_mul), .is_div(d_div), .is_csr(d_csr), .csr_op(d_csr_op), .csr_imm(d_csr_imm),
        .csr_wr(d_csr_wr), .is_ecall(d_ecall), .is_ebreak(d_ebreak), .is_mret(d_mret),
        .is_wfi(d_wfi), .is_fencei(d_fencei), .funct3(d_funct3)
    );
    wire id_illegal = (fe_is_c && id_c_illegal) || d_illegal;
    wire id_rs1_used = d_rs1_used && !id_illegal;
    wire id_rs2_used = d_rs2_used && !id_illegal;

    // Register file (written by WB)
    wire        wb_rf_we;
    wire [4:0]  wb_rf_wa;
    wire [31:0] wb_rf_wd;
    wire [31:0] id_rs1_val, id_rs2_val;
    rv_regfile u_rf (
        .clk(clk), .ra1(d_rs1), .ra2(d_rs2), .rd1(id_rs1_val), .rd2(id_rs2_val),
        .we(wb_rf_we), .wa(wb_rf_wa), .wd(wb_rf_wd)
    );

    // Load-use hazard: results of loads and CSR reads are only available
    // from the MEM/WB register, so a dependent instruction directly behind
    // one must wait a cycle.
    wire ex_late = ex_load || ex_csr;
    wire load_use = ex_valid && ex_late && ex_rd_we &&
                    ((id_rs1_used && d_rs1 == ex_rd) || (id_rs2_used && d_rs2 == ex_rd));

    assign stall_id = stall_ex || load_use;
    assign fe_ready = !stall_id;
    wire id_fire = fe_valid && !stall_id;

    // ==================================================================
    // EX
    // Forwarding sources
    reg         mem_valid, mem_rd_we;
    reg  [4:0]  mem_rd;
    reg  [31:0] mem_result;
    reg         wb_valid;
    wire [31:0] wb_value;

    function [31:0] fwd(input [4:0] r, input [31:0] regval);
        if (r == 5'd0)                               fwd = 32'd0;
        else if (mem_valid && mem_rd_we && mem_rd == r) fwd = mem_result;
        else if (wb_rf_we && wb_rf_wa == r)          fwd = wb_rf_wd;
        else                                         fwd = regval;
    endfunction
    wire [31:0] ex_a_reg = fwd(ex_rs1, ex_rs1_val);
    wire [31:0] ex_b_reg = fwd(ex_rs2, ex_rs2_val);

    wire [31:0] alu_a = (ex_a_sel == `A_PC) ? ex_pc : (ex_a_sel == `A_ZERO) ? 32'd0 : ex_a_reg;
    wire [31:0] alu_b = ex_b_imm ? ex_imm : ex_b_reg;
    wire [31:0] alu_y;
    rv_alu u_alu (.op(ex_alu_op), .a(alu_a), .b(alu_b), .y(alu_y));

    // M extension
    wire [31:0] md_y;
    wire        md_busy;
    wire        ex_fire;
    rv_muldiv u_md (
        .clk(clk), .rst(rst), .valid(ex_valid && (ex_mul || ex_div)), .op(ex_funct3),
        .a(ex_a_reg), .b(ex_b_reg), .kill(mem_redirect), .hold(stall_mem), .consume(ex_fire),
        .result(md_y), .busy(md_busy)
    );

    // Branch / jump resolution
    wire        br_eq  = (ex_a_reg == ex_b_reg);
    wire        br_lt  = ($signed(ex_a_reg) < $signed(ex_b_reg));
    wire        br_ltu = (ex_a_reg < ex_b_reg);
    reg         br_taken;
    always @(*) begin
        case (ex_funct3)
            3'b000:  br_taken = br_eq;
            3'b001:  br_taken = !br_eq;
            3'b100:  br_taken = br_lt;
            3'b101:  br_taken = !br_lt;
            3'b110:  br_taken = br_ltu;
            3'b111:  br_taken = !br_ltu;
            default: br_taken = 1'b0;
        endcase
    end
    wire [31:0] ex_len      = ex_is_c ? 32'd2 : 32'd4;
    wire [31:0] ex_seq_pc   = ex_pc + ex_len;
    wire [31:0] ex_br_tgt   = ex_pc + ex_imm;
    wire [31:0] ex_jalr_tgt = (ex_a_reg + ex_imm) & ~32'd1;
    wire        ex_taken    = ex_jal || ex_jalr || (ex_branch && br_taken);
    wire [31:0] ex_target   = ex_jalr ? ex_jalr_tgt : ex_br_tgt;
    wire [31:0] ex_npc      = ex_taken ? ex_target : ex_seq_pc;

    // Load / store address + alignment
    wire [31:0] ex_maddr = ex_a_reg + ex_imm;
    wire ex_misalign = (ex_msize == `MSZ_W && ex_maddr[1:0] != 2'b00) ||
                       (ex_msize == `MSZ_H && ex_maddr[0]);
    wire ex_ld_mis = ex_load  && ex_misalign;
    wire ex_st_mis = ex_store && ex_misalign;

    reg [3:0]  ex_be;
    reg [31:0] ex_wdata;
    always @(*) begin
        case (ex_msize)
            `MSZ_B:  begin ex_be = 4'b0001 << ex_maddr[1:0]; ex_wdata = {4{ex_b_reg[7:0]}};  end
            `MSZ_H:  begin ex_be = ex_maddr[1] ? 4'b1100 : 4'b0011; ex_wdata = {2{ex_b_reg[15:0]}}; end
            default: begin ex_be = 4'b1111; ex_wdata = ex_b_reg; end
        endcase
    end

    // Exceptions known by the end of EX (priority per the privileged spec)
    reg        ex_exc;
    reg [4:0]  ex_exc_cause;
    reg [31:0] ex_exc_tval;
    always @(*) begin
        ex_exc = 1'b1; ex_exc_cause = `EXC_ILLEGAL; ex_exc_tval = 32'd0;
        if (ex_illegal) begin
            ex_exc_cause = `EXC_ILLEGAL;
            ex_exc_tval  = ex_is_c ? {16'd0, ex_insn[15:0]} : ex_insn;
        end else if (ex_ecall) begin
            ex_exc_cause = `EXC_ECALL_M;
        end else if (ex_ebreak) begin
            ex_exc_cause = `EXC_BREAKPOINT;
            ex_exc_tval  = ex_pc;
        end else if (ex_ld_mis) begin
            ex_exc_cause = `EXC_LD_MISALIGN;
            ex_exc_tval  = ex_maddr;
        end else if (ex_st_mis) begin
            ex_exc_cause = `EXC_ST_MISALIGN;
            ex_exc_tval  = ex_maddr;
        end else
            ex_exc = 1'b0;
    end

    wire [31:0] ex_result = (ex_jal || ex_jalr) ? ex_seq_pc :
                            (ex_mul || ex_div)  ? md_y : alu_y;

    assign stall_ex = stall_mem || (ex_valid && md_busy);
    assign ex_fire  = ex_valid && !stall_ex && !mem_redirect;

    wire ex_mispredict = !ex_exc && (ex_npc != ex_pred_npc);
    assign ex_redirect    = ex_fire && ex_mispredict;
    assign ex_redirect_pc = ex_npc;

    // Branch predictor training
    wire ex_ctrl = ex_branch || ex_jal || ex_jalr;
    wire rd_link  = (ex_rd == 5'd1) || (ex_rd == 5'd5);
    wire rs1_link = (ex_rs1 == 5'd1) || (ex_rs1 == 5'd5);
    assign bp_upd_valid  = ex_fire && ex_ctrl && !ex_exc;
    assign bp_upd_taken  = ex_taken;
    assign bp_upd_target = ex_target;
    assign bp_upd_type   = ex_branch ? `BT_COND :
                           (ex_jalr && !rd_link && rs1_link && ex_rd == 5'd0) ? `BT_RET :
                           (ex_rd_we && rd_link) ? `BT_CALL : `BT_JUMP;

    // ID/EX register
    always @(posedge clk) begin
        if (rst || mem_redirect || ex_redirect) begin
            ex_valid <= 1'b0;
        end else if (!stall_ex) begin
            ex_valid <= id_fire;
            if (id_fire) begin
                ex_pc        <= fe_pc;
                ex_insn      <= fe_insn;
                ex_is_c      <= fe_is_c;
                ex_pred_npc  <= fe_pred_npc;
                ex_bht_idx   <= fe_bht_idx;
                ex_rd        <= d_rd;
                ex_rd_we     <= d_rd_we && !id_illegal;
                ex_rs1       <= id_rs1_used ? d_rs1 : 5'd0;
                ex_rs2       <= id_rs2_used ? d_rs2 : 5'd0;
                ex_rs1_used  <= id_rs1_used;
                ex_rs2_used  <= id_rs2_used;
                ex_rs1_val   <= id_rs1_val;
                ex_rs2_val   <= id_rs2_val;
                ex_imm       <= d_csr_imm && d_csr ? {27'd0, d_rs1} : d_imm;
                ex_alu_op    <= d_alu_op;
                ex_a_sel     <= d_a_sel;
                ex_b_imm     <= d_b_imm;
                ex_branch    <= d_branch;
                ex_jal       <= d_jal;
                ex_jalr      <= d_jalr;
                ex_load      <= d_load;
                ex_store     <= d_store;
                ex_msize     <= d_msize;
                ex_munsigned <= d_munsigned;
                ex_mul       <= d_mul;
                ex_div       <= d_div;
                ex_funct3    <= d_funct3;
                ex_csr       <= d_csr;
                ex_csr_op    <= d_csr_op;
                ex_csr_imm   <= d_csr_imm;
                ex_csr_wr    <= d_csr_wr;
                ex_ecall     <= d_ecall && !id_illegal;
                ex_ebreak    <= d_ebreak && !id_illegal;
                ex_mret      <= d_mret && !id_illegal;
                ex_fencei    <= d_fencei;
                ex_illegal   <= id_illegal;
            end
        end else begin
            // EX is stalled: capture forwarded operands so they survive the
            // producer leaving the bypass network while we wait.
            ex_rs1_val <= ex_a_reg;
            ex_rs2_val <= ex_b_reg;
        end
    end

    // ==================================================================
    // MEM
    reg  [31:0] mem_pc, mem_insn, mem_npc, mem_addr, mem_wdata, mem_csr_src;
    reg  [3:0]  mem_be;
    reg         mem_load, mem_store, mem_munsigned;
    reg  [1:0]  mem_msize;
    reg         mem_csr, mem_csr_wr;
    reg  [1:0]  mem_csr_op;
    reg  [11:0] mem_csr_addr;
    reg         mem_mret, mem_fencei, mem_is_c;
    reg         mem_exc;
    reg  [4:0]  mem_exc_cause;
    reg  [31:0] mem_exc_tval;
    reg  [4:0]  mem_rs1, mem_rs2;
    reg  [31:0] mem_rs1_val, mem_rs2_val;

    always @(posedge clk) begin
        if (rst || mem_redirect) begin
            mem_valid <= 1'b0;
        end else if (!stall_mem) begin
            mem_valid <= ex_fire;
            if (ex_fire) begin
                mem_pc        <= ex_pc;
                mem_insn      <= ex_is_c ? {16'd0, ex_insn[15:0]} : ex_insn;
                mem_is_c      <= ex_is_c;
                mem_npc       <= ex_npc;
                mem_rd        <= ex_rd;
                mem_rd_we     <= ex_rd_we && !ex_exc;
                mem_result    <= ex_result;
                mem_addr      <= ex_maddr;
                mem_wdata     <= ex_wdata;
                mem_be        <= ex_be;
                mem_load      <= ex_load && !ex_exc;
                mem_store     <= ex_store && !ex_exc;
                mem_msize     <= ex_msize;
                mem_munsigned <= ex_munsigned;
                mem_csr       <= ex_csr;
                mem_csr_wr    <= ex_csr_wr;
                mem_csr_op    <= ex_csr_op;
                mem_csr_addr  <= ex_insn[31:20];
                mem_csr_src   <= ex_csr_imm ? ex_imm : ex_a_reg;
                mem_mret      <= ex_mret;
                mem_fencei    <= ex_fencei;
                mem_exc       <= ex_exc;
                mem_exc_cause <= ex_exc_cause;
                mem_exc_tval  <= ex_exc_tval;
                mem_rs1       <= ex_rs1;
                mem_rs2       <= ex_rs2;
                mem_rs1_val   <= ex_a_reg;
                mem_rs2_val   <= ex_b_reg;
            end
        end
    end

    // CSR file
    wire [31:0] csr_rdata, trap_vector, csr_mepc;
    wire        csr_illegal, irq_pending;
    wire [4:0]  irq_cause;
    reg  [31:0] csr_wval;
    always @(*) begin
        case (mem_csr_op)
            2'b01:   csr_wval = mem_csr_src;
            2'b10:   csr_wval = csr_rdata | mem_csr_src;
            default: csr_wval = csr_rdata & ~mem_csr_src;
        endcase
    end

    wire mem_fire;
    wire mem_csr_access = mem_valid && mem_csr;
    wire mem_exc_all    = mem_exc || (mem_csr_access && csr_illegal);
    wire take_irq       = mem_valid && irq_pending;
    wire mem_trap       = mem_valid && (take_irq || mem_exc_all);
    wire [4:0]  trap_cause = take_irq ? irq_cause :
                             mem_exc ? mem_exc_cause : `EXC_ILLEGAL;
    wire [31:0] trap_tval  = take_irq ? 32'd0 :
                             mem_exc ? mem_exc_tval : mem_insn;

    wire retire;
    wire [5:0] hpm_ev;
    rv_csr #(.HART_ID(HART_ID), .NUM_HPM(6)) u_csr (
        .clk(clk), .rst(rst),
        .addr(mem_csr_addr), .access(mem_csr_access), .wr_intent(mem_csr_wr),
        .rdata(csr_rdata), .illegal(csr_illegal),
        .wr_en(mem_fire && mem_csr && mem_csr_wr && !mem_trap), .wdata(csr_wval),
        .trap(mem_fire && mem_trap), .trap_is_irq(take_irq), .trap_cause(trap_cause),
        .trap_pc(mem_pc), .trap_tval(trap_tval),
        .mret(mem_fire && mem_mret && !mem_trap),
        .trap_vector(trap_vector), .mepc_o(csr_mepc),
        .irq_software(irq_software), .irq_timer(irq_timer), .irq_external(irq_external),
        .irq_pending(irq_pending), .irq_cause(irq_cause),
        .retire(retire), .hpm_events(hpm_ev)
    );

    // Data bus request (single outstanding; issued only when MEM can advance)
    wire mem_mem_op = mem_valid && (mem_load || mem_store) && !mem_trap;
    assign dbus_req_valid = mem_mem_op && !stall_wb;
    assign dbus_req_addr  = {mem_addr[31:2], 2'b00};
    assign dbus_req_we    = mem_store;
    assign dbus_req_be    = mem_store ? mem_be : 4'b1111;
    assign dbus_req_wdata = mem_wdata;

    assign stall_mem = stall_wb || (mem_mem_op && !dbus_req_ready);
    assign mem_fire  = mem_valid && !stall_mem;

    assign mem_redirect    = mem_fire && (mem_trap || mem_mret || mem_fencei);
    assign mem_redirect_pc = mem_trap ? trap_vector : mem_mret ? csr_mepc : mem_npc;
    assign fencei          = mem_fire && mem_fencei && !mem_trap;

    // ==================================================================
    // WB
    reg  [31:0] wb_pc, wb_insn, wb_npc, wb_result, wb_addr, wb_wdata;
    reg  [3:0]  wb_be;
    reg  [4:0]  wb_rd;
    reg         wb_rd_we, wb_load, wb_store, wb_munsigned, wb_trap;
    reg  [1:0]  wb_msize;
    reg  [4:0]  wb_rs1, wb_rs2;
    reg  [31:0] wb_rs1_val, wb_rs2_val;
    reg         intr_flag, intr_irq;
    reg  [4:0]  intr_cause;

    always @(posedge clk) begin
        if (rst) begin
            wb_valid <= 1'b0;
        end else if (!stall_wb) begin
            // an interrupted instruction does not retire (it re-executes after MRET)
            wb_valid <= mem_fire && !take_irq;
            if (mem_fire) begin
                wb_pc        <= mem_pc;
                wb_insn      <= mem_insn;
                wb_npc       <= mem_redirect ? mem_redirect_pc : mem_npc;
                wb_rd        <= mem_rd;
                wb_rd_we     <= mem_rd_we && !mem_trap;
                wb_result    <= mem_csr ? csr_rdata : mem_result;
                wb_addr      <= mem_addr;
                wb_wdata     <= mem_wdata;
                wb_be        <= mem_be;
                wb_load      <= mem_load && !mem_trap;
                wb_store     <= mem_store && !mem_trap;
                wb_msize     <= mem_msize;
                wb_munsigned <= mem_munsigned;
                wb_trap      <= mem_trap;
                wb_rs1       <= mem_rs1;
                wb_rs2       <= mem_rs2;
                wb_rs1_val   <= mem_rs1_val;
                wb_rs2_val   <= mem_rs2_val;
            end
        end
    end

    wire wb_wait = wb_valid && (wb_load || wb_store);
    assign stall_wb = wb_wait && !dbus_resp_valid;

    // Load data extraction
    reg [31:0] ld_val;
    wire [31:0] ld_word = dbus_resp_rdata >> {wb_addr[1:0], 3'b000};
    always @(*) begin
        case (wb_msize)
            `MSZ_B:  ld_val = wb_munsigned ? {24'd0, ld_word[7:0]}  : {{24{ld_word[7]}},  ld_word[7:0]};
            `MSZ_H:  ld_val = wb_munsigned ? {16'd0, ld_word[15:0]} : {{16{ld_word[15]}}, ld_word[15:0]};
            default: ld_val = ld_word;
        endcase
    end
    assign wb_value = wb_load ? ld_val : wb_result;

    wire wb_fire = wb_valid && !stall_wb;
    assign wb_rf_we = wb_fire && wb_rd_we;
    assign wb_rf_wa = wb_rd;
    assign wb_rf_wd = wb_value;
    // minstret counts at the MEM commit point (an instruction leaving MEM
    // without trapping is guaranteed to retire), so a CSR read in MEM sees
    // every older instruction already counted.
    assign retire   = mem_fire && !mem_trap;

    // ==================================================================
    // Performance events -> mhpmcounter3..8
    //  3: branch/jump mispredict redirects   4: control-flow instructions
    //  5: load-use stall cycles              6: decode starved (front end empty)
    //  7: data-bus stall cycles              8: divider stall cycles
    assign hpm_ev[0] = ex_redirect;
    assign hpm_ev[1] = bp_upd_valid;
    assign hpm_ev[2] = load_use && !stall_ex;
    assign hpm_ev[3] = !fe_valid && !stall_id;
    assign hpm_ev[4] = stall_mem;
    assign hpm_ev[5] = ex_valid && md_busy && !stall_mem;

    // ==================================================================
    // RVFI
    always @(posedge clk) begin
        if (rst) begin
            rvfi_valid <= 1'b0;
            rvfi_order <= 64'd0;
            intr_flag  <= 1'b0;
            intr_irq   <= 1'b0;
            intr_cause <= 5'd0;
        end else begin
            if (mem_fire && mem_trap) begin
                intr_flag  <= 1'b1;
                intr_irq   <= take_irq;
                intr_cause <= irq_cause;
            end else if (wb_fire && !wb_trap) begin
                intr_flag <= 1'b0;
            end

            rvfi_valid <= wb_fire;
            if (wb_fire) begin
                rvfi_order     <= rvfi_order + 64'd1;
                rvfi_insn      <= wb_insn;
                rvfi_trap      <= wb_trap;
                rvfi_halt      <= 1'b0;
                rvfi_intr      <= intr_flag && !wb_trap;
                dbg_irq        <= intr_flag && intr_irq && !wb_trap;
                dbg_irq_cause  <= intr_cause;
                rvfi_mode      <= 2'd3;
                rvfi_ixl       <= 2'd1;
                rvfi_rs1_addr  <= wb_rs1;
                rvfi_rs2_addr  <= wb_rs2;
                rvfi_rs1_rdata <= (wb_rs1 == 5'd0) ? 32'd0 : wb_rs1_val;
                rvfi_rs2_rdata <= (wb_rs2 == 5'd0) ? 32'd0 : wb_rs2_val;
                rvfi_rd_addr   <= wb_rd_we ? wb_rd : 5'd0;
                rvfi_rd_wdata  <= (wb_rd_we && wb_rd != 5'd0) ? wb_value : 32'd0;
                rvfi_pc_rdata  <= wb_pc;
                rvfi_pc_wdata  <= wb_npc;
                rvfi_mem_addr  <= (wb_load || wb_store) ? {wb_addr[31:2], 2'b00} : 32'd0;
                rvfi_mem_rmask <= wb_load  ? wb_be : 4'd0;
                rvfi_mem_wmask <= wb_store ? wb_be : 4'd0;
                rvfi_mem_rdata <= wb_load  ? dbus_resp_rdata : 32'd0;
                rvfi_mem_wdata <= wb_store ? wb_wdata : 32'd0;
            end
        end
    end
endmodule

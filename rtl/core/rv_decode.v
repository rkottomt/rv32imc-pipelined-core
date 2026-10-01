// rv_decode.v - RV32IM + Zicsr instruction decoder.
// Turns a 32-bit instruction into the control signals used by the
// EX / MEM / WB stages. Every encoding that is not part of the supported
// ISA raises `illegal`, which the pipeline converts into a precise trap.
`include "rv_defs.vh"

module rv_decode (
    input  wire [31:0] insn,
    output reg         illegal,
    output wire [4:0]  rd,
    output wire [4:0]  rs1,
    output wire [4:0]  rs2,
    output reg         rd_we,
    output reg         rs1_used,
    output reg         rs2_used,
    output reg  [31:0] imm,
    output reg  [3:0]  alu_op,
    output reg  [1:0]  a_sel,
    output reg         b_imm,     // operand B = immediate (else rs2)
    output reg         is_branch,
    output reg         is_jal,
    output reg         is_jalr,
    output reg         is_load,
    output reg         is_store,
    output reg  [1:0]  msize,
    output reg         munsigned,
    output reg         is_mul,    // MUL/MULH/MULHSU/MULHU
    output reg         is_div,    // DIV/DIVU/REM/REMU
    output reg         is_csr,
    output reg  [1:0]  csr_op,    // 01 RW, 10 RS, 11 RC
    output reg         csr_imm,   // source is the 5-bit zimm instead of rs1
    output reg         csr_wr,    // instruction actually writes the CSR
    output reg         is_ecall,
    output reg         is_ebreak,
    output reg         is_mret,
    output reg         is_wfi,
    output reg         is_fencei,
    output wire [2:0]  funct3
);
    wire [6:0] opcode = insn[6:0];
    wire [6:0] funct7 = insn[31:25];
    assign funct3 = insn[14:12];
    assign rd  = insn[11:7];
    assign rs1 = insn[19:15];
    assign rs2 = insn[24:20];

    wire [31:0] imm_i = {{20{insn[31]}}, insn[31:20]};
    wire [31:0] imm_s = {{20{insn[31]}}, insn[31:25], insn[11:7]};
    wire [31:0] imm_b = {{19{insn[31]}}, insn[31], insn[7], insn[30:25], insn[11:8], 1'b0};
    wire [31:0] imm_u = {insn[31:12], 12'b0};
    wire [31:0] imm_j = {{11{insn[31]}}, insn[31], insn[19:12], insn[20], insn[30:21], 1'b0};

    always @(*) begin
        illegal = 1'b0; rd_we = 1'b0; rs1_used = 1'b0; rs2_used = 1'b0;
        imm = imm_i; alu_op = `ALU_ADD; a_sel = `A_RS1; b_imm = 1'b1;
        is_branch = 1'b0; is_jal = 1'b0; is_jalr = 1'b0;
        is_load = 1'b0; is_store = 1'b0; msize = funct3[1:0]; munsigned = funct3[2];
        is_mul = 1'b0; is_div = 1'b0;
        is_csr = 1'b0; csr_op = funct3[1:0]; csr_imm = funct3[2]; csr_wr = 1'b0;
        is_ecall = 1'b0; is_ebreak = 1'b0; is_mret = 1'b0; is_wfi = 1'b0; is_fencei = 1'b0;

        case (opcode)
        `OP_LUI:   begin rd_we = 1'b1; imm = imm_u; a_sel = `A_ZERO; end
        `OP_AUIPC: begin rd_we = 1'b1; imm = imm_u; a_sel = `A_PC; end
        `OP_JAL:   begin rd_we = 1'b1; imm = imm_j; is_jal = 1'b1; end
        `OP_JALR:  begin
            rd_we = 1'b1; rs1_used = 1'b1; is_jalr = 1'b1;
            illegal = (funct3 != 3'b000);
        end
        `OP_BRANCH: begin
            rs1_used = 1'b1; rs2_used = 1'b1; imm = imm_b; is_branch = 1'b1;
            illegal = (funct3 == 3'b010) || (funct3 == 3'b011);
        end
        `OP_LOAD: begin
            rd_we = 1'b1; rs1_used = 1'b1; is_load = 1'b1;
            illegal = (funct3 == 3'b011) || (funct3 == 3'b110) || (funct3 == 3'b111);
        end
        `OP_STORE: begin
            rs1_used = 1'b1; rs2_used = 1'b1; imm = imm_s; is_store = 1'b1;
            illegal = (funct3[2] == 1'b1) || (funct3[1:0] == 2'b11);
        end
        `OP_OPIMM: begin
            rd_we = 1'b1; rs1_used = 1'b1;
            case (funct3)
                3'b000: alu_op = `ALU_ADD;
                3'b010: alu_op = `ALU_SLT;
                3'b011: alu_op = `ALU_SLTU;
                3'b100: alu_op = `ALU_XOR;
                3'b110: alu_op = `ALU_OR;
                3'b111: alu_op = `ALU_AND;
                3'b001: begin alu_op = `ALU_SLL; illegal = (funct7 != 7'b0000000); end
                3'b101: begin
                    alu_op = funct7[5] ? `ALU_SRA : `ALU_SRL;
                    illegal = (funct7 != 7'b0000000) && (funct7 != 7'b0100000);
                end
            endcase
        end
        `OP_OP: begin
            rd_we = 1'b1; rs1_used = 1'b1; rs2_used = 1'b1; b_imm = 1'b0;
            if (funct7 == 7'b0000001) begin
                is_mul = ~funct3[2];
                is_div =  funct3[2];
            end else if (funct7 == 7'b0000000) begin
                case (funct3)
                    3'b000: alu_op = `ALU_ADD;
                    3'b001: alu_op = `ALU_SLL;
                    3'b010: alu_op = `ALU_SLT;
                    3'b011: alu_op = `ALU_SLTU;
                    3'b100: alu_op = `ALU_XOR;
                    3'b101: alu_op = `ALU_SRL;
                    3'b110: alu_op = `ALU_OR;
                    3'b111: alu_op = `ALU_AND;
                endcase
            end else if (funct7 == 7'b0100000) begin
                case (funct3)
                    3'b000:  alu_op = `ALU_SUB;
                    3'b101:  alu_op = `ALU_SRA;
                    default: illegal = 1'b1;
                endcase
            end else
                illegal = 1'b1;
        end
        `OP_MISCMEM: begin
            // FENCE is a no-op on this in-order, single-hart core.
            // FENCE.I must flush the pipeline and the I-cache.
            if (funct3 == 3'b001) is_fencei = 1'b1;
            else if (funct3 != 3'b000) illegal = 1'b1;
        end
        `OP_SYSTEM: begin
            if (funct3 == 3'b000) begin
                case (insn[31:7])
                    25'h0000000: is_ecall  = 1'b1;
                    25'h0002000: is_ebreak = 1'b1;
                    25'h0604000: is_mret   = 1'b1;   // 0x30200073
                    25'h020A000: is_wfi    = 1'b1;   // 0x10500073
                    default:     illegal   = 1'b1;
                endcase
            end else if (funct3 == 3'b100) begin
                illegal = 1'b1;
            end else begin
                is_csr   = 1'b1;
                rd_we    = 1'b1;
                rs1_used = ~funct3[2];
                // CSRRW always writes; CSRRS/CSRRC only when rs1/zimm != 0
                csr_wr   = (funct3[1:0] == 2'b01) || (rs1 != 5'd0);
            end
        end
        default: illegal = 1'b1;
        endcase

        if (illegal) begin
            rd_we = 1'b0; rs1_used = 1'b0; rs2_used = 1'b0;
            is_branch = 1'b0; is_jal = 1'b0; is_jalr = 1'b0;
            is_load = 1'b0; is_store = 1'b0; is_mul = 1'b0; is_div = 1'b0;
            is_csr = 1'b0; csr_wr = 1'b0; is_fencei = 1'b0;
        end
        // writes to x0 are discarded
        if (rd == 5'd0) rd_we = 1'b0;
    end
endmodule

// rv_rvc_expand.v - RV32C compressed instruction expander.
// Purely combinational: maps a 16-bit compressed instruction onto the
// equivalent 32-bit RV32I instruction, so the rest of the pipeline only
// ever decodes 32-bit encodings. Reserved / RV64-only / F-extension
// encodings are flagged illegal.
`include "rv_defs.vh"

module rv_rvc_expand (
    input  wire [15:0] c,
    output reg  [31:0] x,
    output reg         illegal
);
    // Register fields
    wire [4:0] rd    = c[11:7];
    wire [4:0] rs2   = c[6:2];
    wire [4:0] rdp   = {2'b01, c[4:2]};   // rd'/rs2' (x8..x15)
    wire [4:0] rs1p  = {2'b01, c[9:7]};   // rs1'/rd'

    // Immediates (sign-extended where the ISA says so)
    wire [11:0] imm_addi4spn = {2'b0, c[10:7], c[12:11], c[5], c[6], 2'b00};
    wire [11:0] imm_lwsw     = {5'b0, c[5], c[12:10], c[6], 2'b00};
    wire [11:0] imm_ci       = {{6{c[12]}}, c[12], c[6:2]};
    wire [20:0] imm_cj       = {{10{c[12]}}, c[8], c[10:9], c[6], c[7], c[2], c[11], c[5:3], 1'b0};
    wire [11:0] imm_16sp     = {{2{c[12]}}, c[12], c[4:3], c[5], c[2], c[6], 4'b0000};
    wire [19:0] imm_lui      = {{14{c[12]}}, c[12], c[6:2]};
    wire [12:0] imm_cb       = {{4{c[12]}}, c[12], c[6:5], c[2], c[11:10], c[4:3], 1'b0};
    wire [11:0] imm_lwsp     = {4'b0, c[3:2], c[12], c[6:4], 2'b00};
    wire [11:0] imm_swsp     = {4'b0, c[8:7], c[12:9], 2'b00};

    // 32-bit encoders
    function [31:0] enc_i(input [11:0] imm, input [4:0] rs1, input [2:0] f3, input [4:0] rdx, input [6:0] op);
        enc_i = {imm, rs1, f3, rdx, op};
    endfunction
    function [31:0] enc_s(input [11:0] imm, input [4:0] rs2x, input [4:0] rs1, input [2:0] f3);
        enc_s = {imm[11:5], rs2x, rs1, f3, imm[4:0], `OP_STORE};
    endfunction
    function [31:0] enc_r(input [6:0] f7, input [4:0] rs2x, input [4:0] rs1, input [2:0] f3, input [4:0] rdx);
        enc_r = {f7, rs2x, rs1, f3, rdx, `OP_OP};
    endfunction
    function [31:0] enc_b(input [12:0] imm, input [4:0] rs1, input [2:0] f3);
        enc_b = {imm[12], imm[10:5], 5'd0, rs1, f3, imm[4:1], imm[11], `OP_BRANCH};
    endfunction
    function [31:0] enc_j(input [20:0] imm, input [4:0] rdx);
        enc_j = {imm[20], imm[10:1], imm[11], imm[19:12], rdx, `OP_JAL};
    endfunction

    always @(*) begin
        x       = 32'h0;
        illegal = 1'b0;
        case (c[1:0])
        2'b00: case (c[15:13])
            3'b000: begin // C.ADDI4SPN
                x = enc_i(imm_addi4spn, 5'd2, 3'b000, rdp, `OP_OPIMM);
                illegal = (imm_addi4spn == 12'd0);
            end
            3'b010: x = {imm_lwsw, rs1p, 3'b010, rdp, `OP_LOAD};      // C.LW
            3'b110: x = enc_s(imm_lwsw, rdp, rs1p, 3'b010);           // C.SW
            default: illegal = 1'b1;
        endcase
        2'b01: case (c[15:13])
            3'b000: x = enc_i(imm_ci, rd, 3'b000, rd, `OP_OPIMM);     // C.ADDI / C.NOP
            3'b001: x = enc_j(imm_cj, 5'd1);                          // C.JAL
            3'b010: x = enc_i(imm_ci, 5'd0, 3'b000, rd, `OP_OPIMM);   // C.LI
            3'b011: begin
                if (rd == 5'd2) begin                                 // C.ADDI16SP
                    x = enc_i(imm_16sp, 5'd2, 3'b000, 5'd2, `OP_OPIMM);
                    illegal = (imm_16sp == 12'd0);
                end else begin                                        // C.LUI
                    x = {imm_lui, rd, `OP_LUI};
                    illegal = ({c[12], c[6:2]} == 6'd0);
                end
            end
            3'b100: case (c[11:10])
                2'b00: begin // C.SRLI
                    x = enc_i({7'b0000000, c[6:2]}, rs1p, 3'b101, rs1p, `OP_OPIMM);
                    illegal = c[12];
                end
                2'b01: begin // C.SRAI
                    x = enc_i({7'b0100000, c[6:2]}, rs1p, 3'b101, rs1p, `OP_OPIMM);
                    illegal = c[12];
                end
                2'b10: x = enc_i(imm_ci, rs1p, 3'b111, rs1p, `OP_OPIMM); // C.ANDI
                2'b11: begin
                    if (c[12]) illegal = 1'b1;  // C.SUBW/C.ADDW are RV64 only
                    else case (c[6:5])
                        2'b00: x = enc_r(7'b0100000, rdp, rs1p, 3'b000, rs1p); // C.SUB
                        2'b01: x = enc_r(7'b0000000, rdp, rs1p, 3'b100, rs1p); // C.XOR
                        2'b10: x = enc_r(7'b0000000, rdp, rs1p, 3'b110, rs1p); // C.OR
                        2'b11: x = enc_r(7'b0000000, rdp, rs1p, 3'b111, rs1p); // C.AND
                    endcase
                end
            endcase
            3'b101: x = enc_j(imm_cj, 5'd0);                          // C.J
            3'b110: x = enc_b(imm_cb, rs1p, 3'b000);                  // C.BEQZ
            3'b111: x = enc_b(imm_cb, rs1p, 3'b001);                  // C.BNEZ
        endcase
        2'b10: case (c[15:13])
            3'b000: begin // C.SLLI
                x = enc_i({7'b0000000, c[6:2]}, rd, 3'b001, rd, `OP_OPIMM);
                illegal = c[12];
            end
            3'b010: begin // C.LWSP
                x = {imm_lwsp, 5'd2, 3'b010, rd, `OP_LOAD};
                illegal = (rd == 5'd0);
            end
            3'b100: begin
                if (!c[12]) begin
                    if (rs2 == 5'd0) begin                            // C.JR
                        x = enc_i(12'd0, rd, 3'b000, 5'd0, `OP_JALR);
                        illegal = (rd == 5'd0);
                    end else                                          // C.MV
                        x = enc_r(7'd0, rs2, 5'd0, 3'b000, rd);
                end else begin
                    if (rd == 5'd0 && rs2 == 5'd0)                    // C.EBREAK
                        x = 32'h00100073;
                    else if (rs2 == 5'd0)                             // C.JALR
                        x = enc_i(12'd0, rd, 3'b000, 5'd1, `OP_JALR);
                    else                                              // C.ADD
                        x = enc_r(7'd0, rs2, rd, 3'b000, rd);
                end
            end
            3'b110: x = enc_s(imm_swsp, rs2, 5'd2, 3'b010);           // C.SWSP
            default: illegal = 1'b1;
        endcase
        default: illegal = 1'b1; // not a compressed instruction
        endcase
    end
endmodule

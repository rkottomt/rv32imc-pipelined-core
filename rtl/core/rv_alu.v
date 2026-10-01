// rv_alu.v - integer ALU (single cycle)
`include "rv_defs.vh"

module rv_alu (
    input  wire [3:0]  op,
    input  wire [31:0] a,
    input  wire [31:0] b,
    output reg  [31:0] y
);
    wire [4:0] sh = b[4:0];
    always @(*) begin
        case (op)
            `ALU_ADD:  y = a + b;
            `ALU_SUB:  y = a - b;
            `ALU_SLL:  y = a << sh;
            `ALU_SLT:  y = {31'b0, $signed(a) < $signed(b)};
            `ALU_SLTU: y = {31'b0, a < b};
            `ALU_XOR:  y = a ^ b;
            `ALU_SRL:  y = a >> sh;
            `ALU_SRA:  y = $signed(a) >>> sh;
            `ALU_OR:   y = a | b;
            `ALU_AND:  y = a & b;
            default:   y = a + b;
        endcase
    end
endmodule

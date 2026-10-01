// rv_defs.vh - shared constants for the RV32IMC core
`ifndef RV_DEFS_VH
`define RV_DEFS_VH

// Major opcodes (inst[6:0])
`define OP_LOAD     7'b0000011
`define OP_MISCMEM  7'b0001111
`define OP_OPIMM    7'b0010011
`define OP_AUIPC    7'b0010111
`define OP_STORE    7'b0100011
`define OP_OP       7'b0110011
`define OP_LUI      7'b0110111
`define OP_BRANCH   7'b1100011
`define OP_JALR     7'b1100111
`define OP_JAL      7'b1101111
`define OP_SYSTEM   7'b1110011

// ALU operations
`define ALU_ADD   4'd0
`define ALU_SUB   4'd1
`define ALU_SLL   4'd2
`define ALU_SLT   4'd3
`define ALU_SLTU  4'd4
`define ALU_XOR   4'd5
`define ALU_SRL   4'd6
`define ALU_SRA   4'd7
`define ALU_OR    4'd8
`define ALU_AND   4'd9

// Operand A select
`define A_RS1   2'd0
`define A_PC    2'd1
`define A_ZERO  2'd2

// Memory access sizes
`define MSZ_B 2'd0
`define MSZ_H 2'd1
`define MSZ_W 2'd2

// Branch predictor entry types
`define BT_COND 2'd0
`define BT_JUMP 2'd1
`define BT_CALL 2'd2
`define BT_RET  2'd3

// Exception causes
`define EXC_ILLEGAL     5'd2
`define EXC_BREAKPOINT  5'd3
`define EXC_LD_MISALIGN 5'd4
`define EXC_ST_MISALIGN 5'd6
`define EXC_ECALL_M     5'd11

// CSR addresses
`define CSR_MSTATUS    12'h300
`define CSR_MISA       12'h301
`define CSR_MIE        12'h304
`define CSR_MTVEC      12'h305
`define CSR_MSTATUSH   12'h310
`define CSR_MCOUNTINH  12'h320
`define CSR_MSCRATCH   12'h340
`define CSR_MEPC       12'h341
`define CSR_MCAUSE     12'h342
`define CSR_MTVAL      12'h343
`define CSR_MIP        12'h344
`define CSR_MCYCLE     12'hB00
`define CSR_MINSTRET   12'hB02
`define CSR_MCYCLEH    12'hB80
`define CSR_MINSTRETH  12'hB82
`define CSR_CYCLE      12'hC00
`define CSR_INSTRET    12'hC02
`define CSR_CYCLEH     12'hC80
`define CSR_INSTRETH   12'hC82
`define CSR_MVENDORID  12'hF11
`define CSR_MARCHID    12'hF12
`define CSR_MIMPID     12'hF13
`define CSR_MHARTID    12'hF14

`endif

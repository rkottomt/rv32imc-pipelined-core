// rv_muldiv.v - RV32M unit.
//  * MUL/MULH/MULHSU/MULHU: single-cycle 33x33 signed multiply (maps to DSPs).
//  * DIV/DIVU/REM/REMU:     radix-2 restoring divider, 32 iterations + 1 setup.
// The EX stage stalls while `busy` is high. `kill` aborts an in-flight divide
// (the instruction was flushed); `consume` acknowledges a finished result
// when the instruction leaves EX.
//
// When RISCV_FORMAL_ALTOPS is defined, the arithmetic is replaced by the
// cheap "alternative" operations defined by riscv-formal so the M-extension
// datapath can be checked formally without solving 32-bit multiplication.
module rv_muldiv (
    input  wire        clk,
    input  wire        rst,
    input  wire        valid,     // instruction in EX is an M-ext op
    input  wire [2:0]  op,        // funct3
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire        kill,
    input  wire        consume,
    output reg  [31:0] result,
    output wire        busy
);
    wire is_div = op[2];

`ifdef RISCV_FORMAL_ALTOPS
    always @(*) begin
        case (op)
            3'b000: result = (a + b) ^ 32'h5876063e;
            3'b001: result = (a + b) ^ 32'hf6583fb7;
            3'b010: result = (a - b) ^ 32'hecfbe137;
            3'b011: result = (a + b) ^ 32'h949ce5e8;
            3'b100: result = (a - b) ^ 32'h7f8529ec;
            3'b101: result = (a - b) ^ 32'h10e8fd70;
            3'b110: result = (a - b) ^ 32'h8da68fa5;
            3'b111: result = (a - b) ^ 32'h3138d0e1;
        endcase
    end
    assign busy = 1'b0;
`else
    // ---------------- multiplier ----------------
    wire a_signed = (op[1:0] == 2'b01) || (op[1:0] == 2'b10); // MULH, MULHSU
    wire b_signed = (op[1:0] == 2'b01);                       // MULH
    wire signed [32:0] ma = {a_signed & a[31], a};
    wire signed [32:0] mb = {b_signed & b[31], b};
    wire signed [65:0] prod = ma * mb;
    wire [31:0] mul_res = (op[1:0] == 2'b00) ? prod[31:0] : prod[63:32];

    // ---------------- divider ----------------
    wire sgn = ~op[0];          // DIV / REM are signed
    wire want_rem = op[1];
    reg        running, done;
    reg [5:0]  cnt;
    reg [31:0] quo, dvs;
    reg [32:0] rem;
    reg        neg_q, neg_r, div0;
    reg [31:0] dividend_save;
    reg [31:0] div_res;

    wire [32:0] rem_sh = {rem[31:0], quo[31]};
    wire [32:0] diff   = rem_sh - {1'b0, dvs};

    wire start = valid && is_div && !running && !done && !kill;

    always @(posedge clk) begin
        if (rst || kill) begin
            running <= 1'b0;
            done    <= 1'b0;
        end else if (start) begin
            running       <= 1'b1;
            cnt           <= 6'd0;
            quo           <= (sgn && a[31]) ? -a : a;
            dvs           <= (sgn && b[31]) ? -b : b;
            rem           <= 33'd0;
            neg_q         <= sgn && (a[31] ^ b[31]);
            neg_r         <= sgn && a[31];
            div0          <= (b == 32'd0);
            dividend_save <= a;
        end else if (running) begin
            if (!diff[32]) begin
                rem <= diff;
                quo <= {quo[30:0], 1'b1};
            end else begin
                rem <= rem_sh;
                quo <= {quo[30:0], 1'b0};
            end
            cnt <= cnt + 6'd1;
            if (cnt == 6'd31) begin
                running <= 1'b0;
                done    <= 1'b1;
            end
        end else if (done && consume) begin
            done <= 1'b0;
        end
    end

    always @(*) begin
        if (div0)
            div_res = want_rem ? dividend_save : 32'hffffffff;
        else if (want_rem)
            div_res = neg_r ? -rem[31:0] : rem[31:0];
        else
            div_res = neg_q ? -quo : quo;
    end

    always @(*) result = is_div ? div_res : mul_res;
    assign busy = valid && is_div && !done;
`endif
endmodule

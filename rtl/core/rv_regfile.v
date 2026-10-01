// rv_regfile.v - 32 x 32-bit register file, 2 read / 1 write.
// Reads are asynchronous (maps to distributed/LUT RAM on FPGAs) and include
// a write-through bypass so an instruction in ID sees the value being
// written back by WB in the same cycle. x0 always reads as zero.
module rv_regfile (
    input  wire        clk,
    input  wire [4:0]  ra1,
    input  wire [4:0]  ra2,
    output wire [31:0] rd1,
    output wire [31:0] rd2,
    input  wire        we,
    input  wire [4:0]  wa,
    input  wire [31:0] wd
);
    reg [31:0] mem [0:31];

    integer i;
    initial for (i = 0; i < 32; i = i + 1) mem[i] = 32'd0;

    always @(posedge clk)
        if (we && wa != 5'd0) mem[wa] <= wd;

    assign rd1 = (ra1 == 5'd0) ? 32'd0 : (we && wa == ra1) ? wd : mem[ra1];
    assign rd2 = (ra2 == 5'd0) ? 32'd0 : (we && wa == ra2) ? wd : mem[ra2];
endmodule

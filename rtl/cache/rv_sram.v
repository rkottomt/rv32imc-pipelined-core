// rv_sram.v - simple dual-port synchronous RAM (1 read, 1 write port) with
// byte enables. Written in the style FPGA tools infer as block RAM.
// Read-during-write to the same address returns the OLD data; callers that
// care must bypass (the D-cache does).
module rv_sram #(
    parameter AW = 9,
    parameter DW = 32
) (
    input  wire            clk,
    input  wire            re,
    input  wire [AW-1:0]   raddr,
    output reg  [DW-1:0]   rdata,
    input  wire [DW/8-1:0] we,
    input  wire [AW-1:0]   waddr,
    input  wire [DW-1:0]   wdata
);
    reg [DW-1:0] mem [0:(1<<AW)-1];

    integer i;
    always @(posedge clk) begin
        for (i = 0; i < DW/8; i = i + 1)
            if (we[i]) mem[waddr][i*8 +: 8] <= wdata[i*8 +: 8];
        if (re) rdata <= mem[raddr];
    end
endmodule

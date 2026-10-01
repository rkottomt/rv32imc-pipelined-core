// rv_ram.v - main memory: synchronous block RAM behind the system bus.
//
// EXTRA_LATENCY adds response delay cycles to emulate an external DRAM
// (used for the cache performance study); 0 = plain 1-cycle BRAM.
// In simulation the contents are loaded from +ram_hex=<file> ($readmemh).
module rv_ram #(
    parameter AW            = 14,       // words: 2^14 * 4 = 64 KiB
    parameter EXTRA_LATENCY = 0,
    parameter INIT_FILE     = ""
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        req_valid,
    input  wire [31:0] req_addr,
    input  wire        req_we,
    input  wire [3:0]  req_be,
    input  wire [31:0] req_wdata,
    output wire        req_ready,
    output wire        resp_valid,
    output wire [31:0] resp_rdata
);
    reg [31:0] mem [0:(1<<AW)-1];

`ifndef SYNTHESIS
    reg [8*1024-1:0] hexfile;   // path of up to 1024 characters (longer ones get truncated)
    initial begin
        if ($value$plusargs("ram_hex=%s", hexfile)) $readmemh(hexfile, mem);
        else if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    end
`else
    initial if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
`endif

    wire [AW-1:0] a = req_addr[AW+1:2];
    wire fire = req_valid && req_ready;
    reg [31:0] rdata;
    reg        rvalid;
    always @(posedge clk) begin
        if (fire) begin
            if (req_we) begin
                if (req_be[0]) mem[a][7:0]   <= req_wdata[7:0];
                if (req_be[1]) mem[a][15:8]  <= req_wdata[15:8];
                if (req_be[2]) mem[a][23:16] <= req_wdata[23:16];
                if (req_be[3]) mem[a][31:24] <= req_wdata[31:24];
            end
            rdata <= mem[a];
        end
    end

    generate if (EXTRA_LATENCY == 0) begin : g_fast
        always @(posedge clk) rvalid <= rst ? 1'b0 : fire;
        assign req_ready  = 1'b1;
        assign resp_valid = rvalid;
        assign resp_rdata = rdata;
    end else begin : g_slow
        // one transaction at a time; response EXTRA_LATENCY cycles later
        reg [7:0]  wait_cnt;
        reg        busy;
        always @(posedge clk) begin
            if (rst) begin
                busy <= 1'b0;
                rvalid <= 1'b0;
            end else begin
                rvalid <= 1'b0;
                if (fire) begin
                    busy <= 1'b1;
                    wait_cnt <= EXTRA_LATENCY;
                end else if (busy) begin
                    if (wait_cnt == 0) begin
                        busy   <= 1'b0;
                        rvalid <= 1'b1;
                    end else
                        wait_cnt <= wait_cnt - 1'b1;
                end
            end
        end
        assign req_ready  = !busy && !rvalid;
        assign resp_valid = rvalid;
        assign resp_rdata = rdata;
    end endgenerate
endmodule

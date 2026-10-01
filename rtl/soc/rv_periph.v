// rv_periph.v - SoC peripherals on the system bus (all 1-cycle responses).
//
//  0x0200_0000  CLINT   msip (+0x0000), mtimecmp (+0x4000), mtime (+0xBFF8)
//  0x1000_0000  UART    +0x0 TXDATA (write), +0x4 STATUS (bit0 = tx busy)
//  0x1000_1000  GPIO    +0x0 output register (LEDs)
//  0x1000_2000  SIMCTRL write v: end of simulation; v==1 -> pass,
//                       otherwise exit code v>>1 ("tohost" convention)
module rv_periph #(
    parameter CLKS_PER_BIT = 434        // 50 MHz / 115200 baud
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        req_valid,
    input  wire [31:0] req_addr,
    input  wire        req_we,
    input  wire [3:0]  req_be,
    input  wire [31:0] req_wdata,
    output wire        req_ready,
    output reg         resp_valid,
    output reg  [31:0] resp_rdata,

    output reg         irq_timer,
    output reg         irq_software,
    output wire        uart_tx,
    output reg  [7:0]  gpio_out,
    output reg         sim_exit,
    output reg  [31:0] sim_exit_code
);
    wire fire = req_valid && req_ready;
    wire is_clint = req_addr[31:16] == 16'h0200;
    wire is_uart  = req_addr[31:12] == 20'h10000;
    wire is_gpio  = req_addr[31:12] == 20'h10001;
    wire is_sim   = req_addr[31:12] == 20'h10002;

    // ---------------- CLINT
    reg [63:0] mtime, mtimecmp;
    reg        msip;
    // registered: keeps the 64-bit compare out of the core's trap logic path
    always @(posedge clk) begin
        irq_timer    <= !rst && (mtime >= mtimecmp);
        irq_software <= !rst && msip;
    end

    // ---------------- UART transmitter (8N1)
    reg [9:0]  tx_shift;
    reg [3:0]  tx_bits;
    reg [15:0] tx_cnt;
    wire       tx_busy = tx_bits != 0;
    assign uart_tx = tx_busy ? tx_shift[0] : 1'b1;
    assign req_ready = 1'b1;

    always @(posedge clk) begin
        if (rst) begin
            mtime    <= 64'd0;
            mtimecmp <= 64'hFFFF_FFFF_FFFF_FFFF;
            msip     <= 1'b0;
            tx_bits  <= 4'd0;
            gpio_out <= 8'd0;
            sim_exit <= 1'b0;
            resp_valid <= 1'b0;
        end else begin
            mtime <= mtime + 64'd1;
            resp_valid <= fire;
            resp_rdata <= 32'd0;

            if (tx_busy) begin
                if (tx_cnt == 0) begin
                    tx_cnt   <= CLKS_PER_BIT - 1;
                    tx_shift <= {1'b1, tx_shift[9:1]};
                    tx_bits  <= tx_bits - 4'd1;
                end else
                    tx_cnt <= tx_cnt - 16'd1;
            end

            if (fire) begin
                if (is_clint) begin
                    case (req_addr[15:0])
                        16'h0000: if (req_we) msip <= req_wdata[0]; else resp_rdata <= {31'd0, msip};
                        16'h4000: if (req_we) mtimecmp[31:0]  <= req_wdata; else resp_rdata <= mtimecmp[31:0];
                        16'h4004: if (req_we) mtimecmp[63:32] <= req_wdata; else resp_rdata <= mtimecmp[63:32];
                        16'hBFF8: if (req_we) mtime[31:0]  <= req_wdata; else resp_rdata <= mtime[31:0];
                        16'hBFFC: if (req_we) mtime[63:32] <= req_wdata; else resp_rdata <= mtime[63:32];
                        default: ;
                    endcase
                end
                if (is_uart) begin
                    if (req_we && req_addr[3:0] == 4'h0 && req_be[0]) begin
`ifndef SYNTHESIS
                        $write("%c", req_wdata[7:0]);
                        $fflush();
`endif
                        if (!tx_busy) begin
                            tx_shift <= {1'b1, req_wdata[7:0], 1'b0};
                            tx_bits  <= 4'd10;
                            tx_cnt   <= CLKS_PER_BIT - 1;
                        end
                    end
                    if (!req_we && req_addr[3:0] == 4'h4)
`ifndef SYNTHESIS
                        resp_rdata <= 32'd0;     // never busy in simulation
`else
                        resp_rdata <= {31'd0, tx_busy};
`endif
                end
                if (is_gpio) begin
                    if (req_we) gpio_out <= req_wdata[7:0];
                    else resp_rdata <= {24'd0, gpio_out};
                end
                if (is_sim && req_we && req_addr[3:0] == 4'h0 && req_wdata != 0) begin
                    sim_exit      <= 1'b1;
                    sim_exit_code <= req_wdata;
                end
            end
        end
    end
endmodule

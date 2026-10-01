// top_ulx3s.v - FPGA top for the Radiona ULX3S (Lattice ECP5-85F) board.
// 25 MHz oscillator drives the SoC directly (nextpnr reports the achievable
// Fmax; a PLL can raise the clock up to that). BTN0 = reset, LEDs = GPIO,
// FTDI UART TX = console.
module top_ulx3s (
    input  wire       clk_25mhz,
    input  wire [6:0] btn,
    output wire [7:0] led,
    output wire       ftdi_rxd,     // FPGA -> PC
    output wire       wifi_gpio0    // keep the ESP32 from resetting the board
);
    assign wifi_gpio0 = 1'b1;

    // reset synchronizer (BTN0 is active-low on ULX3S)
    reg [3:0] rst_sync = 4'hf;
    always @(posedge clk_25mhz) rst_sync <= {rst_sync[2:0], ~btn[0]};
    wire rst = rst_sync[3];

    wire [7:0] gpio;
    rv_soc #(
        .RAM_AW(14),                         // 64 KiB of block RAM
        .RAM_INIT("firmware.hex"),
        .UART_CLKS_PER_BIT(217)              // 25 MHz / 115200
    ) u_soc (
        .clk(clk_25mhz), .rst(rst), .irq_external(1'b0),
        .uart_tx(ftdi_rxd), .gpio_out(gpio),
        .sim_exit(), .sim_exit_code(),
        .rvfi_valid(), .rvfi_insn(), .rvfi_trap(), .rvfi_intr(), .dbg_irq(), .dbg_irq_cause(),
        .rvfi_rd_addr(), .rvfi_rd_wdata(), .rvfi_pc_rdata(), .rvfi_pc_wdata(),
        .rvfi_mem_addr(), .rvfi_mem_rmask(), .rvfi_mem_wmask(),
        .stat_icache_miss(), .stat_dcache_miss(), .stat_dcache_wb(),
        .stat_mispredict(), .stat_ctrl()
    );
    assign led = gpio;
endmodule

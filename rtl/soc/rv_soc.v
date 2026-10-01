// rv_soc.v - SoC top: core + I$ + D$ + system bus + RAM + peripherals.
//
//            +---------+   ibus   +--------+  m1
//            |         |--------->| I-cache|-----+
//            | rv_core |          +--------+     |   +---------+     +------+
//            |         |   dbus   +--------+  m0 +-->| arbiter |--+->| RAM  | 0x0000_0000
//            |         |--------->| D-cache|-----+   +---------+  |  +------+
//            +---------+          +--------+                      +->| periph| CLINT/UART/
//                                                                    +------+ GPIO/SIMCTRL
`include "rv_defs.vh"

module rv_soc #(
    parameter [31:0] BOOT_ADDR     = 32'h0000_0000,
    parameter        RAM_AW        = 14,     // 64 KiB
    parameter        RAM_LATENCY   = 0,      // extra cycles (DRAM emulation)
    parameter        RAM_INIT      = "",
    parameter        ICACHE        = 1,
    parameter        DCACHE        = 1,
    parameter        CACHE_SET_BITS= 7,      // 2 ways x 128 sets x 16 B = 4 KiB each
    parameter        ENABLE_BP     = 1,
    parameter        BTB_BITS      = 6,
    parameter        BHT_BITS      = 8,
    parameter        UART_CLKS_PER_BIT = 434
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        irq_external,
    output wire        uart_tx,
    output wire [7:0]  gpio_out,
    output wire        sim_exit,
    output wire [31:0] sim_exit_code,

    // retirement trace (simulation / formal; unused on the FPGA)
    output wire        rvfi_valid,
    output wire [31:0] rvfi_insn,
    output wire        rvfi_trap,
    output wire        rvfi_intr,
    output wire        dbg_irq,
    output wire [4:0]  dbg_irq_cause,
    output wire [4:0]  rvfi_rd_addr,
    output wire [31:0] rvfi_rd_wdata,
    output wire [31:0] rvfi_pc_rdata,
    output wire [31:0] rvfi_pc_wdata,
    output wire [31:0] rvfi_mem_addr,
    output wire [3:0]  rvfi_mem_rmask,
    output wire [3:0]  rvfi_mem_wmask,
    // performance counters for the testbench
    output wire        stat_icache_miss,
    output wire        stat_dcache_miss,
    output wire        stat_dcache_wb,
    output wire        stat_mispredict,
    output wire        stat_ctrl
);
    // ---------------- core
    wire        ib_req_valid, ib_req_ready, ib_resp_valid;
    wire [31:0] ib_req_addr, ib_resp_data;
    wire        db_req_valid, db_req_ready, db_resp_valid, db_req_we, db_req_flush;
    wire [31:0] db_req_addr, db_req_wdata, db_resp_rdata;
    wire [3:0]  db_req_be;
    wire        fencei, irq_timer, irq_software;
    reg         irq_ext_q;                       // register the external IRQ pin
    always @(posedge clk) irq_ext_q <= !rst && irq_external;

    rv_core #(.HART_ID(0), .ENABLE_BP(ENABLE_BP), .BTB_BITS(BTB_BITS), .BHT_BITS(BHT_BITS)) u_core (
        .clk(clk), .rst(rst), .boot_addr(BOOT_ADDR),
        .ibus_req_valid(ib_req_valid), .ibus_req_addr(ib_req_addr), .ibus_req_ready(ib_req_ready),
        .ibus_resp_valid(ib_resp_valid), .ibus_resp_data(ib_resp_data),
        .dbus_req_valid(db_req_valid), .dbus_req_addr(db_req_addr), .dbus_req_we(db_req_we),
        .dbus_req_be(db_req_be), .dbus_req_wdata(db_req_wdata), .dbus_req_flush(db_req_flush),
        .dbus_req_ready(db_req_ready), .dbus_resp_valid(db_resp_valid), .dbus_resp_rdata(db_resp_rdata),
        .fencei(fencei),
        .irq_software(irq_software), .irq_timer(irq_timer), .irq_external(irq_ext_q),
        .rvfi_valid(rvfi_valid), .rvfi_order(), .rvfi_insn(rvfi_insn), .rvfi_trap(rvfi_trap),
        .rvfi_halt(), .rvfi_intr(rvfi_intr), .rvfi_mode(), .rvfi_ixl(),
        .rvfi_rs1_addr(), .rvfi_rs2_addr(), .rvfi_rs1_rdata(), .rvfi_rs2_rdata(),
        .rvfi_rd_addr(rvfi_rd_addr), .rvfi_rd_wdata(rvfi_rd_wdata),
        .rvfi_pc_rdata(rvfi_pc_rdata), .rvfi_pc_wdata(rvfi_pc_wdata),
        .rvfi_mem_addr(rvfi_mem_addr), .rvfi_mem_rmask(rvfi_mem_rmask), .rvfi_mem_wmask(rvfi_mem_wmask),
        .rvfi_mem_rdata(), .rvfi_mem_wdata(),
        .dbg_irq(dbg_irq), .dbg_irq_cause(dbg_irq_cause),
        .stat_mispredict(stat_mispredict), .stat_ctrl(stat_ctrl)
    );

    // ---------------- caches (or pass-through)
    wire        m0_req_valid, m0_req_ready, m0_resp_valid, m0_req_we;
    wire [31:0] m0_req_addr, m0_req_wdata, m0_resp_rdata;
    wire [3:0]  m0_req_be;
    wire        m1_req_valid, m1_req_ready, m1_resp_valid;
    wire [31:0] m1_req_addr, m1_resp_rdata;

    generate if (ICACHE) begin : g_ic
        rv_icache #(.SET_BITS(CACHE_SET_BITS)) u_icache (
            .clk(clk), .rst(rst), .invalidate(fencei),
            .req_valid(ib_req_valid), .req_addr(ib_req_addr), .req_ready(ib_req_ready),
            .resp_valid(ib_resp_valid), .resp_data(ib_resp_data),
            .m_req_valid(m1_req_valid), .m_req_addr(m1_req_addr), .m_req_ready(m1_req_ready),
            .m_resp_valid(m1_resp_valid), .m_resp_data(m1_resp_rdata),
            .stat_miss(stat_icache_miss));
    end else begin : g_noic
        assign m1_req_valid  = ib_req_valid;
        assign m1_req_addr   = ib_req_addr;
        assign ib_req_ready  = m1_req_ready;
        assign ib_resp_valid = m1_resp_valid;
        assign ib_resp_data  = m1_resp_rdata;
        assign stat_icache_miss = 1'b0;
    end endgenerate

    generate if (DCACHE) begin : g_dc
        rv_dcache #(.SET_BITS(CACHE_SET_BITS)) u_dcache (
            .clk(clk), .rst(rst),
            .req_valid(db_req_valid), .req_addr(db_req_addr), .req_we(db_req_we), .req_be(db_req_be),
            .req_wdata(db_req_wdata), .req_flush(db_req_flush), .req_ready(db_req_ready),
            .resp_valid(db_resp_valid), .resp_rdata(db_resp_rdata),
            .m_req_valid(m0_req_valid), .m_req_addr(m0_req_addr), .m_req_we(m0_req_we),
            .m_req_be(m0_req_be), .m_req_wdata(m0_req_wdata), .m_req_ready(m0_req_ready),
            .m_resp_valid(m0_resp_valid), .m_resp_rdata(m0_resp_rdata),
            .stat_miss(stat_dcache_miss), .stat_writeback(stat_dcache_wb));
    end else begin : g_nodc
        // no D-cache: flush requests are acknowledged locally
        reg flush_ack;
        always @(posedge clk) flush_ack <= !rst && db_req_valid && db_req_flush;
        assign m0_req_valid  = db_req_valid && !db_req_flush;
        assign m0_req_addr   = db_req_addr;
        assign m0_req_we     = db_req_we;
        assign m0_req_be     = db_req_be;
        assign m0_req_wdata  = db_req_wdata;
        assign db_req_ready  = db_req_flush ? 1'b1 : m0_req_ready;
        assign db_resp_valid = m0_resp_valid || flush_ack;
        assign db_resp_rdata = m0_resp_rdata;
        assign stat_dcache_miss = 1'b0;
        assign stat_dcache_wb   = 1'b0;
    end endgenerate

    // ---------------- system bus
    wire        s_req_valid, s_req_ready, s_req_we, s_resp_valid;
    wire [31:0] s_req_addr, s_req_wdata, s_resp_rdata;
    wire [3:0]  s_req_be;
    rv_bus_arbiter u_arb (
        .clk(clk), .rst(rst),
        .m0_req_valid(m0_req_valid), .m0_req_addr(m0_req_addr), .m0_req_we(m0_req_we),
        .m0_req_be(m0_req_be), .m0_req_wdata(m0_req_wdata), .m0_req_ready(m0_req_ready),
        .m0_resp_valid(m0_resp_valid), .m0_resp_rdata(m0_resp_rdata),
        .m1_req_valid(m1_req_valid), .m1_req_addr(m1_req_addr), .m1_req_we(1'b0),
        .m1_req_be(4'hf), .m1_req_wdata(32'd0), .m1_req_ready(m1_req_ready),
        .m1_resp_valid(m1_resp_valid), .m1_resp_rdata(m1_resp_rdata),
        .s_req_valid(s_req_valid), .s_req_addr(s_req_addr), .s_req_we(s_req_we),
        .s_req_be(s_req_be), .s_req_wdata(s_req_wdata), .s_req_ready(s_req_ready),
        .s_resp_valid(s_resp_valid), .s_resp_rdata(s_resp_rdata)
    );

    // address decode: RAM below 0x0200_0000, peripherals above
    wire sel_ram = s_req_addr[31:25] == 7'd0;
    wire ram_ready, ram_resp_valid, per_ready, per_resp_valid;
    wire [31:0] ram_rdata, per_rdata;
    assign s_req_ready  = sel_ram ? ram_ready : per_ready;
    assign s_resp_valid = ram_resp_valid | per_resp_valid;
    assign s_resp_rdata = ram_resp_valid ? ram_rdata : per_rdata;

    rv_ram #(.AW(RAM_AW), .EXTRA_LATENCY(RAM_LATENCY), .INIT_FILE(RAM_INIT)) u_ram (
        .clk(clk), .rst(rst),
        .req_valid(s_req_valid && sel_ram), .req_addr(s_req_addr), .req_we(s_req_we),
        .req_be(s_req_be), .req_wdata(s_req_wdata), .req_ready(ram_ready),
        .resp_valid(ram_resp_valid), .resp_rdata(ram_rdata));

    rv_periph #(.CLKS_PER_BIT(UART_CLKS_PER_BIT)) u_periph (
        .clk(clk), .rst(rst),
        .req_valid(s_req_valid && !sel_ram), .req_addr(s_req_addr), .req_we(s_req_we),
        .req_be(s_req_be), .req_wdata(s_req_wdata), .req_ready(per_ready),
        .resp_valid(per_resp_valid), .resp_rdata(per_rdata),
        .irq_timer(irq_timer), .irq_software(irq_software),
        .uart_tx(uart_tx), .gpio_out(gpio_out),
        .sim_exit(sim_exit), .sim_exit_code(sim_exit_code));
endmodule

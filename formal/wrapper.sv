// rvfi_wrapper for riscv-formal.
//
// The core's buses are driven by unconstrained ("any value") environment
// models that only obey the bus protocol: responses arrive in order, never
// more responses than requests, any latency, any data, any ready pattern.
// Interrupt lines are unconstrained as well. The formal tool therefore
// explores every possible program and every possible memory/IRQ timing up to
// the configured depth.
module rvfi_wrapper (
    input  clock,
    input  reset,
    `RVFI_OUTPUTS
);
    (* keep *) `rvformal_rand_reg        i_ready, i_resp, d_ready, d_resp;
    (* keep *) `rvformal_rand_reg [31:0] i_data, d_data;
    (* keep *) `rvformal_rand_reg        irq_s, irq_t, irq_e;

    (* keep *) wire        ibus_req_valid, dbus_req_valid, dbus_req_we, dbus_req_flush, fencei;
    (* keep *) wire [31:0] ibus_req_addr, dbus_req_addr, dbus_req_wdata;
    (* keep *) wire [3:0]  dbus_req_be;

    // outstanding-request bookkeeping so responses follow the protocol
    reg [2:0] i_out = 0;
    reg       d_out = 0;
    wire i_resp_valid = i_resp && i_out != 0;
    wire d_resp_valid = d_resp && d_out;
    always @(posedge clock) begin
        if (reset) begin
            i_out <= 0;
            d_out <= 0;
        end else begin
            i_out <= i_out + (ibus_req_valid && i_ready) - i_resp_valid;
            d_out <= (d_out && !d_resp_valid) || (dbus_req_valid && d_ready);
        end
    end

    rv_core #(
`ifdef RVCORE_FORMAL_SMALL_BP
        .BTB_BITS(2), .BHT_BITS(2)
`endif
    ) uut (
        .clk(clock), .rst(reset), .boot_addr(32'h0000_0000),
        .ibus_req_valid(ibus_req_valid), .ibus_req_addr(ibus_req_addr), .ibus_req_ready(i_ready),
        .ibus_resp_valid(i_resp_valid), .ibus_resp_data(i_data),
        .dbus_req_valid(dbus_req_valid), .dbus_req_addr(dbus_req_addr), .dbus_req_we(dbus_req_we),
        .dbus_req_be(dbus_req_be), .dbus_req_wdata(dbus_req_wdata), .dbus_req_flush(dbus_req_flush),
        .dbus_req_ready(d_ready && !d_out), .dbus_resp_valid(d_resp_valid), .dbus_resp_rdata(d_data),
        .fencei(fencei),
        .irq_software(irq_s), .irq_timer(irq_t), .irq_external(irq_e),
        .dbg_irq(), .dbg_irq_cause(),
        `RVFI_CONN
    );
endmodule

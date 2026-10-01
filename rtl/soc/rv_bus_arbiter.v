// rv_bus_arbiter.v - 2-master -> 1-slave arbiter for the system bus.
//
// Bus protocol (used everywhere in the SoC):
//   request : valid/ready handshake, addr, we, be, wdata
//   response: resp_valid (exactly one per accepted request, in order), rdata
// The arbiter allows a single outstanding transaction system-wide: once a
// master's request is accepted the bus is locked to it until its response
// returns. Master 0 (D-cache) has priority over master 1 (I-cache); an
// I-side request still gets the bus as soon as the D-side is idle, so neither
// can starve the other while the core makes progress.
module rv_bus_arbiter (
    input  wire        clk,
    input  wire        rst,
    // master 0
    input  wire        m0_req_valid,
    input  wire [31:0] m0_req_addr,
    input  wire        m0_req_we,
    input  wire [3:0]  m0_req_be,
    input  wire [31:0] m0_req_wdata,
    output wire        m0_req_ready,
    output wire        m0_resp_valid,
    output wire [31:0] m0_resp_rdata,
    // master 1
    input  wire        m1_req_valid,
    input  wire [31:0] m1_req_addr,
    input  wire        m1_req_we,
    input  wire [3:0]  m1_req_be,
    input  wire [31:0] m1_req_wdata,
    output wire        m1_req_ready,
    output wire        m1_resp_valid,
    output wire [31:0] m1_resp_rdata,
    // slave side
    output wire        s_req_valid,
    output wire [31:0] s_req_addr,
    output wire        s_req_we,
    output wire [3:0]  s_req_be,
    output wire [31:0] s_req_wdata,
    input  wire        s_req_ready,
    input  wire        s_resp_valid,
    input  wire [31:0] s_resp_rdata
);
    reg busy, owner;
    wire sel = m0_req_valid ? 1'b0 : 1'b1;   // fixed priority, master 0 first

    assign s_req_valid = !busy && (m0_req_valid || m1_req_valid);
    assign s_req_addr  = sel ? m1_req_addr  : m0_req_addr;
    assign s_req_we    = sel ? m1_req_we    : m0_req_we;
    assign s_req_be    = sel ? m1_req_be    : m0_req_be;
    assign s_req_wdata = sel ? m1_req_wdata : m0_req_wdata;

    assign m0_req_ready = !busy && !sel && s_req_ready;
    assign m1_req_ready = !busy &&  sel && s_req_ready;

    assign m0_resp_valid = busy && !owner && s_resp_valid;
    assign m1_resp_valid = busy &&  owner && s_resp_valid;
    assign m0_resp_rdata = s_resp_rdata;
    assign m1_resp_rdata = s_resp_rdata;

    always @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0;
        end else if (!busy) begin
            if (s_req_valid && s_req_ready) begin
                busy  <= 1'b1;
                owner <= sel;
            end
        end else if (s_resp_valid) begin
            busy <= 1'b0;
        end
    end
endmodule

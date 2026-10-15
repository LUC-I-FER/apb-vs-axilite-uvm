`timescale 1ns/1ps

module axi_lite_sram_wrapper #(
    parameter DATA_WIDTH = 32,
    parameter ADDR_WIDTH = 12
)(
    input  logic clk_i,
    input  logic rst_ni,
    
    // Wait-State Configuration (0 = Ideal, >0 = Random stalls)
    input  logic [7:0] cfg_aw_wait_prob_i, // Stall Write Address
    input  logic [7:0] cfg_w_wait_prob_i,  // Stall Write Data
    input  logic [7:0] cfg_ar_wait_prob_i, // Stall Read Address

    // AXI-Lite Interface Signals
    input  logic [ADDR_WIDTH-1:0] s_axi_awaddr,
    input  logic                  s_axi_awvalid,
    output logic                  s_axi_awready,
    input  logic [DATA_WIDTH-1:0] s_axi_wdata,
    input  logic [3:0]            s_axi_wstrb,
    input  logic                  s_axi_wvalid,
    output logic                  s_axi_wready,
    output logic [1:0]            s_axi_bresp,
    output logic                  s_axi_bvalid,
    input  logic                  s_axi_bready,
    input  logic [ADDR_WIDTH-1:0] s_axi_araddr,
    input  logic                  s_axi_arvalid,
    output logic                  s_axi_arready,
    output logic [DATA_WIDTH-1:0] s_axi_rdata,
    output logic [1:0]            s_axi_rresp,
    output logic                  s_axi_rvalid,
    input  logic                  s_axi_rready
);

    // Internal signals from the real AXI RAM
    logic int_awready, int_wready, int_arready;

    // LFSR for Random Generation
    logic [7:0] lfsr_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) lfsr_q <= 8'hAA;
        else         lfsr_q <= {lfsr_q[6:0], lfsr_q[7] ^ lfsr_q[5] ^ lfsr_q[4] ^ lfsr_q[3]};
    end

    // Inject Wait States (Mask the ready signals from the RAM if probability hits)
    assign s_axi_awready = int_awready & ~((cfg_aw_wait_prob_i > 0) && (lfsr_q < cfg_aw_wait_prob_i));
    assign s_axi_wready  = int_wready  & ~((cfg_w_wait_prob_i > 0)  && (lfsr_q < cfg_w_wait_prob_i));
    assign s_axi_arready = int_arready & ~((cfg_ar_wait_prob_i > 0) && (lfsr_q < cfg_ar_wait_prob_i));

    // Instantiate Alex Forencich's axi_ram
    axi_ram #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .PIPELINE_OUTPUT(0) // 0 for strict AXI-Lite timing
    ) i_axi_ram (
        .clk            (clk_i),
        .rst            (~rst_ni), // core uses active high reset
        .s_axi_awaddr   (s_axi_awaddr),
        .s_axi_awvalid  (s_axi_awvalid),
        .s_axi_awready  (int_awready),
        .s_axi_wdata    (s_axi_wdata),
        .s_axi_wstrb    (s_axi_wstrb),
        .s_axi_wvalid   (s_axi_wvalid),
        .s_axi_wready   (int_wready),
        .s_axi_bresp    (s_axi_bresp),
        .s_axi_bvalid   (s_axi_bvalid),
        .s_axi_bready   (s_axi_bready),
        .s_axi_araddr   (s_axi_araddr),
        .s_axi_arvalid  (s_axi_arvalid),
        .s_axi_arready  (int_arready),
        .s_axi_rdata    (s_axi_rdata),
        .s_axi_rresp    (s_axi_rresp),
        .s_axi_rvalid   (s_axi_rvalid),
        .s_axi_rready   (s_axi_rready)
    );
endmodule
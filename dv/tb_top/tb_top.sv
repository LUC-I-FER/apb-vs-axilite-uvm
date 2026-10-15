// Import PULP APB Definitions
`include "third_party/rtl/pulp_apb/include/apb/assign.svh"

// 1. Instantiate the PULP APB Interface (from third_party)
APB #(
    .APB_ADDR_WIDTH(32),
    .APB_DATA_WIDTH(32)
) apb_bus (
    .pclk_i(clk),
    .preset_ni(rst_n)
);

// Wait State probability (e.g., 8'h00 for ideal, 8'h80 for ~50% stall rate)
logic [7:0] apb_wait_prob;
initial apb_wait_prob = 8'h00; // Controlled later by UVM test

// 2. Instantiate our Custom SRAM Wrapper
apb_sram_wrapper #(
    .ADDR_WIDTH(12),
    .DATA_WIDTH(32)
) i_apb_sram (
    .clk_i           (clk),
    .rst_ni          (rst_n),
    .cfg_wait_prob_i (apb_wait_prob),
    
    // Connect to PULP interface signals
    .paddr_i         (apb_bus.paddr[11:0]),
    .psel_i          (apb_bus.psel),
    .penable_i       (apb_bus.penable),
    .pwrite_i        (apb_bus.pwrite),
    .pwdata_i        (apb_bus.pwdata),
    .pready_o        (apb_bus.pready),
    .prdata_o        (apb_bus.prdata),
    .pslverr_o       (apb_bus.pslverr)
);
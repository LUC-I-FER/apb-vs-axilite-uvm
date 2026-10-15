`timescale 1ns/1ps

module apb_sram_wrapper #(
    parameter int unsigned ADDR_WIDTH = 12, // 4KB memory space
    parameter int unsigned DATA_WIDTH = 32
)(
    input  logic                      clk_i,
    input  logic                      rst_ni,
    
    // Wait-State Configuration (0 = Zero Wait States, >0 = Random stalls)
    input  logic [7:0]                cfg_wait_prob_i,

    // Standard APB4 Interface Signals
    input  logic [ADDR_WIDTH-1:0]     paddr_i,
    input  logic                      psel_i,
    input  logic                      penable_i,
    input  logic                      pwrite_i,
    input  logic [DATA_WIDTH-1:0]     pwdata_i,
    output logic                      pready_o,
    output logic [DATA_WIDTH-1:0]     prdata_o,
    output logic                      pslverr_o
);

    // Memory Array
    localparam int MEM_DEPTH = 2**(ADDR_WIDTH - 2); // Word aligned
    logic [DATA_WIDTH-1:0] mem_array [0:MEM_DEPTH-1];

    // LFSR for Random Wait State Generation
    logic [7:0] lfsr_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            lfsr_q <= 8'hAA; // Non-zero seed
        end else begin
            // Simple 8-bit Galois LFSR
            lfsr_q <= {lfsr_q[6:0], lfsr_q[7] ^ lfsr_q[5] ^ lfsr_q[4] ^ lfsr_q[3]};
        end
    end

    // Wait state condition: If LFSR value is below our configured probability, stall.
    logic insert_wait_state;
    assign insert_wait_state = (cfg_wait_prob_i > 0) && (lfsr_q < cfg_wait_prob_i);

    // APB State Machine & Memory Control
    logic [ADDR_WIDTH-3:0] word_addr;
    assign word_addr = paddr_i[ADDR_WIDTH-1:2];

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            pready_o  <= 1'b0;
            prdata_o  <= '0;
            pslverr_o <= 1'b0;
        end else begin
            // Default states
            pready_o  <= 1'b0;
            pslverr_o <= 1'b0;

            // APB SETUP or ACCESS Phase
            if (psel_i) begin
                if (!penable_i) begin
                    // SETUP Phase: Prepare the transaction
                    pready_o <= 1'b0; 
                end else begin
                    // ACCESS Phase
                    if (insert_wait_state) begin
                        // Inject Wait State (Backpressure)
                        pready_o <= 1'b0;
                    end else begin
                        // Complete the transaction
                        pready_o <= 1'b1;
                        
                        if (pwrite_i) begin
                            mem_array[word_addr] <= pwdata_i; // Write
                        end else begin
                            prdata_o <= mem_array[word_addr]; // Read
                        end
                    end
                end
            end
        end
    end
endmodule
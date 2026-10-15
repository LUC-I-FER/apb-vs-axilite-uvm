// ============================================================================
// AMBA AXI4-Lite - Master and Slave
// Paste this into the "design.sv" pane in EDA Playground
// ============================================================================

// ----------------------------------------------------------------------------
// AXI4-Lite Master (bridge from a simple request interface to AXI4-Lite)
//  - Write: drives AW and W together, then waits for B
//  - Read : drives AR, then waits for R
// ----------------------------------------------------------------------------
module axi_lite_master #(
  parameter ADDR_W = 32,
  parameter DATA_W = 32,
  localparam STRB_W = DATA_W/8
)(
  input  logic                ACLK,
  input  logic                ARESETn,

  // Simple user-side request interface
  input  logic                req,      // pulse for 1 cycle when !busy
  input  logic                write,    // 1 = write, 0 = read
  input  logic [ADDR_W-1:0]   addr,
  input  logic [DATA_W-1:0]   wdata,
  input  logic [STRB_W-1:0]   wstrb,
  output logic                busy,
  output logic                done,     // 1-cycle pulse when transfer completes
  output logic [DATA_W-1:0]   rdata,
  output logic [1:0]          resp,     // BRESP / RRESP of last transfer

  // Write address channel
  output logic [ADDR_W-1:0]   AWADDR,
  output logic [2:0]          AWPROT,
  output logic                AWVALID,
  input  logic                AWREADY,
  // Write data channel
  output logic [DATA_W-1:0]   WDATA,
  output logic [STRB_W-1:0]   WSTRB,
  output logic                WVALID,
  input  logic                WREADY,
  // Write response channel
  input  logic [1:0]          BRESP,
  input  logic                BVALID,
  output logic                BREADY,
  // Read address channel
  output logic [ADDR_W-1:0]   ARADDR,
  output logic [2:0]          ARPROT,
  output logic                ARVALID,
  input  logic                ARREADY,
  // Read data channel
  input  logic [DATA_W-1:0]   RDATA,
  input  logic [1:0]          RRESP,
  input  logic                RVALID,
  output logic                RREADY
);

  typedef enum logic [1:0] {IDLE, WR, RD} state_t;
  state_t state;

  assign busy   = (state != IDLE);
  assign AWPROT = 3'b000;
  assign ARPROT = 3'b000;

  always_ff @(posedge ACLK or negedge ARESETn) begin
    if (!ARESETn) begin
      state   <= IDLE;
      AWADDR  <= '0;  AWVALID <= 1'b0;
      WDATA   <= '0;  WSTRB   <= '0;  WVALID  <= 1'b0;
      BREADY  <= 1'b0;
      ARADDR  <= '0;  ARVALID <= 1'b0;
      RREADY  <= 1'b0;
      done    <= 1'b0;
      rdata   <= '0;
      resp    <= 2'b00;
    end else begin
      done <= 1'b0;  // default: pulse only

      case (state)
        IDLE: begin
          if (req) begin
            if (write) begin
              AWADDR  <= addr;
              AWVALID <= 1'b1;
              WDATA   <= wdata;
              WSTRB   <= wstrb;
              WVALID  <= 1'b1;
              BREADY  <= 1'b1;
              state   <= WR;
            end else begin
              ARADDR  <= addr;
              ARVALID <= 1'b1;
              RREADY  <= 1'b1;
              state   <= RD;
            end
          end
        end

        WR: begin
          // AW and W handshakes complete independently
          if (AWVALID && AWREADY) AWVALID <= 1'b0;
          if (WVALID  && WREADY)  WVALID  <= 1'b0;
          // B handshake finishes the transfer
          if (BVALID && BREADY) begin
            BREADY <= 1'b0;
            resp   <= BRESP;
            done   <= 1'b1;
            state  <= IDLE;
          end
        end

        RD: begin
          if (ARVALID && ARREADY) ARVALID <= 1'b0;
          if (RVALID && RREADY) begin
            RREADY <= 1'b0;
            rdata  <= RDATA;
            resp   <= RRESP;
            done   <= 1'b1;
            state  <= IDLE;
          end
        end

        default: state <= IDLE;
      endcase
    end
  end

endmodule


// ----------------------------------------------------------------------------
// AXI4-Lite Slave: small word-addressed register file with byte strobes
//  - Accepts AW and W together (one write outstanding at a time)
//  - BRESP/RRESP = OKAY (2'b00) or SLVERR (2'b10) for out-of-range / unaligned
// ----------------------------------------------------------------------------
module axi_lite_slave #(
  parameter ADDR_W = 32,
  parameter DATA_W = 32,
  parameter DEPTH  = 16,   // number of registers (power of 2)
  localparam STRB_W = DATA_W/8
)(
  input  logic                ACLK,
  input  logic                ARESETn,

  // Write address channel
  input  logic [ADDR_W-1:0]   AWADDR,
  input  logic [2:0]          AWPROT,
  input  logic                AWVALID,
  output logic                AWREADY,
  // Write data channel
  input  logic [DATA_W-1:0]   WDATA,
  input  logic [STRB_W-1:0]   WSTRB,
  input  logic                WVALID,
  output logic                WREADY,
  // Write response channel
  output logic [1:0]          BRESP,
  output logic                BVALID,
  input  logic                BREADY,
  // Read address channel
  input  logic [ADDR_W-1:0]   ARADDR,
  input  logic [2:0]          ARPROT,
  input  logic                ARVALID,
  output logic                ARREADY,
  // Read data channel
  output logic [DATA_W-1:0]   RDATA,
  output logic [1:0]          RRESP,
  output logic                RVALID,
  input  logic                RREADY
);

  localparam IDX_W  = $clog2(DEPTH);
  localparam [1:0] OKAY   = 2'b00;
  localparam [1:0] SLVERR = 2'b10;

  logic [DATA_W-1:0] mem [DEPTH];

  // Address decode (word aligned, within range)
  wire [IDX_W-1:0] widx    = AWADDR[IDX_W+1:2];
  wire             w_ok    = (AWADDR[ADDR_W-1:IDX_W+2] == '0) && (AWADDR[1:0] == 2'b00);
  wire [IDX_W-1:0] ridx    = ARADDR[IDX_W+1:2];
  wire             r_ok    = (ARADDR[ADDR_W-1:IDX_W+2] == '0) && (ARADDR[1:0] == 2'b00);

  // -------------------------- Write channels --------------------------------
  always_ff @(posedge ACLK or negedge ARESETn) begin
    if (!ARESETn) begin
      AWREADY <= 1'b0;
      WREADY  <= 1'b0;
      BVALID  <= 1'b0;
      BRESP   <= OKAY;
      for (int i = 0; i < DEPTH; i++) mem[i] <= '0;
    end else begin
      AWREADY <= 1'b0;   // ready is a 1-cycle pulse
      WREADY  <= 1'b0;

      // Accept AW + W together when no response is pending
      if (!AWREADY && !BVALID && AWVALID && WVALID) begin
        AWREADY <= 1'b1;
        WREADY  <= 1'b1;
      end

      // Handshake edge: perform the write and raise BVALID
      if (AWVALID && AWREADY && WVALID && WREADY) begin
        if (w_ok) begin
          for (int b = 0; b < STRB_W; b++)
            if (WSTRB[b]) mem[widx][8*b +: 8] <= WDATA[8*b +: 8];
          BRESP <= OKAY;
        end else begin
          BRESP <= SLVERR;
        end
        BVALID <= 1'b1;
      end else if (BVALID && BREADY) begin
        BVALID <= 1'b0;
      end
    end
  end

  // --------------------------- Read channels --------------------------------
  always_ff @(posedge ACLK or negedge ARESETn) begin
    if (!ARESETn) begin
      ARREADY <= 1'b0;
      RVALID  <= 1'b0;
      RDATA   <= '0;
      RRESP   <= OKAY;
    end else begin
      ARREADY <= 1'b0;

      if (!ARREADY && !RVALID && ARVALID)
        ARREADY <= 1'b1;

      if (ARVALID && ARREADY) begin
        RDATA  <= r_ok ? mem[ridx] : '0;
        RRESP  <= r_ok ? OKAY : SLVERR;
        RVALID <= 1'b1;
      end else if (RVALID && RREADY) begin
        RVALID <= 1'b0;
      end
    end
  end

endmodule
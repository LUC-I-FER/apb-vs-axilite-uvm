// ============================================================================
// AMBA APB (APB3: PREADY + PSLVERR) - Master and Slave
// Paste this into the "design.sv" pane in EDA Playground
// ============================================================================

// ----------------------------------------------------------------------------
// APB Master (bridge from a simple request interface to APB)
// FSM: IDLE -> SETUP -> ACCESS -> IDLE
// ----------------------------------------------------------------------------
module apb_master #(
  parameter ADDR_W = 32,
  parameter DATA_W = 32
)(
  input  logic              PCLK,
  input  logic              PRESETn,

  // Simple user-side request interface
  input  logic              req,      // pulse for 1 cycle when !busy
  input  logic              write,    // 1 = write, 0 = read
  input  logic [ADDR_W-1:0] addr,
  input  logic [DATA_W-1:0] wdata,
  output logic              busy,
  output logic              done,     // 1-cycle pulse when transfer completes
  output logic [DATA_W-1:0] rdata,
  output logic              slverr,

  // APB side
  output logic              PSEL,
  output logic              PENABLE,
  output logic              PWRITE,
  output logic [ADDR_W-1:0] PADDR,
  output logic [DATA_W-1:0] PWDATA,
  input  logic              PREADY,
  input  logic [DATA_W-1:0] PRDATA,
  input  logic              PSLVERR
);

  typedef enum logic [1:0] {IDLE, SETUP, ACCESS} state_t;
  state_t state;

  assign busy = (state != IDLE);

  always_ff @(posedge PCLK or negedge PRESETn) begin
    if (!PRESETn) begin
      state   <= IDLE;
      PSEL    <= 1'b0;
      PENABLE <= 1'b0;
      PWRITE  <= 1'b0;
      PADDR   <= '0;
      PWDATA  <= '0;
      done    <= 1'b0;
      rdata   <= '0;
      slverr  <= 1'b0;
    end else begin
      done <= 1'b0;  // default: pulse only

      case (state)
        IDLE: begin
          if (req) begin
            PSEL    <= 1'b1;
            PENABLE <= 1'b0;
            PWRITE  <= write;
            PADDR   <= addr;
            PWDATA  <= wdata;
            state   <= SETUP;
          end
        end

        SETUP: begin               // one cycle, then enable
          PENABLE <= 1'b1;
          state   <= ACCESS;
        end

        ACCESS: begin              // wait here until slave asserts PREADY
          if (PREADY) begin
            if (!PWRITE) rdata <= PRDATA;
            slverr  <= PSLVERR;
            done    <= 1'b1;
            PSEL    <= 1'b0;
            PENABLE <= 1'b0;
            state   <= IDLE;
          end
        end

        default: state <= IDLE;
      endcase
    end
  end

endmodule


// ----------------------------------------------------------------------------
// APB Slave: small word-addressed register file
//  - WAIT_STATES inserts wait cycles (PREADY low) in the ACCESS phase
//  - PSLVERR is raised for out-of-range or unaligned addresses
// ----------------------------------------------------------------------------
module apb_slave #(
  parameter ADDR_W      = 32,
  parameter DATA_W      = 32,
  parameter DEPTH       = 16,   // number of 32-bit registers (power of 2)
  parameter WAIT_STATES = 2
)(
  input  logic              PCLK,
  input  logic              PRESETn,
  input  logic              PSEL,
  input  logic              PENABLE,
  input  logic              PWRITE,
  input  logic [ADDR_W-1:0] PADDR,
  input  logic [DATA_W-1:0] PWDATA,
  output logic              PREADY,
  output logic [DATA_W-1:0] PRDATA,
  output logic              PSLVERR
);

  localparam IDX_W = $clog2(DEPTH);

  logic [DATA_W-1:0] mem [DEPTH];
  logic [3:0]        wait_cnt;

  wire access = PSEL && PENABLE;
  wire [IDX_W-1:0] idx = PADDR[IDX_W+1:2];
  wire addr_ok = (PADDR[ADDR_W-1:IDX_W+2] == '0) && (PADDR[1:0] == 2'b00);

  // Wait-state counter
  always_ff @(posedge PCLK or negedge PRESETn) begin
    if (!PRESETn)                wait_cnt <= '0;
    else if (access && !PREADY)  wait_cnt <= wait_cnt + 1'b1;
    else                         wait_cnt <= '0;
  end

  assign PREADY  = access && (wait_cnt == WAIT_STATES);
  assign PSLVERR = PREADY && !addr_ok;
  assign PRDATA  = (access && !PWRITE && addr_ok) ? mem[idx] : '0;

  // Write on the completing cycle of the ACCESS phase
  always_ff @(posedge PCLK or negedge PRESETn) begin
    if (!PRESETn) begin
      for (int i = 0; i < DEPTH; i++) mem[i] <= '0;
    end else if (PREADY && PWRITE && addr_ok) begin
      mem[idx] <= PWDATA;
    end
  end

endmodule
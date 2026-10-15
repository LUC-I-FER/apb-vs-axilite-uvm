// ============================================================================
// APB vs AXI4-Lite  -  Parametric performance-analysis testbench
//
// SETUP (EDA Playground):
//   * design.sv    : paste BOTH design files (APB design + AXI4-Lite design)
//                    one after the other. Module names do not clash.
//   * testbench.sv : paste this file.
//   * Top module   : perf_tb
//
// WHAT IT DOES
//   Both buses run at the same time, on the same clock/reset, and are driven
//   with the SAME write workload (master -> slave): same number of
//   transactions, same addresses, same data, same idle gap between
//   transactions. The workload is swept over several idle-gap values
//   (gap 0 = back-to-back = maximum-throughput case).
//
// METRIC DEFINITIONS (all measured on clock edges, one transfer in flight)
//   issue edge       : edge where the master accepts the request (req && !busy)
//   completion edge  : edge where the transfer finishes on the bus
//                      (APB: PREADY in ACCESS, AXI: BVALID && BREADY)
//   Transaction latency   = completion edge - issue edge            [cycles]
//   Average latency       = mean of all transaction latencies
//   Elapsed time          = first issue edge .. last completion edge (inclusive)
//   Throughput            = payload bytes / elapsed time             [MB/s]
//   Maximum throughput    = best throughput across all scenarios (gap = 0)
//   Transaction rate      = transactions / elapsed time              [Mtxn/s]
//   Bus utilisation       = cycles with a transfer in flight / elapsed cycles
//   Data-phase efficiency = cycles that carry a data beat / elapsed cycles
//   Master stall cycles   = cycles the master is in-flight but waiting on the
//                           slave:
//                           APB : PSEL&&PENABLE&&!PREADY (wait states)
//                           AXI : AWVALID&&!AWREADY, WVALID&&!WREADY,
//                                 BREADY&&!BVALID (waiting for response)
//   Inter-transaction gap = idle cycles between completion of one transfer
//                           and issue of the next
// ============================================================================
`timescale 1ns/1ps

// ----------------------------------------------------------------------------
// Shared package: result record + deterministic workload functions
// (deterministic => both buses see exactly the same data and gaps)
// ----------------------------------------------------------------------------
package perf_pkg;

  typedef struct {
    int  gap_mode;      // programmed idle gap (<0 = pseudo-random 0..7)
    int  n_txn;
    int  elapsed_cyc;
    int  lat_min;
    int  lat_max;
    real lat_avg;
    real lat_avg_ns;
    real thr_mbps;
    real rate_mtps;
    real util_pct;
    real eff_pct;
    int  stall_total;
    real stall_avg;
    int  gap_min;
    int  gap_max;
    real gap_avg;
  } res_t;

  function automatic logic [31:0] hash32(input int unsigned v);
    logic [31:0] x;
    x = v * 32'h9E37_79B1;
    x = x ^ (x >> 15);
    x = x * 32'h85EB_CA6B;
    x = x ^ (x >> 13);
    return x;
  endfunction

  function automatic logic [31:0] data_fn(input int unsigned i);
    return hash32(i + 1);
  endfunction

  function automatic int gap_fn(input int unsigned i, input int mode);
    if (mode >= 0) return mode;
    else           return int'((hash32(i + 977) >> 8) % 8);
  endfunction

endpackage


// ----------------------------------------------------------------------------
// Traffic generator: drives the user-side request interface of either master
// ----------------------------------------------------------------------------
module traffic_gen
  import perf_pkg::*;
(
  input  logic        clk,
  input  logic        busy,
  output logic        req,
  output logic        write,
  output logic [31:0] addr,
  output logic [31:0] wdata,
  output logic [3:0]  wstrb
);

  initial begin
    req = 0; write = 1; addr = '0; wdata = '0; wstrb = 4'hF;
  end

  // n write transactions, each preceded by 'gap' idle cycles after the
  // previous transfer has completed.
  task automatic run(input int n, input int gap_mode);
    @(negedge clk);
    for (int i = 0; i < n; i++) begin
      while (busy) @(negedge clk);              // wait for previous transfer
      repeat (gap_fn(i, gap_mode)) @(negedge clk);   // idle gap
      req   = 1;
      write = 1;
      addr  = (i % 16) * 4;
      wdata = data_fn(i);
      wstrb = 4'hF;
      @(negedge clk);
      req   = 0;
    end
    while (busy) @(negedge clk);                // wait for the last transfer
  endtask

endmodule


// ----------------------------------------------------------------------------
// Performance monitor: one instance per bus
// ----------------------------------------------------------------------------
module perf_monitor
  import perf_pkg::*;
#(
  parameter string NAME          = "BUS",
  parameter int    MAX_TXN       = 1024,
  parameter int    BYTES_PER_TXN = 4,
  parameter real   CLK_NS        = 10.0
)(
  input logic clk,
  input logic rst_n,
  input logic req,        // user-side request strobe
  input logic busy,       // master has a transfer in flight
  input logic done,       // 1-cycle pulse, cycle after completion edge
  input logic stall,      // master waiting on slave (this cycle)
  input logic data_beat   // a data beat is transferred (this cycle)
);

  int cyc = 0;
  int n_issue, n_done;
  int cur_issue, last_comp, first_issue;
  int busy_cnt, stall_cnt, beat_cnt;

  int lat_arr [MAX_TXN];
  int gap_arr [MAX_TXN];

  res_t res;

  task automatic clear_stats();
    n_issue = 0; n_done = 0;
    cur_issue = 0; last_comp = 0; first_issue = 0;
    busy_cnt = 0; stall_cnt = 0; beat_cnt = 0;
  endtask

  initial clear_stats();

  // Sampling happens on the posedge, before the DUT's non-blocking updates
  // take effect, so every signal is read with its pre-edge value.
  always @(posedge clk) begin
    cyc = cyc + 1;                       // index of this clock edge
    if (rst_n === 1'b1) begin
      if (busy)      busy_cnt++;
      if (stall)     stall_cnt++;
      if (data_beat) beat_cnt++;

      // 'done' is registered: seen one edge after the completion edge
      if (done && n_done < MAX_TXN) begin
        last_comp        = cyc - 1;
        lat_arr[n_done]  = last_comp - cur_issue;
        n_done++;
      end

      // request accepted by the master
      if (req && !busy && n_issue < MAX_TXN) begin
        if (n_issue == 0) first_issue = cyc;
        else              gap_arr[n_issue-1] = cyc - last_comp - 1;
        cur_issue = cyc;
        n_issue++;
      end
    end
  end

  task automatic compute(input int gap_mode);
    longint lsum, gsum;
    int     n_gaps;
    real    elapsed_ns;

    res.gap_mode = gap_mode;
    res.n_txn    = n_done;
    res.elapsed_cyc = (n_done > 0) ? (last_comp - first_issue + 1) : 0;
    elapsed_ns   = res.elapsed_cyc * CLK_NS;

    // latency
    lsum = 0;
    res.lat_min = (n_done > 0) ? 32'h7FFF_FFFF : 0;
    res.lat_max = 0;
    for (int i = 0; i < n_done; i++) begin
      if (lat_arr[i] < res.lat_min) res.lat_min = lat_arr[i];
      if (lat_arr[i] > res.lat_max) res.lat_max = lat_arr[i];
      lsum += lat_arr[i];
    end
    res.lat_avg    = (n_done > 0) ? real'(lsum) / n_done : 0.0;
    res.lat_avg_ns = res.lat_avg * CLK_NS;

    // inter-transaction gap
    n_gaps = (n_issue > 0) ? n_issue - 1 : 0;
    gsum = 0;
    res.gap_min = (n_gaps > 0) ? 32'h7FFF_FFFF : 0;
    res.gap_max = 0;
    for (int i = 0; i < n_gaps; i++) begin
      if (gap_arr[i] < res.gap_min) res.gap_min = gap_arr[i];
      if (gap_arr[i] > res.gap_max) res.gap_max = gap_arr[i];
      gsum += gap_arr[i];
    end
    res.gap_avg = (n_gaps > 0) ? real'(gsum) / n_gaps : 0.0;

    // throughput / rate / utilisation / stalls
    if (res.elapsed_cyc > 0) begin
      res.thr_mbps  = real'(n_done) * BYTES_PER_TXN / elapsed_ns * 1000.0;
      res.rate_mtps = real'(n_done) / elapsed_ns * 1000.0;
      res.util_pct  = 100.0 * busy_cnt / res.elapsed_cyc;
      res.eff_pct   = 100.0 * beat_cnt / res.elapsed_cyc;
    end else begin
      res.thr_mbps = 0.0; res.rate_mtps = 0.0; res.util_pct = 0.0; res.eff_pct = 0.0;
    end
    res.stall_total = stall_cnt;
    res.stall_avg   = (n_done > 0) ? real'(stall_cnt) / n_done : 0.0;
  endtask

endmodule


// ----------------------------------------------------------------------------
// Top-level testbench
// ----------------------------------------------------------------------------
module perf_tb;
  import perf_pkg::*;

  // ---------------- Common test conditions (identical for both buses) --------
  localparam int  N_TXN           = 1000;   // write transactions per scenario
  localparam real CLK_PERIOD_NS   = 10.0;   // 100 MHz
  localparam int  BYTES_PER_TXN   = 4;      // 32-bit data
  localparam int  NUM_SCEN        = 7;      // idle-gap sweep (see get_gap)
  localparam int  APB_WAIT_STATES = 0;      // slave wait states (APB slave param)

  function automatic int get_gap(input int s);
    case (s)
      0: return 0;     // back-to-back  -> maximum throughput
      1: return 1;
      2: return 2;
      3: return 4;
      4: return 8;
      5: return 16;
      default: return -1;   // pseudo-random 0..7
    endcase
  endfunction

  function automatic string gap_name(input int g);
    if (g < 0) return "random 0-7";
    else       return $sformatf("%0d", g);
  endfunction

  // ---------------- Clock / reset ----------------
  logic clk = 0;
  logic rst_n;
  always #(CLK_PERIOD_NS/2.0) clk = ~clk;

  // ---------------- APB side signals ----------------
  logic        a_req, a_write, a_busy, a_done, a_slverr;
  logic [31:0] a_addr, a_wdata, a_rdata;
  logic [3:0]  a_wstrb_unused;

  logic        PSEL, PENABLE, PWRITE, PREADY, PSLVERR;
  logic [31:0] PADDR, PWDATA, PRDATA;

  // ---------------- AXI4-Lite side signals ----------------
  logic        x_req, x_write, x_busy, x_done;
  logic [31:0] x_addr, x_wdata, x_rdata;
  logic [3:0]  x_wstrb;
  logic [1:0]  x_resp;

  logic [31:0] AWADDR, ARADDR, WDATA, RDATA;
  logic [2:0]  AWPROT, ARPROT;
  logic [3:0]  WSTRB;
  logic [1:0]  BRESP, RRESP;
  logic        AWVALID, AWREADY, WVALID, WREADY, BVALID, BREADY;
  logic        ARVALID, ARREADY, RVALID, RREADY;

  // ---------------- DUTs ----------------
  apb_master #(.ADDR_W(32), .DATA_W(32)) u_apb_m (
    .PCLK(clk), .PRESETn(rst_n),
    .req(a_req), .write(a_write), .addr(a_addr), .wdata(a_wdata),
    .busy(a_busy), .done(a_done), .rdata(a_rdata), .slverr(a_slverr),
    .*
  );

  apb_slave #(.ADDR_W(32), .DATA_W(32), .DEPTH(16), .WAIT_STATES(APB_WAIT_STATES)) u_apb_s (
    .PCLK(clk), .PRESETn(rst_n),
    .*
  );

  axi_lite_master #(.ADDR_W(32), .DATA_W(32)) u_axi_m (
    .ACLK(clk), .ARESETn(rst_n),
    .req(x_req), .write(x_write), .addr(x_addr), .wdata(x_wdata), .wstrb(x_wstrb),
    .busy(x_busy), .done(x_done), .rdata(x_rdata), .resp(x_resp),
    .*
  );

  axi_lite_slave #(.ADDR_W(32), .DATA_W(32), .DEPTH(16)) u_axi_s (
    .ACLK(clk), .ARESETn(rst_n),
    .*
  );

  // ---------------- Traffic generators (same workload for both) -------------
  traffic_gen u_gen_apb (
    .clk(clk), .busy(a_busy),
    .req(a_req), .write(a_write), .addr(a_addr), .wdata(a_wdata), .wstrb(a_wstrb_unused)
  );

  traffic_gen u_gen_axi (
    .clk(clk), .busy(x_busy),
    .req(x_req), .write(x_write), .addr(x_addr), .wdata(x_wdata), .wstrb(x_wstrb)
  );

  // ---------------- Per-cycle event flags for the monitors ----------------
  wire apb_stall = PSEL && PENABLE && !PREADY;
  wire apb_beat  = PSEL && PENABLE &&  PREADY;

  wire axi_stall = x_busy && ((AWVALID && !AWREADY) || (WVALID && !WREADY) ||
                              (BREADY  && !BVALID)  ||
                              (ARVALID && !ARREADY) || (RREADY && !RVALID));
  wire axi_beat  = (WVALID && WREADY) || (RVALID && RREADY);

  perf_monitor #(.NAME("APB"), .MAX_TXN(N_TXN+8), .BYTES_PER_TXN(BYTES_PER_TXN),
                 .CLK_NS(CLK_PERIOD_NS)) u_mon_apb (
    .clk(clk), .rst_n(rst_n),
    .req(a_req), .busy(a_busy), .done(a_done),
    .stall(apb_stall), .data_beat(apb_beat)
  );

  perf_monitor #(.NAME("AXI4-Lite"), .MAX_TXN(N_TXN+8), .BYTES_PER_TXN(BYTES_PER_TXN),
                 .CLK_NS(CLK_PERIOD_NS)) u_mon_axi (
    .clk(clk), .rst_n(rst_n),
    .req(x_req), .busy(x_busy), .done(x_done),
    .stall(axi_stall), .data_beat(axi_beat)
  );

  // ---------------- Result storage / reporting ----------------
  res_t res_apb [NUM_SCEN];
  res_t res_axi [NUM_SCEN];
  int   errors = 0;
  logic [31:0] exp_mem [16];

  task automatic row_r(input string name, input real a, input real x);
    $display("  %-34s | %12.2f | %12.2f", name, a, x);
  endtask

  task automatic row_i(input string name, input int a, input int x);
    $display("  %-34s | %12d | %12d", name, a, x);
  endtask

  task automatic check_integrity();
    for (int j = 0; j < N_TXN; j++) exp_mem[j % 16] = data_fn(j);
    for (int i = 0; i < 16; i++) begin
      if (u_apb_s.mem[i] !== exp_mem[i]) begin
        errors++;
        $display("ERROR: APB slave mem[%0d] = 0x%08h, expected 0x%08h", i, u_apb_s.mem[i], exp_mem[i]);
      end
      if (u_axi_s.mem[i] !== exp_mem[i]) begin
        errors++;
        $display("ERROR: AXI slave mem[%0d] = 0x%08h, expected 0x%08h", i, u_axi_s.mem[i], exp_mem[i]);
      end
    end
    if (u_mon_apb.res.n_txn != N_TXN) begin
      errors++; $display("ERROR: APB completed %0d of %0d transactions", u_mon_apb.res.n_txn, N_TXN);
    end
    if (u_mon_axi.res.n_txn != N_TXN) begin
      errors++; $display("ERROR: AXI completed %0d of %0d transactions", u_mon_axi.res.n_txn, N_TXN);
    end
  endtask

  task automatic print_scenario(input int s);
    res_t a, x;
    a = res_apb[s];
    x = res_axi[s];
    $display("");
    $display("============================================================================");
    $display(" Scenario %0d : idle gap = %s cycle(s), %0d write transactions x %0d bytes",
             s, gap_name(a.gap_mode), N_TXN, BYTES_PER_TXN);
    $display("============================================================================");
    $display("  %-34s | %12s | %12s", "Metric", "APB", "AXI4-Lite");
    $display("  -----------------------------------+--------------+-------------");
    row_i("Transactions completed",              a.n_txn,       x.n_txn);
    row_i("Elapsed time (cycles)",               a.elapsed_cyc, x.elapsed_cyc);
    row_i("Transaction latency - min (cycles)",  a.lat_min,     x.lat_min);
    row_r("Average latency (cycles)",            a.lat_avg,     x.lat_avg);
    row_r("Average latency (ns)",                a.lat_avg_ns,  x.lat_avg_ns);
    row_i("Transaction latency - max (cycles)",  a.lat_max,     x.lat_max);
    row_r("Throughput (MB/s)",                   a.thr_mbps,    x.thr_mbps);
    row_r("Transaction rate (Mtxn/s)",           a.rate_mtps,   x.rate_mtps);
    row_r("Bus utilisation (%)",                 a.util_pct,    x.util_pct);
    row_r("Data-phase efficiency (%)",           a.eff_pct,     x.eff_pct);
    row_i("Master stall cycles (total)",         a.stall_total, x.stall_total);
    row_r("Master stall cycles per txn",         a.stall_avg,   x.stall_avg);
    row_i("Inter-txn gap - min (cycles)",        a.gap_min,     x.gap_min);
    row_r("Inter-txn gap - avg (cycles)",        a.gap_avg,     x.gap_avg);
    row_i("Inter-txn gap - max (cycles)",        a.gap_max,     x.gap_max);
  endtask

  task automatic print_txn_latency(input int cnt);
    $display("");
    $display("  Per-transaction latency, first %0d transactions of scenario 0", cnt);
    $display("  (request accepted -> transfer complete)");
    $display("  Txn# |  APB (cycles / ns)  |  AXI4-Lite (cycles / ns)");
    $display("  -----+---------------------+-------------------------");
    for (int i = 0; i < cnt; i++)
      $display("  %4d |  %4d / %7.1f ns   |  %4d / %7.1f ns",
               i,
               u_mon_apb.lat_arr[i], u_mon_apb.lat_arr[i] * CLK_PERIOD_NS,
               u_mon_axi.lat_arr[i], u_mon_axi.lat_arr[i] * CLK_PERIOD_NS);
  endtask

  task automatic print_summary();
    real best_a, best_x, theo;
    int  gap_a, gap_x;
    res_t a, x;

    $display("");
    $display("############################################################################");
    $display("#                 SUMMARY  (APB vs AXI4-Lite, same conditions)             #");
    $display("############################################################################");
    $display(" Clock = %0.0f MHz, data width = 32 bit, %0d txns/scenario, APB wait states = %0d",
             1000.0 / CLK_PERIOD_NS, N_TXN, APB_WAIT_STATES);

    $display("");
    $display(" Table A : throughput, transaction rate, bus utilisation");
    $display("  %-11s | %9s %9s | %9s %9s | %8s %8s", "gap(cyc)",
             "APB MB/s", "AXI MB/s", "APB Mtx/s", "AXI Mtx/s", "APB util%", "AXI util%");
    $display("  ------------+---------------------+---------------------+------------------");
    for (int s = 0; s < NUM_SCEN; s++) begin
      a = res_apb[s]; x = res_axi[s];
      $display("  %-11s | %9.2f %9.2f | %9.2f %9.2f | %8.2f %8.2f",
               gap_name(a.gap_mode), a.thr_mbps, x.thr_mbps,
               a.rate_mtps, x.rate_mtps, a.util_pct, x.util_pct);
    end

    $display("");
    $display(" Table B : latency, master stalls, measured inter-transaction gap");
    $display("  %-11s | %8s %8s | %8s %8s | %8s %8s | %8s %8s", "gap(cyc)",
             "APB lat", "AXI lat", "APB max", "AXI max", "APB stl/t", "AXI stl/t",
             "APB gap", "AXI gap");
    $display("  ------------+-------------------+-------------------+-------------------+------------------");
    for (int s = 0; s < NUM_SCEN; s++) begin
      a = res_apb[s]; x = res_axi[s];
      $display("  %-11s | %8.2f %8.2f | %8d %8d | %8.2f %8.2f | %8.2f %8.2f",
               gap_name(a.gap_mode), a.lat_avg, x.lat_avg, a.lat_max, x.lat_max,
               a.stall_avg, x.stall_avg, a.gap_avg, x.gap_avg);
    end
    $display("  (lat = average latency in cycles, stl/t = stall cycles per txn,");
    $display("   gap = measured average idle cycles between transactions)");

    // Maximum throughput
    best_a = 0.0; best_x = 0.0; gap_a = 0; gap_x = 0;
    for (int s = 0; s < NUM_SCEN; s++) begin
      if (res_apb[s].thr_mbps > best_a) begin best_a = res_apb[s].thr_mbps; gap_a = res_apb[s].gap_mode; end
      if (res_axi[s].thr_mbps > best_x) begin best_x = res_axi[s].thr_mbps; gap_x = res_axi[s].gap_mode; end
    end
    theo = BYTES_PER_TXN * 1000.0 / CLK_PERIOD_NS;   // one 32-bit beat every cycle

    $display("");
    $display(" Maximum throughput (best scenario)");
    $display("  APB       : %8.2f MB/s  (gap = %s)  = %5.1f %% of the %0.0f MB/s one-beat-per-cycle limit",
             best_a, gap_name(gap_a), 100.0 * best_a / theo, theo);
    $display("  AXI4-Lite : %8.2f MB/s  (gap = %s)  = %5.1f %% of the %0.0f MB/s one-beat-per-cycle limit",
             best_x, gap_name(gap_x), 100.0 * best_x / theo, theo);

    $display("");
    if (errors == 0) $display(" DATA INTEGRITY: PASS  (both slaves hold the expected data)");
    else             $display(" DATA INTEGRITY: FAIL  (%0d errors)", errors);
    $display("############################################################################");
    $display("");
  endtask

  // ---------------- Main sequence ----------------
  int g;

  initial begin
    $dumpfile("dump.vcd");
    $dumpvars(0, perf_tb);

    rst_n = 0;
    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (3) @(posedge clk);

    $display("");
    $display("APB vs AXI4-Lite performance analysis: %0d scenarios, %0d txns each", NUM_SCEN, N_TXN);

    for (int s = 0; s < NUM_SCEN; s++) begin
      g = get_gap(s);

      // Same workload, same gap, same time - on both buses
      fork
        u_gen_apb.run(N_TXN, g);
        u_gen_axi.run(N_TXN, g);
      join

      repeat (3) @(posedge clk);     // let the monitors see the last 'done'

      u_mon_apb.compute(g);
      u_mon_axi.compute(g);
      res_apb[s] = u_mon_apb.res;
      res_axi[s] = u_mon_axi.res;

      check_integrity();
      print_scenario(s);
      if (s == 0) print_txn_latency(8);

      u_mon_apb.clear_stats();
      u_mon_axi.clear_stats();
      repeat (5) @(posedge clk);
    end

    print_summary();
    $finish;
  end

  // Watchdog
  initial begin
    #20_000_000;
    $display("TIMEOUT");
    $finish;
  end

endmodule
# AMBA APB vs. AXI-Lite Performance Benchmark & Comparative Analysis

A comprehensive SystemVerilog/UVM benchmarking and architectural analysis framework designed to quantitatively evaluate the performance, throughput, latency, and hardware overhead trade-offs between the **AMBA APB (Advanced Peripheral Bus)** and **AMBA AXI-Lite** protocols.

This repository provides reproducible simulation harnesses, wait-state injection mechanisms, and passive UVM performance monitoring to collect empirical data for academic publication.

---

## 1. Project Objectives & Research Scope

Modern System-on-Chip (SoC) architectures require balanced interconnect topologies. While APB is traditionally favored for low-power control registers due to its minimal pin count and simple two-phase state machine, AXI-Lite offers decoupled read/write channels capable of pipelining transactions.

This project bridges functional verification and architectural modeling by answering:

1. What is the empirical latency and throughput penalty of APB's half-duplex, non-pipelined architecture under identical workloads?
2. How resilient is AXI-Lite's decoupled pipeline when subjected to varying degrees of slave backpressure (wait states)?
3. What is the quantitative area overhead (LUTs, FFs, Slice count) required to achieve AXI-Lite's performance gain over APB?

---

## 2. Target Performance Metrics

All metrics are snooped passively at the bus boundary and written to CSV for statistical evaluation:

| Metric | Measurement Methodology | Unit |
| --- | --- | --- |
| **Peak Throughput** | Transfers completed over total clock cycles elapsed under back-to-back traffic | Transfers/Cycle (MB/s) |
| **Transaction Latency** | Clock cycles from address presentation (`PSEL`/`AxVALID`) to handshake termination (`PREADY`/`xVALID` & `xREADY`) | Clock Cycles |
| **Concurrent R/W Efficiency** | Bandwidth under simultaneous 50% Read and 50% Write traffic models | Transfers/Cycle |
| **Backpressure Degradation** | Latency increase curve as slave ready signals are randomly suppressed (10% to 70% duty cycle) | Latency vs. Wait-State % |
| **Hardware Footprint** | Post-synthesis resource utilization using standard FPGA target | LUTs, FFs, Slice Count |

---

## 3. Toolchain & Dependencies

* **Simulation & Synthesis:** AMD Vivado (XSim `xvlog`, `xelab`, `xsim`) with SystemVerilog and native UVM 1.2 support
* **Waveform Analysis:** GTKWave (via VCD trace generation `$dumpfile`/`$dumpvars`)
* **Data Analysis & Visualization:** Python 3.10+ (`pandas`, `matplotlib`, `seaborn`)
* **Build Automation:** GNU Make (4.0+), Vivado TCL

---

## 4. Third-Party IP & Submodules

The project leverages verified open-source RTL implementations and UVM VIPs to isolate the study purely to architectural behavior:

* **RTL Components (`third_party/rtl`):**
* [PULP Platform APB](https://github.com/pulp-platform/apb?utm_source=gemini): Standard-compliant APB slave and peripheral memory wrappers.
* [Alex Forencich Verilog-AXI](https://github.com/alexforencich/verilog-axi?utm_source=gemini): Standard-compliant AXI-Lite memory slave models (`axi_ram.v`).


* **UVM Verification IPs (`third_party/dv_vip`):**
* [muneebullashariff/apb_vip](https://github.com/muneebullashariff/apb_vip?utm_source=gemini): UVM APB Master Agent, Sequencer, Driver, and Monitor.
* [taichi-ishitani/tvip-axi](https://github.com/taichi-ishitani/tvip-axi?utm_source=gemini): Parameterized UVM AXI Master Agent configured for AXI-Lite handshakes.



---

## 5. Repository Directory Structure

```text
ASIC_PROJECT/
├── docs/                     # Paper drafts, architecture diagrams, and timing charts
├── dv/                       # Verification environment (UVM)
│   ├── sequences/            # Performance traffic generators (Burst, Mixed R/W, Backpressure)
│   ├── tb_top/               # Testbench top, VCD dump control, and interface definitions
│   │   ├── apb_if.sv
│   │   ├── axi_lite_if.sv
│   │   └── tb_top.sv
│   ├── tests/                # UVM test definitions for each benchmark scenario
│   └── uvm_env/              # Custom Performance Monitor (PerfMon), Scoreboard, and UVM Env
├── firmware/                 # Optional bare-metal CPU driver stubs
├── fpga/
│   └── constraints/          # Target board physical pin and timing constraints (.xdc)
├── rtl/                      # Design Under Test (DUT)
│   ├── bus/                  # Protocol conversion bridges or crossbars
│   ├── cpu_wrapper/          # Master processor wrapper modules (if driving via core)
│   └── memory/               # APB and AXI-Lite SRAM wrappers with wait-state injectors
├── scripts/                  # Automation scripts
│   ├── make/                 # Modular Makefile targets
│   ├── python/               # CSV parsing and plot generation scripts
│   └── vivado/               # Synthesis and resource utilization report scripts
├── third_party/              # Git submodules for external RTL and VIPs
│   ├── dv_vip/
│   └── rtl/
├── build_vivado.tcl          # Top-level Vivado project build script
├── Makefile                  # Main simulation and build entry point
└── README.md

```

---

## 6. Project Execution Phases

### Phase 1: Environment Setup & Submodule Integration

* Initialize Git repository and pull submodules into `third_party/`.
* Establish directory structure, basic compile targets in `Makefile`, and Vivado TCL hooks.
* Verify XSim compilation and GTKWave trace generation with a barebones SystemVerilog top-level.

### Phase 2: RTL Wrappers & Wait-State Injection

* Wrap PULP APB and Forencich AXI-Lite SRAM modules inside `rtl/memory/`.
* Design a configurable wait-state injection block inside each wrapper to dynamically delay `PREADY` and `AWREADY`/`WREADY`/`ARREADY`.
* Verify basic read/write transactions via directed smoke tests.

### Phase 3: UVM Verification & Performance Monitor (PerfMon)

* Integrate APB and AXI-Lite UVM master agents from `third_party/dv_vip/`.
* Develop `dv/uvm_env/perf_monitor.sv` with cycle-accurate timestamp tracking.
* Implement CSV file export routines in the UVM `report_phase` to log latency per transfer and instantaneous throughput.

### Phase 4: Benchmarking Suite Implementation

* **Scenario A (Zero Wait-State):** 1,000 back-to-back writes and reads to measure theoretical peak bandwidth.
* **Scenario B (Concurrent Duplex):** Simultaneous 50/50 read and write requests targeting disjoint addresses.
* **Scenario C (Stress & Backpressure):** Pseudo-random ready stall injection across variable duty cycles.

### Phase 5: Synthesis & Hardware Cost Profiling

* Execute Vivado out-of-context synthesis runs for both memory wrappers using `scripts/vivado/`.
* Extract Look-Up Table (LUT), Flip-Flop (FF), and timing slack ($F_{\max}$) reports.

### Phase 6: Data Analysis & Manuscript Drafting

* Process CSV logs using Python scripts to plot latency histograms and throughput degradation curves.
* Draft the comparative paper targeting venues such as DVCon, IEEE VLSID, or VDAT.

---

## 7. Quick Start

### 1. Clone with Submodules

```bash
git clone --recursive <repo-url>
cd ASIC_PROJECT

```

### 2. Run Baseline Smoke Test

```bash
make compile
make run

```

### 3. Inspect Waveforms in GTKWave

```bash
make wave

```
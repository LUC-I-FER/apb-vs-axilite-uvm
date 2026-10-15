# Variables
TOP_MODULE = tb_top
SNAPSHOT   = tb_top_sim
VCD_FILE   = dump.vcd

# Include directories
INC_DIRS   = -i dv/tb_top -i dv/uvm_env -i rtl/memory -i rtl/bus \
             -i third_party/rtl/pulp_apb/src -i third_party/rtl/pulp_apb/include

# Source files: dynamically find all .v and .sv files in rtl/
RTL_SRCS   = $(shell find rtl -type f \( -name "*.sv" -o -name "*.v" \))

TB_SRCS    = dv/tb_top/tb_top.sv

RTL_SRCS  += third_party/rtl/pulp_apb/src/apb_intf.sv \
             third_party/rtl/verilog_axi/rtl/axi_ram.v

.PHONY: all compile elaborate run wave clean

all: run

# 1. Compile SystemVerilog files with UVM package
compile:
	xvlog -sv -L uvm $(INC_DIRS) $(RTL_SRCS) $(TB_SRCS)

# 2. Elaborate design and create simulation snapshot
elaborate: compile
	xelab -L uvm -timescale 1ns/1ps $(TOP_MODULE) -s $(SNAPSHOT)

# 3. Run simulation batch (dumps dump.vcd)
run: elaborate
	xsim $(SNAPSHOT) -R

# 4. Open waveform in GTKWave
wave:
	gtkwave $(VCD_FILE) &

# Clean build artifacts
clean:
	rm -rf xsim.dir *.log *.pb *.jou *.vcd $(SNAPSHOT)
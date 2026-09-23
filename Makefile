# Variables
TOP_MODULE = tb_top
SNAPSHOT   = tb_top_sim
VCD_FILE   = dump.vcd

# Include directories
INC_DIRS   = -i dv/tb_top -i dv/uvm_env -i rtl/memory -i rtl/bus

# Source files
RTL_SRCS   = rtl/memory/apb_sram.sv \
             rtl/memory/axi_lite_sram.sv

TB_SRCS    = dv/tb_top/apb_if.sv \
             dv/tb_top/axi_lite_if.sv \
             dv/tb_top/tb_top.sv

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
VERILATOR ?= verilator
BENDER    ?= bender
BUILD     ?= build

# Hart counts the regression sweeps over
HARTS ?= 1 2 3 4 7

RTL := src/aclint_reg_pkg.sv \
       src/frac_tick.sv \
       src/aclint_core.sv \
       src/aclint_flat.sv \
       src/aclint.sv

TB := test/aclint_tb.sv

REG_IF   = $(shell $(BENDER) path register_interface)
TB_DEPS  = +incdir+$(REG_IF)/include $(REG_IF)/src/reg_intf.sv

VFLAGS := --timing --timescale 1ns/1ps -Wall
VLINT_FLAGS := -Wno-SYNCASYNCNET
VSIM_FLAGS := --binary --assert --trace -Wno-UNUSEDSIGNAL -Wno-SYNCASYNCNET -Wno-DECLFILENAME

.PHONY: all lint sim regression ide clean
all: lint regression

# File list for integration into a larger project
sources.f: Bender.yml Bender.lock
	$(BENDER) script flist-plus -t src -t synthesis > $@

ide: .slang/aclint.f
.slang/aclint.f: Bender.yml Bender.lock .slang/flist.sh
	./.slang/flist.sh > $@

lint: $(RTL)
	$(VERILATOR) --lint-only $(VFLAGS) $(VLINT_FLAGS) --top aclint $(RTL)

sim: $(BUILD)/aclint_tb
	$<

# Re-run the testbench for every hart count in HARTS
regression: $(RTL) $(TB)
	@mkdir -p $(BUILD)
	@for n in $(HARTS); do \
		echo "=== NumHarts=$$n ==="; \
		$(VERILATOR) $(VFLAGS) $(VSIM_FLAGS) --top aclint_tb -GNumHarts=$$n \
			--Mdir $(BUILD)/h$$n -o aclint_tb $(TB_DEPS) $(RTL) $(TB) || exit 1; \
		$(BUILD)/h$$n/aclint_tb || exit 1; \
	done
	@echo "=== regression passed for hart counts: $(HARTS) ==="

$(BUILD)/aclint_tb: $(RTL) $(TB)
	$(VERILATOR) $(VFLAGS) $(VSIM_FLAGS) --top aclint_tb \
		--Mdir $(BUILD) -o aclint_tb $(TB_DEPS) $(RTL) $(TB)

clean:
	rm -rf $(BUILD) sources.f

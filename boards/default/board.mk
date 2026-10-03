# Board: vboard1 = iCE40 HX8K (CT256) on a mock PCB, 25 MHz oscillator.
# The mock board runs the *bitstream*: icepack -> iceunpack -> icebox_vlog -> Verilator.

FREQ_MHZ ?= 25
PCF      := $(BOARD_DIR)/vboard.pcf
FRONTEND := $(BOARD_DIR)/frontend.cpp
CELLS     = $(shell $(SUITE_ENV) yosys-config --datdir)/ice40/cells_sim.v

# ---- 1. synthesis ---------------------------------------------------------------------
$(BUILD)/$(TOP).json: $(SRC) | $(BUILD)
	@echo "[yosys]   synthesizing $(TOP) for iCE40   ($$(command -v yosys))"
	@yosys -q -l $(BUILD)/yosys.log $(YS_PLUGIN) -p "$(YS_READ); synth_ice40 -top $(TOP) -json $@" \
	  || $(YS_FAIL)

# ---- 2. place & route against the board's pin constraints -------------------------------
$(BUILD)/$(TOP).asc: $(BUILD)/$(TOP).json $(PCF)
	@echo "[nextpnr] place & route: HX8K CT256 @ $(FREQ_MHZ) MHz"
	@nextpnr-ice40 --hx8k --package ct256 --json $< --pcf $(PCF) --asc $@ \
	  --freq $(FREQ_MHZ) --log $(BUILD)/nextpnr.log $(NEXTPNR_FLAGS) >/dev/null 2>&1 \
	  || { grep -E 'ERROR|FAIL' $(BUILD)/nextpnr.log | head; exit 1; }
	@grep -E 'ICESTORM_(LC|RAM): +[0-9]' $(BUILD)/nextpnr.log | sed 's/^Info: *//; s/^/          /'
	@grep 'Max frequency' $(BUILD)/nextpnr.log | tail -1 | sed 's/^Info: /          /'

# ---- 3. bitstream --------------------------------------------------------------------------
$(BUILD)/$(TOP).bin: $(BUILD)/$(TOP).asc
	@icepack $< $@
	@echo "[icepack] $@ ($$(stat -c %s $@) bytes)"

# ---- 4. "load" the bitstream: decode it back into a netlist -------------------------------
$(BUILD)/netlist.v: $(BUILD)/$(TOP).bin $(PCF)
	@iceunpack $< $(BUILD)/unpacked.asc
	@icebox_vlog -s -S -n chip -p $(PCF) $(BUILD)/unpacked.asc | python3 $(BOARD_DIR)/fixnetlist.py > $@

# board wiring is generated from the pin file
$(BUILD)/pcb_conn.vh: $(PCF) | $(BUILD)
	@awk '$$1=="set_io" && $$2!="clk" { n=$$2; if (n ~ /\[/) printf ", .\\%s (%s)\n", n, n; else printf ", .%s (%s)\n", n, n }' $< > $@

# BRAM etc. need the iCE40 simulation models, added automatically if the netlist has any
GATE_FILES  = $(BOARD_DIR)/pcb.v $(BUILD)/netlist.v $$(grep -q '^SB_' $(BUILD)/netlist.v && echo -DICE40_HX $(CELLS))
GATE_DEPS  := $(BUILD)/pcb_conn.vh $(BOARD_DIR)/pcb.v
RTL_FILES  := $(BOARD_DIR)/pcb.v $(BUILD)/rtl.v
RTL_DEPS   := $(BOARD_DIR)/pcb.v
RTL_FLAGS  := -DRTL -DTOP_MODULE=$(TOP)

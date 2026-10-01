# vboard.mk - include from a project Makefile that sets TOP and SRC.
#
#   make          synthesize + place&route + bitstream   (yosys -> nextpnr -> icepack)
#   make run      "flash" the bitstream onto the mock board and open it (alias: make prog)
#   make run-rtl  same board, but simulating your RTL directly: skips P&R
#   make shot     same, headless, saves build/shot.bmp   (CYCLES=, SW=, BTN= to control it)
#   make wave     headless run that dumps the FPGA pins to build/pins.vcd (WAVE_CYCLES=100000)
#   make sim      RTL simulation of a testbench:  make sim TB=tb.vhd   (-> build/rtl.fst or rtl.vcd)
#   make clean

TOP       ?= top
BUILD     ?= build
FREQ_MHZ  ?= 25
# SV_READER: slang (yosys-slang, full SV) | builtin (yosys's read_verilog -sv)
SV_READER ?= slang
CYCLES    ?= 3000000
WAVE_CYCLES ?= 100000
SW        ?= 0
BTN       ?= 0
TB_TOP    ?= tb

ROOT   := $(patsubst %/,%,$(dir $(lastword $(MAKEFILE_LIST))))
BOARDS  := $(ROOT)/boards
# change board with: make run BOARD=[board]
# Use default if BOARD is undefined or empty.
ifeq ($(strip $(BOARD)),)
  BOARD := default
endif
BOARD_DIR := $(BOARDS)/$(BOARD)
PCF    := $(BOARD_DIR)/vboard.pcf
# simulation models for BRAM etc., added automatically if the netlist contains any
CELLS  := $(shell yosys-config --datdir)/ice40/cells_sim.v
SDL_CFLAGS := $(shell sdl2-config --cflags)
SDL_LIBS   := $(shell sdl2-config --libs)

VHDL_SRC := $(filter %.vhd %.vhdl,$(SRC))
HDL_SRC  := $(filter %.v %.sv,$(SRC))

# ---- pick the yosys front-end from the source language ----------------------------
ifneq ($(VHDL_SRC),)
  ifneq ($(HDL_SRC),)
    $(error Mixed VHDL and Verilog/SV sources are not supported in one project)
  endif
  YS_PLUGIN := -m ghdl
  YS_READ   := ghdl --std=08 $(VHDL_SRC) -e $(TOP)
else ifeq ($(SV_READER),slang)
  YS_PLUGIN := -m slang
  YS_READ   := read_slang --top $(TOP) $(HDL_SRC)
else
  YS_READ   := read_verilog -sv $(HDL_SRC); hierarchy -top $(TOP)
endif

.PHONY: all run prog run-rtl shot wave sim clean
all: $(BUILD)/$(TOP).bin

$(BUILD):
	@mkdir -p $@

# ---- synthesis ---------------------------------------------------------------------
$(BUILD)/$(TOP).json: $(SRC) | $(BUILD)
	@echo "[yosys]   synthesizing $(TOP) for iCE40"
	@yosys -q -l $(BUILD)/yosys.log $(YS_PLUGIN) -p "$(YS_READ); synth_ice40 -top $(TOP) -json $@" \
	  || { tail -20 $(BUILD)/yosys.log; exit 1; }

# ---- place & route against the board's pin constraints -------------------------------
$(BUILD)/$(TOP).asc: $(BUILD)/$(TOP).json $(PCF)
	@echo "[nextpnr] place & route: HX8K CT256 @ $(FREQ_MHZ) MHz"
	@nextpnr-ice40 --hx8k --package ct256 --json $< --pcf $(PCF) --asc $@ \
	  --freq $(FREQ_MHZ) --log $(BUILD)/nextpnr.log $(NEXTPNR_FLAGS) >/dev/null 2>&1 \
	  || { grep -E 'ERROR|FAIL' $(BUILD)/nextpnr.log | head; exit 1; }
	@grep -E 'ICESTORM_(LC|RAM): +[0-9]' $(BUILD)/nextpnr.log | sed 's/^Info: *//; s/^/          /'
	@grep 'Max frequency' $(BUILD)/nextpnr.log | tail -1 | sed 's/^Info: /          /'

# ---- bitstream --------------------------------------------------------------------------
$(BUILD)/$(TOP).bin: $(BUILD)/$(TOP).asc
	@icepack $< $@
	@echo "[icepack] $@ ($$(stat -c %s $@) bytes)"

# ---- mock board: bitstream -> netlist -> Verilator model + SDL front panel --------
$(BUILD)/netlist.v: $(BUILD)/$(TOP).bin $(PCF)
	@iceunpack $< $(BUILD)/unpacked.asc
	@icebox_vlog -s -S -n chip -p $(PCF) $(BUILD)/unpacked.asc | python3 $(BOARD_DIR)/fixnetlist.py > $@

$(BUILD)/pcb_conn.vh: $(PCF)
	@awk '$$1=="set_io" && $$2!="clk" { n=$$2; if (n ~ /\[/) printf ", .\\%s (%s)\n", n, n; else printf ", .%s (%s)\n", n, n }' $< > $@

# $(1)=obj dir  $(2)=extra verilator flags  $(3)=extra cflags  $(4)=design files
define VERILATE
	@verilator --cc --exe --build -j 0 -Wno-fatal -Wno-lint -Wno-style --top-module pcb \
	  -I$(BUILD) -Mdir $(BUILD)/$(1) $(2) -CFLAGS "-O2 $(SDL_CFLAGS) $(3)" -LDFLAGS "$(SDL_LIBS)" \
	  -o vboard $(BOARD_DIR)/pcb.v $(BOARD_DIR)/vboard.cpp $(4) >$(BUILD)/$(1).log 2>&1 \
	  || { tail -30 $(BUILD)/$(1).log; exit 1; }
endef

BOARD_DEPS := $(BOARD_DIR)/pcb.v $(BOARD_DIR)/vboard.cpp
NETLIST    := $(BUILD)/netlist.v $$(grep -q '^SB_' $(BUILD)/netlist.v && echo -DICE40_HX $(CELLS))

$(BUILD)/vboard: $(BUILD)/netlist.v $(BUILD)/pcb_conn.vh $(BOARD_DEPS)
	@echo "[board]   loading bitstream onto vboard-1"
	$(call VERILATE,obj,,,$(NETLIST))
	@cp $(BUILD)/obj/vboard $@

$(BUILD)/vboard_trace: $(BUILD)/netlist.v $(BUILD)/pcb_conn.vh $(BOARD_DEPS)
	$(call VERILATE,obj_trace,--trace,-DWITH_VCD,$(NETLIST))
	@cp $(BUILD)/obj_trace/vboard $@

# fast mode: skip place&route, simulate the RTL itself on the same board
$(BUILD)/rtl.v: $(SRC) | $(BUILD)
	@yosys -q $(YS_PLUGIN) -p "$(YS_READ); proc; opt_clean; write_verilog -noattr $@" \
	  || exit 1

$(BUILD)/vboard_rtl: $(BUILD)/rtl.v $(BOARD_DEPS)
	@echo "[board]   RTL mode (not the bitstream!)"
	$(call VERILATE,obj_rtl_board,-DRTL -DTOP_MODULE=$(TOP),,$(BUILD)/rtl.v)
	@cp $(BUILD)/obj_rtl_board/vboard $@

run prog: $(BUILD)/vboard
	@$(BUILD)/vboard

run-rtl: $(BUILD)/vboard_rtl
	@$(BUILD)/vboard_rtl

shot: $(BUILD)/vboard
	@$(BUILD)/vboard --cycles $(CYCLES) --sw $(SW) --btn $(BTN) --shot $(BUILD)/shot.bmp
	@echo "[board]   $(BUILD)/shot.bmp"

wave: $(BUILD)/vboard_trace
	@$(BUILD)/vboard_trace --cycles $(WAVE_CYCLES) --sw $(SW) --btn $(BTN) --vcd $(BUILD)/pins.vcd
	@echo "[board]   $(BUILD)/pins.vcd   (gtkwave $(BUILD)/pins.vcd)"

# ---- RTL simulation (pre-synthesis), language picked from the testbench extension ------
sim: | $(BUILD)
ifeq ($(TB),)
	@echo "usage: make sim TB=<testbench file>  (TB_TOP=$(TB_TOP))"; exit 1
else ifneq ($(filter %.vhd %.vhdl,$(TB)),)
	@mkdir -p $(BUILD)/ghdl
	@ghdl -a --std=08 --workdir=$(BUILD)/ghdl $(VHDL_SRC) $(TB)
	@ghdl -e --std=08 --workdir=$(BUILD)/ghdl -o $(BUILD)/ghdl/$(TB_TOP) $(TB_TOP)
	@$(BUILD)/ghdl/$(TB_TOP) --fst=$(BUILD)/rtl.fst
	@echo "[sim]     $(BUILD)/rtl.fst   (gtkwave $(BUILD)/rtl.fst)"
else
	@verilator --binary --timing --trace -Wno-fatal -Wno-lint -Wno-style --top-module $(TB_TOP) \
	  -Mdir $(BUILD)/obj_rtl $(HDL_SRC) $(TB) -o rtl_sim >$(BUILD)/obj_rtl.log 2>&1 \
	  || { tail -30 $(BUILD)/obj_rtl.log; exit 1; }
	@$(BUILD)/obj_rtl/rtl_sim
	@echo "[sim]     waveform: $(BUILD)/rtl.vcd (written by your testbench via \$$dumpfile)"
endif

clean:
	rm -rf $(BUILD)

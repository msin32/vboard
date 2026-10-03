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
COMMON    := $(abspath $(ROOT)/common)
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
# all: $(BUILD)/$(TOP).bin
.DEFAULT_GOAL := all

$(BUILD):
	@mkdir -p $@

# ---- board-specific part: pin file, synthesis/P&R/bitstream recipes, wiring, front panel --------
# A board.mk must define:
#   FREQ_MHZ                    default clock constraint for P&R
#   $(BUILD)/$(TOP).bin         the bitstream (the "all" target)
#   $(BUILD)/netlist.v          the netlist the mock board simulates in "run" mode
#   FRONTEND                    the board's SDL front panel (C++)
#   GATE_FILES / GATE_DEPS      verilator inputs / extra prerequisites for "run" mode
#   RTL_FILES  / RTL_DEPS       the same for "run-rtl" mode (uses $(BUILD)/rtl.v)
include $(BOARD_DIR)/board.mk

all: $(BUILD)/$(TOP).bin

# ---- RTL netlist (yosys elaborates any front-end to plain Verilog) ----------------------------
$(BUILD)/rtl.v: $(SRC) | $(BUILD)
	@yosys -q $(YS_PLUGIN) -p "$(YS_READ); proc; opt_clean; write_verilog -noattr $@" || exit 1

# ---- mock board: verilate netlist + wiring + front panel ----------------------------------
# $(1)=obj dir  $(2)=extra verilator flags  $(3)=extra cflags  $(4)=design files
define VERILATE
	@verilator --cc --exe --build -j 0 -Wno-fatal -Wno-lint -Wno-style --top-module pcb \
	  -I$(BUILD) -Mdir $(BUILD)/$(1) $(2) -CFLAGS "-O2 -I$(COMMON) $(SDL_CFLAGS) $(3)" -LDFLAGS "$(SDL_LIBS)" \
	  -o vboard $(FRONTEND) $(4) >$(BUILD)/$(1).log 2>&1 \
	  || { tail -30 $(BUILD)/$(1).log; exit 1; }
endef

$(BUILD)/vboard: $(BUILD)/netlist.v $(GATE_DEPS) $(FRONTEND)
	@echo "[board]   loading design onto $(BOARD)"
	$(call VERILATE,obj,$(GATE_FLAGS),,$(GATE_FILES))
	@cp $(BUILD)/obj/vboard $@

$(BUILD)/vboard_trace: $(BUILD)/netlist.v $(GATE_DEPS) $(FRONTEND)
	$(call VERILATE,obj_trace,--trace $(GATE_FLAGS),-DWITH_VCD,$(GATE_FILES))
	@cp $(BUILD)/obj_trace/vboard $@

$(BUILD)/vboard_rtl: $(BUILD)/rtl.v $(RTL_DEPS) $(FRONTEND)
	@echo "[board]   RTL mode (simulating source)"
	$(call VERILATE,obj_rtl_board,$(RTL_FLAGS),,$(RTL_FILES))
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

#==============================================================================
# File    : Makefile
# Project : MXDOTP XIF Coprocessor - Verilator Build
#------------------------------------------------------------------------------
# Targets:
#   make / make full     full system regression (tb_mxdotp_core).
#                        (`make all` is still kept as an alias.)
#   make mxdotp          standalone dot-product-engine unit test (tb_mxdotp_unit.sv
#                        driving mxdotp_dotp_engine.sv directly, no core/XIF) -
#                        see UNIT_TESTS below. NOT an alias for the full build:
#                        it used to be, before "mxdotp" became a registered unit
#                        test name in its own right (Phase where fp4r was
#                        renamed to mxdotp) - see the note at UNIT_TESTS.
#   make fp4             standalone FP4 fused-engine unit test (tb_fp4_unit.sv
#                        driving mxdotp_fp4_fused_engine.sv directly, no core/XIF).
#   make fp8             standalone FP8 fused-engine unit test (tb_fp8_unit.sv
#                        driving mxdotp_fp8_fused_engine.sv directly).
#   make m2              standalone M2XFP4 fused-engine unit test (tb_m2_unit.sv
#                        driving mxdotp_m2xfp4_fused_engine.sv directly). NOTE:
#                        the engine is not yet routed by mxdotp_xif.sv, so this
#                        unit test is currently the ONLY thing exercising it -
#                        `make mxdotp` does not reach it.
#   make mxfinal         standalone MXFINAL residue-accumulate unit test
#                        (tb_mxfinal_unit.sv driving mxdotp_final_engine.sv
#                        directly). Unlike fp4/fp8/m2, this engine exposes a
#                        plain busy_o/done_o handshake (no ready/id/valid), so
#                        its testbench has no backpressure to randomize -
#                        vectors are still issued back to back, exercising the
#                        BACK1/BACK2/BACK3 pipeline overlap.
#   make units           runs every registered standalone unit test in turn.
#   make clean           removes all build outputs (system + every unit test).
#
# Build outputs all land under one BUILD_ROOT (default: build/) rather than
# scattered per-target directories in tb/ itself:
#   build/system/        the full-system build (was tb/obj_dir)
#   build/units/<name>/  each unit test's build (was tb/obj_dir_<name>)
# `make clean` removes the whole BUILD_ROOT in one shot.
#
# Unit-test golden-vector .hex files live under tb/hex_vectors/, not loose in
# tb/ next to source - $$readmemh paths in each tb_<name>_unit.sv and each
# golden script's --emit-vectors default output path both point there.
#
# Adding a new standalone unit test (e.g. `make fp8`) once its RTL and
# testbench exist is exactly three lines - see "Standalone unit-engine
# testbenches" below:
#   1. add the engine's RTL source(s) to a new <name>_ENGINE_SRCS variable
#      (the shared mx_*.sv blocks come in automatically via MXDOTP_SHARED_SRCS
#       - list only the engine's OWN sources here)
#   2. add <name> to UNIT_TESTS
#   3. drop tb_<name>_unit.sv into tb/
# Nothing else in this file needs to change; the template generates the
# `make <name>` target, its build rule, and its `clean` hook automatically.
#==============================================================================

#----------------------------------------------------------------------------
# Verilator
#----------------------------------------------------------------------------

VERILATOR := $(shell which verilator5 || which verilator)
ifeq ($(VERILATOR),)
$(error Verilator not found in PATH)
endif

#----------------------------------------------------------------------------
# Directories
#----------------------------------------------------------------------------

ROOT_DIR      := ..
RTL_DIR       := $(ROOT_DIR)/rtl
TB_DIR        := .
BHV_DIR       := $(ROOT_DIR)/bhv
BUILD_ROOT    := $(TB_DIR)/build
# Full-system build only; each unit test gets its own $(1)_BUILD_DIR below,
# under build/units/ - see the UNIT_TEST_template.
BUILD_DIR     := $(BUILD_ROOT)/system
HEX_DIR       := $(TB_DIR)/hex_vectors

MXDOTP_RTL_DIR := $(RTL_DIR)/mxdotp

TOP_MODULE    := tb_mxdotp_core

MANIFEST      := $(ROOT_DIR)/cv32e40x_manifest.flist
VERILATOR_FLIST := $(BUILD_DIR)/verilator.f

# Core RTL files the generated filelist names (same filter as the
# $(VERILATOR_FLIST) rule below). Every build that reads that filelist lists
# them as prerequisites: a file reached only through -f is not one, so an
# edit to it would not rebuild the simulator (found 22 Oct 2026, MXR4DOT
# question 10 fix) - the same rule as for MXDOTP_SHARED_SRCS below.
CORE_SRCS := $(shell sed 's|$${DESIGN_RTL_DIR}|$(RTL_DIR)|g' $(MANIFEST) | \
	grep -v '^[[:space:]]*+' | grep -v '^[[:space:]]*//' | grep '\.sv' | \
	grep -v "cv32e40x_wrapper.sv" | grep -v "cv32e40x_rvfi.sv" | \
	grep -v "cv32e40x_rvfi_pkg.sv" | grep -v "/sva/")

# This Makefile is a prerequisite of every simulator and of the filelist, so a
# change to the Verilator flags, the filelist filter or the source lists
# rebuilds them (side effect: any edit here rebuilds everything). Each
# simulator recipe ends with `touch $@`: when Verilator finds its generated
# code unchanged it does not relink, the binary keeps its old timestamp and
# would otherwise look out of date forever.
THIS_MAKEFILE := $(TB_DIR)/Makefile

#==============================================================================
# make full (default) - full system regression
#------------------------------------------------------------------------------
# Was `make mxdotp`, back when "mxdotp" meant "the whole design". Renamed
# because Phase A gave the project several same-named-ish engines
# (mxdotp_fp4_fused_engine, mxdotp_final_engine, ...) - `make mxdotp` read as
# if it built one specific engine. `all` is kept as a backward-compatible
# alias below. `mxdotp` itself is NOT kept as an alias here: it was reused as
# the registered name of the dot-product-engine unit test (the renamed fp4r
# unit test), and a target can't be both - see UNIT_TESTS below, where
# `mxdotp` is now defined for real. Keeping both definitions in one Makefile
# previously left GNU Make silently taking the later (unit-test) recipe and
# dropping this alias with no visible warning without -d - `make mxdotp` was
# actually already running the unit test, not `full`, despite this alias
# still being declared. Removed rather than left as a misleading no-op.
#==============================================================================

#----------------------------------------------------------------------------
# Testbench
#----------------------------------------------------------------------------

TB_SRCS := \
	$(TB_DIR)/tb_pkg.sv \
	$(TB_DIR)/instr_rom.sv \
	$(TB_DIR)/data_mem_stub.sv \
	$(TB_DIR)/tb_mxdotp_core.sv

#----------------------------------------------------------------------------
# MXDOTP sources
#----------------------------------------------------------------------------

# Shared, format-parameterized datapath blocks (Phase A.1). Every engine
# instantiates these with its own frame widths, so they belong to the common
# set rather than to any one engine's <name>_ENGINE_SRCS. Listing them here
# (and in the unit-test template below) means a NEW unit test picks them up
# with no extra wiring, exactly the way it already picks up mxdotp_pkg.sv.
#
# These must be real prerequisites, not just findable via -I$(MXDOTP_RTL_DIR):
# a file reachable only through the include search path does not trigger a
# rebuild when it is edited. That was a real latent bug in this Makefile once
# already (mxdotp_fp8_fused_engine.sv, found in the M2XFP4 pass) - do not let
# it come back through the shared blocks.
MXDOTP_SHARED_SRCS := \
	$(MXDOTP_RTL_DIR)/mx_find_lead.sv \
	$(MXDOTP_RTL_DIR)/mx_finalize.sv \
	$(MXDOTP_RTL_DIR)/mx_acc_slide.sv

MXDOTP_SRCS := \
	$(MXDOTP_RTL_DIR)/mxdotp_pkg.sv \
	$(MXDOTP_SHARED_SRCS) \
	$(MXDOTP_RTL_DIR)/mxdotp_decoder.sv \
	$(MXDOTP_RTL_DIR)/mxdotp_dotp_engine.sv \
	$(MXDOTP_RTL_DIR)/mxdotp_final_engine.sv \
	$(MXDOTP_RTL_DIR)/mxdotp_fp4_fused_engine.sv \
	$(MXDOTP_RTL_DIR)/mxdotp_fp8_fused_engine.sv \
	$(MXDOTP_RTL_DIR)/mxdotp_m2xfp4_fused_engine.sv \
	$(MXDOTP_RTL_DIR)/mxdotp_xif.sv \
	$(MXDOTP_RTL_DIR)/mxdotp_core_top.sv

#----------------------------------------------------------------------------
# C++ harness
#----------------------------------------------------------------------------

# $(abspath ...), not a bare relative path: Verilator's own shared include
# (verilated.mk) hardcodes `VPATH += ..` for locating user .cpp sources -
# it assumes --Mdir is always exactly ONE directory below the invocation
# dir. That was true of the old single-level obj_dir/; it is NOT true of
# build/system/ (two levels below tb/), so the generated sub-Makefile fails
# with "No rule to make target 'verilator_tb.cpp'" once make -C descends
# into build/system/ and `..` only reaches build/, not tb/. Passing an
# absolute path here sidesteps the VPATH mechanism entirely - Verilator
# embeds the absolute path directly in the generated compile rule instead of
# a bare filename needing VPATH resolution. Reproduced and confirmed fixed
# directly against Verilator (5.020) before landing this. This does NOT
# affect the unit-test targets (make fp4 etc.): those use --binary with a
# self-contained SV testbench and no --exe/.cpp at all, so this VPATH
# codepath never executes for them regardless of --Mdir depth.
CXX_FILES := $(abspath $(TB_DIR)/verilator_tb.cpp)

#----------------------------------------------------------------------------
# Verilator flags
#----------------------------------------------------------------------------

VERILATOR_FLAGS := \
	-sv \
	--cc \
    --Wno-fatal \
	--exe \
	--build \
	--trace \
	--top-module $(TOP_MODULE) \
	--Mdir $(BUILD_DIR) \
	-j 8 \
	-O3 \
    --timing \
	-Wall \
	-Wno-BLKANDNBLK \
	-I$(RTL_DIR)/include \
	-I$(MXDOTP_RTL_DIR) \
	-I$(BHV_DIR) \
	-I$(BHV_DIR)/include

EXECUTABLE := $(BUILD_DIR)/V$(TOP_MODULE)

.DEFAULT_GOAL := full

#----------------------------------------------------------------------------
# Build manifest for Verilator
#----------------------------------------------------------------------------

$(VERILATOR_FLIST): $(MANIFEST) $(THIS_MAKEFILE)
	@mkdir -p $(BUILD_DIR)
	@echo "Generating Verilator file list..."
	@sed 's|$${DESIGN_RTL_DIR}|$(abspath $(RTL_DIR))|g' $(MANIFEST) | \
	grep -v "cv32e40x_wrapper.sv" | \
	grep -v "cv32e40x_rvfi.sv" | \
	grep -v "cv32e40x_rvfi_pkg.sv" | \
	grep -v "/sva/" > $@

#----------------------------------------------------------------------------
# Build + run
#----------------------------------------------------------------------------

.PHONY: full all
full: $(EXECUTABLE)
	@echo
	@echo "==============================="
	@echo "Running simulation..."
	@echo "==============================="
	$(EXECUTABLE)

# `all` is kept as a backward-compatible alias for `full`. `mxdotp` is NOT -
# see the comment block above this section for why.
all: full

$(EXECUTABLE): $(VERILATOR_FLIST) $(CORE_SRCS) $(MXDOTP_SRCS) $(TB_SRCS) $(CXX_FILES) $(THIS_MAKEFILE)
	$(VERILATOR) $(VERILATOR_FLAGS) \
		-f $(VERILATOR_FLIST) \
		$(MXDOTP_SRCS) \
		$(TB_SRCS) \
		$(CXX_FILES)
	@touch $@

#==============================================================================
# Standalone unit-engine testbenches (make fp4, make fp8, ...)
#------------------------------------------------------------------------------
# Each unit test drives ONE arithmetic engine directly against
# rtl/mxdotp/mxdotp_pkg.sv - no core, no XIF, no CXX harness (tb_<name>_unit.sv
# is self-contained: it drives its own clock/reset and calls $finish itself,
# same pattern as tb_fp4_unit.sv). Verilator's --binary mode builds and links
# in one step, so no separate CXX_FILES entry is needed per unit test either.
#
# Each gets its own --Mdir (build/units/<name>) so unit builds never collide
# with each other or with the system build (build/system).
#
# If a unit test has a golden-model Python script (verification/, one level
# up from tb/), setting <name>_GOLDEN to that script's path makes `make
# <name>` automatically run it with --emit-vectors first: the script re-runs
# its full verification sweep and only (re)writes the vector file if every
# check passes, aborting the whole `make <name>` (nothing builds or runs) if
# not. This is optional per test - a unit test with no _GOLDEN variable set
# just skips straight to build+run, same as before.
#
# TO ADD A NEW ONE: define <name>_ENGINE_SRCS (and <name>_GOLDEN, if it has
# a golden-model script), add <name> to UNIT_TESTS, and drop
# tb_<name>_unit.sv into tb/. That's the entire integration - the shared
# mx_*.sv datapath blocks are added by the template itself, so
# <name>_ENGINE_SRCS lists only that engine's own file(s).
#==============================================================================

VERIFICATION_DIR := $(ROOT_DIR)/verification

# --- registered unit tests ---------------------------------------------------

UNIT_TESTS := fp4 fp8 m2 mxdotp mxfinal

mxdotp_ENGINE_SRCS := $(MXDOTP_RTL_DIR)/mxdotp_dotp_engine.sv
mxdotp_GOLDEN      := $(VERIFICATION_DIR)/mxdotp_golden.py

fp4_ENGINE_SRCS := $(MXDOTP_RTL_DIR)/mxdotp_fp4_fused_engine.sv
fp4_GOLDEN      := $(VERIFICATION_DIR)/fp4_golden.py

fp8_ENGINE_SRCS := $(MXDOTP_RTL_DIR)/mxdotp_fp8_fused_engine.sv
fp8_GOLDEN      := $(VERIFICATION_DIR)/fp8_golden.py

m2_ENGINE_SRCS  := $(MXDOTP_RTL_DIR)/mxdotp_m2xfp4_fused_engine.sv
m2_GOLDEN       := $(VERIFICATION_DIR)/m2_golden.py

mxfinal_ENGINE_SRCS := $(MXDOTP_RTL_DIR)/mxdotp_final_engine.sv
mxfinal_GOLDEN      := $(VERIFICATION_DIR)/mxfinal_golden.py

# Future targets - uncomment the ENGINE_SRCS line (and _GOLDEN, once each has
# its own golden-model script) and add the name to UNIT_TESTS once both the
# engine RTL and tb_<name>_unit.sv exist:
#
# fp4r_ENGINE_SRCS    := $(MXDOTP_RTL_DIR)/mxdotp_dotp_engine.sv
# fp4r_GOLDEN         := $(VERIFICATION_DIR)/fp4r_golden.py
#
# UNIT_TESTS += fp4r

# --- shared flags for every unit test ----------------------------------------

UNIT_VERILATOR_FLAGS := \
	-sv \
	--binary \
	--Wno-fatal \
	-O3 \
	--timing \
	-Wall \
	-Wno-UNOPTFLAT \
	-Wno-BLKANDNBLK \
	-I$(RTL_DIR)/include \
	-I$(MXDOTP_RTL_DIR)

# --- per-test target template ------------------------------------------------
# $(1) is the unit test name (e.g. "fp4"). Every variable/target it defines
# is namespaced by $(1), so instantiating it once per registered test (via
# the $(foreach)/$(eval) below) never collides across tests.
#
# $(1)-vectors is always a prerequisite of $(1): when $(1)_GOLDEN is set it
# regenerates+verifies the vector file (aborting on failure); when unset it's
# a harmless no-op. Vector regeneration doesn't affect what gets compiled
# (Verilator has no vector-file dependency; tb_$(1)_unit.sv reads it at
# SIMULATION run time via $$readmemh), so $(1)-vectors and the executable
# build are independent and Make is free to satisfy either first - the only
# thing guaranteed, which is the only thing that matters here, is that both
# complete successfully before $(1)'s own recipe (which runs the binary)
# starts.

define UNIT_TEST_template

$(1)_TOP        := tb_$(1)_unit
$(1)_BUILD_DIR  := $(BUILD_ROOT)/units/$(1)
$(1)_TB_SRC     := $(TB_DIR)/tb_$(1)_unit.sv
$(1)_EXECUTABLE := $$($(1)_BUILD_DIR)/V$$($(1)_TOP)

.PHONY: $(1) $(1)-vectors
ifneq ($$($(1)_GOLDEN),)
$(1)-vectors:
	@cd $(TB_DIR) && python3 $$($(1)_GOLDEN) --emit-vectors
else
$(1)-vectors:
	@:
endif

$(1): $(1)-vectors $$($(1)_EXECUTABLE)
	@echo
	@echo "==============================="
	@echo "Running $(1) unit testbench ($$($(1)_TOP))..."
	@echo "==============================="
	@cd $(TB_DIR) && ./$$($(1)_EXECUTABLE)

# Run from $(TB_DIR) (where the Makefile itself lives) so any relative
# $$readmemh path in tb_$(1)_unit.sv (e.g. fp4_unit_vectors.hex) resolves
# against tb/ without warnings, regardless of where `make` was invoked from.
#
# The explicit mkdir -p matters: Verilator's --Mdir creates at most ONE
# missing directory level, not the full chain. On a fresh checkout, neither
# build/ nor build/units/ exists yet, so a bare --Mdir build/units/$(1) (two
# missing levels) fails with "Cannot write .../V$(1)__Syms.cpp" - reproduced
# directly (verilator --Mdir ./build/units/fp4 with nothing pre-existing
# fails the same way; it only succeeds once build/units/ already exists and
# just the leaf is missing). The system build's $(VERILATOR_FLIST) rule
# already had this covered (mkdir -p $(BUILD_DIR)); this template didn't.
$$($(1)_EXECUTABLE): $(MXDOTP_RTL_DIR)/mxdotp_pkg.sv $(MXDOTP_SHARED_SRCS) $$($(1)_ENGINE_SRCS) $$($(1)_TB_SRC) $(THIS_MAKEFILE)
	@mkdir -p $$($(1)_BUILD_DIR)
	$(VERILATOR) $(UNIT_VERILATOR_FLAGS) \
		--top-module $$($(1)_TOP) \
		--Mdir $$($(1)_BUILD_DIR) \
		$(MXDOTP_RTL_DIR)/mxdotp_pkg.sv $(MXDOTP_SHARED_SRCS) $$($(1)_ENGINE_SRCS) $$($(1)_TB_SRC)
	@touch $$@

endef

$(foreach t,$(UNIT_TESTS),$(eval $(call UNIT_TEST_template,$(t))))

# --- run every registered unit test in one shot ------------------------------

.PHONY: units
units: $(UNIT_TESTS)

#==============================================================================
# Directed stream measurement (make stream)
#------------------------------------------------------------------------------
# Same system testbench, built with MX_STREAM_TEST: instr_rom.sv swaps in the
# back-to-back stream program and tb_mxdotp_core.sv runs a fixed window instead
# of the Tests 1-5 scoreboard. A measurement run, not a regression - the output
# is the [XIFMON] log. Own build dir, so it never disturbs `make full`'s build;
# it is run from that dir, so its VCD lands there too, not in tb/.
#==============================================================================

STREAM_BUILD_DIR := $(BUILD_ROOT)/stream
STREAM_EXECUTABLE := $(STREAM_BUILD_DIR)/V$(TOP_MODULE)
STREAM_VERILATOR_FLAGS := $(subst --Mdir $(BUILD_DIR),--Mdir $(STREAM_BUILD_DIR),$(VERILATOR_FLAGS)) -DMX_STREAM_TEST

.PHONY: stream
stream: $(STREAM_EXECUTABLE)
	@echo
	@echo "==============================="
	@echo "Running stream measurement..."
	@echo "==============================="
	cd $(STREAM_BUILD_DIR) && ./V$(TOP_MODULE)

$(STREAM_EXECUTABLE): $(VERILATOR_FLIST) $(CORE_SRCS) $(MXDOTP_SRCS) $(TB_SRCS) $(CXX_FILES) $(THIS_MAKEFILE)
	@mkdir -p $(STREAM_BUILD_DIR)
	$(VERILATOR) $(STREAM_VERILATOR_FLAGS) \
		-f $(VERILATOR_FLIST) \
		$(MXDOTP_SRCS) \
		$(TB_SRCS) \
		$(CXX_FILES)
	@touch $@

#==============================================================================
# Compiled-program runs (make loop PROG=<name>)
#------------------------------------------------------------------------------
# Same system testbench, built with MX_PROGRAM_IMAGE: tb/mem_model.sv replaces
# instr_rom.sv + data_mem_stub.sv and loads the program image named by
# +image=. The program is sw/<PROG>/ (all .c/.S files) + sw/common/crt0.S,
# linked at 0x0 by sw/common/link.ld. The run ends when the program writes its
# exit code (0 = pass) to the EXIT register; +max_cycles bounds it. The
# testbench is verilated once into build/loop and reused for every program.
#
#   make loop PROG=smoke                   run one program
#   make loop PROG=x LOOP_ARGS=+xifmon     extra plusargs (+xifmon, +trace...)
#
# Tracing is off (+notrace) unless LOOP_TRACE=1; the VCD then lands in
# build/loop/.
#==============================================================================

SW_DIR       := $(abspath $(TB_DIR)/../sw)
SW_COMMON    := $(SW_DIR)/common
SW_BUILD_DIR := $(BUILD_ROOT)/sw

RV_PREFIX  := riscv64-unknown-elf-
RV_CC      := $(RV_PREFIX)gcc
RV_OBJCOPY := $(RV_PREFIX)objcopy
RV_OBJDUMP := $(RV_PREFIX)objdump
RV_CFLAGS  := -march=rv32im_zicsr -mabi=ilp32 -O2 -g -ffreestanding -nostdlib -nostartfiles -Wall -Wextra -I$(SW_COMMON) -Wl,--no-warn-rwx-segments

PROG            ?= smoke
LOOP_MAX_CYCLES ?= 2000000
LOOP_TRACE      ?= 0
LOOP_ARGS       ?=

LOOP_BUILD_DIR        := $(BUILD_ROOT)/loop
LOOP_EXECUTABLE       := $(LOOP_BUILD_DIR)/V$(TOP_MODULE)
LOOP_VERILATOR_FLAGS  := $(subst --Mdir $(BUILD_DIR),--Mdir $(LOOP_BUILD_DIR),$(VERILATOR_FLAGS)) -DMX_PROGRAM_IMAGE
LOOP_TB_SRCS          := $(TB_SRCS) $(TB_DIR)/mem_model.sv

PROG_SRCS := $(wildcard $(SW_DIR)/$(PROG)/*.c $(SW_DIR)/$(PROG)/*.S)
PROG_ELF  := $(SW_BUILD_DIR)/$(PROG).elf
PROG_HEX  := $(SW_BUILD_DIR)/$(PROG).hex

# Generated operand data: if sw/<PROG>/gen_args exists, its contents are the
# arguments to tb/scripts/gen_loop_data.py, which writes the data + golden
# expected words to build/sw/<PROG>_data.S (linked into the program) and a
# JSON summary next to it.
PROG_GEN_ARGS_FILE := $(SW_DIR)/$(PROG)/gen_args
PROG_GEN_ARGS      := $(strip $(shell cat $(PROG_GEN_ARGS_FILE) 2>/dev/null))
ifneq ($(PROG_GEN_ARGS),)
PROG_GEN_S := $(SW_BUILD_DIR)/$(PROG)_data.S
$(PROG_GEN_S): $(PROG_GEN_ARGS_FILE) $(TB_DIR)/scripts/gen_loop_data.py $(wildcard $(VERIFICATION_DIR)/*_golden.py)
	@mkdir -p $(SW_BUILD_DIR)
	python3 $(TB_DIR)/scripts/gen_loop_data.py $(PROG_GEN_ARGS) --out-s $@ --out-json $(SW_BUILD_DIR)/$(PROG)_expected.json
else
PROG_GEN_S :=
endif

ifeq ($(LOOP_TRACE),1)
LOOP_TRACE_ARG :=
else
LOOP_TRACE_ARG := +notrace
endif

.PHONY: loop
loop: $(LOOP_EXECUTABLE) $(PROG_HEX)
	@echo
	@echo "==============================="
	@echo "Running program $(PROG)..."
	@echo "==============================="
	cd $(LOOP_BUILD_DIR) && ./V$(TOP_MODULE) +image=$(abspath $(PROG_HEX)) +max_cycles=$(LOOP_MAX_CYCLES) $(LOOP_TRACE_ARG) $(LOOP_ARGS)

$(LOOP_EXECUTABLE): $(VERILATOR_FLIST) $(CORE_SRCS) $(MXDOTP_SRCS) $(LOOP_TB_SRCS) $(CXX_FILES) $(THIS_MAKEFILE)
	@mkdir -p $(LOOP_BUILD_DIR)
	$(VERILATOR) $(LOOP_VERILATOR_FLAGS) \
		-f $(VERILATOR_FLIST) \
		$(MXDOTP_SRCS) \
		$(LOOP_TB_SRCS) \
		$(CXX_FILES)
	@touch $@

$(PROG_ELF): $(PROG_SRCS) $(PROG_GEN_S) $(wildcard $(SW_DIR)/$(PROG)/*.h) $(SW_COMMON)/crt0.S $(SW_COMMON)/link.ld $(wildcard $(SW_COMMON)/*.h)
	@test -n "$(PROG_SRCS)" || (echo "no sources in $(SW_DIR)/$(PROG)" && false)
	@mkdir -p $(SW_BUILD_DIR)
	$(RV_CC) $(RV_CFLAGS) -T $(SW_COMMON)/link.ld -o $@ $(SW_COMMON)/crt0.S $(PROG_SRCS) $(PROG_GEN_S) -lgcc
	$(RV_OBJDUMP) -d $@ > $(SW_BUILD_DIR)/$(PROG).dis

$(PROG_HEX): $(PROG_ELF)
	$(RV_OBJCOPY) -O binary $< $(SW_BUILD_DIR)/$(PROG).bin
	python3 $(TB_DIR)/scripts/bin2hex.py $(SW_BUILD_DIR)/$(PROG).bin $@

#==============================================================================
# q10 regression (make q10)
#------------------------------------------------------------------------------
# sw/q10_isolation (lw;lw and mxfused;lw;lw, 3 times each) on the program-image
# build at every data-port setting below. Each run must exit 0 and grant exactly
# one data access per load in both cases (counted by mem_model.sv +gcount at
# the MARKs; tb/scripts/q10_check.py). Guards the CV32E40X EX halt for a
# load/store in EX behind an offloaded instruction in WB (xif_lsu_stall):
# without it the load re-requests every cycle and, at read latency 1, the
# offloaded instruction's XIF result is lost and WB hangs.
#==============================================================================

Q10_SETTINGS := dwait=0 dwait=1 dwait=2 dwait=3 dwait=4 dwait=5 dgnt=1 dgnt=3
Q10_DIR      := $(BUILD_ROOT)/q10

.PHONY: q10
q10: $(LOOP_EXECUTABLE)
	$(MAKE) --no-print-directory PROG=q10_isolation $(SW_BUILD_DIR)/q10_isolation.hex
	@mkdir -p $(Q10_DIR)
	@for s in $(Q10_SETTINGS); do \
	  echo "q10_isolation +$$s"; \
	  (cd $(LOOP_BUILD_DIR) && ./V$(TOP_MODULE) +image=$(abspath $(SW_BUILD_DIR)/q10_isolation.hex) \
	    +max_cycles=20000 +notrace +gcount +$$s) > $(Q10_DIR)/$$s.log 2>&1; \
	done
	python3 $(TB_DIR)/scripts/q10_check.py $(addprefix $(Q10_DIR)/,$(addsuffix .log,$(Q10_SETTINGS)))

#==============================================================================
# Utilities
#==============================================================================

view:
	gtkwave tb_mxdotp_core.vcd &

clean:
	# One root now (build/system + build/units/<name>), instead of separately
	# removing obj_dir and each obj_dir_<name>.
	rm -rf $(BUILD_ROOT)
	# hex_vectors/ is fully regenerable (make fp4/fp8/m2/mxfinal each
	# recreate their own file via each golden model's --emit-vectors), so
	# clean removing it is consistent with everything else this target
	# removes - none of it is committed source.
	rm -rf $(HEX_DIR)
	rm -f *.vcd *.fst

.PHONY: clean view
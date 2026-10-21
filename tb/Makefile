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

$(VERILATOR_FLIST): $(MANIFEST)
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

$(EXECUTABLE): $(VERILATOR_FLIST) $(MXDOTP_SRCS) $(TB_SRCS) $(CXX_FILES)
	$(VERILATOR) $(VERILATOR_FLAGS) \
		-f $(VERILATOR_FLIST) \
		$(MXDOTP_SRCS) \
		$(TB_SRCS) \
		$(CXX_FILES)

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
$$($(1)_EXECUTABLE): $(MXDOTP_RTL_DIR)/mxdotp_pkg.sv $(MXDOTP_SHARED_SRCS) $$($(1)_ENGINE_SRCS) $$($(1)_TB_SRC)
	@mkdir -p $$($(1)_BUILD_DIR)
	$(VERILATOR) $(UNIT_VERILATOR_FLAGS) \
		--top-module $$($(1)_TOP) \
		--Mdir $$($(1)_BUILD_DIR) \
		$(MXDOTP_RTL_DIR)/mxdotp_pkg.sv $(MXDOTP_SHARED_SRCS) $$($(1)_ENGINE_SRCS) $$($(1)_TB_SRC)

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

$(STREAM_EXECUTABLE): $(VERILATOR_FLIST) $(MXDOTP_SRCS) $(TB_SRCS) $(CXX_FILES)
	@mkdir -p $(STREAM_BUILD_DIR)
	$(VERILATOR) $(STREAM_VERILATOR_FLAGS) \
		-f $(VERILATOR_FLIST) \
		$(MXDOTP_SRCS) \
		$(TB_SRCS) \
		$(CXX_FILES)

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
# =============================================================================
# Integration build for the assembled S1 core.
#
#   make lint     elaborate and lint the RTL      (strict: RTL only)
#
# Layout:
#   rtl/pkg/s1_pkg.sv     shared types; compiled before everything else
#   rtl/modules/*.sv      one file per module, one module per file
#   rtl/top/s1_core.sv    the integrated core that wires the modules together
#   simulation/           testbench, the test program and its generator
#   make prog     regenerate prog.svh from rv64i.s via the RISC-V toolchain
#   make test     build and run the RV64I integration testbench
#   make clean
#
# -----------------------------------------------------------------------------
# How this was run, so you can reproduce it exactly
# -----------------------------------------------------------------------------
# The MEDS-S1 PR gate installs Verilator 5.020 (.github/workflows/pr.yml).  A
# newer local Verilator accepts SystemVerilog that 5.020 rejects, and in one
# case MISCOMPILES it silently -- writing one element of an unpacked-array input
# port reads as zero in the DUT, with no warning.  So a clean run on a newer
# Verilator proves nothing about the gate.  Run against 5.020:
#
#   podman run --rm -v "$(PWD):/w:z" -w /w \
#     --entrypoint /bin/bash docker.io/verilator/verilator:v5.020 \
#     -c 'make lint && make test'
#
# Results as committed, on 5.020:
#   make lint   lint clean
#   make test   retired 55 of 55 program instructions, then spun 3 times
#               === PASS : 399 checks ===
#
# -----------------------------------------------------------------------------
# prog.svh is GENERATED and COMMITTED
# -----------------------------------------------------------------------------
# gen.py assembles rv64i.s with riscv64-unknown-elf-gcc at 0x80000000, takes the
# instruction image from objcopy and the expected retirement stream from spike's
# commit log.  No part of the expectation is hand-written, so a bug in the
# testbench cannot agree with a matching bug in the core.
#
# `make prog` needs the RISC-V toolchain (riscv64-unknown-elf-*, spike) and is a
# HOST step.  `make test` needs only Verilator -- which is why prog.svh is
# committed: the simulation runs on a machine with no toolchain, and inside the
# Verilator container.  Edit rv64i.s, run `make prog`, commit the result.
#
# -----------------------------------------------------------------------------
# Lint waivers, and why each one is not a bug
# -----------------------------------------------------------------------------
# UNUSEDPARAM    s1_pkg holds constants for the whole core.  No single module
#                uses all of them; that is what a shared package is for.
# UNUSEDSIGNAL   the testbench declares every core port and reads only some.
# BLKSEQ         a scoreboard counts and compares inside a clocked block, where
#                blocking assignment is the correct idiom, not a race.
# SYNCASYNCNET   the testbench drives reset from an initial block while the DUT
#                uses it asynchronously -- what reset looks like from outside.
# WIDTHEXPAND    deliberate width mixing when building stimulus.
#
# The last four are testbench idioms.  A command-line -Wno- is global, not
# per-file, so `make test` would also waive them for the RTL.  That is why
# `make lint` runs over the RTL ALONE and waives only UNUSEDPARAM: every real
# RTL warning is still caught there, and lint is the gate for RTL quality.
# =============================================================================

VERILATOR ?= verilator

# rtl/pkg    shared types, compiled first
# rtl/modules  one file per module
# rtl/top    the integrated core
# simulation   testbench and its generated program
PKG        = rtl/pkg/s1_pkg.sv
MODULES    = $(sort $(wildcard rtl/modules/*.sv))
TOPRTL     = rtl/top/s1_core.sv
RTL        = $(MODULES) $(TOPRTL)
TB         = simulation/tb_s1_core.sv
TOP        = tb_s1_core
INC        = -Isimulation

WAIVE_RTL  = -Wno-UNUSEDPARAM
WAIVE_TB   = $(WAIVE_RTL) -Wno-UNUSEDSIGNAL -Wno-BLKSEQ -Wno-SYNCASYNCNET \
             -Wno-WIDTHEXPAND -Wno-DECLFILENAME

.PHONY: all lint prog test clean
all: lint test

lint:
	@echo "lint + elaborate: s1_core  (RTL only, -Wall $(WAIVE_RTL))"
	@$(VERILATOR) --lint-only --timing -Wall $(WAIVE_RTL) \
	  --top-module s1_core $(PKG) $(RTL) && echo "  lint clean"

prog: simulation/prog.svh

simulation/prog.svh: simulation/rv64i.s simulation/gen.py
	@python3 simulation/gen.py

test:
	@$(VERILATOR) --binary --timing -Wall $(WAIVE_TB) $(INC) \
	  --top-module $(TOP) -Mdir obj -o $(TOP) $(PKG) $(RTL) $(TB)
	@./obj/$(TOP)

clean:
	@rm -rf obj

# Copyright 2026 Maktab-e-Digital Systems Lahore.
# SPDX-License-Identifier: Apache-2.0
#
# =============================================================================
# The assembled S1 core and its RV64I integration test.
#
#   make lint       elaborate and lint the RTL           (strict: RTL only)
#   make test       each program in PROGS vs spike, once with ideal memory and
#                   then once per seed in SEEDS with random stalls on both ports
#   make test-unit  the unit testbenches (s1_hazard)
#   make prog       regenerate verif/prog_<p>.svh and .hex for each p in PROGS
#                   (host step: needs the RISC-V toolchain and spike)
#   make all        lint, test, test-unit
#   make clean
#
# Layout:
#   rtl/pkg/s1_pkg.sv     shared types; compiled before everything else
#   rtl/common/*.sv       platform-shared modules (meds_s1_sram)
#   rtl/modules/*.sv      one file per module, one module per file
#   rtl/top/s1_core.sv    the integrated core
#   verif/                testbenches, the test program and its generator
#
# -----------------------------------------------------------------------------
# Run against the Verilator the MEDS-S1 gate installs (5.020), not a newer one:
# 5.020 rejects SystemVerilog that later versions accept, and miscompiles
# writes to one element of an unpacked-array input port silently.
#
#   podman run --rm -v "$(PWD):/w:z" -w /w \
#     --entrypoint /bin/bash docker.io/verilator/verilator:v5.020 \
#     -c 'make all'
#
# -----------------------------------------------------------------------------
# Lint waivers
# -----------------------------------------------------------------------------
# All of them live in verif/verilator.vlt, scoped by file and each with its
# reason (CODING_STANDARD.md R-L2).  None is passed on the command line, where
# a waiver would be global and a testbench's would silence the RTL too.
# =============================================================================

VERILATOR ?= verilator

# bash with pipefail: a failing simulation must fail make even through `| grep`.
SHELL       := /bin/bash
.SHELLFLAGS := -o pipefail -c

PKG        = rtl/pkg/s1_pkg.sv
COMMON     = $(sort $(wildcard rtl/common/*.sv))
MODULES    = $(sort $(wildcard rtl/modules/*.sv))
TOPRTL     = rtl/top/s1_core.sv
RTL        = $(COMMON) $(MODULES) $(TOPRTL)
TB         = verif/tb_csr_model.sv verif/tb_s1_core.sv
TOP        = tb_s1_core
INC        = -Iverif

VLT        = verif/verilator.vlt

# Random-stall runs.  Each seed is a different interleaving of backpressure
# and response latency on the I$ and D$ ports.
SEEDS     ?= 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16

.PHONY: all lint prog build test test-unit clean
all: lint test test-unit

lint:
	@echo "lint + elaborate: s1_core  (-Wall, waivers in $(VLT) only)"
	@$(VERILATOR) --lint-only --timing -Wall $(VLT) \
	  --top-module s1_core $(PKG) $(RTL) && echo "  lint clean"

# Programs run by `make test`, each as verif/prog_<name>.svh + its .hex files:
#   rv64i_full  every RV64I instruction and the hazards around them (asm)
#   sort        quicksort, insertion, shell, bubble, counting sort (C, -O2)
PROGS ?= rv64i_full sort

# `make prog` regenerates them all; `make prog PROGS=sort` just one.
# rv64i_full must cover all 52 RV64I instructions or gen.py refuses.
prog:
	@for p in $(PROGS); do \
	  python3 verif/gen.py $$p $$( [ $$p = rv64i_full ] && echo --require-rv64i ) || exit 1; \
	done

build: $(foreach p,$(PROGS),obj/$(p)/$(TOP))

obj/%/$(TOP): $(PKG) $(RTL) $(TB) $(VLT) verif/prog_%.svh
	@mkdir -p obj/$*
	@$(VERILATOR) --binary --timing -Wall $(VLT) $(INC) -DPROG_SVH='"prog_$*.svh"' \
	  --top-module $(TOP) -Mdir obj/$* -o $(TOP) $(PKG) $(RTL) $(TB) > obj-$*.log 2>&1 \
	  || { cat obj-$*.log; rm -f obj-$*.log; exit 1; }
	@rm -f obj-$*.log

# The simulation reads the .hex files at run time, by path from core/.
test: build
	@for p in $(PROGS); do \
	  echo "=== $$p: ideal memory"; \
	  ./obj/$$p/$(TOP) | grep -v -e '^- ' -e 'Verilog \$$finish' || exit 1; \
	  for s in $(SEEDS); do \
	    echo "=== $$p: random stalls, seed $$s"; \
	    ./obj/$$p/$(TOP) +stall +verilator+seed+$$s | grep -v -e '^- ' -e 'Verilog \$$finish' \
	      || exit 1; \
	  done; \
	done
	@echo "all runs passed"

UNIT_TBS   = tb_s1_hazard

test-unit:
	@mkdir -p obj
	@for tb in $(UNIT_TBS); do \
	  $(VERILATOR) --binary --timing -Wall $(VLT) $(INC) \
	    --top-module $$tb -Mdir obj/$$tb -o $$tb $(PKG) $(RTL) verif/$$tb.sv \
	    > obj-$$tb.log 2>&1 || { cat obj-$$tb.log; rm -f obj-$$tb.log; exit 1; }; \
	  rm -f obj-$$tb.log; \
	  echo "$$tb"; ./obj/$$tb/$$tb || exit 1; \
	done

clean:
	@rm -rf obj

# `core/verif/` — tests for the assembled core

## What lives here

| File | |
|---|---|
| `tb_s1_core.sv` | integration testbench: runs a program through the core and checks every RVFI retirement against spike |
| `tb_csr_model.sv` | minimal CSR stand-in for the testbench (the CSR file is another project's) |
| `tb_s1_hazard.sv` | unit testbench for `s1_hazard` |
| `rv64i_full.s` | program 1: all 52 RV64I instructions and the hazards around them |
| `sort.c`, `crt0.s` | program 2: five sorting algorithms in C, self-checking |
| `gen.py` | builds a program and runs spike; writes `prog_<p>.svh`, `<p>.img.hex`, `<p>.exp.hex` |
| `prog_*.svh`, `*.hex` | GENERATED and committed, so the simulation needs only Verilator |
| `verilator.vlt` | every lint waiver for `core/`, each with its reason |

## What does *not* live here
Hand-written expected values. Expectations come from spike, the image from objcopy.

## How to add something
- **A test case:** edit `rv64i_full.s`, run `make -C core prog` (needs the RISC-V toolchain and
  spike at `/opt/riscv/bin`), commit the regenerated files.  A new program `x` is `x.s` or
  `x.c` (linked behind `crt0.s`); add it to `PROGS` in `../Makefile`. Keep the program's rules (header of
  the `.s`): no register read before it is written, no misaligned access, end by writing `tohost`
  and spinning at `spin`.
- **A unit testbench:** `tb_<module>.sv` here, add it to `UNIT_TBS` in `../Makefile`, print
  `=== PASS : <n> checks ===` and exit non-zero on failure (R-V3).

---
*See [`../README.md`](../README.md) for what the checks are and what they found.*

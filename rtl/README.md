# `core/rtl/` — S1 core RTL

## What lives here
The synthesisable RTL of the assembled five-stage core.

| Directory | Contents |
|---|---|
| `pkg/` | `s1_pkg.sv` — every type and constant two modules must agree on (R-C8); compiled first |
| `common/` | `meds_s1_sram.sv` — the SRAM wrapper every array goes through (R-C5) |
| `modules/` | one module per file: `s1_fetch`, `s1_rvc_expand`, `s1_id`, `s1_decode`, `s1_hazard`, `s1_regfile`, `s1_ex`, `s1_alu`, `s1_mem`, `s1_wb` |
| `top/` | `s1_core.sv` — wires the stages together; every external connection is a port |

## What does *not* live here
Testbenches (`../verif/`), the CSR file (another project's), caches, fabric, the PMA/PMP checkers
and the RV64M unit — those attach to
`s1_core`'s ports. Nothing here speaks AXI (INTERFACES.md I2).

## How to add something
Add the module under `modules/`, any shared struct to `pkg/s1_pkg.sv`, instantiate it in
`top/s1_core.sv`, give it a page in MEDS-S1's `docs/modules/`, and keep `make all` green on
Verilator 5.020.

---
*Conventions: MEDS-S1 [`docs/guidelines/CODING_STANDARD.md`](https://github.com/meds-uet/MEDS-S1/blob/main/docs/guidelines/CODING_STANDARD.md)*

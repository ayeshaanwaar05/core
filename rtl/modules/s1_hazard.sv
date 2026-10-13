// =============================================================================
// Copyright 2026 Maktab-e-Digital Systems Lahore.
// Licensed under the Apache License, Version 2.0, see LICENSE file for details.
// SPDX-License-Identifier: Apache-2.0
//
// s1_hazard : ID-stage hazard unit                                 [WIP -- T-02]
//
// Purely combinational.  For the instruction in ID it decides, per operand,
// where EX takes the value from (SPEC 8.1) and whether ID has to stall
// (SPEC 8.2).  It holds no state and owns no pipeline register: s1_id does.
//
// What a producer ahead of ID looks like, and what is done about it:
//
//   in EX, result final in EX   FWD_EXMEM.  The value does not exist yet; EX
//                               reads it out of its own EX/MEM register next
//                               cycle.  Penalty 0.
//   in EX, a load / LR / AMO    stall (load-use).
//   in EX/MEM, result final     the value is on exmem_result_i now, so it is
//                               returned in rs*_val_o with FWD_RF.
//   in EX/MEM, a load / LR / AMO  stall until MEM has answered.
//   committing in WB            nothing: s1_regfile already returns a value
//                               written in the same cycle.
//
// A CSR or system instruction is serialised: it waits for an empty pipeline
// (SPEC 8.2, last row).
//
// Where this differs from SPEC 8, because of the core it sits in:
//   - No MEM/WB source, so load-use costs 2 cycles, not 1.  Forwarding MEM's
//     answer into EX needs EX to hold an operand that is not ready yet.
//   - No CB source and no CB-full stall: this core has no completion buffer.
//
// Reference: SPEC 7.2, 8.1, 8.2.  Testbench: simulation/tb_s1_hazard.sv.
// =============================================================================

module s1_hazard
  import s1_pkg::*;
(
  // The instruction in ID: its operands and the register-file values for them
  input  logic [REG_ADDR_W-1:0] rs1_addr_i,
  input  logic                  rs1_re_i,
  input  logic [XLEN-1:0]       rs1_rf_i,
  input  logic [REG_ADDR_W-1:0] rs2_addr_i,
  input  logic                  rs2_re_i,
  input  logic [XLEN-1:0]       rs2_rf_i,
  input  csr_op_e               csr_op_i,
  input  sys_op_e               sys_op_i,

  // The instruction in EX (the ID/EX register)
  input  logic                  ex_valid_i,
  input  logic [REG_ADDR_W-1:0] ex_rd_i,
  input  logic                  ex_rd_we_i,
  input  exec_unit_e            ex_unit_i,

  // The instruction in EX/MEM
  input  logic                  exmem_valid_i,
  input  logic [REG_ADDR_W-1:0] exmem_rd_i,
  input  logic                  exmem_rd_we_i,
  input  logic                  exmem_is_load_i,
  input  amo_op_e               exmem_amo_op_i,
  input  logic [XLEN-1:0]       exmem_result_i,

  // Anything in flight past the ID/EX register; serialisation only
  input  logic                  downstream_busy_i,

  // Per operand: the forwarding select and the value known in ID
  output fwd_src_e              rs1_fwd_o,
  output logic [XLEN-1:0]       rs1_val_o,
  output fwd_src_e              rs2_fwd_o,
  output logic [XLEN-1:0]       rs2_val_o,

  output logic                  stall_o,      // ID must not issue this cycle
  output logic                  load_use_o    // the stall is a load-use (SPEC 12)
);

  // One operand's answer.  Private to this module: nothing else needs its shape.
  typedef struct packed {
    fwd_src_e        src;
    logic [XLEN-1:0] val;
    logic            stall;
  } resolved_t;

  // Is a producer's result final by the time it reaches the EX/MEM register?
  // True for the ALU, a CSR read and RV64M (which completes inside EX).  False
  // for a load, an LR or an AMO, whose result MEM replaces, and for an MXIF
  // candidate, which never produces one here.
  logic ex_writes, ex_final;
  assign ex_writes = ex_valid_i && ex_rd_we_i && (ex_rd_i != '0);
  assign ex_final  = (ex_unit_i == UNIT_ALU) || (ex_unit_i == UNIT_CSR)
                  || (ex_unit_i == UNIT_MUL) || (ex_unit_i == UNIT_DIV);

  logic exmem_writes, exmem_final;
  assign exmem_writes = exmem_valid_i && exmem_rd_we_i && (exmem_rd_i != '0);
  assign exmem_final  = !exmem_is_load_i && (exmem_amo_op_i == AMO_NONE);

  // Written once and called twice so the two operands cannot drift apart.  EX
  // is checked before EX/MEM: it holds the younger producer.
  function automatic resolved_t resolve(input logic                  re,
                                        input logic [REG_ADDR_W-1:0] addr,
                                        input logic [XLEN-1:0]       rf_val,
                                        input logic                  ex_wr,
                                        input logic                  ex_fin,
                                        input logic [REG_ADDR_W-1:0] ex_rd,
                                        input logic                  exmem_wr,
                                        input logic                  exmem_fin,
                                        input logic [REG_ADDR_W-1:0] exmem_rd,
                                        input logic [XLEN-1:0]       exmem_val);
    resolved_t r;
    logic      need;
    need    = re && (addr != '0);
    r.src   = FWD_RF;
    r.val   = rf_val;
    r.stall = 1'b0;
    if (need && ex_wr && (ex_rd == addr)) begin
      if (ex_fin) r.src   = FWD_EXMEM;
      else        r.stall = 1'b1;
    end else if (need && exmem_wr && (exmem_rd == addr)) begin
      if (exmem_fin) r.val   = exmem_val;
      else           r.stall = 1'b1;
    end
    return r;
  endfunction

  resolved_t r1, r2;

  assign r1 = resolve(rs1_re_i, rs1_addr_i, rs1_rf_i, ex_writes, ex_final, ex_rd_i,
                      exmem_writes, exmem_final, exmem_rd_i, exmem_result_i);
  assign r2 = resolve(rs2_re_i, rs2_addr_i, rs2_rf_i, ex_writes, ex_final, ex_rd_i,
                      exmem_writes, exmem_final, exmem_rd_i, exmem_result_i);

  assign rs1_fwd_o = r1.src;
  assign rs1_val_o = r1.val;
  assign rs2_fwd_o = r2.src;
  assign rs2_val_o = r2.val;

  // Serialisation.  A CSR write lands in WB, so an older one still in flight
  // is not visible to a CSR read in EX; rather than forward CSR values, a CSR
  // or system instruction waits for the pipeline ahead of it to drain.  xRET
  // and the fences take effect in WB too, and are covered by the same rule.
  // It cannot deadlock: everything ahead completes in bounded time and nothing
  // waits on the instruction being held.
  logic serialise, ser_stall;
  assign serialise = (csr_op_i != CSR_NONE) || (sys_op_i != SYS_NONE);
  assign ser_stall = serialise && (ex_valid_i || downstream_busy_i);

  // Every operand stall here is a wait for MEM's answer.
  assign load_use_o = r1.stall || r2.stall;
  assign stall_o    = load_use_o || ser_stall;

endmodule

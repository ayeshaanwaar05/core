// =============================================================================
// Copyright 2026 Maktab-e-Digital Systems Lahore.
// Licensed under the Apache License, Version 2.0, see LICENSE file for details.
// SPDX-License-Identifier: Apache-2.0
//
// Author(s)    : integration (Oct,2026)
// Modified By  :
//
// s1_id        : ID stage -- decode, register read, hazards        [COMPLETE]
// Description  :
// Instantiates s1_decode, reads the register file, resolves each operand,
// assigns the in-flight tag, and owns the ID/EX register.
//
// Reference: SPEC 7.2, 8.1, 8.2.  Testbench: verif/unit/tb_s1_id.sv.
//
// -----------------------------------------------------------------------------
// FORWARDING IN A 5-STAGE, IN-ORDER PIPELINE
//
// Three places can hold a producer this stage has to read around, and the only
// thing that distinguishes them is whether the value exists yet:
//
//   in EX now          its result is computed this cycle and registered into
//                      EX/MEM at this edge.  The value does NOT exist yet, so
//                      EX must read it out of its own EX/MEM register next
//                      cycle: FWD_EXMEM.  Penalty 0.
//                      Exact, because the consumer enters EX only when EX
//                      accepted the producer -- the same event that moves the
//                      producer into the register the consumer then reads.
//
//   in EX/MEM now      the value is already on `exmem_i.result` where this
//                      stage can see it, so it is captured here into
//                      rs1_val/rs2_val and EX is handed a plain number.
//
//   at MEM's output    WB is committing it this cycle, and the register file's
//                      read-during-write bypass already returns the new value.
//                      Nothing special to do: FWD_RF is correct.
//
// A LOAD is the exception to the first two: its result is not final until MEM
// has answered, so a consumer stalls until the value shows up at MEM's output,
// where the register-file bypass picks it up.
//
// COST, STATED PLAINLY.  Load-use costs 2 cycles where a textbook 5-stage
// costs 1.  The missing cycle is MEM/WB forwarding straight into EX's operand
// mux: a consumer could sit in EX in the cycle MEM produces the value, but
// only if EX can be told "your operand is not ready yet" and hold.  That needs
// MEM to export a completion signal and EX to gate its first-cycle operand
// capture on it -- two module interfaces, deliberately not changed here.
// Everything else keeps its textbook penalty: back-to-back ALU dependencies
// are free, and EV_LOAD_USE counts what this actually costs.
// -----------------------------------------------------------------------------
// =============================================================================

module s1_id
  import s1_pkg::*;
#(
  // Passed straight to s1_decode: whether an unrecognised encoding is an MXIF
  // candidate (SPEC 7.2) or plainly illegal.
  parameter bit MXIF_EN = 1'b0
) (
  input  logic                  clk_i,
  input  logic                  rst_ni,

  // Kills.  A trap flush from WB discards everything; a mispredict discards ID
  // and the ID/EX register, which are by construction younger than the branch.
  input  logic                  flush_i,
  input  logic                  ex_redirect_valid_i,

  // From IF
  input  logic                  fetch_rsp_valid_i,
  output logic                  fetch_rsp_ready_o,
  input  fetch_rsp_t            fetch_rsp_i,

  // Register file read data for fetch_rsp_i's rs1/rs2.  The addresses are
  // not driven from here: the file's read is registered, so s1_fetch presents
  // them a cycle early (nxt_rs*_addr_o).
  input  logic [XLEN-1:0]       rs1_data_i,
  input  logic [XLEN-1:0]       rs2_data_i,

  // What is in EX/MEM right now, for the hazard check and for its value
  input  logic                  exmem_valid_i,
  input  ex_mem_t               exmem_i,

  // Is anything still in flight ahead of ID?  Used only for serialisation.
  input  logic                  downstream_busy_i,

  // To EX
  output logic                  ex_valid_o,
  input  logic                  ex_ready_i,
  output id_ex_t                ex_o,

  // Performance events (SPEC 12)
  output logic                  perf_load_use_o,
  output logic                  perf_hazard_stall_o
);

  // ---------------------------------------------------------------------------
  // Decode.  Purely combinational on the fetched word.
  // ---------------------------------------------------------------------------
  decoded_op_t dec;

  s1_decode #(
    .MXIF_EN (MXIF_EN)
  ) u_decode (
    .instr_i   (fetch_rsp_i.instr),
    .pc_i      (fetch_rsp_i.pc),
    .decoded_o (dec)
  );

  // ---------------------------------------------------------------------------
  // ID/EX register and the in-flight tag
  // ---------------------------------------------------------------------------
  logic             ex_valid_q;
  id_ex_t           ex_q;
  logic [TAG_W-1:0] tag_q;

  logic kill, out_free;
  assign kill     = flush_i || ex_redirect_valid_i;
  assign out_free = !ex_valid_q || ex_ready_i;

  // ---------------------------------------------------------------------------
  // Hazards
  // ---------------------------------------------------------------------------

  // Is a producer's result final by the time it reaches the EX/MEM register?
  // True for the ALU, a CSR read and RV64M (which now completes inside EX).
  // False for a load, an LR or an AMO: MEM replaces the result.
  function automatic logic final_at_ex(exec_unit_e u);
    return (u == UNIT_ALU) || (u == UNIT_CSR)
        || (u == UNIT_MUL) || (u == UNIT_DIV);
  endfunction

  // The instruction in EX right now
  logic ex_writes;
  assign ex_writes = ex_valid_q && ex_q.op.rd_we && (ex_q.op.rd != '0);

  // The instruction in EX/MEM right now.  `is_load`/`amo_op` travel in
  // ex_mem_t, so whether its result is final is readable directly.
  logic exmem_writes, exmem_final;
  assign exmem_writes = exmem_valid_i && exmem_i.rd_we && (exmem_i.rd != '0);
  assign exmem_final  = !exmem_i.is_load && (exmem_i.amo_op == AMO_NONE);

  logic     need1, need2;
  fwd_src_e src1, src2;
  logic     stall1, stall2, lu1, lu2;
  logic [XLEN-1:0] val1, val2;

  assign need1 = dec.rs1_re && (dec.rs1 != '0);
  assign need2 = dec.rs2_re && (dec.rs2 != '0);

  // One operand's resolution.  Written once and called twice so the two
  // operands cannot drift apart.
  task automatic resolve(input logic           need,
                         input logic [REG_ADDR_W-1:0] addr,
                         input logic [XLEN-1:0] rf_val,
                         output fwd_src_e       src,
                         output logic [XLEN-1:0] val,
                         output logic           stall,
                         output logic           load_use);
    src      = FWD_RF;
    val      = rf_val;
    stall    = 1'b0;
    load_use = 1'b0;
    if (need && ex_writes && (ex_q.op.rd == addr)) begin
      if (final_at_ex(ex_q.op.unit)) begin
        src = FWD_EXMEM;                 // value appears next cycle, in EX/MEM
      end else begin
        stall    = 1'b1;                 // a load in EX: classic load-use
        load_use = 1'b1;
      end
    end else if (need && exmem_writes && (exmem_i.rd == addr)) begin
      if (exmem_final) begin
        val = exmem_i.result;            // already computed, capture it here
      end else begin
        stall    = 1'b1;                 // a load in EX/MEM: wait for MEM
        load_use = 1'b1;
      end
    end
    // Otherwise the register file is right, including the instruction WB is
    // committing this cycle -- the file's read-during-write bypass covers it.
  endtask

  always_comb begin
    resolve(need1, dec.rs1, rs1_data_i, src1, val1, stall1, lu1);
    resolve(need2, dec.rs2, rs2_data_i, src2, val2, stall2, lu2);
  end

  // ---------------------------------------------------------------------------
  // Serialisation.
  //
  // A CSR access reads the CSR file in EX, but a CSR write does not land until
  // WB -- so an older CSR write still in flight would not be visible.  Rather
  // than forward CSR values (a second forwarding network for the rarest
  // instructions in the ISA), a CSR or system instruction simply waits for the
  // pipeline ahead of it to drain.  The same rule covers xRET and the fences,
  // whose effect is also taken in WB.
  //
  // This cannot deadlock: the instructions ahead are in order and all complete
  // in bounded time, and the one being held has not been issued, so nothing is
  // waiting on it.
  // ---------------------------------------------------------------------------
  logic serialise, ser_stall;
  assign serialise = (dec.csr_op != CSR_NONE) || (dec.sys_op != SYS_NONE);
  assign ser_stall = serialise && (ex_valid_q || downstream_busy_i);

  // ---------------------------------------------------------------------------
  // Issue
  // ---------------------------------------------------------------------------
  logic hz_stall, can_issue, issue;

  assign hz_stall  = stall1 || stall2;
  assign can_issue = out_free && !hz_stall && !ser_stall;
  assign issue     = fetch_rsp_valid_i && can_issue && !kill;

  // Independent of the kill: on a kill IF drops its own valid in the same
  // cycle, and nothing accepted here survives it.
  assign fetch_rsp_ready_o = can_issue;

  id_ex_t nxt;
  always_comb begin
    nxt            = '0;
    nxt.op         = dec;
    nxt.tag        = tag_q;
    nxt.rs1_val    = val1;
    nxt.rs2_val    = val2;
    nxt.rs1_fwd    = src1;
    nxt.rs2_fwd    = src2;
    nxt.compressed = fetch_rsp_i.compressed;
    nxt.pred_taken = fetch_rsp_i.pred_taken;
    nxt.instr_raw  = fetch_rsp_i.instr_raw;
    nxt.exc        = fetch_rsp_i.exc;
    nxt.exccode    = fetch_rsp_i.exccode;
    nxt.exctval    = fetch_rsp_i.exctval;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ex_valid_q <= 1'b0;
      ex_q       <= '0;
      tag_q      <= '0;
    end else begin
      if (kill) begin
        ex_valid_q <= 1'b0;
      end else if (issue) begin
        ex_valid_q <= 1'b1;
        ex_q       <= nxt;
        tag_q      <= tag_q + TAG_W'(1);
      end else if (ex_ready_i) begin
        ex_valid_q <= 1'b0;
      end
    end
  end

  assign ex_valid_o = ex_valid_q;
  assign ex_o       = ex_q;

  assign perf_load_use_o     = fetch_rsp_valid_i && (lu1 || lu2);
  assign perf_hazard_stall_o = fetch_rsp_valid_i && (hz_stall || ser_stall);

  // Only rd, rd_we, result, is_load and amo_op are read above; the rest of
  // ex_mem_t is on its way to MEM and WB and passes through this stage's
  // sight without being its business.
  logic unused;
  assign unused = ^exmem_i;

endmodule

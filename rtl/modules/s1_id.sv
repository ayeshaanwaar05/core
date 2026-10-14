// =============================================================================
// Copyright 2026 Maktab-e-Digital Systems Lahore.
// Licensed under the Apache License, Version 2.0, see LICENSE file for details.
// SPDX-License-Identifier: Apache-2.0
//
// Author(s)    : integration (Oct,2026)
// Modified By  :
//
// s1_id        : ID stage -- decode, hazards, ID/EX register    [WIP -- T-02]
// Description  :
// Instantiates s1_decode and s1_hazard, assigns the in-flight tag, and owns
// the ID/EX register.  The decode is in s1_decode and every forwarding and
// stall decision is in s1_hazard; what is left here is the stage's handshake.
//
// Reference: SPEC 7.2.  Testbench: core/verif/tb_s1_core.sv (integration only).
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

  // What is held in MEM/WB, while it is still waiting on the bus
  input  logic                  memwb_pend_i,
  input  logic [REG_ADDR_W-1:0] memwb_rd_i,
  input  logic                  memwb_rd_we_i,

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
  // Hazards (SPEC 8).  The instruction in EX is this stage's own ID/EX
  // register; the one in EX/MEM comes from s1_ex.
  // ---------------------------------------------------------------------------
  fwd_src_e        src1, src2;
  logic [XLEN-1:0] val1, val2;
  logic            hz_stall, load_use;

  s1_hazard u_hazard (
    .rs1_addr_i        (dec.rs1),
    .rs1_re_i          (dec.rs1_re),
    .rs1_rf_i          (rs1_data_i),
    .rs2_addr_i        (dec.rs2),
    .rs2_re_i          (dec.rs2_re),
    .rs2_rf_i          (rs2_data_i),
    .csr_op_i          (dec.csr_op),
    .sys_op_i          (dec.sys_op),

    .ex_valid_i        (ex_valid_q),
    .ex_rd_i           (ex_q.op.rd),
    .ex_rd_we_i        (ex_q.op.rd_we),
    .ex_unit_i         (ex_q.op.unit),

    .exmem_valid_i     (exmem_valid_i),
    .exmem_rd_i        (exmem_i.rd),
    .exmem_rd_we_i     (exmem_i.rd_we),
    .exmem_is_load_i   (exmem_i.is_load),
    .exmem_amo_op_i    (exmem_i.amo_op),
    .exmem_result_i    (exmem_i.result),

    .memwb_pend_i      (memwb_pend_i),
    .memwb_rd_i        (memwb_rd_i),
    .memwb_rd_we_i     (memwb_rd_we_i),

    .downstream_busy_i (downstream_busy_i),

    .rs1_fwd_o         (src1),
    .rs1_val_o         (val1),
    .rs2_fwd_o         (src2),
    .rs2_val_o         (val2),

    .stall_o           (hz_stall),
    .load_use_o        (load_use)
  );

  // ---------------------------------------------------------------------------
  // Issue
  // ---------------------------------------------------------------------------
  logic can_issue, issue;

  assign can_issue = out_free && !hz_stall;
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

  // Only a WB flush empties the ID/EX register.  EX reads its instruction
  // straight out of this register, so on a mispredict the register holds the
  // branch itself: if EX cannot pass it on this cycle (MEM is busy) clearing
  // it would lose the branch.  `kill` already stops the wrong-path
  // instruction in ID from issuing, and the branch leaves through the
  // ex_ready_i arm below once EX fires.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ex_valid_q <= 1'b0;
      ex_q       <= '0;
      tag_q      <= '0;
    end else begin
      if (flush_i) begin
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

  assign perf_load_use_o     = fetch_rsp_valid_i && load_use;
  assign perf_hazard_stall_o = fetch_rsp_valid_i && hz_stall;

  // Only rd, rd_we, result, is_load and amo_op go to the hazard unit; the rest
  // of ex_mem_t is on its way to MEM and WB and is not this stage's business.
  logic unused;
  assign unused = ^exmem_i;

endmodule

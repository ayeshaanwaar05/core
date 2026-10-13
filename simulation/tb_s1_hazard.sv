// =============================================================================
// Copyright 2026 Maktab-e-Digital Systems Lahore.
// Licensed under the Apache License, Version 2.0, see LICENSE file for details.
// SPDX-License-Identifier: Apache-2.0
//
// tb_s1_hazard : unit testbench for the ID-stage hazard unit            [WIP]
//
// Directed: one case per row of the table in the s1_hazard header, then a
// random sweep against a model written from that same table.  The DUT is
// combinational, so there is no clock.
// =============================================================================

module tb_s1_hazard
  import s1_pkg::*;
;

  localparam int unsigned N_RANDOM = 5000;

  logic [REG_ADDR_W-1:0] rs1_addr, rs2_addr, ex_rd, exmem_rd;
  logic                  rs1_re, rs2_re, ex_valid, ex_rd_we;
  logic                  exmem_valid, exmem_rd_we, exmem_is_load, busy;
  logic [XLEN-1:0]       rs1_rf, rs2_rf, exmem_result;
  csr_op_e               csr_op;
  sys_op_e               sys_op;
  exec_unit_e            ex_unit;
  amo_op_e               exmem_amo_op;

  fwd_src_e              rs1_fwd, rs2_fwd;
  logic [XLEN-1:0]       rs1_val, rs2_val;
  logic                  stall, load_use;

  s1_hazard dut (
    .rs1_addr_i        (rs1_addr),
    .rs1_re_i          (rs1_re),
    .rs1_rf_i          (rs1_rf),
    .rs2_addr_i        (rs2_addr),
    .rs2_re_i          (rs2_re),
    .rs2_rf_i          (rs2_rf),
    .csr_op_i          (csr_op),
    .sys_op_i          (sys_op),
    .ex_valid_i        (ex_valid),
    .ex_rd_i           (ex_rd),
    .ex_rd_we_i        (ex_rd_we),
    .ex_unit_i         (ex_unit),
    .exmem_valid_i     (exmem_valid),
    .exmem_rd_i        (exmem_rd),
    .exmem_rd_we_i     (exmem_rd_we),
    .exmem_is_load_i   (exmem_is_load),
    .exmem_amo_op_i    (exmem_amo_op),
    .exmem_result_i    (exmem_result),
    .downstream_busy_i (busy),
    .rs1_fwd_o         (rs1_fwd),
    .rs1_val_o         (rs1_val),
    .rs2_fwd_o         (rs2_fwd),
    .rs2_val_o         (rs2_val),
    .stall_o           (stall),
    .load_use_o        (load_use)
  );

  int unsigned checks = 0;
  int unsigned errors = 0;

  task automatic check(input string what, input logic [XLEN-1:0] got,
                       input logic [XLEN-1:0] exp);
    checks++;
    if (got !== exp) begin
      errors++;
      $display("  FAIL %s: got %h, expected %h", what, got, exp);
    end
  endtask

  // Nothing in flight, an instruction reading x5 and x6.
  task automatic idle();
    rs1_addr = 5'd5;  rs1_re = 1'b1;  rs1_rf = XLEN'(64'h1111);
    rs2_addr = 5'd6;  rs2_re = 1'b1;  rs2_rf = XLEN'(64'h2222);
    csr_op   = CSR_NONE;  sys_op = SYS_NONE;
    ex_valid = 1'b0;  ex_rd = '0;  ex_rd_we = 1'b0;  ex_unit = UNIT_ALU;
    exmem_valid = 1'b0;  exmem_rd = '0;  exmem_rd_we = 1'b0;
    exmem_is_load = 1'b0;  exmem_amo_op = AMO_NONE;
    exmem_result = XLEN'(64'hABCD);
    busy = 1'b0;
  endtask

  task automatic expect_out(input string what,
                            input fwd_src_e f1, input logic [XLEN-1:0] v1,
                            input fwd_src_e f2, input logic [XLEN-1:0] v2,
                            input logic st, input logic lu);
    #1;
    check({what, ": stall"},    XLEN'(stall),    XLEN'(st));
    check({what, ": load_use"}, XLEN'(load_use), XLEN'(lu));
    // The select and value only matter when ID is allowed to issue.
    if (!st) begin
      check({what, ": rs1_fwd"}, XLEN'(rs1_fwd), XLEN'(f1));
      check({what, ": rs2_fwd"}, XLEN'(rs2_fwd), XLEN'(f2));
      if (f1 == FWD_RF) check({what, ": rs1_val"}, rs1_val, v1);
      if (f2 == FWD_RF) check({what, ": rs2_val"}, rs2_val, v2);
    end
  endtask

  // ---------------------------------------------------------------------------
  // Reference model, from the table in the s1_hazard header
  // ---------------------------------------------------------------------------
  function automatic logic unit_final(exec_unit_e u);
    return u == UNIT_ALU || u == UNIT_CSR || u == UNIT_MUL || u == UNIT_DIV;
  endfunction

  task automatic model_operand(input  logic re, input logic [REG_ADDR_W-1:0] a,
                               input  logic [XLEN-1:0] rf,
                               output fwd_src_e f, output logic [XLEN-1:0] v,
                               output logic st);
    f = FWD_RF;  v = rf;  st = 1'b0;
    if (re && a != '0) begin
      if (ex_valid && ex_rd_we && ex_rd != '0 && ex_rd == a) begin
        if (unit_final(ex_unit)) f = FWD_EXMEM; else st = 1'b1;
      end else if (exmem_valid && exmem_rd_we && exmem_rd != '0 && exmem_rd == a) begin
        if (!exmem_is_load && exmem_amo_op == AMO_NONE) v = exmem_result; else st = 1'b1;
      end
    end
  endtask

  initial begin
    fwd_src_e        f1, f2;
    logic [XLEN-1:0] v1, v2;
    logic            s1, s2, ser;
    int unsigned     pick;

    // -- no producer ----------------------------------------------------------
    idle();
    expect_out("idle", FWD_RF, rs1_rf, FWD_RF, rs2_rf, 1'b0, 1'b0);

    // -- producer in EX, result final there: forward, no stall -----------------
    idle();  ex_valid = 1'b1;  ex_rd_we = 1'b1;  ex_rd = 5'd5;  ex_unit = UNIT_ALU;
    expect_out("EX alu -> rs1", FWD_EXMEM, '0, FWD_RF, rs2_rf, 1'b0, 1'b0);
    ex_rd = 5'd6;  ex_unit = UNIT_MUL;
    expect_out("EX mul -> rs2", FWD_RF, rs1_rf, FWD_EXMEM, '0, 1'b0, 1'b0);
    ex_unit = UNIT_DIV;
    expect_out("EX div -> rs2", FWD_RF, rs1_rf, FWD_EXMEM, '0, 1'b0, 1'b0);
    ex_unit = UNIT_CSR;
    expect_out("EX csr -> rs2", FWD_RF, rs1_rf, FWD_EXMEM, '0, 1'b0, 1'b0);

    // -- producer in EX, result not final: load-use stall ----------------------
    ex_rd = 5'd5;  ex_unit = UNIT_LSU;
    expect_out("EX load -> rs1", FWD_RF, '0, FWD_RF, '0, 1'b1, 1'b1);
    ex_unit = UNIT_MXIF;
    expect_out("EX mxif -> rs1", FWD_RF, '0, FWD_RF, '0, 1'b1, 1'b1);

    // -- things in EX that are not producers for this instruction --------------
    ex_unit = UNIT_ALU;  ex_valid = 1'b0;
    expect_out("EX not valid", FWD_RF, rs1_rf, FWD_RF, rs2_rf, 1'b0, 1'b0);
    ex_valid = 1'b1;  ex_rd_we = 1'b0;
    expect_out("EX no rd_we", FWD_RF, rs1_rf, FWD_RF, rs2_rf, 1'b0, 1'b0);
    ex_rd_we = 1'b1;  ex_rd = 5'd7;
    expect_out("EX other rd", FWD_RF, rs1_rf, FWD_RF, rs2_rf, 1'b0, 1'b0);

    // -- producer in EX/MEM, result final: value captured in ID -----------------
    idle();  exmem_valid = 1'b1;  exmem_rd_we = 1'b1;  exmem_rd = 5'd5;
    expect_out("EXMEM final -> rs1", FWD_RF, exmem_result, FWD_RF, rs2_rf, 1'b0, 1'b0);
    exmem_rd = 5'd6;
    expect_out("EXMEM final -> rs2", FWD_RF, rs1_rf, FWD_RF, exmem_result, 1'b0, 1'b0);

    // -- producer in EX/MEM, MEM has not answered: stall ------------------------
    exmem_is_load = 1'b1;
    expect_out("EXMEM load -> rs2", FWD_RF, '0, FWD_RF, '0, 1'b1, 1'b1);
    exmem_is_load = 1'b0;  exmem_amo_op = AMO_LR;
    expect_out("EXMEM lr -> rs2", FWD_RF, '0, FWD_RF, '0, 1'b1, 1'b1);
    exmem_amo_op = AMO_SC;
    expect_out("EXMEM sc -> rs2", FWD_RF, '0, FWD_RF, '0, 1'b1, 1'b1);
    exmem_amo_op = AMO_ADD;
    expect_out("EXMEM amoadd -> rs2", FWD_RF, '0, FWD_RF, '0, 1'b1, 1'b1);

    // -- both stages write the same register: EX holds the younger one ----------
    idle();
    ex_valid = 1'b1;     ex_rd_we = 1'b1;     ex_rd = 5'd5;     ex_unit = UNIT_ALU;
    exmem_valid = 1'b1;  exmem_rd_we = 1'b1;  exmem_rd = 5'd5;  exmem_is_load = 1'b1;
    expect_out("EX beats EXMEM", FWD_EXMEM, '0, FWD_RF, rs2_rf, 1'b0, 1'b0);

    // -- x0 and unread operands never match -------------------------------------
    idle();  rs1_addr = '0;  ex_valid = 1'b1;  ex_rd_we = 1'b1;  ex_rd = '0;  ex_unit = UNIT_LSU;
    expect_out("x0 operand", FWD_RF, rs1_rf, FWD_RF, rs2_rf, 1'b0, 1'b0);
    idle();  rs1_re = 1'b0;  ex_valid = 1'b1;  ex_rd_we = 1'b1;  ex_rd = 5'd5;  ex_unit = UNIT_LSU;
    expect_out("rs1 not read", FWD_RF, rs1_rf, FWD_RF, rs2_rf, 1'b0, 1'b0);

    // -- serialisation: CSR and system instructions wait for an empty pipe ------
    idle();  rs1_re = 1'b0;  rs2_re = 1'b0;  csr_op = CSR_RW;
    expect_out("csr, pipe empty", FWD_RF, rs1_rf, FWD_RF, rs2_rf, 1'b0, 1'b0);
    busy = 1'b1;
    expect_out("csr, downstream busy", FWD_RF, '0, FWD_RF, '0, 1'b1, 1'b0);
    busy = 1'b0;  ex_valid = 1'b1;
    expect_out("csr, EX occupied", FWD_RF, '0, FWD_RF, '0, 1'b1, 1'b0);
    csr_op = CSR_NONE;  sys_op = SYS_MRET;
    expect_out("mret, EX occupied", FWD_RF, '0, FWD_RF, '0, 1'b1, 1'b0);
    sys_op = SYS_NONE;
    expect_out("plain op, EX occupied", FWD_RF, rs1_rf, FWD_RF, rs2_rf, 1'b0, 1'b0);

    // -- random sweep against the model ----------------------------------------
    // Register addresses are drawn from a small set so that matches are common.
    for (int unsigned i = 0; i < N_RANDOM; i++) begin
      rs1_addr = REG_ADDR_W'($urandom_range(0, 3));
      rs2_addr = REG_ADDR_W'($urandom_range(0, 3));
      ex_rd    = REG_ADDR_W'($urandom_range(0, 3));
      exmem_rd = REG_ADDR_W'($urandom_range(0, 3));
      rs1_re = 1'($urandom);  rs2_re = 1'($urandom);
      rs1_rf = {$urandom, $urandom};  rs2_rf = {$urandom, $urandom};
      exmem_result = {$urandom, $urandom};
      ex_valid = 1'($urandom);     ex_rd_we = 1'($urandom);
      exmem_valid = 1'($urandom);  exmem_rd_we = 1'($urandom);
      exmem_is_load = 1'($urandom);
      busy = 1'($urandom);
      pick = $urandom_range(0, 6);
      unique case (pick)
        0: ex_unit = UNIT_ALU;
        1: ex_unit = UNIT_LSU;
        2: ex_unit = UNIT_MUL;
        3: ex_unit = UNIT_DIV;
        4: ex_unit = UNIT_CSR;
        5: ex_unit = UNIT_MXIF;
        default: ex_unit = UNIT_NONE;
      endcase
      pick = $urandom_range(0, 3);
      unique case (pick)
        0: exmem_amo_op = AMO_LR;
        1: exmem_amo_op = AMO_SWAP;
        default: exmem_amo_op = AMO_NONE;
      endcase
      csr_op = ($urandom_range(0, 7) == 0) ? CSR_RS   : CSR_NONE;
      sys_op = ($urandom_range(0, 7) == 0) ? SYS_WFI  : SYS_NONE;

      model_operand(rs1_re, rs1_addr, rs1_rf, f1, v1, s1);
      model_operand(rs2_re, rs2_addr, rs2_rf, f2, v2, s2);
      ser = (csr_op != CSR_NONE || sys_op != SYS_NONE) && (ex_valid || busy);
      expect_out("random", f1, v1, f2, v2, s1 || s2 || ser, s1 || s2);
    end

    if (errors != 0) $fatal(1, "=== FAIL : %0d of %0d checks ===", errors, checks);
    $display("=== PASS : %0d checks ===", checks);
    $finish;
  end

endmodule

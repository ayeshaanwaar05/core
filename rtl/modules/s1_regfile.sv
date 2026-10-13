// =============================================================================
// Copyright 2026 Maktab-e-Digital Systems Lahore.
// Licensed under the Apache License, Version 2.0, see LICENSE file for details.
// SPDX-License-Identifier: Apache-2.0
//
// Author(s)    : integration (Oct,2026)
// Modified By  :
//
// s1_regfile   : architectural integer register file               [COMPLETE]
// Description  :
// 31x XLEN registers, two read ports, one write port.  x0 is not storage: it
// reads zero and a write to it is dropped.
//
// The write port is driven by WB, which is the commit point: nothing writes
// here speculatively, so a flush does not touch this file and there is no
// state to roll back.
//
// Read-during-write returns the new value, and the 5-stage core depends on it.
// WB commits an instruction in the same cycle ID may be reading its
// destination, and ID's hazard check deliberately does not look at WB -- it
// relies on this bypass instead.  Without it, every dependency at a distance
// of three instructions would read a stale register.
//
// Reference: SPEC 7.2, 7.5.  Testbench: verif/unit/tb_s1_regfile.sv.
// =============================================================================

module s1_regfile
  import s1_pkg::*;
(
  input  logic                  clk_i,
  input  logic                  rst_ni,

  // Read ports, combinational (ID)
  input  logic [REG_ADDR_W-1:0] rs1_addr_i,
  input  logic [REG_ADDR_W-1:0] rs2_addr_i,
  output logic [XLEN-1:0]       rs1_data_o,
  output logic [XLEN-1:0]       rs2_data_o,

  // Architectural write port, from retire
  input  rf_wr_t                wr_i
);

  localparam int unsigned N_REG = 2 ** REG_ADDR_W;

  logic [N_REG-1:0][XLEN-1:0] rf_q;

  // x0 is hardwired: dropping the write here means no read path has to special
  // case it, including the read-during-write bypass below.
  logic we;
  assign we = wr_i.we && (wr_i.addr != '0);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rf_q <= '0;
    end else if (we) begin
      rf_q[wr_i.addr] <= wr_i.data;
    end
  end

  always_comb begin
    rs1_data_o = (rs1_addr_i == '0) ? '0 : rf_q[rs1_addr_i];
    rs2_data_o = (rs2_addr_i == '0) ? '0 : rf_q[rs2_addr_i];
    if (we && rs1_addr_i == wr_i.addr) rs1_data_o = wr_i.data;
    if (we && rs2_addr_i == wr_i.addr) rs2_data_o = wr_i.data;
  end

  // rf_q[0] is never written and never read; keeping the array a full 2**5
  // entries costs nothing and keeps the index width honest.
  logic unused_x0;
  assign unused_x0 = ^rf_q[0];

endmodule

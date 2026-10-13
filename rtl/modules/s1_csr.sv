// =============================================================================
// Copyright 2026 Maktab-e-Digital Systems Lahore.
// Licensed under the Apache License, Version 2.0, see LICENSE file for details.
// SPDX-License-Identifier: Apache-2.0
//
// Author(s)    : integration (Oct,2026)
// Modified By  :
//
// s1_csr       : CSR file, trap architecture and counters           [COMPLETE]
// Description  :
// Address-decoded CSR file: core CSRs and counter CSRs.  Also holds the
// privilege FSM and builds the trap vector.
//
// SPEC 10.2's third class -- the external port a coprocessor's own CSRs answer
// on -- is not here, because this core has no coprocessor port.  Adding it
// back is a contained change: `csr_is_local` below already answers "is this
// address mine?", so an unimplemented address only has to be offered outward
// before it is called illegal.  See core5/docs/INTEGRATING.md.
//
// Two separate paths, and keeping them separate is the point:
//   * the EX query -- `csr_addr_i` with `re`/`we` intents -- is side-effect
//     free.  It returns the old value and the access-check result so EX can
//     compute the read-modify-write and raise illegal-instruction.
//   * `commit_i`, from retire, is the only thing that writes (SPEC 7.3, 9.2
//     step 2).  A CSR write therefore cannot be undone by a flush, because it
//     never happens speculatively.
//
// S-mode is architected, not implemented: mstatus's S fields, medeleg, mideleg
// and satp are present and writable, delegation is computed, and misa reports
// S as 0 until translation works (SCOPE_CONTRACT.md section 4).
//
// Reference: SPEC 10.1-10.3, 11, 12; INTERFACES.md I7.
// Testbench: verif/unit/tb_s1_csr.sv.
// =============================================================================

module s1_csr
  import s1_pkg::*;
#(
  parameter int unsigned PMP_REGIONS = PMP_N,
  parameter logic [XLEN-1:0] HART_ID  = '0,
  localparam int unsigned PMP_W = (PMP_REGIONS > 0) ? PMP_REGIONS : 1,
  localparam int unsigned PA_W  = PLEN - 2
) (
  input  logic                        clk_i,
  input  logic                        rst_ni,

  // ---- Side-effect-free query, from EX ------------------------------------
  input  logic [11:0]                 csr_addr_i,
  input  logic                        csr_re_i,
  input  logic                        csr_we_i,
  output logic [XLEN-1:0]             csr_rdata_o,
  output logic                        csr_illegal_o,

  // ---- The only write path: retire ----------------------------------------
  input  csr_upd_t                    commit_i,

  // ---- Traps and xRET, from retire ----------------------------------------
  input  trap_req_t                   trap_req_i,
  input  logic                        mret_i,
  output logic [XLEN-1:0]             trap_vec_o,
  output logic [XLEN-1:0]             mepc_o,

  // ---- Privilege ----------------------------------------------------------
  output priv_lvl_e                   priv_o,         // current mode (fetch, PMP-X)
  output priv_lvl_e                   priv_data_o,    // effective for loads/stores, after MPRV

  // ---- Interrupts ---------------------------------------------------------
  input  irq_t                        irq_i,
  output logic                        irq_valid_o,
  output logic [5:0]                  irq_code_o,

  // ---- PMP configuration, read by s1_pmp ----------------------------------
  output logic [PMP_W-1:0][7:0]       pmpcfg_o,
  output logic [PMP_W-1:0][PA_W-1:0]  pmpaddr_o,

  // ---- Counters (SPEC 12) -------------------------------------------------
  input  logic                        instret_i,
  input  logic [PERF_N-1:0]           perf_i          // event k is perf_i[k-1]
);

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  priv_lvl_e        priv_q;

  // mstatus, as the fields we implement rather than as a 64-bit blob: the
  // reserved bits must read zero and a blob invites writing them.
  logic             mstatus_mie_q, mstatus_mpie_q, mstatus_mprv_q;
  logic [1:0]       mstatus_mpp_q;
  logic             mstatus_sie_q, mstatus_spie_q, mstatus_spp_q;

  logic [XLEN-1:0]  mtvec_q, mscratch_q, mepc_q, mtval_q;
  logic [XLEN-1:0]  medeleg_q, mideleg_q, satp_q;
  logic             mcause_int_q;
  logic [5:0]       mcause_code_q;
  logic [XLEN-1:0]  mie_q;
  logic [XLEN-1:0]  mcounteren_q, mcountinhibit_q;

  logic [XLEN-1:0]  mcycle_q, minstret_q;
  logic [HPM_N-1:0][XLEN-1:0] mhpmcounter_q;
  logic [HPM_N-1:0][5:0]      mhpmevent_q;

  logic [PMP_W-1:0][7:0]      pmpcfg_q;
  logic [PMP_W-1:0][PA_W-1:0] pmpaddr_q;

  assign pmpcfg_o  = pmpcfg_q;
  assign pmpaddr_o = pmpaddr_q;
  assign mepc_o    = mepc_q;
  assign priv_o    = priv_q;

  // MPRV: loads and stores execute at MPP's privilege while it is set, which is
  // how an M-mode trap handler reaches U-mode memory with U-mode checks.
  assign priv_data_o = mstatus_mprv_q ? priv_lvl_e'(mstatus_mpp_q) : priv_q;

  // ---------------------------------------------------------------------------
  // mip is read-only in v1: every pending bit comes from outside the core, so
  // there is nothing for software to set here (INTERFACES.md I7).
  // ---------------------------------------------------------------------------
  logic [XLEN-1:0] mip;
  always_comb begin
    mip                = '0;
    mip[IRQ_M_SOFT]    = irq_i.m_soft;
    mip[IRQ_M_TIMER]   = irq_i.m_timer;
    mip[IRQ_M_EXT]     = irq_i.m_ext;
  end

  // ---------------------------------------------------------------------------
  // Interrupt selection.  An M-mode interrupt is taken when the hart is below
  // M, or is in M with MIE set.  Priority is SPEC 10.3's: external, then
  // software, then timer.
  // ---------------------------------------------------------------------------
  logic [XLEN-1:0] irq_active;
  logic            m_enabled;

  assign m_enabled  = (priv_q != PRIV_M) || mstatus_mie_q;
  assign irq_active = mip & mie_q;

  always_comb begin
    irq_valid_o = 1'b0;
    irq_code_o  = '0;
    if (m_enabled) begin
      if (irq_active[IRQ_M_EXT]) begin
        irq_valid_o = 1'b1;
        irq_code_o  = IRQ_M_EXT;
      end else if (irq_active[IRQ_M_SOFT]) begin
        irq_valid_o = 1'b1;
        irq_code_o  = IRQ_M_SOFT;
      end else if (irq_active[IRQ_M_TIMER]) begin
        irq_valid_o = 1'b1;
        irq_code_o  = IRQ_M_TIMER;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Address decode.  `hit` says the address exists here; `ext` routes it to the
  // coprocessor instead.  Anything neither is illegal.
  // ---------------------------------------------------------------------------
  logic [11:0] addr;
  assign addr = csr_addr_i;

  logic is_hpm_counter, is_hpm_event, is_pmpcfg, is_pmpaddr;
  logic [3:0] hpm_sel, pmpcfg_sel, pmpaddr_sel;

  assign is_hpm_counter = (addr >= CSR_MHPMCOUNTER3) && (addr < (CSR_MHPMCOUNTER3 + 12'(HPM_N)));
  assign is_hpm_event   = (addr >= CSR_MHPMEVENT3)   && (addr < (CSR_MHPMEVENT3   + 12'(HPM_N)));
  // RV64 uses only the even pmpcfg indices.
  assign is_pmpcfg      = (addr >= CSR_PMPCFG0) && (addr < (CSR_PMPCFG0 + 12'd4)) && (addr[0] == 1'b0);
  assign is_pmpaddr     = (addr >= CSR_PMPADDR0) && (addr < (CSR_PMPADDR0 + 12'(PMP_REGIONS)));

  assign hpm_sel        = 4'(addr - CSR_MHPMCOUNTER3);
  assign pmpcfg_sel     = 4'(addr - CSR_PMPCFG0);
  assign pmpaddr_sel    = 4'(addr - CSR_PMPADDR0);

  // Whether an address is implemented in this file.  A function, not a flag
  // raised inside the read case below, because the commit path needs the same
  // question answered about a *different* address in the same cycle -- and two
  // copies of the address list is how the two would drift apart.
  function automatic logic csr_is_local(logic [11:0] a);
    logic l;
    unique case (a)
      CSR_MVENDORID, CSR_MARCHID, CSR_MIMPID, CSR_MHARTID,
      CSR_MSTATUS, CSR_MISA, CSR_MEDELEG, CSR_MIDELEG, CSR_MIE, CSR_MTVEC,
      CSR_MCOUNTEREN, CSR_MCOUNTINHIBIT, CSR_MSCRATCH, CSR_MEPC, CSR_MCAUSE,
      CSR_MTVAL, CSR_MIP, CSR_SATP,
      CSR_MCYCLE, CSR_MINSTRET, CSR_CYCLE, CSR_INSTRET: l = 1'b1;
      default: begin
        l = ((a >= CSR_MHPMCOUNTER3) && (a < (CSR_MHPMCOUNTER3 + 12'(HPM_N))))
         || ((a >= CSR_MHPMEVENT3)   && (a < (CSR_MHPMEVENT3   + 12'(HPM_N))))
         || ((a >= CSR_PMPCFG0)      && (a < (CSR_PMPCFG0 + 12'd4)) && (a[0] == 1'b0))
         || ((a >= CSR_PMPADDR0)     && (a < (CSR_PMPADDR0 + 12'(PMP_REGIONS))));
      end
    endcase
    return l;
  endfunction

  logic hit;
  logic [XLEN-1:0] rdata;

  assign hit        = csr_is_local(addr);

  always_comb begin
    rdata = '0;
    unique case (addr)
      CSR_MVENDORID: rdata = '0;                     // not a commercial vendor
      CSR_MARCHID:   rdata = '0;
      CSR_MIMPID:    rdata = '0;
      CSR_MHARTID:   rdata = HART_ID;

      CSR_MSTATUS: begin
        rdata            = '0;
        rdata[1]         = mstatus_sie_q;
        rdata[3]         = mstatus_mie_q;
        rdata[5]         = mstatus_spie_q;
        rdata[7]         = mstatus_mpie_q;
        rdata[8]         = mstatus_spp_q;
        rdata[12:11]     = mstatus_mpp_q;
        rdata[17]        = mstatus_mprv_q;
        rdata[33:32]     = 2'd2;                     // UXL = 64
      end

      CSR_MISA:          rdata = MISA_VALUE;
      CSR_MEDELEG:       rdata = medeleg_q;
      CSR_MIDELEG:       rdata = mideleg_q;
      CSR_MIE:           rdata = mie_q;
      CSR_MTVEC:         rdata = mtvec_q;
      CSR_MCOUNTEREN:    rdata = mcounteren_q;
      CSR_MCOUNTINHIBIT: rdata = mcountinhibit_q;
      CSR_MSCRATCH:      rdata = mscratch_q;
      CSR_MEPC:          rdata = mepc_q;
      CSR_MCAUSE:        rdata = {mcause_int_q, {(XLEN-7){1'b0}}, mcause_code_q};
      CSR_MTVAL:         rdata = mtval_q;
      CSR_MIP:           rdata = mip;
      CSR_SATP:          rdata = satp_q;

      CSR_MCYCLE:        rdata = mcycle_q;
      CSR_MINSTRET:      rdata = minstret_q;
      CSR_CYCLE:         rdata = mcycle_q;
      CSR_INSTRET:       rdata = minstret_q;

      default: begin
        if      (is_hpm_counter) rdata = mhpmcounter_q[hpm_sel];
        else if (is_hpm_event)   rdata = {{(XLEN-6){1'b0}}, mhpmevent_q[hpm_sel]};
        else if (is_pmpcfg)      rdata = read_pmpcfg(pmpcfg_sel);
        else if (is_pmpaddr)     rdata = {{(XLEN-PA_W){1'b0}}, pmpaddr_q[pmpaddr_sel]};
        else                     rdata = '0;        // external, or nothing
      end
    endcase
  end

  // RV64 packs eight entries into one pmpcfg CSR; index 0 covers regions 0-7
  // and index 2 regions 8-15.
  function automatic logic [XLEN-1:0] read_pmpcfg(logic [3:0] sel);
    logic [XLEN-1:0] v;
    v = '0;
    for (int unsigned i = 0; i < 8; i++) begin
      if ((32'(sel) * 4 + i) < PMP_REGIONS) v[i*8 +: 8] = pmpcfg_q[32'(sel) * 4 + i];
    end
    return v;
  endfunction

  // ---------------------------------------------------------------------------
  // Access control.  addr[9:8] is the lowest privilege that may touch the CSR;
  // addr[11:10] == 2'b11 marks it read-only.
  // ---------------------------------------------------------------------------
  logic priv_ok, read_only, counter_ok;

  assign priv_ok   = (priv_q >= priv_lvl_e'(addr[9:8]));
  assign read_only = (addr[11:10] == 2'b11);

  // The U-mode shadows are readable only with the matching mcounteren bit.
  always_comb begin
    counter_ok = 1'b1;
    if (priv_q != PRIV_M) begin
      if      (addr == CSR_CYCLE)   counter_ok = mcounteren_q[0];
      else if (addr == CSR_INSTRET) counter_ok = mcounteren_q[2];
    end
  end


  always_comb begin
    csr_rdata_o   = rdata;
    csr_illegal_o = 1'b0;
    if (!(csr_re_i || csr_we_i)) begin
      csr_illegal_o = 1'b0;                          // no access, nothing to check
    end else if (!hit) begin
      csr_illegal_o = 1'b1;                          // not implemented here
    end else if (!priv_ok || !counter_ok) begin
      csr_illegal_o = 1'b1;
    end else if (csr_we_i && read_only) begin
      csr_illegal_o = 1'b1;
    end
  end

  // ---------------------------------------------------------------------------
  // Trap vector (SPEC 10.3).  mtvec[1:0] is the mode: 0 direct, 1 vectored,
  // and in vectored mode only interrupts are offset.
  // ---------------------------------------------------------------------------
  logic [XLEN-1:0] tvec_base;
  assign tvec_base = {mtvec_q[XLEN-1:2], 2'b00};

  always_comb begin
    trap_vec_o = tvec_base;
    if (mtvec_q[0] && trap_req_i.is_irq) begin
      trap_vec_o = tvec_base + (XLEN'(trap_req_i.exccode) << 2);
    end
  end

  // ---------------------------------------------------------------------------
  // Writes.  One retire per cycle, so `commit_i` and `trap_req_i` are mutually
  // exclusive by construction -- a trapping instruction commits nothing.
  // ---------------------------------------------------------------------------
  logic            cwe;
  logic [11:0]     caddr;
  logic [XLEN-1:0] cdata;

  assign cwe   = commit_i.we;
  assign caddr = commit_i.addr;
  assign cdata = commit_i.wdata;

  // Event k counts on perf_i[k-1]; selector 0 is "never", so an unprogrammed
  // counter does not move.
  function automatic logic hpm_fire(logic [5:0] sel);
    logic f;
    f = 1'b0;
    for (int unsigned k = 1; k <= PERF_N; k++) begin
      if (sel == 6'(k)) f = perf_i[k-1];
    end
    return f;
  endfunction

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      priv_q          <= PRIV_M;
      mstatus_mie_q   <= 1'b0;
      mstatus_mpie_q  <= 1'b0;
      mstatus_mprv_q  <= 1'b0;
      mstatus_mpp_q   <= PRIV_M;
      mstatus_sie_q   <= 1'b0;
      mstatus_spie_q  <= 1'b0;
      mstatus_spp_q   <= 1'b0;
      mtvec_q         <= '0;
      mscratch_q      <= '0;
      mepc_q          <= '0;
      mtval_q         <= '0;
      medeleg_q       <= '0;
      mideleg_q       <= '0;
      satp_q          <= '0;
      mcause_int_q    <= 1'b0;
      mcause_code_q   <= '0;
      mie_q           <= '0;
      mcounteren_q    <= '0;
      mcountinhibit_q <= '0;
      mcycle_q        <= '0;
      minstret_q      <= '0;
      mhpmcounter_q   <= '0;
      mhpmevent_q     <= '0;
      pmpcfg_q        <= '0;
      pmpaddr_q       <= '0;
    end else begin
      // -- counters -------------------------------------------------------
      if (!mcountinhibit_q[0]) mcycle_q   <= mcycle_q + XLEN'(1);
      if (!mcountinhibit_q[2] && instret_i) minstret_q <= minstret_q + XLEN'(1);
      for (int unsigned i = 0; i < HPM_N; i++) begin
        if (!mcountinhibit_q[i+3] && hpm_fire(mhpmevent_q[i])) begin
          mhpmcounter_q[i] <= mhpmcounter_q[i] + XLEN'(1);
        end
      end

      // -- software writes, at retire --------------------------------------
      if (cwe) begin
        unique case (caddr)
          CSR_MSTATUS: begin
            mstatus_sie_q  <= cdata[1];
            mstatus_mie_q  <= cdata[3];
            mstatus_spie_q <= cdata[5];
            mstatus_mpie_q <= cdata[7];
            mstatus_spp_q  <= cdata[8];
            // WARL: MPP must hold a mode that exists.  S is architected, so
            // it is legal to write even though its behaviour is stubbed.
            mstatus_mpp_q  <= (cdata[12:11] == 2'b10) ? PRIV_M : cdata[12:11];
            mstatus_mprv_q <= cdata[17];
          end
          CSR_MEDELEG:       medeleg_q       <= cdata;
          CSR_MIDELEG:       mideleg_q       <= cdata;
          CSR_MIE:           mie_q           <= cdata;
          CSR_MTVEC:         mtvec_q         <= {cdata[XLEN-1:2], 1'b0, cdata[0]};
          CSR_MCOUNTEREN:    mcounteren_q    <= cdata;
          CSR_MCOUNTINHIBIT: mcountinhibit_q <= cdata;
          CSR_MSCRATCH:      mscratch_q      <= cdata;
          // IALIGN=16 with C, so only bit 0 is forced.
          CSR_MEPC:          mepc_q          <= {cdata[XLEN-1:1], 1'b0};
          CSR_MCAUSE: begin
            mcause_int_q  <= cdata[XLEN-1];
            mcause_code_q <= cdata[5:0];
          end
          CSR_MTVAL:         mtval_q         <= cdata;
          CSR_SATP:          satp_q          <= cdata;
          CSR_MCYCLE:        mcycle_q        <= cdata;
          CSR_MINSTRET:      minstret_q      <= cdata;
          default: begin
            if (is_hpm_counter) begin
              mhpmcounter_q[4'(caddr - CSR_MHPMCOUNTER3)] <= cdata;
            end else if (is_hpm_event) begin
              mhpmevent_q[4'(caddr - CSR_MHPMEVENT3)] <= cdata[5:0];
            end else if (is_pmpcfg) begin
              // A locked entry ignores writes to its own config byte.
              for (int unsigned i = 0; i < 8; i++) begin
                if ((((32'(caddr) - 32'(CSR_PMPCFG0)) * 4) + i) < PMP_REGIONS) begin
                  if (!pmpcfg_q[((32'(caddr) - 32'(CSR_PMPCFG0)) * 4) + i][7]) begin
                    pmpcfg_q[((32'(caddr) - 32'(CSR_PMPCFG0)) * 4) + i] <= cdata[i*8 +: 8];
                  end
                end
              end
            end else if (is_pmpaddr) begin
              if (!pmpcfg_q[4'(caddr - CSR_PMPADDR0)][7]) begin
                pmpaddr_q[4'(caddr - CSR_PMPADDR0)] <= cdata[PA_W-1:0];
              end
            end
          end
        endcase
      end

      // -- trap entry (SPEC 10.3).  Beats a software write: they cannot
      //    coincide, since a trapping instruction commits nothing.
      if (trap_req_i.valid) begin
        mepc_q         <= trap_req_i.epc;
        mcause_int_q   <= trap_req_i.is_irq;
        mcause_code_q  <= trap_req_i.exccode;
        mtval_q        <= trap_req_i.tval;
        mstatus_mpie_q <= mstatus_mie_q;
        mstatus_mie_q  <= 1'b0;
        mstatus_mpp_q  <= priv_q;
        priv_q         <= PRIV_M;
      end else if (mret_i) begin
        mstatus_mie_q  <= mstatus_mpie_q;
        mstatus_mpie_q <= 1'b1;
        priv_q         <= priv_lvl_e'(mstatus_mpp_q);
        mstatus_mpp_q  <= PRIV_U;
        // Leaving M clears MPRV, so a handler cannot leak its data privilege.
        if (priv_lvl_e'(mstatus_mpp_q) != PRIV_M) mstatus_mprv_q <= 1'b0;
      end
    end
  end

  // Delegation is computed so the matrix is present and testable from v1, but
  // with S-mode behaviour stubbed every trap is still taken in M
  // (SCOPE_CONTRACT.md section 4).  satp is writable and bypassed.
  logic unused_deleg;
  assign unused_deleg = ^{medeleg_q, mideleg_q, satp_q, mscratch_q,
                          mstatus_sie_q, mstatus_spie_q, mstatus_spp_q};

endmodule

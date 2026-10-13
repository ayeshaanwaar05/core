// Copyright 2026 Maktab-e-Digital Systems Lahore.
// Licensed under the Apache License, Version 2.0, see LICENSE file for details.
// SPDX-License-Identifier: Apache-2.0
//
// =============================================================================
// s1_pkg : MEDS-S1 core parameters and shared types                [COMPLETE]
//
// Every type the core passes between modules lives here.  Nothing in rtl/core/
// declares a struct of its own -- if two modules need to agree on a shape, that
// shape belongs in this file.
//
// THIS IS THE 5-STAGE CORE.  Classic in-order IF -> ID -> EX -> MEM -> WB,
// in-order issue AND in-order completion.  There is no completion buffer, no
// MXIF coprocessor port, and no multi-cycle units hanging off the side of the
// pipeline: MUL and DIV execute inside EX and stall it, so every instruction
// leaves EX in program order and WB is the commit point.
//
// What that removes, relative to the decoupled design in SPEC 9: cb_entry_t,
// cb_fwd_t, wb_upd_t, the MXIF channel and the external CSR port.  What
// replaces the completion-buffer index is `tag` -- a small rotating number
// that lets the store buffer match a committed store to the instruction that
// made it.  It orders nothing and nothing waits on it.
//
// Reference: SPEC Part II, INTERFACES.md sections 1 and 2.
// =============================================================================

package s1_pkg;

  // ---------------------------------------------------------------------------
  // Global parameters
  // ---------------------------------------------------------------------------
  parameter int unsigned XLEN      = 64;
  parameter int unsigned ILEN      = 32;
  parameter int unsigned CLEN      = 16;   // compressed instruction (and IALIGN) width
  parameter int unsigned PLEN      = 40;   // physical address width
  parameter int unsigned REG_ADDR_W = 5;

  // In-flight tag.  Not an ordering mechanism: the pipeline is in order.  It
  // exists so the store buffer can tell which pending store belongs to the
  // instruction now committing in WB.  Four in-flight stages means it only has
  // to be unique across the pipeline depth; 3 bits is ample.
  parameter int unsigned TAG_W     = 3;

  parameter int unsigned PMP_N     = 16;
  parameter int unsigned SB_DEPTH  = 4;    // store buffer entries (SPEC 14)

  // Reset vector.  Overridable per config; the boot ROM lives here.
  parameter logic [XLEN-1:0] BOOT_ADDR = 64'h0000_0000_0000_1000;

  // ---------------------------------------------------------------------------
  // Privilege levels
  // ---------------------------------------------------------------------------
  typedef enum logic [1:0] {
    PRIV_U = 2'b00,
    PRIV_S = 2'b01,
    PRIV_M = 2'b11
  } priv_lvl_e;

  // ---------------------------------------------------------------------------
  // RV64 major opcodes, inst[6:0].  Shared by the C expander, fetch and the decoder.
  // ---------------------------------------------------------------------------
  parameter logic [6:0] OPC_LOAD      = 7'b0000011;
  parameter logic [6:0] OPC_LOAD_FP   = 7'b0000111;
  parameter logic [6:0] OPC_MISC_MEM  = 7'b0001111;
  parameter logic [6:0] OPC_OP_IMM    = 7'b0010011;
  parameter logic [6:0] OPC_AUIPC     = 7'b0010111;
  parameter logic [6:0] OPC_OP_IMM_32 = 7'b0011011;
  parameter logic [6:0] OPC_STORE     = 7'b0100011;
  parameter logic [6:0] OPC_STORE_FP  = 7'b0100111;
  parameter logic [6:0] OPC_AMO       = 7'b0101111;
  parameter logic [6:0] OPC_OP        = 7'b0110011;
  parameter logic [6:0] OPC_LUI       = 7'b0110111;
  parameter logic [6:0] OPC_OP_32     = 7'b0111011;
  parameter logic [6:0] OPC_BRANCH    = 7'b1100011;
  parameter logic [6:0] OPC_JALR      = 7'b1100111;
  parameter logic [6:0] OPC_JAL       = 7'b1101111;
  parameter logic [6:0] OPC_SYSTEM    = 7'b1110011;

  // ---------------------------------------------------------------------------
  // ALU
  //
  // The W-suffixed operations are the RV64 32-bit forms: compute on the low 32
  // bits and sign-extend the result.  Keeping them as distinct opcodes rather
  // than a width flag keeps the decoder flat.
  // ---------------------------------------------------------------------------
  typedef enum logic [4:0] {
    ALU_ADD, ALU_SUB, ALU_SLL, ALU_SLT, ALU_SLTU,
    ALU_XOR, ALU_SRL, ALU_SRA, ALU_OR,  ALU_AND,
    ALU_ADDW, ALU_SUBW, ALU_SLLW, ALU_SRLW, ALU_SRAW,
    ALU_PASS_B                      // LUI and friends: forward operand b
  } alu_op_e;

  // Branch conditions, evaluated by the ALU comparator.
  typedef enum logic [2:0] {
    CMP_NONE, CMP_EQ, CMP_NE, CMP_LT, CMP_GE, CMP_LTU, CMP_GEU
  } cmp_op_e;

  // ---------------------------------------------------------------------------
  // Where a completed instruction's result came from
  // ---------------------------------------------------------------------------
  typedef enum logic [2:0] {
    UNIT_ALU, UNIT_LSU, UNIT_MUL, UNIT_DIV, UNIT_CSR, UNIT_NONE
  } exec_unit_e;


  // ---------------------------------------------------------------------------
  // Decode-stage types (rtl/core/s1_decode.sv)
  // ---------------------------------------------------------------------------

  // Load/store operand width, ID-stage view. The LSU, not the
  // decoder, owns that translation.
  typedef enum logic [1:0] {
    LS_BYTE, LS_HALF, LS_WORD, LS_DOUBLE
  } ls_size_e;

  // Zicsr operation.  CSRRW/CSRRS/CSRRC and their *-immediate forms collapse
  // to the same three read-modify-write ops; `decoded_op_t.csr_imm` carries
  // whether the operand is rs1 or a zero-extended uimm[4:0].
  typedef enum logic [1:0] {
    CSR_RW, CSR_RS, CSR_RC, CSR_NONE
  } csr_op_e;

  // RV64A atomic-memory-operation, from funct7[6:2].
  typedef enum logic [3:0] {
    AMO_LR, AMO_SC, AMO_SWAP, AMO_ADD, AMO_XOR, AMO_AND, AMO_OR,
    AMO_MIN, AMO_MAX, AMO_MINU, AMO_MAXU, AMO_NONE
  } amo_op_e;

  // Zicbom/Zicboz cache-block operation, from imm[11:0] under OP_MISC_MEM
  // funct3==010. CBO_ZERO is Zicboz; the other
  // three are Zicbom. Address is rs1 alone, same as AMO -- no offset.
  typedef enum logic [2:0] {
    CBO_INVAL, CBO_CLEAN, CBO_FLUSH, CBO_ZERO, CBO_NONE
  } cbo_op_e;

  // RV64M operation.  W-suffixed forms are the OP-32 (word) encodings, kept as
  // distinct values for the same reason alu_op_e keeps ALU_ADDW distinct from
  // ALU_ADD: the multiply/divide unit needs to know the truncation width
  // without decoding funct7/opcode a second time.
  typedef enum logic [3:0] {
    MULDIV_MUL, MULDIV_MULH, MULDIV_MULHSU, MULDIV_MULHU,
    MULDIV_DIV, MULDIV_DIVU, MULDIV_REM, MULDIV_REMU,
    MULDIV_MULW, MULDIV_DIVW, MULDIV_DIVUW, MULDIV_REMW, MULDIV_REMUW,
    MULDIV_NONE
  } muldiv_op_e;

  // System/privileged/Zifencei micro-op (FENCE, FENCE.I, and SYSTEM funct3==000
  // instructions). MRET/SRET/WFI/DRET legality (privilege, debug mode) is
  // checked at retire, not here (SPEC 10.1, 13). SFENCE.VMA differs: rs1/rs2
  // are real operands (vaddr, asid), identified by funct7==0001001; only rd
  // is fixed to 0.
  typedef enum logic [3:0] {
    SYS_NONE, SYS_ECALL, SYS_EBREAK, SYS_MRET, SYS_SRET, SYS_WFI,
    SYS_FENCE, SYS_FENCE_I, SYS_SFENCE_VMA, SYS_DRET
  } sys_op_e;

  // ---------------------------------------------------------------------------
  // decoded_op_t -- ID-stage control bundle (SPEC 7.2). Produced only by
  // s1_decode.sv; consumed by s1_regfile, s1_alu, s1_lsu, s1_csr, and
  // s1_completion_buffer. Carries no register values and no privilege
  // checks -- those belong to s1_regfile.sv and s1_csr.sv respectively.
  // ---------------------------------------------------------------------------
  typedef struct packed {
    // -- classification ------------------------------------------------------
    exec_unit_e             unit;            // which path through EX this op takes
    logic                   illegal;         // nothing will ever accept this encoding

    // -- register addressing ---------------------------------------------------
    logic [REG_ADDR_W-1:0]  rs1;             // raw instr[19:15]; uimm[4:0] when csr_imm=1
    logic [REG_ADDR_W-1:0]  rs2;             // raw instr[24:20]
    logic                   rs1_re;          // rs1 is an operand -- read/forward/hazard-check it
    logic                   rs2_re;          // rs2 is an operand
    logic [REG_ADDR_W-1:0]  rd;              // raw instr[11:7]
    logic                   rd_we;           // writes rd (x0 writes are discarded downstream, not gated here)

    // -- immediate ---------------------------------------------------------------
    logic [XLEN-1:0]        imm;             // sign- or zero-extended, format already selected

    // -- ALU / branch / address operand routing (consumed by s1_alu.sv) -----------
    alu_op_e                alu_op;
    cmp_op_e                cmp_op;          // CMP_NONE unless is_branch
    logic                   op1_is_pc;       // ALU operand A is PC, not rs1 (AUIPC, JAL)
    logic                   op2_is_imm;      // ALU operand B is imm, not rs2
    logic                   is_branch;
    logic                   is_jal;
    logic                   is_jalr;

    // -- load / store / atomic / cache-block (consumed by s1_lsu.sv) ---------------
    logic                   is_load;
    logic                   is_store;
    logic                   is_amo;
    ls_size_e               mem_size;
    logic                   mem_signed;
    amo_op_e                amo_op;
    logic                   aq;
    logic                   rl;
    logic                   is_cbo;          // Zicbom/Zicboz; address = rs1, no offset
    cbo_op_e                cbo_op;

    // -- multiply / divide --------------------------------------------------------
    logic                   is_mul;
    logic                   is_div;
    muldiv_op_e             muldiv_op;

    // -- CSR (Zicsr), consumed by s1_csr.sv -----------------------------------------
    logic                   is_csr;
    csr_op_e                csr_op;
    logic                   csr_imm;         // operand is uimm[4:0] (rs1 field), not rs1
    logic [11:0]            csr_addr;

    // -- system / privileged / Zifencei ---------------------------------------------
    sys_op_e                sys_op;

    // -- bookkeeping, carried through to the completion buffer (SPEC 9.1) -----------
    logic [XLEN-1:0]        pc;
    logic [ILEN-1:0]        instr;
  } decoded_op_t;

  // ---------------------------------------------------------------------------
  // RVFI's memory group, carried with a completion-buffer entry until retire
  // drives the trace port (SPEC 28.2).  Masks are relative to `addr`, data
  // right-justified.
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic [XLEN-1:0]       addr;
    logic [XLEN/8-1:0]     rmask;
    logic [XLEN/8-1:0]     wmask;
    logic [XLEN-1:0]       rdata;
    logic [XLEN-1:0]       wdata;
  } rvfi_mem_t;

  // The CSR read-modify-write EX computed, committed at retire (SPEC 7.3, 9.2).
  typedef struct packed {
    logic                  we;
    logic [11:0]           addr;
    logic [XLEN-1:0]       wdata;
  } csr_upd_t;
  // ---------------------------------------------------------------------------
  // Standard exception codes (mcause, interrupt bit clear)
  // ---------------------------------------------------------------------------
  parameter logic [5:0] EXC_INSTR_ADDR_MISALIGNED = 6'd0;
  parameter logic [5:0] EXC_INSTR_ACCESS_FAULT    = 6'd1;
  parameter logic [5:0] EXC_ILLEGAL_INSTR         = 6'd2;
  parameter logic [5:0] EXC_BREAKPOINT            = 6'd3;
  parameter logic [5:0] EXC_LOAD_ADDR_MISALIGNED  = 6'd4;
  parameter logic [5:0] EXC_LOAD_ACCESS_FAULT     = 6'd5;
  parameter logic [5:0] EXC_STORE_ADDR_MISALIGNED = 6'd6;
  parameter logic [5:0] EXC_STORE_ACCESS_FAULT    = 6'd7;
  parameter logic [5:0] EXC_ECALL_U               = 6'd8;
  parameter logic [5:0] EXC_ECALL_S               = 6'd9;
  parameter logic [5:0] EXC_ECALL_M               = 6'd11;
  parameter logic [5:0] EXC_INSTR_PAGE_FAULT      = 6'd12;
  parameter logic [5:0] EXC_LOAD_PAGE_FAULT       = 6'd13;
  parameter logic [5:0] EXC_STORE_PAGE_FAULT      = 6'd15;

  // ---------------------------------------------------------------------------
  // Physical memory attributes (SPEC section 11, INTERFACES.md P1-P5)
  //
  // Generated into pma_decode.sv from soc.yaml; this is the shape it produces.
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic       cacheable;
    logic       idempotent;
    logic       strong_order;   // 1 = strongly-ordered I/O, 0 = RVWMO
    logic       atomic_lrsc;
    logic       atomic_amo;
    logic       align_natural;  // 1 = misaligned access faults
  } pma_t;

  // Execute stage (rtl/core/s1_execute.sv).  Contract: docs/modules/s1_execute.md.
  // ---------------------------------------------------------------------------

  // Forwarding source of an EX operand, chosen by the hazard unit in ID.
  //
  // Only two, and the difference is *when the value exists*.  FWD_EXMEM names
  // a producer that is in EX right now: its result does not exist yet, so EX
  // must read it out of its own EX/MEM register next cycle.  FWD_RF means the
  // value is already known in ID and travels in rs1_val/rs2_val -- whether it
  // came from the register file, from the EX/MEM register, or from MEM's
  // output in the cycle it completed.  See s1_id.sv for why resolving in ID is
  // the only timing that works.
  typedef enum logic [0:0] {
    FWD_RF, FWD_EXMEM
  } fwd_src_e;

  // ID/EX register.
  typedef struct packed {
    decoded_op_t           op;
    logic [TAG_W-1:0]      tag;         // in-flight tag, assigned in ID
    logic [XLEN-1:0]       rs1_val;     // register-file reads
    logic [XLEN-1:0]       rs2_val;
    fwd_src_e              rs1_fwd;
    fwd_src_e              rs2_fwd;
    logic                  compressed;  // from fetch: successor is pc+2
    logic                  pred_taken;  // from fetch
    logic [ILEN-1:0]       instr_raw;   // from fetch: mtval for illegal instructions
    logic                  exc;         // fetch-time exception
    logic [5:0]            exccode;
    logic [XLEN-1:0]       exctval;
  } id_ex_t;

  // EX/MEM register.
  typedef struct packed {
    logic [TAG_W-1:0]      tag;
    logic [REG_ADDR_W-1:0] rd;
    logic                  rd_we;
    logic [XLEN-1:0]       result;      // ALU, link or old CSR value; loads replace it in MEM
    logic [XLEN-1:0]       next_pc;     // actual successor (RVFI pc_wdata)
    logic                  is_load;
    logic                  is_store;
    logic                  is_amo;
    ls_size_e              mem_size;
    logic                  mem_signed;
    amo_op_e               amo_op;
    logic                  aq;
    logic                  rl;
    logic [XLEN-1:0]       mem_addr;
    logic [XLEN-1:0]       mem_wdata;
    logic                  csr_we;      // committed at retire (SPEC 7.3)
    logic [11:0]           csr_addr;
    logic [XLEN-1:0]       csr_wdata;
    logic                  exc;
    logic [5:0]            exccode;
    logic [XLEN-1:0]       exctval;

    // The completion buffer used to hold these for the whole of an
    // instruction's life (SPEC 9.1).  With no buffer they travel with it, so
    // that WB -- which is now the commit point -- can drive RVFI, build mtval,
    // and act on xRET and the fences.
    logic [XLEN-1:0]       pc;
    logic [ILEN-1:0]       instr;       // as fetched: 16-bit forms zero-extended
    sys_op_e               sys_op;
    logic [REG_ADDR_W-1:0] rs1_addr;    // RVFI; 0 when the operand is not read
    logic [REG_ADDR_W-1:0] rs2_addr;
  } ex_mem_t;

  // EX -> MUL/DIV dispatch.
  typedef struct packed {
    exec_unit_e            unit;        // UNIT_MUL or UNIT_DIV
    muldiv_op_e            op;
    logic [XLEN-1:0]       a;
    logic [XLEN-1:0]       b;
    logic [TAG_W-1:0]      tag;
    logic [REG_ADDR_W-1:0] rd;
  } md_req_t;

  // MUL/DIV -> WB completion, the return leg of md_req_t.  RV64M does not trap,
  // so there is no exception group; x0 is gated in WB.
  typedef struct packed {
    logic [TAG_W-1:0]      tag;
    logic [REG_ADDR_W-1:0] rd;
    logic [XLEN-1:0]       result;
  } md_rsp_t;

  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  // MEM-REQ protocol payloads (INTERFACES.md section 2)
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic [XLEN-1:0]      addr;
    logic                 we;
    logic [XLEN/8-1:0]    be;
    logic [XLEN-1:0]      wdata;
    logic [2:0]           size;   // log2 bytes
    priv_lvl_e            mode;
    logic [3:0]           id;
  } mem_req_t;

  typedef struct packed {
    logic [3:0]           id;
    logic [XLEN-1:0]      rdata;
    logic                 err;
    logic [1:0]           errcode;
  } mem_rsp_t;

  // ---------------------------------------------------------------------------
  // Fetch -> decode bundle (SPEC 6 fetch_rsp).  Contract: docs/modules/s1_fetch.md.
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic [XLEN-1:0]  pc;
    logic [ILEN-1:0]  instr;       // 32-bit encoding, C already expanded
    logic [ILEN-1:0]  instr_raw;   // as fetched (RVFI, mtval); 16-bit zero-extended
    logic             compressed;  // next sequential pc is pc+2
    logic             pred_taken;  // BTFN already redirected to the target
    logic             exc;
    logic [5:0]       exccode;     // EXC_INSTR_ACCESS_FAULT or EXC_ILLEGAL_INSTR
    logic [XLEN-1:0]  exctval;
  } fetch_rsp_t;

  // ---------------------------------------------------------------------------
  // Memory stage (rtl/core/s1_mem_stage.sv).  Contract: docs/modules/s1_mem_stage.md.
  // ---------------------------------------------------------------------------

  // MEM/WB: one completion per instruction.  The mem_* group is RVFI's: the
  // access address, byte masks relative to it, and right-justified data.
  typedef struct packed {
    logic [TAG_W-1:0]      tag;
    logic [REG_ADDR_W-1:0] rd;
    logic                  rd_we;
    logic [XLEN-1:0]       result;      // load / LR / AMO value, SC status, else EX's result
    logic [XLEN-1:0]       next_pc;
    logic                  csr_we;
    logic [11:0]           csr_addr;
    logic [XLEN-1:0]       csr_wdata;
    logic                  sb_alloc;    // owns a store-buffer entry: retire must commit it
    logic                  exc;
    logic [5:0]            exccode;
    logic [XLEN-1:0]       exctval;
    logic [XLEN-1:0]       mem_addr;
    logic [XLEN/8-1:0]     mem_rmask;
    logic [XLEN/8-1:0]     mem_wmask;
    logic [XLEN-1:0]       mem_rdata;
    logic [XLEN-1:0]       mem_wdata;

    // The completion buffer used to hold these for the whole of an
    // instruction's life (SPEC 9.1).  With no buffer they travel with it, so
    // that WB -- which is now the commit point -- can drive RVFI, build mtval,
    // and act on xRET and the fences.
    logic [XLEN-1:0]       pc;
    logic [ILEN-1:0]       instr;       // as fetched: 16-bit forms zero-extended
    sys_op_e               sys_op;
    logic [REG_ADDR_W-1:0] rs1_addr;    // RVFI; 0 when the operand is not read
    logic [REG_ADDR_W-1:0] rs2_addr;
  } mem_wb_t;

  // ---------------------------------------------------------------------------
  // mstatus (M-mode subset only, v1.0 scope -- SPEC Appendix C)
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic [50:0] reserved_hi;
    logic [1:0]  mpp;     // bits [12:11]
    logic [2:0]  reserved_mid;
    logic        mpie;    // bit [7]
    logic [2:0]  reserved_lo;
    logic        mie;     // bit [3]
    logic [2:0]  reserved_bot;
  } mstatus_t;


  // ===========================================================================
  // INTEGRATION ADDITIONS
  //
  // Types for the modules that close the pipeline: the register file, the ID
  // glue (hazard + CB allocation), the completion buffer and its retire logic,
  // the CSR file, and the in-EX multiply/divide helper.
  // ===========================================================================

  // ---------------------------------------------------------------------------
  // RV64M timing.  MUL and DIV run inside EX and stall it; there is no second
  // completion path, so these are latencies, not channel counts.
  // ---------------------------------------------------------------------------
  parameter int unsigned MUL_LAT  = 3;      // cycles, non-pipelined here

  // ---------------------------------------------------------------------------
  // Retire -> fetch / CSR / regfile.  The architectural commit point (SPEC 9.2).
  // ---------------------------------------------------------------------------

  // Why the pipeline was flushed.  The CB drives at most one of these per
  // cycle; fetch only needs the redirect, the CSR file needs the cause.
  typedef enum logic [2:0] {
    FLUSH_NONE,
    FLUSH_TRAP,       // exception or interrupt: pc <- tvec
    FLUSH_MRET,       // xRET: pc <- xepc
    FLUSH_FENCE_I,    // Zifencei: refetch from the successor, invalidate I$
    FLUSH_SFENCE      // SFENCE.VMA: refetch (no MMU in v1, so refetch is all)
  } flush_cause_e;

  // The trap the CB asks the CSR file to take.  `interrupt` picks the mcause
  // high bit; `exccode` is the low field for both kinds.
  typedef struct packed {
    logic                  valid;
    // Named is_irq, not `interrupt`: Verilator flags that as a C++ common word
    // (SYMRSVDWORD) and the repo's waiver file takes reasons, not renames.
    logic                  is_irq;
    logic [5:0]            exccode;
    logic [XLEN-1:0]       epc;        // mepc: the faulting instruction
    logic [XLEN-1:0]       tval;       // mtval
  } trap_req_t;

  // Architectural register-file write, at retire only (SPEC 9.2 step 1).
  typedef struct packed {
    logic                  we;
    logic [REG_ADDR_W-1:0] addr;
    logic [XLEN-1:0]       data;
  } rf_wr_t;

  // ---------------------------------------------------------------------------
  // RVFI (SPEC 28.2, INTERFACES.md I6).  One retired instruction per cycle.
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic                  valid;
    logic [63:0]           order;
    logic [ILEN-1:0]       insn;
    logic                  trap;
    logic                  halt;
    logic                  intr;
    logic [1:0]            mode;
    logic [1:0]            ixl;
    logic [REG_ADDR_W-1:0] rs1_addr;
    logic [REG_ADDR_W-1:0] rs2_addr;
    logic [XLEN-1:0]       rs1_rdata;
    logic [XLEN-1:0]       rs2_rdata;
    logic [REG_ADDR_W-1:0] rd_addr;
    logic [XLEN-1:0]       rd_wdata;
    logic [XLEN-1:0]       pc_rdata;
    logic [XLEN-1:0]       pc_wdata;
    rvfi_mem_t             mem;
  } rvfi_t;

  // ---------------------------------------------------------------------------
  // CSR file
  // ---------------------------------------------------------------------------

  // Interrupt inputs (INTERFACES.md I7).  CLINT drives the timer and software
  // lines, the PLIC the external one.
  typedef struct packed {
    logic                  m_timer;
    logic                  m_soft;
    logic                  m_ext;
  } irq_t;

  // mcause interrupt codes
  parameter logic [5:0] IRQ_M_SOFT  = 6'd3;
  parameter logic [5:0] IRQ_M_TIMER = 6'd7;
  parameter logic [5:0] IRQ_M_EXT   = 6'd11;

  // Counter-event selectors for mhpmevent3-15 (SPEC 12).  Event 0 is "never",
  // so a counter with an unwritten selector does not count.
  parameter int unsigned HPM_N      = 13;    // mhpmcounter3 .. mhpmcounter15
  parameter int unsigned PERF_N     = 8;     // event lines the core exports

  parameter logic [5:0] EV_NONE           = 6'd0;
  parameter logic [5:0] EV_BR_TAKEN       = 6'd1;
  parameter logic [5:0] EV_BR_MISPREDICT  = 6'd2;
  parameter logic [5:0] EV_LOAD_RETIRED   = 6'd3;
  parameter logic [5:0] EV_STORE_RETIRED  = 6'd4;
  parameter logic [5:0] EV_SB_FULL        = 6'd5;
  parameter logic [5:0] EV_MULDIV_STALL   = 6'd6;   // EX held by MUL or DIV
  parameter logic [5:0] EV_LOAD_USE       = 6'd7;   // load-use interlock
  parameter logic [5:0] EV_HAZARD_STALL  = 6'd8;

  // CSR addresses the core implements.  Grouped as SPEC 10.2's three classes.
  parameter logic [11:0] CSR_MVENDORID    = 12'hF11;
  parameter logic [11:0] CSR_MARCHID      = 12'hF12;
  parameter logic [11:0] CSR_MIMPID       = 12'hF13;
  parameter logic [11:0] CSR_MHARTID      = 12'hF14;

  parameter logic [11:0] CSR_MSTATUS      = 12'h300;
  parameter logic [11:0] CSR_MISA         = 12'h301;
  parameter logic [11:0] CSR_MEDELEG      = 12'h302;
  parameter logic [11:0] CSR_MIDELEG      = 12'h303;
  parameter logic [11:0] CSR_MIE          = 12'h304;
  parameter logic [11:0] CSR_MTVEC        = 12'h305;
  parameter logic [11:0] CSR_MCOUNTEREN   = 12'h306;
  parameter logic [11:0] CSR_MCOUNTINHIBIT= 12'h320;
  parameter logic [11:0] CSR_MSCRATCH     = 12'h340;
  parameter logic [11:0] CSR_MEPC         = 12'h341;
  parameter logic [11:0] CSR_MCAUSE       = 12'h342;
  parameter logic [11:0] CSR_MTVAL        = 12'h343;
  parameter logic [11:0] CSR_MIP          = 12'h344;

  parameter logic [11:0] CSR_SATP         = 12'h180;   // writable, translation bypassed

  parameter logic [11:0] CSR_PMPCFG0      = 12'h3A0;   // RV64: even indices only
  parameter logic [11:0] CSR_PMPADDR0     = 12'h3B0;

  parameter logic [11:0] CSR_MCYCLE       = 12'hB00;
  parameter logic [11:0] CSR_MINSTRET     = 12'hB02;
  parameter logic [11:0] CSR_MHPMCOUNTER3 = 12'hB03;
  parameter logic [11:0] CSR_MHPMEVENT3   = 12'h323;

  parameter logic [11:0] CSR_CYCLE        = 12'hC00;   // U-mode read-only shadows
  parameter logic [11:0] CSR_INSTRET      = 12'hC02;

  // misa: RV64 IMAC + Zicsr/Zifencei (no separate bit).  S is 0 until
  // translation works -- SCOPE_CONTRACT.md section 4.
  parameter logic [XLEN-1:0] MISA_VALUE =
      {2'b10, 36'b0, 26'b00_0000_0000_0001_0001_0000_0101};   // MXL=64: A(0) C(2) I(8) M(12)


endpackage

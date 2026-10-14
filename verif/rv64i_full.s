# Copyright 2026 Maktab-e-Digital Systems Lahore.
# SPDX-License-Identifier: Apache-2.0
#
# rv64i_full.s -- every RV64I instruction, through the whole pipeline.
#
# All 52 RV64I instructions (RV32I's 40 plus RV64I's 12), each with the corner
# cases that break real implementations, and arranged so the pipeline sees
# every hazard class the core has a mechanism for: EX/MEM forwarding, the
# register-file write bypass, load-use, store-buffer forwarding, mispredicts in
# both directions, traps, xRET and a privilege change.
#
# Nothing here states an expected value.  gen.py runs this program on spike and
# the testbench compares the core against spike's commit log, so a comment
# below saying "-> 1" is a note for the reader, not an assertion anyone checks.
#
# Zicsr is used only to install a trap handler, open PMP for U-mode (spike
# enforces PMP; the core's checker is external and tied permissive in the
# testbench) and observe mcause/mepc/mtval/minstret.  It is test plumbing.
#
# Rules this program keeps, because the checker depends on them:
#   - no register is read before this program writes it (spike's boot ROM
#     leaves values in a0/a1/t0 that the core's reset does not);
#   - no misaligned access (the core and spike are allowed to differ there);
#   - the program ends by writing tohost, then spinning at `spin`.

	.option norelax
	.section .text
	.globl _start
_start:
	# ---- trap handler, PMP open for U-mode, minstret from zero --------------
	la     t0, trap_handler
	csrw   mtvec, t0
	li     t0, -1
	csrw   pmpaddr0, t0
	li     t0, 0x1f                # NAPOT, R W X
	csrw   pmpcfg0, t0
	csrw   minstret, zero

	# ---- constants used throughout ------------------------------------------
	li     s2, 0x8000000000000000  # INT64_MIN
	li     s3, 0x7fffffffffffffff  # INT64_MAX
	li     s4, 0x123456789abcdef0  # low word has bit 31 set
	li     s5, 0xffffffff00000001
	addi   s6, x0, 1
	addi   s7, x0, -1

	# ---- OP-IMM ---------------------------------------------------------------
	addi   a0, x0, 2047            # largest positive imm
	addi   a1, x0, -2048           # most negative imm
	addi   a2, a1, 2047            # -1, back-to-back on a1 (EX/MEM forward)
	addi   a3, a2, 1               # 0
	addi   a4, s3, 1               # wraps to INT64_MIN
	addi   x0, a0, 5               # write to x0 is discarded
	slti   a5, a1, -2047           # -2048 < -2047 -> 1
	slti   a6, a2, -1              # equal -> 0
	slti   a7, s2, 0               # INT64_MIN < 0 -> 1
	slti   t0, s3, -1              # 0
	sltiu  t1, a2, -1              # all-ones < all-ones -> 0
	sltiu  t2, a3, 1               # seqz -> 1
	sltiu  t3, a0, -2048           # imm sign-extends, compares unsigned -> 1
	sltiu  t4, s7, 0               # 0
	xori   t5, a1, -1              # not
	xori   t6, s4, 0x555
	ori    a0, a1, 0x7ff           # -1
	ori    a3, s2, 1
	andi   a4, s7, -16             # imm sign-extends
	andi   a5, s4, 0x0f0
	andi   a6, s4, 0
	slli   a7, s4, 0
	slli   t0, s6, 63              # shamt bit 5 is a real bit on RV64
	slli   t1, s4, 32
	slli   t2, s4, 1
	srli   t3, s2, 63
	srli   t4, s7, 1
	srli   t5, s4, 32
	srli   t6, s4, 0
	srai   a0, s2, 63              # -1
	srai   a1, s2, 1
	srai   a2, s4, 4
	srai   a3, s3, 62

	# ---- OP -------------------------------------------------------------------
	add    a0, s3, s6              # signed overflow wraps
	add    a1, s2, s2              # 0
	add    a2, s7, s6
	sub    a3, s2, s6              # INT64_MIN - 1 = INT64_MAX
	sub    a4, x0, s2              # -INT64_MIN = INT64_MIN
	sub    a5, s4, s4
	addi   t0, x0, 67              # shift amounts use rs2[5:0] only
	sll    a6, s4, t0              # << 3
	srl    a7, s2, t0
	sra    t1, s2, t0
	addi   t2, x0, 63
	sll    t3, s6, t2
	srl    t4, s7, t2              # 1
	sra    t5, s7, t2              # -1
	sll    t6, s4, x0              # shift by zero
	slt    a0, s2, s3              # 1
	slt    a1, s3, s2              # 0
	slt    a2, s7, s7              # 0
	sltu   a3, s2, s3              # 0
	sltu   a4, s3, s2              # 1
	sltu   a5, x0, s7              # snez -> 1
	xor    a6, s4, s7
	xor    a7, s4, s4
	or     t0, s2, s6
	or     t1, s4, x0
	and    t2, s4, s5
	and    t3, s4, s7

	# ---- LUI / AUIPC ----------------------------------------------------------
	lui    a0, 0x80000             # bit 31 set: sign-extends on RV64
	lui    a1, 0xfffff
	lui    a2, 0x7ffff
	lui    a3, 0
	auipc  a4, 0
	auipc  a5, 0xfffff             # pc - 4096
	auipc  a6, 0x80000             # pc - 2^31
	auipc  a7, 0x7ffff
	addi   t0, a4, 1               # consumer of auipc, back to back

	# ---- RV64 word forms ------------------------------------------------------
	li     t0, 0x7fffffff
	addiw  a0, t0, 1               # 32-bit overflow -> 0xffffffff80000000
	addiw  a1, s4, 0               # sext.w of a word with bit 31 set
	addiw  a2, t0, -2048
	addiw  a3, s5, -1              # upper half ignored -> 0
	slliw  a4, t0, 31
	slliw  a5, s4, 0
	slliw  a6, s6, 31              # result bit 31 set -> negative
	srliw  a7, s4, 31              # shifts in zeros at bit 31 -> 1
	srliw  t1, s4, 0               # by zero still sign-extends the word
	srliw  t2, s7, 1               # 0x7fffffff, not 0x7fff...ffff
	sraiw  t3, s4, 31              # -1
	sraiw  t4, s4, 4
	sraiw  t5, t0, 0
	addw   t6, t0, s6              # 32-bit overflow
	addw   a0, s5, s5              # upper halves ignored
	subw   a1, x0, t0
	subw   a2, s2, s6              # low words 0 - 1 -> -1
	addi   s8, x0, 35              # rs2 bit 5 set: W shifts use rs2[4:0]
	sllw   a3, s4, s8              # << 3
	sllw   a4, s6, s7              # << 31 -> negative
	srlw   a5, s4, s8
	srlw   a6, s4, x0
	srlw   a7, s7, s7              # 0xffffffff >> 31 = 1
	sraw   t1, s4, s8
	sraw   t2, s4, s7              # -1
	sraw   t3, s3, s6              # low word all ones, arithmetic -> -1

	# ---- loads: every width, sign and zero extension, +/- offsets ---------------
	la     s0, data
	lb     a0, 0(s0)
	lb     a1, 7(s0)               # 0x88 -> negative
	lbu    a2, 7(s0)
	lh     a3, 6(s0)               # 0x8877 -> negative
	lhu    a4, 6(s0)
	lh     a5, 2(s0)
	lw     a6, 4(s0)               # 0x88776655 -> negative
	lwu    a7, 4(s0)
	lw     t0, 0(s0)
	ld     t1, 0(s0)
	ld     t2, 8(s0)
	lw     t3, 16(s0)              # 0xffffffff -> -1
	lwu    t4, 16(s0)
	lhu    t5, 18(s0)
	lbu    t6, 23(s0)
	lb     x0, 0(s0)               # load to x0: accessed, not written
	addi   s1, s0, 48
	ld     a0, -8(s1)              # negative offset
	lw     a1, -12(s1)
	lh     a2, -14(s1)
	lb     a3, -16(s1)

	# ---- stores, read straight back: store-buffer forwarding ------------------
	la     s1, scratch
	sd     s4, 0(s1)
	sw     s4, 8(s1)
	sh     s4, 12(s1)
	sb     s4, 14(s1)
	sb     s7, 15(s1)
	ld     a0, 0(s1)               # whole doubleword from one pending store
	ld     a1, 8(s1)               # assembled from four pending stores
	lbu    a2, 15(s1)
	lhu    a3, 12(s1)
	lw     a4, 8(s1)
	sd     s3, 16(s1)
	sb     x0, 17(s1)              # younger byte must win
	sh     s7, 20(s1)
	ld     a5, 16(s1)
	lw     a6, 20(s1)
	# partial forward: two bytes from the buffer, the rest from memory
	sb     s6, 1(s0)
	sh     x0, 4(s0)
	ld     a7, 0(s0)
	lwu    t0, 4(s0)
	# different address: no forwarding, load goes to memory
	sd     s5, 24(s1)
	ld     t1, 8(s0)
	# more stores than store-buffer entries, back to back
	sd     s2, 32(s1)
	sd     s3, 40(s1)
	sw     s5, 48(s1)
	sw     s4, 52(s1)
	sh     s4, 56(s1)
	sh     s5, 58(s1)
	sb     s4, 60(s1)
	sb     s5, 61(s1)
	sb     s7, 62(s1)
	sb     s6, 63(s1)
	fence                          # drain: everything below reads memory
	ld     t2, 0(s1)
	ld     t3, 8(s1)
	ld     t4, 16(s1)
	ld     t5, 24(s1)
	ld     t6, 32(s1)
	ld     a0, 40(s1)
	ld     a1, 48(s1)
	ld     a2, 56(s1)
	ld     a3, 0(s0)

	# ---- hazards through memory ----------------------------------------------
	addi   t0, x0, 0x5a
	sb     t0, 64(s1)              # store data forwarded from EX/MEM
	addi   t1, s1, 64
	lbu    t2, 0(t1)               # address forwarded from EX/MEM
	ld     t3, 8(s0)
	addi   t4, t3, 1               # load-use, distance 1
	ld     t5, 8(s0)
	nop
	addi   t6, t5, 1               # load-use, distance 2
	ld     a0, 8(s0)
	nop
	nop
	addi   a1, a0, 1               # distance 3: register-file write bypass
	sd     s0, 72(s1)              # store a pointer ...
	ld     a2, 72(s1)              # ... load it back ...
	ld     a3, 16(a2)              # ... and use it as an address (load-use)
	ld     a4, 0(s0)
	sd     a4, 80(s1)              # load-use into store data
	ld     a5, 80(s1)
	lw     a6, 80(s1)
	sw     a6, 88(s1)
	lw     a7, 88(s1)
	ld     a0, 8(s0)
	ld     a0, 16(s0)              # WAW on a load
	addi   a1, a0, 0
	ld     t0, 0(s0)
	addi   t1, x0, 1               # independent: load still in flight
	beq    t1, t1, 1f              # mispredicted branch behind a load
	addi   t2, x0, 99              # skipped
1:	ld     t3, 0(s0)
	bne    t3, t1, 2f              # load-use into a branch, taken
	addi   t4, x0, 99              # skipped
2:	la     t0, 3f
	sd     t0, 112(s1)             # a code pointer in memory ...
	ld     t5, 112(s1)
	jalr   t6, 0(t5)               # ... loaded and used at once by jalr
	addi   t4, x0, 98              # skipped
3:	nop

	# ---- branches: each condition, taken / not taken, forward / backward --------
	# BTFN predicts backward taken, forward not taken, so each loop below
	# exercises a correct prediction and a mispredict in both directions.
	addi   t0, x0, 7
	addi   t1, x0, -7
	beq    t0, t0, 1f              # forward taken: mispredict
	addi   a0, x0, 1               # skipped
1:	beq    t0, t1, 1f              # forward not taken: predicted
	addi   a0, x0, 2
1:	bne    t0, t1, 1f
	addi   a1, x0, 1               # skipped
1:	bne    t0, t0, 1f
	addi   a1, x0, 2
1:	blt    t1, t0, 1f              # -7 < 7
	addi   a2, x0, 1               # skipped
1:	blt    t0, t1, 1f
	addi   a2, x0, 2
1:	blt    t0, t0, 1f              # equal: not taken
	addi   a2, x0, 3
1:	bge    t0, t1, 1f
	addi   a3, x0, 1               # skipped
1:	bge    t0, t0, 1f              # equal: taken
	addi   a3, x0, 2               # skipped
1:	bge    t1, t0, 1f
	addi   a3, x0, 3
1:	bltu   t0, t1, 1f              # 7 <u 0xff..f9
	addi   a4, x0, 1               # skipped
1:	bltu   t1, t0, 1f
	addi   a4, x0, 2
1:	bgeu   t1, t0, 1f
	addi   a5, x0, 1               # skipped
1:	bgeu   t0, t1, 1f
	addi   a5, x0, 2
1:	bgeu   x0, x0, 1f              # equal: taken
	addi   a5, x0, 3               # skipped
1:	blt    s2, s3, 1f              # INT64_MIN < INT64_MAX
	addi   a6, x0, 1               # skipped
1:	bltu   s3, s2, 1f
	addi   a6, x0, 2               # skipped
1:
	# backward loops: taken (predicted) until the exit (mispredicted)
	addi   a0, x0, 0
	addi   a1, x0, 3
1:	addi   a0, a0, 1
	blt    a0, a1, 1b
	addi   a0, x0, 3
1:	addi   a0, a0, -1
	bne    a0, x0, 1b
1:	addi   a0, a0, 1
	beq    a0, s6, 1b              # taken once, then falls through
	addi   a0, x0, 2
1:	addi   a0, a0, -1
	bge    a0, x0, 1b
	addi   a0, x0, 0
1:	addi   a0, a0, 1
	bltu   a0, a1, 1b
	addi   a0, x0, 3
1:	addi   a0, a0, -1
	bgeu   a0, s6, 1b
	# a branch whose condition is produced the cycle before (EX/MEM forward)
	addi   a2, x0, 5
	addi   a3, a2, -5
	beq    a3, x0, 1f
	addi   a4, x0, 1               # skipped
1:	nop

	# ---- JAL / JALR ------------------------------------------------------------
	jal    ra, func_fwd            # forward call
	addi   s8, a0, 0
	j      1f
func_back:
	addi   a0, a0, 7
	jalr   x0, 0(ra)               # return
1:	jal    ra, func_back           # backward call: predicted taken
	addi   s9, a0, 0
	la     t0, func_fwd+1          # odd target: jalr clears bit 0
	jalr   ra, 0(t0)
	la     t0, func_fwd+8
	jalr   ra, -8(t0)              # negative offset
	la     t0, 1f
	jalr   t0, 0(t0)               # rd == rs1: link overwrites the base
1:	addi   s10, t0, 0
	jal    x0, 1f                  # j: no link
	addi   s10, x0, 99             # skipped
1:	auipc  t1, 0
	jalr   x0, 12(t1)              # computed forward jump, no link
	addi   s10, x0, 98             # skipped
	addi   s11, x0, 42

	# ---- FENCE ------------------------------------------------------------------
	sd     s4, 96(s1)
	fence  rw, rw
	ld     t2, 96(s1)
	fence  w, r
	fence.tso
	fence  i, o

	# ---- ECALL / EBREAK in M-mode -------------------------------------------------
	csrr   s8, minstret            # retired so far
	ecall
	csrr   s9, minstret            # a trapped instruction does not retire
	ebreak
	csrr   s10, minstret

	# ---- U-mode: run RV64I there, then ECALL back to M -----------------------------
	la     t0, user_code
	csrw   mepc, t0
	li     t0, 0x1800
	csrc   mstatus, t0             # MPP = U
	mret
user_code:
	addi   a0, x0, 11
	slli   a1, a0, 4
	sd     a1, 104(s1)
	ld     a2, 104(s1)
	lw     a3, 4(s0)
	beq    a1, a2, 1f
	addi   a4, x0, 1               # skipped
1:	jal    ra, func_fwd
	ecall                          # from U: mcause 8, handler returns to M
	# back in M-mode
	addi   a5, a0, 1
	ebreak
	csrr   s11, minstret

	# ---- done: tell the host, then spin -------------------------------------------
	li     t0, 1
	la     t1, tohost
	sd     t0, 0(t1)
	.globl spin
spin:	beq    x0, x0, spin

	# ---- subroutines -----------------------------------------------------------------
func_fwd:
	addi   a0, a0, 3
	ret

	# ---- trap handler ----------------------------------------------------------------
	# Records the cause, the faulting pc and mtval, steps over the instruction,
	# and returns to M if the trap came from U.
	.balign 4
trap_handler:
	csrr   s5, mcause
	csrr   s6, mepc
	csrr   s7, mtval
	addi   s6, s6, 4
	csrw   mepc, s6
	addi   gp, x0, 8               # mcause for an ECALL from U
	bne    s5, gp, 1f
	li     gp, 0x1800
	csrs   mstatus, gp             # MPP = M: return to M
1:	mret

	.section .data
	.balign 64
data:
	.dword 0x8877665544332211
	.dword 0xfedcba9876543210
	.dword 0x01020304ffffffff
	.dword 0x7fffffffffffffff
	.dword 0x8000000000000000
	.dword 0xdeadbeefcafebabe
	.balign 64
scratch:
	.zero  128
	.balign 8
	.globl tohost
tohost:   .dword 0
	.globl fromhost
fromhost: .dword 0

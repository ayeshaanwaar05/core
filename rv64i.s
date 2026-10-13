# Every RV64I instruction except loads, stores, ecall and ebreak.
# Assembled by riscv64-unknown-elf-as; expectations come from spike.
	.section .text
	.globl _start
_start:
	# ---- OP-IMM ------------------------------------------------------------
	addi   x1,  x0,  5
	addi   x2,  x0,  -3
	slti   x3,  x2,  0              # -3 < 0  -> 1
	slti   x4,  x1,  0              #  5 < 0  -> 0
	sltiu  x5,  x2,  1              # huge u  -> 0
	sltiu  x6,  x1,  9              #  5 < 9  -> 1
	xori   x7,  x1,  -1             # ~5
	ori    x8,  x1,  8
	andi   x9,  x2,  7
	slli   x10, x1,  20
	srli   x11, x10, 8
	srai   x12, x2,  1              # -3 >> 1 -> -2
	# ---- OP ----------------------------------------------------------------
	add    x13, x1,  x2
	sub    x14, x1,  x2
	sll    x15, x1,  x9
	slt    x16, x2,  x1
	sltu   x17, x2,  x1
	xor    x18, x1,  x2
	srl    x19, x10, x1
	sra    x20, x2,  x1
	or     x21, x1,  x2
	and    x22, x1,  x9
	# ---- LUI / AUIPC -------------------------------------------------------
	lui    x23, 0xABCDE
	auipc  x24, 0x1
	# ---- RV64 32-bit forms -------------------------------------------------
	addiw  x25, x1,  -7             # sign-extends from bit 31
	lui    x26, 0x80000             # 0x80000000, bit 31 set
	addiw  x27, x26, 0              # -> 0xffffffff80000000
	slliw  x28, x1,  30             # 5<<30 in 32 bits, sign-extended
	srliw  x29, x26, 4
	sraiw  x30, x26, 4
	addw   x31, x26, x1
	subw   x1,  x26, x1
	sllw   x2,  x1,  x1
	srlw   x3,  x26, x1
	sraw   x4,  x26, x1
	# ---- branches: each condition, taken and not taken --------------------
	addi   x5,  x0,  7
	addi   x6,  x0,  -7
	beq    x5,  x5,  1f
	addi   x7,  x0,  111            # skipped
1:	bne    x5,  x5,  2f             # not taken
	blt    x6,  x5,  2f             # -7 < 7 taken
	addi   x8,  x0,  222            # skipped
2:	bge    x5,  x6,  3f             # 7 >= -7 taken
	addi   x9,  x0,  333            # skipped
3:	bltu   x5,  x6,  4f             # 7 <u huge taken
	addi   x10, x0,  444            # skipped
4:	bgeu   x6,  x5,  5f             # huge >=u 7 taken
	addi   x11, x0,  555            # skipped
5:	blt    x5,  x6,  6f             # not taken
	bge    x6,  x5,  6f             # not taken
	bltu   x6,  x5,  6f             # not taken
	bgeu   x5,  x6,  6f             # not taken
6:	addi   x12, x0,  9
	# ---- JAL / JALR --------------------------------------------------------
	jal    x13, 7f
	addi   x14, x0,  666            # skipped
7:	auipc  x15, 0
	addi   x15, x15, 16             # address of label 8
	jalr   x16, 0(x15)
	addi   x17, x0,  777            # skipped
8:	addi   x18, x0,  21
	# ---- FENCE -------------------------------------------------------------
	fence
	addi   x19, x0,  99
9:	beq    x0,  x0,  9b             # spin

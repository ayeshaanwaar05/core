# The sequence as given, with one addition: x3 holds a base pointing at valid
# memory, because 0x20 absolute is not mappable (spike has a bootrom there, and
# no real memory map puts DRAM at 0).  The offset stays 0x20.
	.section .text
	.globl _start
_start:
	auipc x3, 0x1             # data base = pc + 0x1000 (lui would sign-extend)
	addi x1, x0, 6
	addi x2, x0, 2
	add  x4, x1, x2           # RAW on x1 and x2
	sw   x4, 0x20(x3)         # RAW on x4
	lw   x9, 0x20(x3)         # reads back what the store wrote
	add  x5, x9, x2           # LOAD-USE on x9
	add  x11, x1, x2
	beq  x4, x11, label       # 8 == 8, taken
	addi x9, x0, 2            # skipped
	addi x4, x0, 16           # skipped
label:	or   x2, x9, x4
	# A load from an address nothing has written: the store buffer cannot
	# forward it, so this one must go to the bus and read zero.
	lw   x6, 0x40(x3)
	add  x7, x6, x1           # load-use on a bus read
spin:	beq  x0, x0, spin

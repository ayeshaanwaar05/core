# Copyright 2026 Maktab-e-Digital Systems Lahore.
# SPDX-License-Identifier: Apache-2.0
#
# crt0.s -- start-up for the C test programs (sort.c).
#
# Sets the stack, calls main(), and reports main's return value through tohost
# the riscv-tests way: (code << 1) | 1, so 1 means pass and spike exits with
# main's return value.  Then spins at `spin`, which is where the testbench
# expects every program to end.

	.option norelax
	.section .text
	.globl _start
_start:
	la     sp, stack_top
	call   main
	slli   a0, a0, 1
	ori    a0, a0, 1
	la     t0, tohost
	sd     a0, 0(t0)
	.globl spin
spin:	beq    x0, x0, spin

	.section .data
	.balign 8
	.globl tohost
tohost:   .dword 0
	.globl fromhost
fromhost: .dword 0

	.section .bss
	.balign 16
	.space 4096
stack_top:

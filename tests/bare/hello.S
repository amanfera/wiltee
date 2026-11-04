# Bare-metal smoke test, entered in S-mode at physical 0 with the MMU off.
# Prints through the UART and the SBI console, checks a few M-extension
# results and an S-mode trap round trip, then powers off through SBI SRST.
	.text
	.globl _start
_start:
	li	s0, 0xF4000000
	la	a1, msg
1:	lbu	a0, 0(a1)
	beqz	a0, 2f
	sb	a0, 0(s0)
	addi	a1, a1, 1
	j	1b
2:	li	a7, 1			# legacy console putchar
	li	a0, 'S'
	ecall
	li	a0, '\n'
	ecall
	li	a0, 7
	li	a1, -6
	mul	a2, a0, a1
	li	a3, -42
	bne	a2, a3, fail
	mulh	a2, a1, a1		# hi(36) = 0
	bnez	a2, fail
	li	a0, 0x80000000
	li	a1, -1
	div	a2, a0, a1		# overflow: stays 0x80000000
	bne	a2, a0, fail
	rem	a2, a0, a1
	bnez	a2, fail
	divu	a2, a0, zero		# by zero: all ones
	li	a3, -1
	bne	a2, a3, fail
	li	a0, 0x12345678
	li	a1, 0x9abcdef0
	mulhu	a2, a0, a1
	li	a3, 0x0b00ea4e
	bne	a2, a3, fail
	la	t0, handler		# trap round trip: ebreak -> handler -> sret
	csrw	stvec, t0
	li	s1, 0
	ebreak
	li	t1, 1
	bne	s1, t1, fail
	la	a1, okmsg
3:	lbu	a0, 0(a1)
	beqz	a0, 4f
	sb	a0, 0(s0)
	addi	a1, a1, 1
	j	3b
4:	li	a7, 0x53525354		# SRST: shutdown
	li	a6, 0
	li	a0, 0
	li	a1, 0
	ecall
5:	j	5b

fail:	la	a1, failmsg
6:	lbu	a0, 0(a1)
	beqz	a0, 4b
	sb	a0, 0(s0)
	addi	a1, a1, 1
	j	6b

	.align 2
handler:
	csrr	t0, scause
	li	t1, 3
	bne	t0, t1, fail
	addi	s1, s1, 1
	csrr	t0, sepc
	addi	t0, t0, 4
	csrw	sepc, t0
	sret

	.data
msg:	.asciz "hello from wiltee (UART)\n"
okmsg:	.asciz "PASS\n"
failmsg: .asciz "FAIL\n"

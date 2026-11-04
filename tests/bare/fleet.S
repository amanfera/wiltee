# Fleet workload: each machine starts with a0 = its id, runs 4M rounds of an
# LCG seeded by it, prints "vm <id> <result>" in hex and powers off.
	.text
	.globl _start
_start:
	mv	s2, a0
	mv	t1, a0
	li	t0, 4000000
	li	t2, 1664525
	li	t3, 1013904223
1:	mul	t1, t1, t2
	add	t1, t1, t3
	addi	t0, t0, -1
	bnez	t0, 1b
	li	s0, 0xF4000000
	li	a0, 'v'
	sb	a0, 0(s0)
	li	a0, 'm'
	sb	a0, 0(s0)
	li	a0, ' '
	sb	a0, 0(s0)
	mv	a1, s2
	jal	hex
	li	a0, ' '
	sb	a0, 0(s0)
	mv	a1, t1
	jal	hex
	li	a0, '\n'
	sb	a0, 0(s0)
	li	a7, 0x53525354
	li	a6, 0
	li	a0, 0
	li	a1, 0
	ecall
2:	j	2b

hex:	li	t4, 28
3:	srl	a0, a1, t4
	andi	a0, a0, 15
	addi	a0, a0, '0'
	li	t5, '9'
	ble	a0, t5, 4f
	addi	a0, a0, 39
4:	sb	a0, 0(s0)
	addi	t4, t4, -4
	bgez	t4, 3b
	ret

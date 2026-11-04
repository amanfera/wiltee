// A riscv-tests environment for wiltee: the test starts in S-mode at
// physical 0 with the MMU off (where wiltee resets a hart), reports through
// the UART and powers off through SBI SRST. There is no M-mode to set up.
#ifndef WILTEE_RISCV_TEST_H
#define WILTEE_RISCV_TEST_H

#define RVTEST_RV32U .macro init; .endm
#define RVTEST_RV64U RVTEST_RV32U
#define TESTNUM gp

#define RVTEST_CODE_BEGIN \
	.text; .align 6; .globl _start; _start: init;

#define RVTEST_CODE_END unimp

#define WILTEE_PUTS(label) \
	li t5, 0xF4000000; la t6, label; \
8001:	lbu t4, 0(t6); beqz t4, 8002f; sb t4, 0(t5); addi t6, t6, 1; j 8001b; 8002:

// Prints the failing test number in hex, then "\n".
#define WILTEE_PUTHEX(reg) \
	li t5, 0xF4000000; li t3, 28; \
8003:	srl t4, reg, t3; andi t4, t4, 15; addi t4, t4, '0'; li t6, '9'; \
	ble t4, t6, 8004f; addi t4, t4, 39; 8004: sb t4, 0(t5); addi t3, t3, -4; \
	bgez t3, 8003b; li t4, '\n'; sb t4, 0(t5);

#define WILTEE_OFF \
	li a7, 0x53525354; li a6, 0; li a0, 0; li a1, 0; ecall; 8005: j 8005b;

#define RVTEST_PASS fence; WILTEE_PUTS(wiltee_pass) WILTEE_OFF
#define RVTEST_FAIL fence; WILTEE_PUTS(wiltee_fail) WILTEE_PUTHEX(TESTNUM) WILTEE_OFF

#define RVTEST_DATA_BEGIN \
	.data; wiltee_pass: .asciz "PASS\n"; wiltee_fail: .asciz "FAIL "; \
	.align 4; .global begin_signature; begin_signature:
#define RVTEST_DATA_END .align 4; .global end_signature; end_signature:

#endif

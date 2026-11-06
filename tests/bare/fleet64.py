#!/usr/bin/env python3
"""Expected output of tests/bare/fleet64.S for machines 0..n-1 (1M rounds of
x = x*A + C mod 2^64 from x = id), via the closed-form jump of the LCG."""
import sys
A, C, M, ROUNDS = 6364136223846793005, 1442695040888963407, (1 << 64) - 1, 1000000

def jump(n):
    ra, rc, a, c = 1, 0, A, C           # result map x -> ra*x + rc; step map
    while n:
        if n & 1:
            ra, rc = (a * ra) & M, (a * rc + c) & M
        a, c = (a * a) & M, (a * c + c) & M
        n >>= 1
    return ra, rc

ja, jc = jump(ROUNDS)
for i in range(int(sys.argv[1])):
    print("vm %016x %016x" % (i, (ja * i + jc) & M))

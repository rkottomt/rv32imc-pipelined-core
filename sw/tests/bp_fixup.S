# bp_fixup.S - directed test for the fetch aligner's prediction-repair path.
#
# Written after code coverage showed the "fixup" logic in rv_frontend.v was
# never exercised by riscv-tests or random programs. Each case trains the
# BTB, then makes the trained entry stale so the prediction points at a
# halfword that is no longer an instruction boundary:
#
#  1. Self-modifying code: a 16-bit jump at word+2 (trained, off=1)
#     is overwritten, together with the 16-bit instruction before it, by one
#     32-bit instruction at word+0  -> "32-bit instruction covers the
#     predicted slot" mismatch.
#  2. A 32-bit jump straddling two words is trained (BTB entry keyed
#     by the word where it ends, "xe"); then the branch is overwritten with
#     16-bit NOPs, so the second word reaches the aligner head carrying an
#     "xe" prediction with no straddling instruction to own it.
#
# The program checks its own results and reports via the SIM controller.
    .section .text.init
    .globl _start
    .option norvc
_start:
    la    sp, __stack_top
    li    s0, 0                 # error count

    # ---------------- case 1: self-modifying code -------------------------
    li    s1, 20                # iterations to train the predictor
1:  call  smc_target
    addi  s1, s1, -1
    bnez  s1, 1b
    # rewrite smc_target's first word with a 32-bit "addi a0, a0, 100"
    la    t0, smc_target
    li    t1, 0x06450513        # addi a0, a0, 100
    sw    t1, 0(t0)
    fence.i
    li    a0, 0
    call  smc_target            # now: a0 = 0 + 100, then falls into "ret" path
    li    t2, 100
    beq   a0, t2, 2f
    addi  s0, s0, 1
2:
    # ---------------- case 2: stale "xe" (straddling) prediction
    li    s1, 20
    li    a1, 0
3:  call  straddle_loop         # trains the straddling taken branch
    addi  s1, s1, -1
    bnez  s1, 3b
    # replace the 32-bit branch at word+2 with two 16-bit c.nop
    la    t0, straddle_loop
    li    t1, 0x0001
    sh    t1, 2(t0)
    sh    t1, 4(t0)
    fence.i
    li    a1, 0
    call  straddle_loop         # now falls through: a1 = 3 + 4
    li    t2, 7
    beq   a1, t2, 4f
    addi  s0, s0, 1
4:
    # ---------------- report ----------------------------------------------
    li    t0, 0x10002000
    li    t1, 1
    beqz  s0, 5f
    slli  t1, s0, 1
    ori   t1, t1, 1
5:  sw    t1, 0(t0)
6:  j     6b

    # smc_target: word 0 = [c.li a0,1 | c.j skip]. Unconditional jumps are
    # predicted on every BTB hit (no dependence on gshare history), which
    # makes the stale-prediction scenario deterministic.
    .align 4
smc_target:
    .option rvc
    c.li   a0, 1
    c.j    smc_skip
    .option norvc
    ret
smc_skip:
    ret

    # straddle_loop: a 32-bit taken branch placed at word+2
    .align 4
straddle_loop:
    .option rvc
    c.nop                       # word+0
    .option norvc
    jal   x0, sl_tail           # word+2..+5: 32-bit jump, straddles two words
sl_mid:                         # word+6 (second word, halfword 1)
    addi  a1, a1, 3
sl_tail:
    addi  a1, a1, 4
    ret

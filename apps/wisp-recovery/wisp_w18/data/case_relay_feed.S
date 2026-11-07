@ SPDX-License-Identifier: MIT
@ The case relay's YHM4005 feed (docs/wisp/recovery.md, "The relay feeds the case watchdog").
@
@ The G2 case (STM32G0B1, case app 1.2.57) has a YHM4005 external watchdog. The case app arms
@ it at boot with a 20 s timeout and "any falling edge on its ACMD pin feeds it" (4005 reg 4 =
@ 0x07, reg 5 = 0x3B), and feeds it every 5 s with a low pulse on PB2. The ROM loader and
@ drdaeman's SRAM relay never did, so the case reset about 20 s into every relay session.
@
@ This code is appended to the relay at 0x20011584 (relay offset 0x1584, right after the
@ relocated waveform stubs; free up to the G2RQ buffer at 0x20011900). image.build_relay()
@ points six places of the relay at it (wisp_w18/relay_feed.py):
@
@   0x20010032  bl 0x200103e8      -> bl feed_start      (relay start: set up, first feed)
@   0x2001031c  ldr/movs (2 x 16)  -> bl poll_bridge_rx  (bridge: wait for a host byte)
@   0x2001074c  ldr/movs           -> bl poll_beacon     (relay: wait for the temple's HELO)
@   0x200108b2  movs/cmp           -> bl poll_temple_rx  (relay: wait for a temple frame,
@                                                         also the empty-G2TX poll bound)
@   0x200109bc  ldr/lsls           -> bl poll_host_rx    (relay: wait for a host byte)
@   0x20010232  bl 0x20010624      -> bl fed_delay       (exit: the 25 ms wait before the reset)
@
@ Each poll_* runs the two instructions it displaced, flags included, after one cheap check:
@ TIM6's update flag. Nothing here calls into the case flash, and nothing waits with a UART
@ busy: a feed pulse is started and ended by later polls, never by a busy wait.
@
@ Time base: TIM6, a basic timer the case app never uses, at 64 MHz / 6400 = 10 kHz. The case
@ clock is the app's own (SystemClock_Config 0x08008438, called by the bridge at start: HSI16
@ x 8 / 2 = 64 MHz, AHB and APB /1). The flag is sticky, so a stretch without polls delays a
@ feed but never loses one; interrupts stay masked throughout.
@
@ Pulse shape, as the app's feed (0x0800A270): PB2 push-pull, no pull, idle high, low for a
@ while, high again. The app holds it low for 14,000 turns of its delay loop, about 1.1-2 ms at
@ 64 MHz; this holds it at least 4.5 ms (the datasheet gives no minimum; any falling edge feeds).
@ The first pulse, at relay start, is a busy 4.5 ms; later ones end at the first poll after
@ 4.5 ms, so a stretch without polls (at most ~0.1 s: the temple reset waveform) lengthens one.
@ One falling edge every 2.0045 s plus the time to the next poll; the 4005 needs one every 18 s
@ (20 s -10 %).
@
@ Reproduce case_relay_feed.bin (binutils 2.46, arm-none-eabi):
@   as -mcpu=cortex-m0plus -mthumb -o feed.o case_relay_feed.S
@   ld -Ttext=0x20011584 --section-start=.bridge=0x200103e8 -e feed_start -o feed.elf feed.o
@   objcopy -O binary -j .text feed.elf case_relay_feed.bin

        .syntax unified
        .cpu cortex-m0plus
        .thumb

        .set RCC_IOPENR,   0x40021034   @ RCC_APBENR1 = RCC_IOPENR + 8
        .set GPIOB,        0x50000400   @ MODER 0, OTYPER 4, OSPEEDR 8, PUPDR 0xC, ODR 0x14, BSRR 0x18
        .set TIM6,         0x40001000   @ CR1 0, SR 0x10, EGR 0x14, PSC 0x28, ARR 0x2C
        .set TIM6_SR,      0x40001010
        .set PSC_10KHZ,    6399         @ 64 MHz / 6400 = 10 kHz, 100 us per tick
        .set PULSE_ARR,    44           @ low for 45 ticks = 4.5 ms
        .set GAP_ARR,      19999        @ high for 20,000 ticks = 2.0 s
        .set HIGH_SPIN,    2133         @ 3 cycles each at 64 MHz: 100 us high before the first low
        .set LOW_SPIN,     96000        @ 3 cycles each at 64 MHz: the first pulse, 4.5 ms low

        .section .bridge, "ax"          @ placed at 0x200103e8 by the link, not in the output
        .thumb_func
bridge_init:                            @ the bridge's own GPIO/state init, already in the relay
        bx      lr

        .text
        .thumb_func
        .global feed_start
@ Relay start, in place of the bridge's `bl bridge_init` (0x20010032), so before the banner.
@ The bridge's first call into the case flash, MX_GPIO_Init (0x08006A40), has just made PB2 a
@ push-pull output driven low. Clobbers r0-r3 like the call it replaces.
feed_start:
        push    {r4, lr}
        bl      bridge_init
        ldr     r0, =RCC_IOPENR
        ldr     r1, [r0]
        movs    r2, #2                  @ GPIOBEN
        orrs    r1, r2
        str     r1, [r0]
        ldr     r1, [r0, #8]            @ RCC_APBENR1
        movs    r2, #16                 @ TIM6EN
        orrs    r1, r2
        str     r1, [r0, #8]
        ldr     r1, [r0, #8]            @ read back before touching TIM6 (RCC write delay)
        ldr     r0, =GPIOB
        movs    r1, #4
        str     r1, [r0, #0x18]         @ BSRR: PB2 high before it is (re)configured
        ldr     r1, [r0, #0x04]
        movs    r2, #4
        bics    r1, r2
        str     r1, [r0, #0x04]         @ OTYPER: PB2 push-pull
        ldr     r1, [r0, #0x0C]
        movs    r2, #0x30
        bics    r1, r2
        str     r1, [r0, #0x0C]         @ PUPDR: PB2 no pull
        ldr     r1, [r0, #0x08]
        orrs    r1, r2
        str     r1, [r0, #0x08]         @ OSPEEDR: PB2 very high (the app's feed init)
        ldr     r1, [r0, #0x00]
        bics    r1, r2
        movs    r2, #0x10
        orrs    r1, r2
        str     r1, [r0, #0x00]         @ MODER: PB2 general-purpose output
        ldr     r1, =HIGH_SPIN
1:      subs    r1, #1
        bne     1b
        movs    r1, #1
        lsls    r1, r1, #18
        str     r1, [r0, #0x18]         @ BSRR: PB2 low -- the first feed, at relay start
        ldr     r1, =LOW_SPIN           @ busy here is harmless: no UART traffic before the banner
2:      subs    r1, #1
        bne     2b
        movs    r1, #4
        str     r1, [r0, #0x18]         @ BSRR: PB2 high
        ldr     r3, =TIM6
        str     r1, [r3, #0x00]         @ CR1 = URS, stopped: UG will not set the update flag
        ldr     r1, =PSC_10KHZ
        str     r1, [r3, #0x28]         @ PSC
        ldr     r1, =GAP_ARR
        str     r1, [r3, #0x2C]         @ ARR: the first gap
        movs    r1, #1
        str     r1, [r3, #0x14]         @ EGR = UG: load PSC, CNT = 0
        movs    r1, #0
        str     r1, [r3, #0x10]         @ SR = 0
        movs    r1, #5
        str     r1, [r3, #0x00]         @ CR1 = URS | CEN
        pop     {r4, pc}

        .thumb_func
@ TIM6 overflowed: end the pulse (PB2 low -> high, then wait GAP) or start one (PB2 high ->
@ low: the falling edge feeds the 4005, then wait PULSE). Keeps every register but the flags.
feed_tick:
        push    {r0, r1, r2}
        ldr     r0, =TIM6
        ldr     r1, =GPIOB
        ldr     r2, [r1, #0x14]         @ ODR
        lsls    r2, r2, #29             @ PB2 -> N
        bpl     2f
        movs    r2, #1
        lsls    r2, r2, #18
        str     r2, [r1, #0x18]         @ BSRR: PB2 low (feed)
        movs    r2, #PULSE_ARR
        b       3f
2:      movs    r2, #4
        str     r2, [r1, #0x18]         @ BSRR: PB2 high
        ldr     r2, =GAP_ARR
3:      str     r2, [r0, #0x2C]         @ ARR
        movs    r2, #1
        str     r2, [r0, #0x14]         @ EGR = UG: CNT = 0, the new period starts now
        movs    r2, #0
        str     r2, [r0, #0x10]         @ SR = 0: clear the update flag (after UG: URS = 1, and
                                        @ the next overflow is >= 4.5 ms away, so none is lost)
        pop     {r0, r1, r2}
        bx      lr

@ The poll hooks. Each is reached by a `bl` that replaced two 16-bit instructions of a poll
@ loop; it checks the update flag in a register those two instructions overwrite anyway, keeps
@ LR there across feed_tick, then runs them and returns with their flags. The enclosing
@ functions saved LR on entry, so the `bl` itself costs nothing they need.
        .macro  poll_hook scratch, insn1, insn2
        ldr     \scratch, =TIM6_SR
        ldr     \scratch, [\scratch]
        lsrs    \scratch, \scratch, #1  @ update flag -> C
        bcc     1f
        mov     \scratch, lr
        bl      feed_tick
        mov     lr, \scratch
1:      \insn1
        \insn2
        bx      lr
        .endm

        .thumb_func
poll_bridge_rx:                         @ 0x2001031c, the bridge's host read (G2RQ)
        poll_hook r1, "ldr r0, [r2, #28]", "movs r1, #15"

        .thumb_func
poll_beacon:                            @ 0x2001074c, the wait for the temple's HELO
        poll_hook r4, "ldr r1, [r3, #28]", "movs r4, #15"

        .thumb_func
poll_temple_rx:                         @ 0x200108b2, the wait for a temple frame
        poll_hook r0, "movs r0, #2", "cmp r3, #0"

        .thumb_func
poll_host_rx:                           @ 0x200109bc, the relay's host read (G2TX, G2EX)
        poll_hook r7, "ldr r6, [r4, #0]", "lsls r7, r6, #28"

        .thumb_func
@ In place of the bridge's last `bl 0x20010624` (r0 = 0x80000 turns of a 3-cycle loop, 25 ms)
@ between G2RS and its reset: the same wait, about 23 ms (11 cycles per turn), still polling, so
@ the relay feeds right up to its reset. The case then waits in its ROM, unfed, for the host's
@ cleanup (NRST 0.3 s after G2RS, about 2 s of ROM work, then the case app runs and feeds).
fed_delay:
        push    {r4, lr}
        lsrs    r4, r0, #2
        beq     2f
1:      ldr     r0, =TIM6_SR
        ldr     r0, [r0]
        lsrs    r0, r0, #1
        bcc     3f
        bl      feed_tick
3:      subs    r4, #1
        bne     1b
2:      pop     {r4, pc}

        .ltorg
        .balign 4

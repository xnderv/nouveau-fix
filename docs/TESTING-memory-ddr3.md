# Memory reclocking on GF108 cards with DDR3: scripts built from the VBIOS (first round, 26 Nov 2026)

Until now the lab driver changed the memory clock by **replaying a script recorded from the NVIDIA driver on one
particular board**. That works only on a board somebody has recorded, and the replay keeps its own idea of where the
memory is. This build can **build the script itself**: field values from your card's VBIOS, the order of steps from the
recordings, and every "write only if it changes" decision from the registers as they are at that moment. It keeps no copy
of the memory state, so a module reload or a suspend/resume cannot put it out of step with the card.

**Where it applies** is decided at load from the hardware and the VBIOS, not from a list of cards: DDR3, one memory
partition with two controllers, VBIOS memory tables version 1.0. Among the boards we have seen that is GF108 with DDR3
(GT 630, GT 730 with DDR3, GT 630M, Quadro 600). The kernel log says which it is:

```
journalctl -k -b | grep "LAB gen:"
# LAB gen: DDR3 memory scripts can be built from the VBIOS and the register state here; memory levels, MHz: ...
# LAB gen: the DDR3 script generator does not apply to this card: ...        (GDDR5, GF117, GF119: nothing changes for you)
```

**What has been checked, and what has not.** Offline, the very C text that is in the driver reproduces 35 of the 37
distinct NVIDIA scripts recorded on five GF108 DDR3 boards word for word, and the host writes around them
(`bash lab/memgen-ddr3-ctest.sh` repeats that check on your machine in a few seconds; it touches no hardware). The two
that differ come from one board of the public trace collection and differ by six writes to one register we cannot
explain. **No built script has run on hardware yet.** Our own card has GDDR5 and cannot run it.

## Three modes: `lab_mem_gen`

| Value | What happens at a memory transition |
|---|---|
| **2** (default in this round) | The script is built and printed to the kernel log. The switch itself is done by the recorded scripts of your board, exactly as in the previous build. A board with no recording: memory stays where it is. |
| **1** | The built script runs. |
| **0** | Recorded scripts only, nothing is built. |

It can be changed at run time: `echo 1 | sudo tee /sys/module/nouveau/parameters/lab_mem_gen`. One exception: after a
built script has run, going back to the recorded scripts (0 or 2) needs a module reload or a reboot. `lab_mem_new=1` is
still what turns memory reclocking on for a board whose recording has not been tested live.

## Step 1: build and print (no new risk)

Update and build as in [TESTING-core.md](TESTING-core.md) (`git pull`, `bash lab/tester-build.sh`,
`bash lab/tester-build.sh install`, reboot), then use the machine as you did with the previous build: same options, a
single monitor. With the default `lab_mem_gen=2` the memory is switched as before, and each distinct script the driver
would have built is printed once. Then:

```
journalctl -k -b | python3 lab/memgen-ddr3-logcheck.py -
```

For every built script this says whether it **matches a recorded NVIDIA script word for word**, or which recorded script
is nearest and which register writes differ. A transition that is not in any recording of your board (for example a
direct 324 -> 896 MHz on the GT 630M, where NVIDIA went through 135) cannot match exactly; the differences are still
worth seeing. A script may also be reported as matching "except the frame wait and the display pause": NVIDIA leaves
these out when no display is active (at its driver start, or on a GPU that drives no screen), the lab driver always has
them at run time. Please send the output and the kernel log (`journalctl -k -b > nouveau-$(date +%Y%m%d-%H%M).txt`).

This step tells us whether the driver reads your VBIOS tables and the register state the way the offline check assumes.
On a board with no recording it is the only step we ask for now: send the log first.

## Step 2: run the built scripts (the actual test; your choice)

```
echo 1 | sudo tee /sys/module/nouveau/parameters/lab_mem_gen
```

From the next level change the built scripts run. What differs from the recorded path:

- every transition is one direct step (the recorded plans went through an intermediate level where the direct step had
  not been recorded);
- the state comes from the registers each time: module reload at any level and suspend/resume are exactly what we would
  like to see tested here;
- the line registers `0x11x620/628/630` are written inside the script, in both directions, where NVIDIA has them;
- a level your board's recording lacks becomes reachable (135 MHz on the Quadro 600);
- after each script the driver checks on the registers that the memory clock is where the script should have left it,
  and logs `LAB gen ...: memory at the target` or an error.

**Risks.** This is the first run on hardware. A wrong script can corrupt the picture, hang the GPU or freeze the machine,
as any memory experiment so far. Save your work, keep a second way in (SSH) or be ready to press Reset, and see
[boot-recovery.md](boot-recovery.md). Please do not put `lab_mem_gen=1` into `/etc/modprobe.d` yet: set it by hand after
boot, so that a bad script cannot run at every start.

**One kind of transition has no recording behind it:** from one divider-clocked level up to another (it needs two memory
levels on the divider; of the boards we know only the ASUS GT 630 has that, 135 -> 324 MHz). By default the driver goes
through the highest PLL level there, in two steps of recorded kinds: the route the recorded plan of that board took.
`lab_mem_gen_updiv=1` allows the direct step instead; treat it as a separate experiment.

**What to send:** the kernel log of the session, the `memgen-ddr3-logcheck.py` output, and a word about anything odd:
artifacts, freezes, a level that did not change. If the screen freezes, reboot and send `journalctl -k -b -1`.

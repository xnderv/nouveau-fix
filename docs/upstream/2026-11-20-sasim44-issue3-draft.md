@sasim44 — as promised, the build is ready.

It changes the **core clocks automatically by load** (the NVIDIA driver's way: up when busy, down step by step when idle),
with every clock, source and voltage computed from your card's own VBIOS. **Memory stays at your boot clock**, 324 MHz on
your board — your recording will help with the memory part later. I checked your VBIOS tables against the one known
problem on GF108 (a hub clock that a divider can't make): your board takes that clock from a PLL, so it isn't affected.

Instructions: [docs/TESTING-core.md](https://github.com/xnderv/nouveau-fix/blob/main/docs/TESTING-core.md). On Debian 13's
6.12 kernel the patches apply as they are. Please use **one monitor** for this — after your finding we're even more careful
about two.

Use the computer normally for an evening, then attach the kernel log as described. Thank you!

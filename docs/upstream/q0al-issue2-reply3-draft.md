# Reply 3 to Q0AL in xnderv/nouveau-fix#2 — DRAFT, post after approval

@Q0AL — thank you, this is a complete recording: 3.96 M lines, both passes, no losses (it is about the same size as
ours; 7 MB is just the compression). It already answered something we could not pin down on our own card:

- inside the clock-switch "bracket" NVIDIA 390 waits a fixed time from the moment it engages the slowdown — on your card
  the timer readings pin it to exactly **8.000 µs for the GPC and 4.000 µs for the hub** clock (ours only gave a range
  around those values). Same slowdown factors as ours (/6 and /2), so this is a GF114 constant, not a board quirk;
- the memory scripts are close to ours: one identical, one differs in a single value, the other two in the parts that
  depend on your memory clock (2052 vs our 2004 MHz) and board layout. Your card goes from 135 straight to 2052 MHz in one
  step, ours uses an intermediate 324 MHz script.

One thing did not work, and it is my instructions' fault: the ROM file is the shortened copy the system BIOS keeps for the
boot GPU (reading /sys/.../rom of the primary card returns that), so the VBIOS tables in it are not readable. Could you
get the full image one of these ways, whichever is easiest:
- boot once with nouveau (remove the blacklist file again) and `sudo cp /sys/kernel/debug/dri/0/vbios.rom ~/gtx560-nouveau.rom`;
- or `nvflash --save gtx560.rom`, or GPU-Z on Windows (Save BIOS).

With the real VBIOS I can run our generator for your board and compare its memory scripts with the ones in your recording —
that is the main test we are after. The NVS 5200M and the GT 730 are still welcome whenever you get to them.

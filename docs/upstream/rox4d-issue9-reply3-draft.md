# Third reply in Twilight0/nouveau-dkms issue #9 (to rox4d) — posted 27.10.2026 21:32 MSK as xnderv: https://github.com/Twilight0/nouveau-dkms/issues/9#issuecomment-6450414733

Place: a comment in https://github.com/Twilight0/nouveau-dkms/issues/9 (public). Our own analysis of his trace; credit him.

---

Thank you — the GF106 trace is complete (5.7 M lines, both passes, every phase marked) and it already answered things we
could not settle on one card. What we see in it, compared with the same scenario on our GTX 560 Ti (GF114):

Same on both chips:
- the level values follow one rule: at the two lower levels every unit runs from the 1620 MHz PLL through integer
  dividers (ROP/hub 270 and 810, hub01 540/810, copy/vdec 135/405, GPC post-divider /16 and /1), and only the top
  level uses the GPC/ROP PLLs; the register values at the lower levels are identical to ours;
- the order of a transition: voltage and memory first on the way up, PTHERM "FSRM" slowdown bracket around every
  GPC/hub06 clock-source switch, the GPC PLL restarted inside that bracket right before the switch on the way up,
  the post-divider written inside the bracket on the 07→03 step;
- the regulator: straight to the top level under load, stepping down through 07 to 03 about 8 s apart.

Different:
- the FSRM slowdown code in the bracket: your card uses 0x20082/0x2 for the GPC (same as for hub06), ours uses
  0xa008a/0xa for the GPC;
- the fixed wait the driver inserts after engaging the slowdown and before writing the switch (it polls PTIMER): on
  your card 16–22 µs on the way down (both GPC and hub06), on ours 7–9 µs (GPC) and 4–5 µs (hub06); the ~40 µs wait
  around the PLL restart on the way up is the same;
- on your card the driver never touches the GPC main divider (0x1371d0 stays at /4 from boot); on ours it parks it at
  /8 (405 MHz) while the GPC is on its PLL and changes it back inside the bracket on the way down. So that step is
  specific to our board, not to Fermi;
- 0x020130 (set by the VBIOS) is 0x8107030a on yours, 0x8107040a on ours — we had a guess that the wait length is encoded
  there (byte + 1 µs); your data kills it, the GPC byte is the same and the waits differ 2–3×.

Why the wait matters to us: on our card, with an FSRM bracket but a wait of only ~2–3 µs, the GPC clock-source switch
occasionally sticks on the PLL (about 1 % of downshifts in some boots); waiting 8 µs as the driver does removes it
completely (0 in 1500 vs 5 in 167, same boot). Your trace says the safe wait is not a constant of the chip family.

If you ever record the same card again, two small things would help: `dmesg | grep mmiotrace` after the run (whether the
tracer reports lost events), and, if you don't mind, the output of `nvidia-settings -q GPUPerfModes` — the clock table
the driver sees for your board. No need to send anything else. Thanks again; your trace goes into the write-up as a
GF106 observation credited to you.

**Summary so far (21 Nov 2026)** — @sasim44's ASUS GT 630 2GD3 (GF108, DDR3, PCI subsystem 1043:8400) has become the reference card for GF108. Results from the rounds by e-mail, collected here so others can find them.

**What was done on this card**
- Card report and VBIOS (the image itself stays private; only table values are published).
- Two recordings of the NVIDIA 390 driver. With two monitors (DVI + HDMI) the NVIDIA driver kept the card at the top level all the time; with one monitor it switched normally between all three levels (50/135, 405/324, 810/896 MHz).
- The lab build on Debian 13 (6.12): an evening of normal use and games, 38 automatic core switches, no hang, no GPU error. **The first chip other than our GTX 560 Ti on which the automatic core runs.**

**What we learned**
- **Hub clock (HUB2CLK) at the top level: 1282 MHz, not the 1595 the VBIOS asks for.** Measured with the card's clock counters: in "PLL" mode the hub runs from the system PLL (SYS2CLK) — on GF108 the same as on GF114. The NVIDIA driver writes exactly the same registers, so under NVIDIA it runs at 1282 too.
- **GF108 has a wire from the hub's clock source to the crossbar PLL** (source code 2, sub-select 7): a probe on this card read 797 MHz = 1594.7 / 2. Our GF114 doesn't have it. On GF108 boards whose VBIOS marks the hub "divider", the NVIDIA driver feeds the hub this way (GT 730: 1400 MHz).
- **The VBIOS of three ASUS GF108 boards (GT 440, this GT 630, a laptop GF108M) marks the hub "from PLL"**, while every other GF108 image we have marks it "divider" — with the same numbers (an MSI GT 440 gets its 1595 MHz). With that flag the NVIDIA driver ends up 20 % below the VBIOS. Details: [docs/deviations.md](https://github.com/xnderv/nouveau-fix/blob/main/docs/deviations.md), [docs/2026-11-21/vbios-hit.md](https://github.com/xnderv/nouveau-fix/blob/main/docs/2026-11-21/vbios-hit.md).
- The memory scripts of the one-monitor recording are regular: six distinct scripts, repeats identical to the byte; DDR3 needs no link training.

**What changed in the build because of this card**
- One rule for all clocks: the route the VBIOS flag gives; if it misses the VBIOS number by more than ±2 %, a divider; then a PLL. On this card the hub at the top level becomes 1620 MHz from a divider.
- This card's own memory scripts are in the build, **off by default** — `lab_mem_new=1` turns them on at runtime (the first replay of DDR3 memory scripts anywhere).
- Tester fixes from this card: `/usr/sbin` in PATH (Debian), the check script reading the journal with sudo.

**Next:** the hub at 1620 MHz confirmed by the counters, and, optionally, the memory replay (135/324/896 MHz).

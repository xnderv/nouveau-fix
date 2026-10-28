# Sixth reply to rox4d in Twilight0/nouveau-dkms#9 — final text, awaiting approval (not posted)

Thanks for the BIOS dump — received, md5 matches, and I can confirm what you expected: your GTS450.ROM is byte-for-byte
identical (sha256 a5988291…) to the TechPowerUp image `Gigabyte.GTS450.1024.100923.rom`, so it was not modified. That
image is also exactly the "twin" VBIOS I had used earlier today to generate your memory scripts and compare them with the
scripts extracted from your second recording, so that comparison stands as is (88 % of the common registers match; the
remaining differences are chip-level skeleton and driver-init bits, not VBIOS data) — it was already run against your
real VBIOS without my knowing it.

A few things your VBIOS explains directly:
- devinit sets 0x020130 = 0x8107030a (ours: 0x8107040a) and 0x020004 = 0x00110028 — the boot values I saw in your recordings;
- devinit sets the GPC dividers 0x1371d0/d4/d8 to 0x0202 at POST (ours: 0x1e1e / 0x0a0a) — that is why 390 never writes 0x1371d0 in your recordings and skips the "divider before PLL" step we need on GF114;
- 0x137340 bit 0 = 0 on GF106 (and GF110), 1 on GF114/GF116 — the only chip-dependent bit in the PLL area that any Fermi VBIOS touches (306 images checked);
- voltage: table base 1.2125 V, −12.5 mV per step, max 1.1625 V; levels 03/07 fixed at 0.9625 V, 0f 1.000–1.1375 V (CVB). Decoded from the GPIO writes in your recordings, the NVIDIA driver actually sets 1.1125 V at 0f and 0.9625 V at 03/07 on your card.

You offered testing earlier. So as not to fill this thread (which is about the trace) with my driver, I have opened an
issue in my own repository with a build of the lab driver for your card and everything you would need to know before
deciding: __ISSUE_URL__ — entirely optional.

# Sixth reply to rox4d in Twilight0/nouveau-dkms#9 — DRAFT (not posted; post only after approval)

Thanks for the BIOS dump — received, md5 matches.

Interesting result: your GTS450.ROM is byte-for-byte identical (sha256 a5988291…) to the TechPowerUp image
`Gigabyte.GTS450.1024.100923.rom`, which is exactly the "twin" VBIOS I had used earlier today to generate your memory
scripts and compare them with the scripts extracted from your second recording. So that comparison stands as is
(88 % of the common registers match; the remaining differences are chip-level skeleton and driver-init bits, not VBIOS
data) — it was already run against your real VBIOS without my knowing it. Good news for the TechPowerUp collection too:
for this card their dump is the real ROM.

A few things your VBIOS explains directly:
- devinit sets 0x020130 = 0x8107030a (ours: 0x8107040a) and 0x020004 = 0x00110028 — the boot values I saw in your recordings;
- devinit sets the GPC dividers 0x1371d0/d4/d8 to 0x0202 at POST (ours: 0x1e1e / 0x0a0a) — that is why 390 never writes 0x1371d0 in your recordings and skips the "divider before PLL" step we need on GF114;
- 0x137340 bit 0 = 0 on GF106 (and GF110), 1 on GF114/GF116 — the only chip-dependent bit in the PLL area that any Fermi VBIOS touches (306 images checked);
- voltage: table base 1.2125 V, −12.5 mV per step, max 1.1625 V; levels 03/07 fixed at 0.9625 V, 0f 1.000–1.1375 V (CVB).

Nothing more needed from you right now. If the lab driver gets to a state where it takes these values from the VBIOS
instead of GF114 constants, I will let you know — no obligation to test anything.

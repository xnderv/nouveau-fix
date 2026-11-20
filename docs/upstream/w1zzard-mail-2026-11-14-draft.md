Subject: VBIOS collection — what we found, and a request for a larger sample

Hi W1zzard,

Thanks again for letting us use the VBIOS collection for the nouveau Fermi reclocking research. A short update and one request.

**What we have taken so far:** 403 Fermi images (GTS 450, GTX 550 Ti / 560 / 560 Ti and a few per other Fermi chip),
one request every 3 seconds, and today the 10 Volta images (Titan V, Quadro GV100, Tesla V100), downloaded by hand in a
browser. Nothing published or redistributed.

**What we would like to take now:** about 1,130 more images, as small per-model samples across the next generations —
needed to check that rules we derived on Fermi hold from generation to generation:

| generation | images |
|---|---|
| Kepler (GTX 600 / 700, Titan) | ~315 |
| Maxwell (GTX 750, 900) | ~200 |
| Pascal (GTX 1000) | ~300 |
| Turing (GTX 1600, RTX 2000) | ~250 |
| Ampere (RTX 3000) | ~65 |

Together with what we already have that is about 1,550 images, roughly 10 % of the collection (15,374 as of today). Same manner
as before: one request every 3 seconds, stop on the first 403/429, files kept private.

**One practical problem:** today the site answered our script with the automated bot check on the first ROM download, so
it stopped right there, as it should — we do not work around such checks. If you are fine with the sample above, could you
tell us how you would prefer us to fetch it (a whitelisted User-Agent or IP, a time window, or an archive from your side)?
Our script identifies itself as `nouveau-fix-vbios-research/1.0` with a link to the project.

**If you ever feel like it, the full ask would be:** those generations complete (about 4,000 images, ~29 % of the
collection). We will not do that without your explicit yes.

**What might be useful for your parsed VBIOS page** (you asked to let you know):
- The PLL table (BIT 'C') carries stable PLL ids from Fermi through Pascal: 0x07 → 0x1370e0 (SYSPLL), 0x08 → GPC PLL,
  0x0a → 0x137020, 0x0b → 0x137040, 0x04 / 0x0c → memory PLLs, 0x41 / 0x42 → the two system PLLs.
- On Pascal and newer the Clocks Table lists the clock domains in a fixed order (GPC2CLK, XBAR2CLK, MCLK, SYS2CLK,
  HUB2CLK, NVDCLK, PWRCLK, DISPCLK, PCIEGENCLK) with a master / slave / fixed flag per domain.
- On Fermi the init script writes register 0x020130; one byte of it sets how long NVIDIA's driver waits around every
  clock switch (we verified this on real hardware). It differs between desktop and mobile boards.

Happy to send the exact offsets or a small parser for any of these.

Best regards,
Alex

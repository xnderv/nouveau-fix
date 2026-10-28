# Draft: reply to W1zzard (TechPowerUp) — how to fetch the agreed subset past the bot check (28.10.2026, not sent)

Subject: Re: VBIOS collection — permission for research use

Hi,

Thank you very much for the permission.

A practical question. I started re-fetching the small subset we agreed on (one model at a time: GTX 560 Ti, then GTX 560 /
560 SE / 460 v2 for the GF114 side, and GTS 450 / GTX 550 Ti for the GF106/GF116 side — about 350 images in total), with a
single-threaded script that waits 3 s between requests and identifies itself as
"nouveau-fix-vbios-research/1.0 (+https://github.com/xnderv/nouveau-fix)". The BIOS pages load fine, but every .rom link
returns your "Automated bot check in progress" page instead of the file. I did not try to get around it and stopped after
the first one.

What would you prefer: a user-agent string or token you whitelist for this script, a one-off archive of those model sets, or
simply downloading them by hand in a browser? Any of these is fine with me; I just don't want to trip your protections.

What we are looking for, in case it is useful for your parsed output: the init-script (devinit) writes to the PTHERM block
(0x020000–0x020200, e.g. 0x020130) and to the clock block (0x1371c8/0x1371cc, 0x139060…0x139220), which differ between our
GF114 board and a GF106 trace we were sent, and the per-board perf-table clocks/voltages against the 1620 MHz PLL grid.
If a field turns out to be board-specific in a way your page could show, I will let you know.

Best regards,
Alex (xnderv)

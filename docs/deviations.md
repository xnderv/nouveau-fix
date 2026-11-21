# Where the VBIOS, the NVIDIA driver or nouveau get it wrong — and what this project does

The project started as "repeat what the NVIDIA driver does". Recordings of that driver, VBIOS images of 473 Fermi boards and
clock counters on real cards now show places where the VBIOS contradicts itself, where the NVIDIA driver misses the VBIOS, and
where upstream nouveau goes wrong. This file collects them, each with its evidence. The rule we follow: **the VBIOS states the
intent; where its own route can't deliver the number, we find a route that does; where it can, we do what NVIDIA does.**

Evidence classes: **image** — VBIOS tables (our parser, `lab/vbios-survey.py`); **trace** — mmiotrace recordings of the NVIDIA
driver (ours, testers', the nouveau trace collection; contributors anonymized); **counter** — clock counters read on a real card;
**test** — our hardware tests (`results/`).

## VBIOS errors

| What | Where | Evidence | What we do |
|---|---|---|---|
| The hub clock (HUB2CLK) at the top level asks for the crossbar's frequency (1595, 950 MHz) but is marked "from PLL" (flag 1). On Fermi that PLL route leads to the system PLL (SYS2CLK: 1282, 890 MHz) — the number can't be reached that way | 3 ASUS GF108 boards (GT 440 of 06.2011, GT 630, a laptop GF108M). All 14 other GF108 images mark it "divider" (flag 2), and NVIDIA then feeds it from the crossbar PLL. Same chip and same numbers on an MSI GT 440 — flag 2 | image (473), trace (ASUS laptop), counter (GT 630: 1282.5 MHz at the top level) | the route by flag misses → the divider (1620, +1.6 %) or the crossbar PLL (950) — [2026-11-21/vbios-hit.md](2026-11-21/vbios-hit.md) |
| The hub clock asks for a number no route gives: 1451 MHz with the system PLL at 1401 | 1 GF100 image | image | nearest not above the VBIOS (1401, −3.4 %), logged |
| The hub clock asks for 1400 MHz while the crossbar runs at 1460 (+4.3 %) | 1 Gigabyte GT 430 (GF108) image | image | nearest not above the VBIOS + 2 % (1080), logged — not overclocking the hub by 4 % |

Everything else is consistent: over 12,551 clock/level pairs of 470 Fermi images, 99.97 % are reachable within ±1 %, the rest
within 1.6 % — except the three cases above.

## NVIDIA driver

| What | Where | Evidence | What we do |
|---|---|---|---|
| Follows the hub's "from PLL" flag on the ASUS boards above and runs the hub 20 % (1282 instead of 1595) or 6 % (891 instead of 950) below the VBIOS, without checking | ASUS GF108 | trace (GT 630, ASUS laptop), counter (GT 630) | reach the VBIOS number (see above) |
| Never checks a clock after switching | all recordings | trace | where we use a route NVIDIA uses only on some boards (hub from the crossbar PLL), we measure it with the card's clock counter and fall back if it's wrong |
| An extra 405 MHz step before switching the shader PLL up from the idle level, only on GF110/GF114 | GF110, GF114 | trace; test 107: 8,800 switches with and 8,800 without, all clean (GF114) | no step on any chip, as NVIDIA does on GF104/106/108/116/117/119 (switch `lab_gpc_pre405=1` restores it) |
| With two active monitors stays at the top level all the time | GF108 (tester), others in the trace collection differ | tester's notes; trace collection | open — we ask testers to use one monitor; not tested with two |

## Upstream nouveau

| What | Evidence | What we do |
|---|---|---|
| The VBIOS stores whole megahertz (101 for 101.25 MHz); nouveau took that as an exact target and put the idle shader clock on its PLL — switching away from that PLL could wedge the GPU | trace, test (900 switches clean after the fix) | recognise "a divider value written in whole MHz" and use the divider, as NVIDIA |
| PMU clock rounded down: 216 instead of 202.5 MHz | trace | both divider fields as the VBIOS / NVIDIA |
| A clock a divider can't make is rounded to the nearest divider **above**: GT 730 hub 1400 → 1620 (+16 %, an overclock) | image, trace | never above the VBIOS + 2 %; the hub from the crossbar PLL where the VBIOS wired it |
| Source "code 2" read as always 100 MHz; its sub-select (bits 24–26) is ignored. On GF108 sub-select 7 is the crossbar PLL | counter (GF114, GF108 probe) | read and use the sub-select |
| Fan PWM read back with the update bit set → the fan could drop to 3 % | test | patch 0006, sent upstream |
| A GPU hang when an app deletes an engine object while its channel is busy | test | patch 0001, sent upstream |

Open questions are tracked in the dated folders under `docs/`; this file is updated when a row is confirmed or overturned.

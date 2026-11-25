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
| The hub clock asks for a number its flagged route can't give: 1451 MHz (the crossbar's number) with the system PLL at 1401 | 1 GF100 board | image; NVIDIA keeps the hub on the system PLL there (trace) | since 24 Nov: one attempt at the crossbar-PLL route with the counter self-check; if the chip has no such wire (GF114 has none, GF100 not measured) — 1401 (−3.4 %), logged |
| The hub clock asks for 1400 MHz while the crossbar runs at 1460 (+4.3 %) | 1 Gigabyte GT 430 (GF108) image | image | nearest not above the VBIOS + 2 % (1080), logged — not overclocking the hub by 4 % |

Everything else is consistent: over 12,551 clock/level pairs of 470 Fermi images, 99.97 % are reachable within ±1 %, the rest
within 1.6 % — except the three cases above.

## NVIDIA driver

| What | Where | Evidence | What we do |
|---|---|---|---|
| Follows the hub's "from PLL" flag on the ASUS boards above and runs the hub 20 % (1282 instead of 1595) or 6 % (891 instead of 950) below the VBIOS, without checking | ASUS GF108 | trace (GT 630, ASUS laptop), counter (GT 630) | reach the VBIOS number (see above) |
| Never checks a clock after switching | all recordings | trace | where we use a route NVIDIA uses only on some boards (hub from the crossbar PLL), we measure it with the card's clock counter and fall back if it's wrong |
| An extra 405 MHz step before switching the shader PLL up from the idle level, only on GF110/GF114 | GF110, GF114 | trace; test 107: 8,800 switches with and 8,800 without, all clean (GF114) | no step on any chip, as NVIDIA does on GF104/106/108/116/117/119 (switch `lab_gpc_pre405=1` restores it) |
| Changes the crossbar (XBAR2CLK) and memory in a different order on different chips: on GF108/GF117 the crossbar goes up before the memory and down after it ("crossbar outside memory"); on all other Fermi chips the other way round ("memory outside crossbar") | all Fermi; see the section below | trace (44 recordings, 9 chips); test 119 | one order on every chip: crossbar outside memory — see [The crossbar/memory order](#the-crossbarmemory-order) |
| On GF119 never touches the LTC2CLK node (nouveau's "rop", index 01): it stays on the 27 MHz crystal at every level, although the VBIOS lists 810 / 1701 MHz for it; at boot the node is on the crystal too | all 4 GF119 boards in the trace collection (5 recordings) | trace; boot state on a tester's NVS 315 (our log: node on the crystal after POST) | open: our build still sets the VBIOS number (NVS 315: 810, and 1080 for 1099 at the top level) and ran clean; candidate rule — a node the VBIOS left on the crystal is not used on that board, leave it (one rule, no chip list) |
| With two active monitors stays at the top level all the time | GF108 (tester), others in the trace collection differ | tester's notes; trace collection | open — we ask testers to use one monitor; not tested with two |

### The crossbar/memory order

**What it is.** When the level changes, two things change speed: the crossbar (XBAR2CLK, the bus between the GPU and the
memory controllers) and the memory itself. One of them has to go first.

**What NVIDIA does** (all Fermi recordings in the trace collection):
- GF108 and GF117: going up — crossbar first, then memory; going down — memory first, then crossbar. The crossbar is fast the
  whole time the memory is fast: **crossbar outside memory**.
- GF100, GF104, GF106, GF110, GF114, GF116, GF119: the other way round — **memory outside crossbar**.

**What separates the two groups inside Fermi — memory topology (a fit, not a proof).** The NVIDIA driver reads the layout of the memory at start
(the same registers nouveau reads): partitions (0x022438), disabled partitions (0x022554), L2 slices per partition
(0x17e8dc bits 28–31). GF108 and GF117 have **one active partition split into two slices**: all memory traffic converges in
one partition. GF119 has one partition with one slice; the others have 2–6 partitions. The rule "crossbar outside memory ⇔ one
active partition with ≥ 2 slices" matches NVIDIA on all 9 Fermi chips. NVIDIA's own memory scripts confirm that it counts
GF108 as one partition: a register address in the scripts follows the number of active partitions (0x13d834 + 0x40 · (n − 1)),
and on GF108 it is n = 1 although the chip has two memory controllers. Details: [2026-11-23/mem-meaning.md](2026-11-23/mem-meaning.md) §7–9.

**Checked against the next generations (24 Nov).** On Kepler and Maxwell (9 chips, 65 recordings) NVIDIA puts the crossbar
outside the memory on every chip, whatever the memory layout: the crossbar moved to its PLL before the memory script in 89 of
89 upward changes, and back to the divider after it in 90 of 93 downward ones (the three exceptions are in one recording with
an unusual slow frequency ramp). The same tool reproduces the Fermi split above with no exceptions (40 recordings). So GF108
and GF117 already use the order that became universal one generation later, and the topology rule does not carry beyond
Fermi: inside Fermi it still separates the chips, but it may be a coincidence rather than the reason. Raw output:
[2026-11-24/xbar-order-raw.md](2026-11-24/xbar-order-raw.md).

**What we first blamed, and what turned out (corrected 24 Nov).** A tester's GF108 (GT 630, DDR3) crashed on the first memory
switch, and our build did use the order of the large chips there, so we blamed the order
([2026-11-22/ddr3-replay-crash.md](2026-11-22/ddr3-replay-crash.md)). With the order fixed the memory still fails: on two GF108
DDR3 boards the data read back at 896 MHz is corrupt while 324 MHz is fine, with the crossbar already fast. So the order is
what NVIDIA does on this chip and a sensible guard, but it was not shown to be the cause of that crash. The search continues
in [2026-11-24/seq-ops.md](2026-11-24/seq-ops.md).

**What we do — one order on every chip, deliberately different from NVIDIA on the large chips.** Crossbar outside memory: while
the memory changes, the crossbar is already (or still) fast. On GF108/GF117 this is NVIDIA's order; on the other chips it is a
safety margin with a clear reason and no cost, and it works there: tests 28 and 69 (October), a tester's GF106 run, and test 119
(300 level changes with memory on GF114, 0 errors). We keep it on all chips rather than copy NVIDIA's per-chip choice. It is
also the order NVIDIA itself uses on every Kepler and Maxwell chip.

**The module parameter `lab_nv_xbarmem`** (for experiments; users never need to set it):

| value | order | use |
|---|---|---|
| **1** (default) | crossbar outside memory on every chip | normal use |
| 0 | memory outside crossbar on every chip (NVIDIA's order on the large chips; on GF108/GF117 this is the order that crashed) | comparison only |
| −1 | as NVIDIA would on this card: decided from the memory topology read from the card (rule above), not from a chip list | comparison only |

On the first level change the kernel log shows the card's topology and what NVIDIA's rule would choose, for example:
`LAB топология памяти: разделов 4 (выключены 0, активных 4), контроллеров …, подразделов на раздел 2 -> по правилу NVIDIA шина XBAR внутри памяти`.
This line only reports; the order used is set by `lab_nv_xbarmem`.

## Upstream nouveau

| What | Evidence | What we do |
|---|---|---|
| The VBIOS stores whole megahertz (101 for 101.25 MHz); nouveau took that as an exact target and put the idle shader clock on its PLL — switching away from that PLL could wedge the GPU | trace, test (900 switches clean after the fix) | recognise "a divider value written in whole MHz" and use the divider, as NVIDIA |
| PMU clock rounded down: 216 instead of 202.5 MHz | trace | both divider fields as the VBIOS / NVIDIA |
| A clock a divider can't make is rounded to the nearest divider **above**: GT 730 hub 1400 → 1620 (+16 %, an overclock) | image, trace | never above the VBIOS + 2 %; the hub from the crossbar PLL whenever no other route hits and the crossbar runs on its PLL at that number, checked with the clock counter (until 24 Nov only where the VBIOS selected that source at boot — too narrow: 7 of 39 GF108 images don't, and NVIDIA uses the route on such boards too; [survey](2026-11-24/hub-alt.md)) |
| Source "code 2" read as always 100 MHz; its sub-select (bits 24–26) is ignored. On GF108 sub-select 7 is the crossbar PLL | counter (GF114, GF108 probe) | read and use the sub-select |
| Fan PWM read back with the update bit set → the fan could drop to 3 % | test | patch 0006, sent upstream |
| A GPU hang when an app deletes an engine object while its channel is busy | test | patch 0001, sent upstream |

Open questions are tracked in the dated folders under `docs/`; this file is updated when a row is confirmed or overturned.

# nouveau-fix: automatic clock changes for NVIDIA Fermi cards in nouveau, computed from the card's own VBIOS

A hobby research project. Upstream nouveau keeps Fermi cards (GeForce 400/500 and many 600/700 and mobile parts) at their
boot clocks, so they are slow in 3D and video. This project records how the NVIDIA driver changes clocks, works out the
rules behind it, and builds a lab nouveau driver that does the same **on any Fermi card, from that card's VBIOS** — no
per-board tables. Small, self-contained fixes go upstream; there are no support promises.

Issues may be written in Russian too. / Issues можно писать по-русски. Research notes under `docs/` (dated folders, the
model) are in Russian — they are the lab notebook; everything a tester needs is in English.

## Status (27 Nov 2026)

- **Core clocks change automatically by load**, the way the NVIDIA driver does it: up to the top level when the GPU is
  busy, down step by step when it's idle. The governor runs inside the driver (load is counted in the PMU firmware); no
  service or options are needed.
- **Every core clock, source, divider, PLL and voltage is computed from the card's VBIOS**, including the display clock and
  the waits around each switch. The one rule for choosing a clock route — the VBIOS flag first, then a divider, then a PLL,
  always within ±2 % of the VBIOS number — is checked against 473 Fermi VBIOS images
  ([docs/2026-11-21/vbios-hit.md](docs/2026-11-21/vbios-hit.md)).
- **Core reclocking has run on 7 boards of 4 chips** (GF114, GF106, GF108, GF119): ours and six testers', without a hang.
  GF100, GF104, GF110, GF116 and GF117 have not run it yet.
- **Memory clock, by replaying NVIDIA's recorded script of the board:** works on five boards (GDDR5 on GF114 and GF106,
  DDR3 on three GF108 boards); two more are recorded and not yet run (GDDR5 on GF108 and on GF116). On the DDR3 boards
  memory is where the speed is: on a
  tester's Quadro 600 glmark2 goes from 749 to 1498 with the memory clock, and gains nothing from the core clocks alone.
- **Memory clock without a recording (new, 26 Nov):** for GF108 cards with DDR3 the driver can build the script from the
  VBIOS and the register state. The C code of the driver reproduces 35 of 37 distinct NVIDIA scripts recorded on five
  boards word for word. First hardware run (a tester's Quadro 600): 507 built scripts, every transition between the three
  levels, also after a module reload and across suspend/resume, with no error and no corrupted video memory. By default
  the driver still builds and prints the script while the recorded one does the switch, until more boards have run it
  ([docs/TESTING-memory-ddr3.md](docs/TESTING-memory-ddr3.md)). On every other card the memory stays at the VBIOS boot clock.
- **Open:** one GPU fault during a memory switch on our GF114 after 6,726 clean level cycles, in our own order of steps
  (bus clock outside the memory step); a day-long run in NVIDIA's order then went 34,800 cycles without an error, and the
  hang that followed the fault matches a nouveau recovery bug for which a tester has sent a fix to the nouveau list.
  A glitch on both screens during level changes with two monitors on a tester's GT 630.
- **Use a single monitor: unplug any others.** Two or more monitors is a setup we have not tested, and we are not asking you to test it.

| Card | Chip, memory | Core clocks | Memory clock |
|---|---|---|---|
| Gigabyte GTX 560 Ti (reference board, ours) | GF114, GDDR5 | 10,000 + 17,600 switches under load; a night of 900 automatic switches: no hang | recorded scripts: 37,800 full level cycles clean in NVIDIA's order of steps (one run of 34,800 over 23 hours); in our own order one GPU fault after 6,726 clean cycles (open) |
| Gigabyte GTS 450 (tester) | GF106, GDDR5 | clean | recorded scripts, 324 ↔ 1804 MHz: clean |
| ASUS GT 630 (tester) | GF108, DDR3 | an evening of normal use and games: clean | recorded scripts: 3 hours of use and games, 71 switches, no error |
| GT 630M, Medion laptop (tester) | GF108, DDR3 | clean | recorded scripts: all level transitions, suspend/resume, 134 GiB of video memory read back correct; on by default |
| HP Quadro 600 (tester) | GF108, DDR3 | clean; piglit `quick` with no regression | recorded scripts: about 1,100 switches in 5 hours, no error; built scripts: 507 switches, module reload and suspend/resume included, no error |
| GT 730 4 GB (tester) | GF108, DDR3 | first run clean | not yet: no recording, the first candidate for built scripts |
| NVS 315 (tester) | GF119 | the first run on a GF119: works | not yet |
| Dell NVS 5200M (tester) | GF108, GDDR5 | not yet run | recorded, not yet run |
| Palit GTX 550 Ti (tester) | GF116, GDDR5 | not yet run; computed from its VBIOS, every clock of the two recorded levels equals what NVIDIA set | recorded 26 Nov (324 ↔ 2052 MHz), not yet run |
| GF100, GF104, GF110 | — | not yet | testers wanted |
| GF117 | — | not yet: no display, and nouveau doesn't run its power-management controller (PMU), so no automatic governor | planned |

## Which cards

Fermi is the GPU generation of 2010–2012. If your NVIDIA card is one of these and the legacy NVIDIA 390 driver no longer
suits you (it ended in 2022 and needs patches for new kernels), this project is for you:

- **Desktop:** GeForce 405, GT 420, GT 430, GT 440, GTS 450, GTX 460, GTX 465, GTX 470, GTX 480, GeForce 510, GT 520, GT 530,
  GTX 550 Ti, GTX 560, GTX 560 Ti, GTX 570, GTX 580, GTX 590, GT 610, GT 620, GT 630, GT 640, GT 705, GT 730.
- **Laptop:** GeForce 410M, GT 415M–GT 555M, GTX 460M–GTX 580M, GeForce 610M, GT 620M–GT 640M, GTX 670M, GTX 675M,
  GT 710M, GT 720M; NVS 4200M, NVS 5200M; Quadro 1000M–5010M.
- **Workstation:** Quadro 600, 2000, 4000, 5000, 6000; NVS 300, 310, 315.

Many of these names were also used for Kepler or Maxwell chips (GT 630, GT 640, GT 705, GT 730, GT 720M and others), so the
name alone isn't enough: `bash tools/card-report.sh` tells you which chip you have, and `lspci -nn` shows it as well.
Status by chip is in the table above.

**Where we differ from the NVIDIA driver and the VBIOS** — VBIOS errors, NVIDIA misses and nouveau bugs, each with its
evidence: [docs/deviations.md](docs/deviations.md).

## Try it

Step by step: **[docs/TESTING-core.md](docs/TESTING-core.md)**; memory on GF108 cards with DDR3:
**[docs/TESTING-memory-ddr3.md](docs/TESTING-memory-ddr3.md)**. In short: `bash tools/card-report.sh` (read-only report of
your card), `bash lab/tester-build.sh` (fetches nouveau for your running kernel, applies the patches, builds; checked on
Linux 6.12, 7.0, 7.2, 7.3), `bash lab/tester-build.sh install`, reboot. Undo: `bash lab/tester-build.sh remove`. Your
distribution's nouveau stays untouched. Results and questions: the issues of this repository.

On a GF108 card, `bash lab/gf108-check.sh` measures which PLL feeds the hub clock (read-only, 15 seconds).

## How we work

- **Observation and experiment only.** We record how the NVIDIA 390 driver talks to the hardware (the kernel's
  built-in mmiotrace), read registers and the VBIOS, test every step on the hardware, and use open sources: nouveau,
  envytools, NVIDIA's open nvgpu and Tegra code. Facts from others are hypotheses until our own traces or registers
  confirm them, and every fact records its source. No conclusions from decompiled or disassembled NVIDIA code —
  ours or anyone's ([`docs/provenance.md`](docs/provenance.md)).
- **What happened before.** Until 24 Oct 2026 we also relied on notes and a decoder from the Twilight0 project.
  Part of its findings come from decompiling NVIDIA's driver. We stopped, audited what we had taken, and on 26 Oct
  removed what we had not verified ourselves (`docs/2026-10-26/provenance-and-research.md`, part 1).
- **No NVIDIA binaries in this repository.** VBIOS images and raw traces stay private; only findings and register
  values are published.
- **One change per test.** Every step is a separate switch, tested alone on the hardware, with the logs in `results/`.

## Data from other Fermi cards (welcome, not required)

If you own another Fermi card and want to help: `bash tools/card-report.sh` only reads; it prints a summary of your VBIOS
tables and, with your consent, saves an archive. Open a **Card data** issue with the summary, and send the archive to
**xnderv@yandex.com** — not to the issue: the image belongs to NVIDIA and your card's vendor, so we never publish it, only
values from its tables. A recording of the NVIDIA driver on your card (`trace/`, one evening) helps most.

## Patches

Tester build (`lab/tester-build.sh`): `0001` + `lab/0002` (one of three variants, picked for your kernel) + `0004` + `0006`.

- `0001` — a GPU hang when a Chromium-based app deletes an engine object while its channel is busy. **Sent upstream**
  23 Oct 2026 (v2 the same day): [lore](https://lore.kernel.org/dri-devel/20261023144219.46478-1-xnderv@yandex.com/).
- `lab/0002` — clocks computed from the VBIOS, with a `lab_*` switch for every step (`-v7.2`, `-v7.3`: the same for kernels
  that already have upstream's own clk fixes). Rebuilt from the lab tree by `lab/regen-patches.sh`.
- `0003` — HDMI refused when the monitor supports SCDC and the GPU does not; fixed upstream (`1717fcc5be57`), kept for 7.0.x.
- `0004` — load counting in the PMU firmware and the in-driver governor.
- `0005` — HDMI AVI InfoFrame ITC (lab).
- `0006` — the fan could drop to 3 %: the PWM duty was read back with the update bit set. **Sent upstream** 25 Oct 2026:
  [lore](https://lore.kernel.org/dri-devel/20261025101640.49779-1-xnderv@yandex.com/).
- `archive/stable-2026-10/` — the first, board-specific driver (`0010`, DKMS) for the reference board only; retired.

## Where things are

| Path | Contents |
|---|---|
| `docs/TESTING-core.md` | how to test the build on your card |
| `docs/TESTING-memory-ddr3.md` | memory reclocking on GF108 cards with DDR3: scripts built from the VBIOS |
| `docs/deviations.md` | VBIOS errors, NVIDIA misses, nouveau bugs — and what we do |
| `docs/model/` | the model of NVIDIA's behaviour (Russian), register coverage |
| `docs/2026-MM-DD/` | research notes by date (Russian); the newest are the most current |
| `docs/provenance.md` | where our knowledge may come from |
| `lab/` | lab driver patches, tester scripts, tests, VBIOS and trace parsers |
| `tools/card-report.sh` | read-only card report |
| `trace/` | kit for recording the NVIDIA driver (a separate boot disk with NVIDIA 390) |
| `results/` | test logs |

## License

MIT (see `LICENSE`). The patches change files of the nouveau driver, which are themselves MIT-licensed. NVIDIA binaries
and VBIOS images are not part of the repository.

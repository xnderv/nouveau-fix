# nouveau-fix: automatic clock changes for NVIDIA Fermi cards in nouveau, computed from the card's own VBIOS

A hobby research project. Upstream nouveau keeps Fermi cards (GeForce 400/500 and many 600/700 and mobile parts) at their
boot clocks, so they are slow in 3D and video. This project records how the NVIDIA driver changes clocks, works out the
rules behind it, and builds a lab nouveau driver that does the same **on any Fermi card, from that card's VBIOS** — no
per-board tables. Small, self-contained fixes go upstream; there are no support promises.

Issues may be written in Russian too. / Issues можно писать по-русски. Research notes under `docs/` (dated folders, the
model) are in Russian — they are the lab notebook; everything a tester needs is in English.

## Status (21 Nov 2026)

- **Core clocks change automatically by load**, the way the NVIDIA driver does it: up to the top level when the GPU is
  busy, down step by step when it's idle. The governor runs inside the driver (load is counted in the PMU firmware); no
  service or options are needed.
- **Every core clock, source, divider, PLL and voltage is computed from the card's VBIOS**, including the display clock and
  the waits around each switch. The one rule for choosing a clock route — the VBIOS flag first, then a divider, then a PLL,
  always within ±2 % of the VBIOS number — is checked against 473 Fermi VBIOS images
  ([docs/2026-11-21/vbios-hit.md](docs/2026-11-21/vbios-hit.md)).
- **Memory stays at the VBIOS boot clock** on every card except the reference board. The memory part is the next stage;
  recordings from testers (GF108 DDR3 so far) are its material.
- **Not tested with more than one monitor.** Please use one.

| Card | Chip | What ran | Result |
|---|---|---|---|
| Gigabyte GTX 560 Ti (reference board, ours) | GF114 | 10,000 + 17,600 core switches under load; a night of 900 automatic switches | no hang, no error |
| ASUS GT 630 (tester) | GF108 | an evening of normal use and games; 38 automatic switches; clock counters | no hang, no error |
| GF100, GF104, GF106, GF110, GF116, GF117 | — | not yet | testers wanted |
| GF119 | — | build ready (PMU firmware with load counting, two-level governor), never run on the hardware | first tester wanted |

**Where we differ from the NVIDIA driver and the VBIOS** — VBIOS errors, NVIDIA misses and nouveau bugs, each with its
evidence: [docs/deviations.md](docs/deviations.md).

## Try it

Step by step: **[docs/TESTING-core.md](docs/TESTING-core.md)**. In short: `bash tools/card-report.sh` (read-only report of
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

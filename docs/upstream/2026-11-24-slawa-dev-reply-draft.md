# Ответ slawa-dev в issue #6 — ОПУБЛИКОВАН 24.11.2026 21:37 (https://github.com/xnderv/nouveau-fix/issues/6#issuecomment-7140897495)

Публиковать после «Да, публикуй». Перед публикацией: три инструмента (lab/trace-memstate.py, lab/memstate-dump.py,
lab/memstate-diff.py) должны быть в репозитории; в тексте заменить 8f32f79.

---

Thank you for test 4. It is a clean negative result, and it changes the plan.

**Your question first:** yes, a run with a longer unit is worth doing — but as part of one "slow tempo" run (point 2 below),
not on its own.

**Where this stands.** Your tests have ruled out the voltage, the hub route, the crossbar/memory order, the two init
registers, and now the waits after `0x13d834 = 0` at 250 ns. The replayed sequence itself is right: 324 on the PLL works
after U and D. So the difference is something that matters only at 896. Instead of trying one more candidate at a time,
I would like to measure where the replay differs from the recording. Two measurements cover most of what is left.

### 1. State comparison (read-only)

Three small tools are in the tree (8f32f79):

- `python3 -I lab/trace-memstate.py mmiotrace.txt.xz memscr-akoya.json out/` runs on any machine. From your recording it
  rebuilds the value NVIDIA holds in every register it reads or writes in the memory controller, PFB, crossbar,
  memory-clock, L2-cache and GPIO blocks, before and after each memory script. It counts host writes, host reads and the
  writes made by the PMU scripts. On your recording that is 194 registers, 179 of them in the dump list.
- `sudo python3 -I lab/memstate-dump.py out/addrs.txt FILE.txt` runs on the laptop under nouveau. It reads only those
  addresses, three times, and writes nothing.
- `python3 -I lab/memstate-diff.py out/nvidia-state.json FILE.txt 896` lists the registers where our state differs from
  NVIDIA's state after a rise to 896.

Please take three dumps: after boot (before U), right after U (at 896), and after D. The diff after U is the one that
matters. It covers in one pass everything NVIDIA writes outside the scripts and outside our time window:

- its one-time init — about 30 registers in these blocks, your `0x10f440` among them;
- the crossbar table: `0x13c054`, `0x13c844` and `0x13ec14` are 2 / 2 / 0 before each script and 3 / 3 / 1 after each
  rise on your board;
- `0x001548` and `0x610300`;
- the settings NVIDIA applies 7–19 ms after each descent and takes back before the next script (`0x100b44`, `0x100b48`,
  `0x100b4c`, `0x10f150`, `0x10f254`, `0x10f2f8`, `0x10f2fc`); our list generator stops before them.

The dump list holds only addresses that NVIDIA's driver itself touches. The training-pattern ports, the DRAM command
registers and the TLB flush trigger are left out.

### 2. One "slow tempo" run

In the recording the host writes are not adjacent to the script. The six `0x10f4xx` writes come 1.5 ms before the
launch, and their counterparts 3.3 ms after it. The replay does them back to back with the script.

NVIDIA's open Tegra K1 code for the same DDR3 (`drivers/memory/tegra/tegra124-emc.c`) waits at exactly these points. It
disables the pad power features and the auto-calibration, then waits until the calibration is idle, or 5–30 µs. After
each "update timing" strobe it polls a status bit before going on.

One run: sleep 2 ms after the "pre" host writes, sleep 2 ms before the "post" ones, and use a unit of 2000 ns for the
`0x3a` waits. If the data is good at 896, we bisect. If not, tempo is ruled out as a whole.

Either result removes a class of causes, not a single candidate.

### On our side

The same `0x39` / `0x3a` translation is in our tree, with your state-from-hardware finding, the hub route without the
boot condition and a mask for the voltage GPIO lines. It is not pushed yet. On our GF114 it passed 330 full level cycles
and 300 memory-only switches 324 ↔ 2004.

A memory-only test at 135 ↔ 2004 with the core held at the top level then hung the graphics engine. A control run
without today's changes hung the same way within a minute, so that hang comes from the test mode itself (core at the top
level, memory at 135 MHz, under load) and not from the changes. A long run of normal level cycles is going tonight; the
push follows it.

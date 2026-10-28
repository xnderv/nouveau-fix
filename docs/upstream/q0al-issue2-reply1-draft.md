# Reply to Q0AL in xnderv/nouveau-fix#2 — DRAFT, post after approval

@Q0AL — great, thank you. An EVGA GTX 560 1 GB is exactly what we are missing: same chip (GF114) as our card, a
different board, so it tests both the chip-level model and the "per board" part. The recipe, so that nothing is lost:

**Setup (same as rox4d used, Debian sid works):**
- NVIDIA 390.157 installed but **not loaded at boot** (blacklist nouveau; the script loads nvidia itself — mmiotrace only
  sees mappings made after the tracer is on, so a driver loaded at boot gives an almost empty trace);
- a kernel with `CONFIG_MMIOTRACE=y` (Debian kernels have it), `mesa-utils` (glxgears), `xinit`, `nvidia-settings`;
- a fast disk with a few GB free for the raw trace; run from a text console with no X running.

**Recording:** `git clone https://github.com/xnderv/nouveau-fix`, then `sudo trace/run-trace.sh` (comments inside are in
Russian; it needs nothing from you: a control pass without tracing, then the same ~4-minute scenario under mmiotrace —
idle/adaptive, a heavy glxgears, bursts — about 9 minutes total, ends with the line «ГОТОВО»). It writes a directory
`trace/out-<date>/` with `mmiotrace.txt.xz`, `steps.txt`, `nvsettings.txt` and the X logs. A "Device or resource busy"
from the tracer at the very end is harmless (newer kernels; the recording is complete by then).

**Also useful:** the VBIOS image —
`cd /sys/bus/pci/devices/0000:01:00.0 && sudo sh -c 'echo 1 > rom; cat rom > /tmp/gtx560.rom; echo 0 > rom'`
(adjust the PCI address from `lspci -nn | grep -i nvidia`), or an nvflash dump — plus `lspci -nn` and `uname -r`.

Attach the `out-*` directory as a zip (GitHub takes up to 25 MB; the compressed trace is usually a few hundred MB, so a
link to any file host is fine) and the ROM. If the trace comes out tiny (a few MB) or the script stops early, post
`steps.txt` and I will look. No rush.

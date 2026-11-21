---
name: Test report (lab build on your Fermi card)
about: You ran the tester build (docs/TESTING-core.md) — tell us what happened
---
**GPU / board** (`lspci -nn | grep -iE "vga|3d"`, vendor and model):
**Kernel / distro:**
**Monitors connected** (we ask for one):

**Result:** works / partially / hang / no change

**What you did** (desktop, video, games, how long):

**Attach the kernel log** (it is partly in Russian — that's fine):
```
journalctl -k -b | grep -E "nouveau|LAB" > nouveau-log.txt
cat /sys/module/nouveau/srcversion
```
On a GF108 card, also the file printed by `bash lab/gf108-check.sh`.

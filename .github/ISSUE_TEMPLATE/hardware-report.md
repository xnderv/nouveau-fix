---
name: Hardware report (another GF11x board)
about: You tried this on a different Fermi card — tell us what happened
---
**GPU / board** (`lspci -nn | grep -i vga`, PCI subsystem id):
**Kernel / distro:**
**Which driver:** stable (`stable/stable.sh install`) / lab (`lab/lab.sh install`)
**Boot parameters used** (e.g. `nouveau.gf114_board=1`):

**Result:** works / partially / hang / no change

**Output:**
```
bash stable/stable.sh status
dmesg | grep -iE "nouveau|GF11" | tail -n 60
```
**Your VBIOS pstate table** (`sudo cat /sys/kernel/debug/dri/0/pstate`):

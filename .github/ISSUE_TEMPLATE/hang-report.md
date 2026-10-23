---
name: Hang report
about: The system froze (black screen / Caps Lock dead) with this driver
---
**What you were doing** (screenshot, app launch, video, game, idle…):
**Driver:** stable / lab, `lab_pcie` value if lab.
**Time since boot / since resume from suspend:**

**After Reset, attach the output of:**
```
bash lab/blackbox.sh show 80          # if the black box was installed (lab/blackbox.sh install)
sudo ls /var/lib/systemd/pstore /sys/fs/pstore
journalctl -b -1 -k | grep -iE "nouveau|LAB" | tail -n 80
```
If the black box was not installed: `journalctl -b -1 | tail -n 100`.

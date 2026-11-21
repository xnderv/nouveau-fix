---
name: Hang report
about: The system froze (black screen / Caps Lock dead) with this driver
---
**What you were doing** (screenshot, app launch, video, game, idle…):
**Driver:** tester build (`cat /sys/module/nouveau/srcversion`), monitors connected:
**Time since boot / since resume from suspend:**

**After Reset, attach the output of:**
```
journalctl -b -1 -k | grep -iE "nouveau|LAB" | tail -n 120
sudo ls /var/lib/systemd/pstore /sys/fs/pstore
```
If the black box was not installed: `journalctl -b -1 | tail -n 100`.

@jfouquart — thank you for the card data, and sorry for the failed build: our README still pointed to an old package that only ever supported one GTX 560 Ti board. That's fixed now.

**Your GT 610M (GF119) turned out to be a special case, and since your report we've built support for it.** I want to be honest about what that means:

- GF119 is the last Fermi chip, with a newer power-management controller (the same generation as Kepler). The load counting our automatic governor relies on wasn't built for it — **now it is**, from the same source as for the other Fermi chips.
- Every GF119 VBIOS has only two performance levels (yours: 270/405 and 850/800 MHz), while all the cards we've tested have three. **The governor now takes the levels from the card's own table.**
- All of this was put together **from data**: your VBIOS, NVIDIA driver recordings of four other GF119 boards, and tests on our GTX 560 Ti, where we made sure nothing changed for three-level cards. **It has never run on GF119 hardware** — your laptop would be the first.

GF119 is in a great many laptops and office PCs, so this would help a lot of people besides yourself. To save you round trips, we made **one script that checks as much as possible in one go**.

**Steps** (laptop panel only, no external monitor; `sudo pacman -S mesa-utils` for glxgears if you don't have it):
```
git clone https://github.com/xnderv/nouveau-fix.git && cd nouveau-fix
bash lab/tester-build.sh
bash lab/tester-build.sh install
```
Reboot, then in a terminal on your desktop (about 7 minutes, keep other programs closed):
```
bash lab/tester-check.sh
```
It goes through both levels and measures the actual clocks with the card's own counters, switches 50 times between them, lets the automatic governor work under load (glxgears on the NVIDIA GPU) and at rest, and lets the NVIDIA GPU fall asleep and wake up. At the end it prints the path of one archive — please attach that here (it holds only the nouveau part of the kernel log, without your host name).

**If the laptop hangs:** hold the power button, boot again, and run `bash lab/tester-check.sh after-hang` — it collects the log of the boot that hung, which is the most useful thing we could get. `bash lab/tester-build.sh remove` undoes everything.

One more thing: I saw your nouveau-dkms fork. What you observed with it on this laptop (did the clocks change, any hangs) is welcome as an observation, but we don't use that project's code or notes — some of its findings come from disassembling NVIDIA's driver, and we keep this project clean of that ([docs/provenance.md](https://github.com/xnderv/nouveau-fix/blob/main/docs/provenance.md)).

Thanks — your card data is already useful either way.

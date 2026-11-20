@Q0AL — a quick update on the GT 730: **it's OK to try it now** (after the GTX 560, or instead of it — whichever is easier).

The build no longer sets a clock above what the VBIOS asks for. For the hub clock on your GT 730 it now does what the NVIDIA driver does on GF108: at the top level it feeds that clock from another PLL that runs at exactly the requested 1400 MHz, and checks the result with the card's own clock counter. If that path doesn't give the right clock, it puts everything back and uses the nearest divider below 1400 MHz instead — never above.

We can't check this path on our GTX 560 (its chip doesn't have that wire — the self-check correctly saw "nothing" there and fell back), so your card will be the first real run.

If you already built the earlier version: `git pull`, then build and install again ([docs/TESTING-core.md](https://github.com/xnderv/nouveau-fix/blob/main/docs/TESTING-core.md)); one monitor, as before. Besides the usual kernel log, please send the output of:
```
journalctl -k -b | grep -E "hub01-alt|беру снизу"
```
(the log text is partly in Russian — that's fine). It shows which of the two ways your card took.

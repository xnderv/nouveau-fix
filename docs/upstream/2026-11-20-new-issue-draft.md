**Title:** Fermi owners: automatic core reclocking from your card's VBIOS — testers wanted

nouveau leaves Fermi cards (GeForce 400/500 and many 600/700M) at their boot clocks. This project now has a lab build that **changes the core clocks automatically by load**, like the NVIDIA driver: up to the top level when the GPU is busy, down step by step when it's idle. All core clocks, sources and voltages are **computed from your card's own VBIOS** — nothing is tuned for one board.

**What it does not do yet:** change the memory clock (except on two recorded boards). Memory stays at your VBIOS boot clock, so the gain is mostly in compute; memory-heavy 3D gains less.

**Tested so far:** GTX 560 Ti (GF114): 10,000 core switches under load without a hang, and a night of 900 automatic switches without an error. Every other chip group — GF100, GF104, GF106, GF108, GF110, GF116, GF117, GF119 — is untested with this build. **Not tested with more than one monitor** — please use one.

**How to try it and what to send:** [docs/TESTING-core.md](https://github.com/xnderv/nouveau-fix/blob/main/docs/TESTING-core.md). It builds against your running kernel (checked on 6.12, 7.0, 7.2, 7.3) and is removed with one command.

Before installing, please post the output of `tools/card-report.sh` here (or open a "Card data" issue): it lets me check your VBIOS for the one known problem case (a clock that a divider can't make exactly; seen on one GF108 board).

I came across your hardware reports for Fermi cards in another reclocking project — thank you for posting them; reports like these are exactly what moves this work forward. This project takes a different route (everything derived from the card's VBIOS and from recordings of the NVIDIA driver), and if you'd like to contribute — a card report, an evening of testing, or a recording of the NVIDIA driver on your card — I'd be very grateful. Every chip group you cover is one we can't test ourselves: @chrisnoisel (GTX 560 Ti), @MegaRak64 (GTX 550 Ti), @aruncveli (820M), @Bonjour540 (410M), @kriho520m (GT 520M), @yhaenggi (NVS 4200M), @jfouquart (GT 610M), @RowerStudios (GF108).

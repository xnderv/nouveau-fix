# Archived: the first, board-specific "stable" driver (Oct 2026)

`0010-nouveau-gf114-reclock.patch` and the DKMS kit (`stable.sh`, `dkms.conf`, `prepare.sh`) reclocked only the reference
board (Gigabyte GTX 560 Ti, GF114) with values recorded on it. They were retired on 21 Nov 2026: the lab driver computes
everything from each card's VBIOS, and during testing we need its `lab_*` switches. **Do not install this on any card** — use
`lab/tester-build.sh` ([docs/TESTING-core.md](../../docs/TESTING-core.md)). Kept for history only; the scripts' own paths
point to the old locations and are not maintained.

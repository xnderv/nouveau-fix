#!/bin/bash
# ТОЛЬКО ЧТЕНИЕ регистров + переключение уровня через pstate (как memunit-probe.sh; регулятор возвращается). 28.10.
# Регистры PLL ядра, которыми на Kepler/Maxwell (открытый код NVIDIA gk20a/gm20b) делают плавное замедление и DVFS:
#   0x13700c CFG2, 0x137010/14 DVFS0/1 (gm20b), 0x137018 CFG3, 0x13701c NDIV_SLOWDOWN (gk20a), 0x137340 BYPASSCTRL_SYS (gm20b,
#   бит 0 — GPCPLL bypass/VCO), 0x1328a0 GPC_BCAST_NDIV_SLOWDOWN_DEBUG; для сравнения 0x137000/04 (CFG/COEFF), 0x137100 (SEL_VCO).
# Читаем на текущем уровне и после 07 → 0f → 03: регистр, который меняется вместе с уровнем, — живой (есть в железе GF114).
# Первое чтение 28.10 19:35 на уровне 03: всё 0, кроме 0x137340 = 1 (bypass?) и CFG/COEFF.
# bash ~/Home/nouveau-fix/lab/pll-ramp-probe.sh
set -u
PRM=/sys/module/nouveau/parameters
OUT=~/Home/nouveau-fix/results/pll-ramp-probe-$(date +%Y%m%d-%H%M%S).txt
echo "$(date +%T) $(uname -r) srcversion $(cat /sys/module/nouveau/srcversion 2>/dev/null)" | tee "$OUT"
PSF="$(sudo sh -c 'ls /sys/kernel/debug/dri/*/pstate' | head -n1)"
ac() { sudo sh -c "grep '^AC' '$PSF'" | sed 's/^AC: //'; }
rd() { sudo python3 -I - <<'PY'
import mmap, os, glob
d=[x for x in glob.glob('/sys/bus/pci/devices/*') if open(x+'/vendor').read().strip()=='0x10de' and open(x+'/class').read().startswith('0x03')][0]
fd=os.open(d+'/resource0', os.O_RDONLY|os.O_SYNC); m=mmap.mmap(fd, 16<<20, mmap.MAP_SHARED, mmap.PROT_READ)
w=lambda r: int.from_bytes(m[r:r+4],'little')
regs=[(0x137000,'CFG'),(0x137004,'COEFF'),(0x137100,'SEL_VCO'),(0x13700c,'CFG2'),(0x137010,'DVFS0'),(0x137014,'DVFS1'),(0x137018,'CFG3'),(0x13701c,'NDIV_SLOWDOWN'),(0x137340,'BYPASSCTRL'),(0x1328a0,'BCAST_NDIV_DBG')]
print('    ' + '  '.join(f'{n}={w(r):08x}' for r,n in regs))
PY
}
G0="$(cat $PRM/lab_gov)"; sudo sh -c "echo 0 > $PRM/lab_gov"
{ echo "$(date +%T) сейчас: $(ac)"; rd; } | tee -a "$OUT"
for lv in 07 0f 07 03; do sudo sh -c "echo $lv > '$PSF'"; sleep 3; { echo "$(date +%T) после $lv: $(ac)"; rd; } | tee -a "$OUT"; done
sudo sh -c "echo $G0 > $PRM/lab_gov"; echo "регулятор возвращён (lab_gov=$G0); копия: $OUT" | tee -a "$OUT"

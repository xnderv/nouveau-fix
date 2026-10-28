#!/bin/bash
# ТОЛЬКО ЧТЕНИЕ (28.10): регистры PLL ядра, которые на Kepler/Maxwell (открытый код NVIDIA gk20a/gm20b) служат плавному
# замедлению и DVFS: 0x13700c GPCPLL_CFG2, 0x137010/14 DVFS0/1 (gm20b), 0x137018 CFG3, 0x13701c NDIV_SLOWDOWN (gk20a),
# 0x137340 BYPASSCTRL_SYS (gm20b), 0x1328a0 GPC_BCAST_NDIV_SLOWDOWN_DEBUG; для сравнения 0x137000/04 (CFG/COEFF).
# Драйверы NVIDIA на Fermi их не трогают (записи 390/270); вопрос — есть ли они в железе GF114: осмысленные значения или
# нули/шум. bash ~/Home/nouveau-fix/lab/pll-ramp-probe.sh
sudo python3 -I - <<'PY'
import mmap, os, glob
d=[x for x in glob.glob('/sys/bus/pci/devices/*') if open(x+'/vendor').read().strip()=='0x10de' and open(x+'/class').read().startswith('0x03')][0]
fd=os.open(d+'/resource0', os.O_RDONLY|os.O_SYNC); m=mmap.mmap(fd, 16<<20, mmap.MAP_SHARED, mmap.PROT_READ)
w=lambda r: int.from_bytes(m[r:r+4],'little')
names={0x137000:'GPCPLL_CFG',0x137004:'GPCPLL_COEFF',0x13700c:'GPCPLL_CFG2 (gk20a)',0x137010:'GPCPLL_DVFS0 (gm20b)',0x137014:'GPCPLL_DVFS1 (gm20b)',0x137018:'GPCPLL_CFG3 (gk20a)',0x13701c:'GPCPLL_NDIV_SLOWDOWN (gk20a)',0x137340:'BYPASSCTRL_SYS (gm20b)',0x1328a0:'GPC_BCAST_NDIV_SLOWDOWN_DEBUG (gk20a)',0x1373c0:'счётчик частоты: настройка'}
for r in sorted(names):
    v1=w(r); v2=w(r); print(f"{r:06x} {v1:08x}{'' if v1==v2 else f' (второе чтение {v2:08x})'}  {names[r]}")
PY

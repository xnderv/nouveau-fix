#!/bin/bash
# ТОЛЬКО ЧТЕНИЕ (28.10): регистры теплового блока по именам из открытого кода NVIDIA для Tegra (hw_therm_gk20a.h, класс Г):
#   0x020130 therm_config2 (бит 31 grad_enable, бит 24 slowdown_factor_extended), 0x020160+4i therm_clk_slowdown (поле 16–21
#   idle_factor, код = 2·делитель − 2: 1 = /1.5, 2 = /2, 6 = /4, 0xe = /8; наши коды скобки 0xa = /6, 0x2 = /2),
#   0x0202c0 grad_stepping0 (бит 0 — плавное замедление включено), 0x0202c4 grad_stepping1 (биты 0–16 — длительность шага),
#   0x0202c8+4i grad_stepping_table (пять коэффициентов по 6 бит), 0x0203c0+4i clk_timing (бит 16 grad_slowdown),
#   0x020200+4i gate_ctrl, 0x0201e0/e4 — статус (наш «признак»). Ни один из наших драйверов эти регистры не пишет (записи
#   390, 270, GF106): значения — состояние после POST / по умолчанию. bash ~/Home/nouveau-fix/lab/therm-grad-probe.sh
OUT=~/Home/nouveau-fix/results/therm-grad-probe-$(date +%Y%m%d-%H%M%S).txt; echo "$(date +%T) $(uname -r) srcversion $(cat /sys/module/nouveau/srcversion 2>/dev/null)" | tee "$OUT"
sudo python3 -I - <<'PY' | tee -a "$OUT"
import mmap, os, glob
d=[x for x in glob.glob('/sys/bus/pci/devices/*') if open(x+'/vendor').read().strip()=='0x10de' and open(x+'/class').read().startswith('0x03')][0]
fd=os.open(d+'/resource0', os.O_RDONLY|os.O_SYNC); m=mmap.mmap(fd, 16<<20, mmap.MAP_SHARED, mmap.PROT_READ)
w=lambda r: int.from_bytes(m[r:r+4],'little')
names={0x020004:'CTRL_1',0x020130:'config2',0x020160:'clk_slowdown[0] GPC',0x020164:'clk_slowdown[1] hub',0x020168:'clk_slowdown[2]',0x02016c:'clk_slowdown[3]',
       0x0201e0:'статус[0]',0x0201e4:'статус[1]',0x0202c0:'grad_stepping0',0x0202c4:'grad_stepping1 (длительность шага)'}
for r in (0x020004,0x020130,0x020160,0x020164,0x020168,0x02016c,0x0201e0,0x0201e4,0x0202c0,0x0202c4):
    v=w(r); extra=''
    if r==0x020130: extra=f"  grad_enable={v>>31&1} extended={v>>24&1} байт2={v>>16&0xff:#x} байт1={v>>8&0xff:#x} байт0={v&0xff:#x}"
    if r in (0x020160,0x020164,0x020168,0x02016c): f=(v>>16)&0x3f; extra=f"  idle_factor={f} (/{(f+2)/2:g})"
    if r==0x0202c4: extra=f"  pdiv_duration={v&0x1ffff}"
    if r==0x0202c0: extra=f"  feature={v&1}"
    print(f"{r:06x} {v:08x}  {names[r]}{extra}")
print('grad_stepping_table (0x0202c8..):', ' '.join(f'{w(0x0202c8+4*i):08x}' for i in range(4)), '→ коэффициенты таблицы 0:', [ (w(0x0202c8)>>(6*k))&0x3f for k in range(5)])
print('clk_timing (0x0203c0..):', ' '.join(f'{w(0x0203c0+4*i):08x}' for i in range(4)), ' gate_ctrl (0x020200..):', ' '.join(f'{w(0x020200+4*i):08x}' for i in range(4)))
PY

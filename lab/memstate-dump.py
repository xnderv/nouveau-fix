#!/usr/bin/env python3
# СВЕРКА СОСТОЯНИЯ, часть 2 (на машине с картой, под любым драйвером): прочитать регистры из списка lab/trace-memstate.py
# три раза с паузой 50 мс и записать в файл. ТОЛЬКО ЧТЕНИЕ. Читаются лишь адреса из списка — те, к которым драйвер NVIDIA
# обращается сам (сплошные диапазоны читать нельзя: в блоке памяти есть порты, чтение которых меняет состояние).
#   sudo python3 -I lab/memstate-dump.py addrs.txt ВЫХОД.txt [метка]
import glob, mmap, os, struct, sys, time
addrs = [int(l.split()[0], 16) for l in open(sys.argv[1]) if l.strip() and not l.startswith('#')]
out, label = sys.argv[2], (sys.argv[3] if len(sys.argv) > 3 else '')
res = os.environ.get('MEMSTATE_RESOURCE')          # для проверки сценария без карты
if not res:
    dev = next((d for d in glob.glob('/sys/bus/pci/devices/*')
                if open(d + '/vendor').read().strip() == '0x10de' and open(d + '/class').read().startswith('0x03')), None)
    if not dev: sys.exit('видеокарта NVIDIA не найдена')
    res = dev + '/resource0'
fd = os.open(res, os.O_RDONLY | os.O_SYNC)
bar = mmap.mmap(fd, 16 << 20, mmap.MAP_SHARED, mmap.PROT_READ)
rd = lambda a: struct.unpack_from('<I', bar, a)[0]
passes = []
for i in range(3):
    passes.append([rd(a) for a in addrs]); time.sleep(0.05)
drv = next((os.path.basename(os.path.realpath(d + '/driver')) for d in glob.glob('/sys/bus/pci/devices/*')
            if os.path.exists(d + '/driver') and open(d + '/vendor').read().strip() == '0x10de' and open(d + '/class').read().startswith('0x03')), '?')
ac = next((l.strip() for f in glob.glob('/sys/kernel/debug/dri/*/pstate') for l in open(f) if l.startswith('AC')), '')
with open(out, 'w') as f:
    f.write(f'# снимок {time.strftime("%F %T")}; драйвер {drv}; {ac}; метка: {label}\n')
    for k, a in enumerate(addrs):
        v = [p[k] for p in passes]
        f.write('%06x %08x' % (a, v[0]) + ('' if v[0] == v[1] == v[2] else ' %08x %08x  # меняется' % (v[1], v[2])) + '\n')
print(f'{len(addrs)} регистров -> {out}; меняются между чтениями: {sum(1 for k in range(len(addrs)) if not passes[0][k] == passes[1][k] == passes[2][k])}')

#!/usr/bin/env python3
# ТОЛЬКО ЧТЕНИЕ: разовый снимок тех же регистров, что чёрный ящик снимает при зависании. Список адресов берётся из
# lab/blackbox.py (переменная SNAP), чтобы он был один: только регистры, которые есть на GF114, без «дыр».
# Нужен, когда ящик свой снимок не сделал: он снимает не чаще раза в 10 минут.
#   sudo python3 -I lab/grsnap.py МЕТКА > ФАЙЛ
#   python3 -I lab/grsnap.py --list            — показать список адресов, карту не трогать
import glob, mmap, os, struct, sys, time

src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'blackbox.py'), encoding='utf-8').read()
i = src.find('SNAP = ['); j = src.find('\ndef snapshot', i)
if i < 0 or j < 0:
    sys.exit('В lab/blackbox.py не найден список SNAP')
ns = {}
exec(src[i:j], {'range': range}, ns)
SNAP = ns['SNAP']

if len(sys.argv) > 1 and sys.argv[1] == '--list':
    for grp, regs in SNAP:
        print(f'{grp}: {len(regs)} — ' + ' '.join(f'{a:06x}' for a in regs))
    print('всего', sum(len(r) for _, r in SNAP))
    sys.exit(0)

dev = next((d for d in glob.glob('/sys/bus/pci/devices/*')
            if open(d + '/vendor').read().strip() == '0x10de' and open(d + '/class').read().startswith('0x03')), None)
if not dev:
    sys.exit('Видеокарта NVIDIA не найдена')
fd = os.open(dev + '/resource0', os.O_RDONLY | os.O_SYNC)
bar = mmap.mmap(fd, 16 << 20, mmap.MAP_SHARED, mmap.PROT_READ)
print(f'### снимок регистров {time.strftime("%F %T")}: {sys.argv[1] if len(sys.argv) > 1 else "-"}')
for grp, regs in SNAP:
    print(f'## {grp}')
    for a in regs:
        try:
            v = f'{struct.unpack_from("<I", bar, a)[0]:08x}'
        except Exception as e:
            v = f'err {e}'
        print(f'{a:06x} {v}')

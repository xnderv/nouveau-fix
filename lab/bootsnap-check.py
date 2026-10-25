#!/usr/bin/env python3
# ПРОВЕРКА перед установкой сборки со снимком при загрузке (lab_boot_snap): читает из пользовательского пространства ровно
# те адреса, что читает lab_boot_snapshot() в патче lab/0002 (список берётся из самого патча), и сообщает, если какой-то
# регистр отвечает ошибкой шины PRIV (0xbadf…) или чтение не проходит. Только чтение.
# Запуск: sudo python3 ~/Home/nouveau-fix/lab/bootsnap-check.py
import glob, mmap, os, re, struct, sys

patch = os.path.join(os.path.dirname(os.path.abspath(__file__)), '0002-LAB-fermi-reclock-instrumented.patch')
src = open(patch, encoding='utf-8').read()
body = src[src.index('+lab_boot_snapshot(struct nvkm_clk *base)'):]
body = body[:body.index('+	static int n;')]
groups = re.findall(r'static const u32 (\w+)\[\] = \{(.*?)\};', body.replace('\n+', ' '), re.S)
if not groups:
    sys.exit('В патче не найден список адресов lab_boot_snapshot')

dev = None
for d in glob.glob('/sys/bus/pci/devices/*'):
    try:
        if open(d + '/vendor').read().strip() == '0x10de' and open(d + '/class').read().startswith('0x03'):
            dev = d
            break
    except OSError:
        pass
if not dev:
    sys.exit('Видеокарта NVIDIA не найдена')
fd = os.open(dev + '/resource0', os.O_RDONLY | os.O_SYNC)
bar = mmap.mmap(fd, 16 << 20, mmap.MAP_SHARED, mmap.PROT_READ)
rd = lambda a: struct.unpack_from('<I', bar, a)[0]

bad = total = 0
for name, lst in groups:
    addrs = [int(x, 16) for x in re.findall(r'0x([0-9a-f]+)', lst)]
    out = []
    for a in addrs:
        v = rd(a); total += 1
        flag = ''
        if (v & 0xfff00000) == 0xbad00000:
            flag = ' ⚠PRIV'; bad += 1
        out.append(f'{a:06x}={v:08x}{flag}')
    print(f'{name:6} ({len(addrs):2}): ' + ' '.join(out))
print(f'\nПрочитано {total} регистров, ответов с ошибкой шины: {bad}' + (' — можно ставить' if bad == 0 else ' — НЕ ставить, показать ассистенту'))

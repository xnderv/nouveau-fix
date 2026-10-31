#!/usr/bin/env python3
# Распаковка архивов tpu-bulk-NN.tar (выгрузка TechPowerUp из встроенного браузера, 30.10) в архив образов по поколениям:
# ~/Home/nouveau-archive/tpu-vbios/2026-10-30-<fermi|tesla|nv4x>/ + manifest.csv (id, файл, sha256, размер, адрес, модель, PCI id
# из образа). Проверки: подпись 55 AA, размер как в manifest.tsv архива. Образы — данные, ничего не запускается; архив после
# успешной распаковки удаляется. Запуск: python3 -I tools/tpu-unbundle.py [~/Downloads/tpu-bulk-*.tar ...]
import csv, glob, hashlib, io, os, struct, sys, tarfile
BASE = os.path.expanduser('~/Home/nouveau-archive/tpu-vbios')
tars = sys.argv[1:] or sorted(glob.glob(os.path.expanduser('~/Downloads/tpu-bulk-*.tar')))
for tp in tars:
    tf = tarfile.open(tp)
    names = {m.name: m for m in tf.getmembers() if m.isfile()}
    man = tf.extractfile(names.pop('manifest.tsv')).read().decode().strip().split('\n')
    ok = bad = 0
    for line in man:
        tid, fname, size, fam, model, url = line.split('\t')
        m = names.get(fname)
        b = tf.extractfile(m).read() if m else b''
        if not b or len(b) != int(size) or b[:2] != b'\x55\xaa':
            bad += 1; print('  пропуск', fname, len(b)); continue
        pr = struct.unpack_from('<H', b, 0x18)[0]
        pci = f"{struct.unpack_from('<H', b, pr + 4)[0]:04x}:{struct.unpack_from('<H', b, pr + 6)[0]:04x}" if b[pr:pr + 4] == b'PCIR' else '?'
        d = os.path.join(BASE, f'2026-10-30-{fam}'); os.makedirs(d, exist_ok=True)
        mp = os.path.join(d, 'manifest.csv'); new = not os.path.exists(mp)
        out = os.path.join(d, fname)
        if not os.path.exists(out):
            open(out, 'wb').write(b)
            with open(mp, 'a', newline='') as f:
                w = csv.writer(f)
                if new: w.writerow(['id', 'file', 'sha256', 'size', 'source', 'model', 'pci'])
                w.writerow([tid, fname, hashlib.sha256(b).hexdigest(), len(b), url, model, pci])
        ok += 1
    print(f'{os.path.basename(tp)}: образов {ok}, отброшено {bad}')
    if bad == 0: os.remove(tp)

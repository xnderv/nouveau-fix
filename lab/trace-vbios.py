#!/usr/bin/env python3
# VBIOS ПЛАТ С ТРАССАМИ (30.10): у каких плат internal vbios repo с трассами NVIDIA рядом нет образа VBIOS, и сборка образа
# из самой трассы — драйвер NVIDIA при старте читает VBIOS (окно PROM 0x300000 или копию в видеопамяти через окно PRAMIN
# 0x700000, база окна — запись в 0x001700; чтения шириной 1/2/4 байта). Участники обезличены (у1, у2 … по порядку), пути
# не выводятся. Класс В (данные VBIOS из чужой записи).
#   python3 -I lab/trace-vbios.py list [c0 df]          — пары (чип, участник) с трассами: есть ли VBIOS, плата по PCI
#   python3 -I lab/trace-vbios.py extract КАТАЛОГ [c0 df] — собрать образы из трасс плат без VBIOS; на платах с VBIOS — сверка
# Проверено 30.10 на платах с образом в базе: из PROM — побайтно равен образу из базы (GF100, 0 различий); из видеопамяти —
# та же версия, но 32–36 байт другие (поля, которые VBIOS правит в своей копии при старте). Копия из VRAM — не дамп ПЗУ.
import collections, hashlib, os, re, subprocess, sys

DB = os.path.expanduser('~/Home/nouveau-archive/nouveau_vbios_trace')

def boards(lo, hi):
    files = subprocess.run(['git', '-C', DB, 'ls-files', '-z'], capture_output=True, text=True).stdout.split('\0')
    g = collections.defaultdict(lambda: {'tr': [], 'vb': []})
    for p in files:
        parts = p.split('/')
        m = re.fullmatch(r'nv([0-9a-f]+)t?', parts[0])
        if not m or len(parts) < 3:
            continue
        b = parts[-1].lower()
        if re.search(r'mmio|trace|downclock|reclock', b) and not b.endswith('traces.tar.xz') and 'crap' not in b:
            g[(parts[0], parts[1])]['tr'].append(p)
        elif re.search(r'\.(rom|bin)$|vbios', b) and not b.endswith('.eml'):
            g[(parts[0], parts[1])]['vb'].append(p)
    # номера участников не зависят от запрошенного диапазона: сначала Fermi (c0–df), потом остальные
    num = lambda chip: int(chip[2:].rstrip('t'), 16)
    who = {}
    for fermi in (True, False):
        for (chip, c), v in sorted(g.items()):
            if v['tr'] and (0xc0 <= num(chip) <= 0xdf) == fermi:
                who.setdefault(c, 'у%d' % (len(who) + 1))
    for (chip, c), v in sorted(g.items()):
        if v['tr'] and lo <= num(chip) <= hi:
            yield chip, who[c], v['tr'], v['vb']

def stream(path):
    head = open(path, 'rb').read(6)
    if head.startswith(b'\xfd7zXZ'):
        inner = subprocess.run(f"xz -dc '{path}' | head -c 6", shell=True, capture_output=True).stdout
        cmd = f"xz -dc '{path}'" + (" | xz -dc" if inner.startswith(b'\xfd7zXZ') else '')
    else:
        cmd = f"cat '{path}'"
    return subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout

def scan(path):
    """Зеркало PCI-конфигурации (0x088000–0x08803f, первые чтения) и байты, прочитанные в окнах PROM и PRAMIN."""
    cfg, mem, base, bar = {}, {'PROM': {}, 'VRAM': {}}, 0, None
    for raw in stream(path):
        if raw.startswith(b'MAP '):
            f = raw.split()
            if bar is None and len(f) > 5 and int(f[5], 16) == 0x1000000:
                bar = int(f[3], 16)
            continue
        if bar is None or not (raw.startswith(b'W ') or raw.startswith(b'R ')):
            continue
        f = raw.split()
        if len(f) < 6:
            continue
        w, a, v = int(f[1]), int(f[4], 16) - bar, int(f[5], 16)
        if raw[0] == ord('W'):
            if a == 0x001700:
                base = v << 16
            continue
        if 0x088000 <= a < 0x088040:
            cfg.setdefault(a, v)
            continue
        if 0x300000 <= a < 0x400000:
            m, o = mem['PROM'], a - 0x300000
        elif 0x700000 <= a < 0x800000:
            m, o = mem['VRAM'], base + a - 0x700000
        else:
            continue
        for i in range(w):
            m.setdefault(o + i, (v >> (8 * i)) & 0xff)
    return cfg, mem

def version(b):
    m = re.search(rb'Version (\d\d\.\d\d\.[0-9A-Fa-f.]+)', b)
    return m.group(1).decode() if m else '?'

def image(mem):
    """Лучший полный образ (55 AA, размер из байта 2, без пропусков) или None."""
    for name, m in mem.items():
        for s in sorted(k for k in m if m[k] == 0x55 and m.get(k + 1) == 0xaa):
            size = m.get(s + 2, 0) * 512
            if size >= 4096 and all(s + i in m for i in range(size)):
                return name, bytes(m[s + i] for i in range(size))
    return None

def board(cfg):
    i, s = cfg.get(0x088000, 0), cfg.get(0x08802c, 0)
    return f'{i & 0xffff:04x}:{i >> 16:04x} плата {s & 0xffff:04x}:{s >> 16:04x}' if i else 'id не прочитан'

def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else 'list'
    out = sys.argv[2] if mode == 'extract' else None
    rest = sys.argv[3:] if mode == 'extract' else sys.argv[2:]
    lo, hi = (int(rest[0], 16), int(rest[1], 16)) if len(rest) >= 2 else (0xc0, 0xdf)
    if out:
        os.makedirs(out, exist_ok=True)
        man = open(os.path.join(out, 'manifest.csv'), 'a')
    for chip, who, trs, vbs in boards(lo, hi):
        if mode == 'list':
            print(f'{chip:6s} {who:5s} трасс {len(trs)}  VBIOS в базе {len(vbs)}', flush=True)
            continue
        cfg, mem = scan(os.path.join(DB, trs[0]))
        got = image(mem)
        line = f'{chip} {who}: {board(cfg)}; '
        if not got:
            print(line + 'образа в трассе нет (вероятно, VBIOS взят из ACPI)', flush=True)
            continue
        src, b = got
        line += f'образ из {src}: {len(b)} байт, версия {version(b)}, сумма {sum(b) & 0xff:#04x}'
        if vbs:
            ref = open(os.path.join(DB, vbs[0]), 'rb').read()
            n = min(len(b), len(ref))
            d = sum(1 for i in range(n) if b[i] != ref[i])
            print(line + f'; сверка с VBIOS из базы ({len(ref)} байт, версия {version(ref)}): различных байт {d}', flush=True)
            continue
        name = f'{chip}-{who}-{version(b)}.rom'
        open(os.path.join(out, name), 'wb').write(b)
        man.write(f'{name},{chip},{who},{board(cfg)},{src},{len(b)},{hashlib.sha256(b).hexdigest()}\n'); man.flush()
        print(line + f' → {name}', flush=True)

if __name__ == '__main__':
    main()

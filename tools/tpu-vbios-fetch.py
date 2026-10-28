#!/usr/bin/env python3
# Выгрузка небольшой целевой выборки образов VBIOS из коллекции TechPowerUp — по письменному разрешению главного
# редактора TechPowerUp (W1zzard) от 28.10.2026: «присланными файлами пользоваться можно; дальше — небольшие целевые
# подмножества базы для исследования, не всё». Запускает только человек (robots.txt сайта запрещает агентам Claude любой
# доступ; разрешение выдано автору проекта, поэтому скрипт представляется честно — именем проекта и ссылкой на разрешение).
# Вежливость: один поток, пауза между запросами (по умолчанию 3 с), остановка при 403/429, повтор не чаще раза в минуту.
#
#   python3 -I tools/tpu-vbios-fetch.py КАТАЛОГ --model "GTX 560 Ti" [--max 400] [--delay 3]
#
# В КАТАЛОГ кладутся *.rom и manifest.csv (id, slug, url, sha256, размер, дата, страница-источник). Повторный запуск
# докачивает недостающее. Каталог держать ВНЕ репозитория (~/Home/nouveau-archive/tpu-vbios/...): образы не публикуем.
import sys, os, re, csv, time, hashlib, argparse, urllib.request, urllib.parse, urllib.error, html

BASE = 'https://www.techpowerup.com'
UA = ('Mozilla/5.0 (compatible; nouveau-fix-vbios-research/1.0; +https://github.com/xnderv/nouveau-fix; '
      'written permission of TechPowerUp editor-in-chief, 2026-10-28)')

LAST = {}   # заголовки последнего ответа — для разбора отказов

def get(url, delay, binary=False, tries=3, referer=None):
    for i in range(tries):
        time.sleep(delay)
        h = {'User-Agent': UA, 'Accept': '*/*'}
        if referer: h['Referer'] = referer          # ссылка на .rom открывается со страницы образа — так и представляемся
        req = urllib.request.Request(url, headers=h)
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                data = r.read()
                LAST.clear(); LAST.update({'status': r.status, 'url': r.geturl(), 'type': r.headers.get('Content-Type', '')})
                return data if binary else data.decode('utf-8', 'replace')
        except urllib.error.HTTPError as e:
            if e.code in (403, 429):
                sys.exit(f'СТОП: сервер ответил {e.code} на {url} — дальше не ходим, напишите W1zzard или подождите')
            print(f'  HTTP {e.code} на {url}, попытка {i+1}/{tries}', file=sys.stderr)
        except Exception as e:  # сеть
            print(f'  ошибка {e} на {url}, попытка {i+1}/{tries}', file=sys.stderr)
        time.sleep(60)
    return None

def listing(model, delay):
    """Список (id, slug, текст строки) по фильтру модели; страницы до тех пор, пока появляются новые id."""
    seen, out, page = set(), [], 1
    while True:
        q = {'architecture': 'NVIDIA', 'model': model}
        if page > 1: q['page'] = page
        url = BASE + '/vgabios/?' + urllib.parse.urlencode(q)
        text = get(url, delay)
        if text is None: break
        new = 0
        for m in re.finditer(r'href="/vgabios/(\d+)/([^"/?#]+)"', text):
            bid, slug = m.group(1), m.group(2)
            if slug.endswith('.rom') or bid in seen: continue
            seen.add(bid); out.append((bid, slug, url)); new += 1
        print(f'страница {page}: новых {new}, всего {len(out)}')
        if new == 0: break
        page += 1
    return out

def rom_link(bid, slug, delay):
    text = get(f'{BASE}/vgabios/{bid}/{slug}', delay)
    if text is None: return None
    m = re.search(r'href="(/vgabios/%s/[^"]+\.rom)"' % bid, text)
    return BASE + html.unescape(m.group(1)) if m else None

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('outdir'); ap.add_argument('--model', required=True)
    ap.add_argument('--max', type=int, default=400); ap.add_argument('--delay', type=float, default=3.0)
    a = ap.parse_args()
    os.makedirs(a.outdir, exist_ok=True)
    man = os.path.join(a.outdir, 'manifest.csv')
    have = set()
    if os.path.exists(man):
        with open(man, newline='') as f:
            for row in csv.DictReader(f): have.add(row['id'])
    items = listing(a.model, a.delay)
    if len(items) > a.max:
        sys.exit(f'СТОП: в выборке {len(items)} образов, а предел --max {a.max}: это уже не «небольшое подмножество», сузьте фильтр или поднимите предел осознанно')
    todo = [it for it in items if it[0] not in have]
    print(f'модель «{a.model}»: в коллекции {len(items)}, уже есть {len(items)-len(todo)}, качать {len(todo)}, пауза {a.delay} с')
    newfile = not os.path.exists(man)
    with open(man, 'a', newline='') as f:
        w = csv.writer(f)
        if newfile: w.writerow(['id', 'slug', 'url', 'sha256', 'size', 'date', 'listing'])
        for n, (bid, slug, src) in enumerate(todo, 1):
            link = rom_link(bid, slug, a.delay)
            if not link: print(f'  {bid} {slug}: ссылки .rom не нашёл, пропуск'); continue
            data = get(link, a.delay, binary=True, referer=f'{BASE}/vgabios/{bid}/{slug}')
            if not data: print(f'  {bid}: не скачалось'); continue
            if data[:2] != b'\x55\xaa':
                if b'bot check' in data[:4096].lower(): print('  сервер показал проверку на бота — её не обходим')
                dbg = os.path.join(a.outdir, f'debug-{bid}.bin'); open(dbg, 'wb').write(data[:65536])
                sys.exit(f'СТОП: {link} вернул не образ ROM (нет 55 AA): статус {LAST.get("status")}, тип {LAST.get("type")}, '
                         f'конечный адрес {LAST.get("url")}, {len(data)} байт; начало сохранено в {dbg}. Дальше не ходим, разбираемся.')
            name = f'{bid}-{os.path.basename(urllib.parse.urlparse(link).path)}'
            with open(os.path.join(a.outdir, name), 'wb') as g: g.write(data)
            w.writerow([bid, slug, link, hashlib.sha256(data).hexdigest(), len(data), time.strftime('%Y-%m-%d %H:%M:%S'), src]); f.flush()
            print(f'  {n}/{len(todo)} {name} {len(data)} байт')
    print('ГОТОВО:', a.outdir)

if __name__ == '__main__':
    main()

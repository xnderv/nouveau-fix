#!/usr/bin/env python3
# Письма по рассылке nouveau и ответы разработчиков в ящике (IMAP Яндекса, только чтение, флаги не меняются).
# Пароль (пароль приложения Яндекса) вводится в терминале при запуске и нигде не сохраняется.
#   python3 tools/mail-check.py [дней=3] [слова через запятую=freedesktop,Fermi,nouveau] [файл для копии вывода]
# Ищет слово в From, To, Cc и Subject; цитаты (строки с >) сворачиваются.
import imaplib, email, getpass, sys, datetime, re
from email.header import decode_header, make_header
days = int(sys.argv[1]) if len(sys.argv) > 1 else 3
words = (sys.argv[2] if len(sys.argv) > 2 else 'freedesktop,Fermi,nouveau').split(',')
out = open(sys.argv[3], 'w') if len(sys.argv) > 3 else None
_print = print
def print(*a, **k):
    _print(*a, **k)
    if out: _print(*a, **{**k, 'file': out}); out.flush()
user = 'xnderv@yandex.com'
pw = getpass.getpass(f'Пароль приложения Яндекс для {user} (не отображается): ')
M = imaplib.IMAP4_SSL('imap.yandex.ru', 993); M.login(user, pw)
since = (datetime.date.today() - datetime.timedelta(days=days)).strftime('%d-%b-%Y')
def dec(s):
    try: return str(make_header(decode_header(s or '')))
    except Exception: return s or ''
def utf7(b):
    try: return b.decode('imap4-utf-7')
    except Exception: return b.decode('latin1')
typ, boxes = M.list()
names = []
for b in boxes:
    m = re.search(rb'"([^"]+)"$|(\S+)$', b); raw = (m.group(1) or m.group(2))
    nm = raw.decode('latin1'); names.append((nm, utf7(raw)))
print('папки:', ', '.join(h for _, h in names))
for raw, human in names:
    if not any(k in human.lower() for k in ('inbox', 'spam', 'спам', 'входящ')): continue
    if M.select(f'"{raw}"', readonly=True)[0] != 'OK': continue
    ids = set()
    for w in words:
        for fld in ('FROM', 'TO', 'CC', 'SUBJECT'):
            typ, data = M.search(None, f'(SINCE {since})', fld, f'"{w}"')
            if data and data[0]: ids.update(data[0].split())
    ids = sorted(ids, key=int)
    print(f'\n=== {human}: писем со словами {words} за {days} дн.: {len(ids)}')
    for i in ids[-25:]:
        typ, msg = M.fetch(i, '(BODY.PEEK[])'); e = email.message_from_bytes(msg[0][1])
        print(f"--- {dec(e['Date'])} | от {dec(e['From'])} | кому {dec(e['To'])}\n    тема: {dec(e['Subject'])}")
        body = ''
        for part in e.walk():
            if part.get_content_type() == 'text/plain':
                body = part.get_payload(decode=True).decode(part.get_content_charset() or 'utf-8', 'replace'); break
        lines, q = [], 0
        for l in body.strip().splitlines():
            if l.lstrip().startswith('>'): q += 1; continue
            if q: lines.append(f'[> {q} строк цитаты]'); q = 0
            lines.append(l)
        if q: lines.append(f'[> {q} строк цитаты]')
        print(f"    Message-ID: {e['Message-ID']}  In-Reply-To: {e['In-Reply-To']}")
        print('    ' + '\n    '.join(lines[:80]))
M.logout()

#!/usr/bin/env python3
# Письма по рассылке nouveau и ответы разработчиков в ящике (IMAP Яндекса, только чтение, флаги не меняются).
# Пароль (пароль приложения Яндекса) вводится в терминале при запуске и нигде не сохраняется.
#   python3 tools/mail-check.py [дней=3] [слова через запятую=freedesktop,Fermi,nouveau | ALL] [файл для копии вывода]
# Папки: входящие, спам, отправленные.
# Ищет слово в From, To, Cc и Subject; цитаты (строки с >) сворачиваются.
import imaplib, email, getpass, sys, datetime, re
from email.header import decode_header, make_header
from html.parser import HTMLParser
class _H2T(HTMLParser):
    # HTML письма -> текст; содержимое <blockquote> помечается '> ', чтобы цитаты сворачивались
    def __init__(self): super().__init__(); self.out, self.q, self.skip = [''], 0, 0
    def handle_starttag(self, t, a):
        if t in ('style', 'script', 'head'): self.skip += 1
        if t == 'blockquote': self.q += 1
        if t in ('br', 'p', 'div', 'li', 'tr', 'blockquote'): self.out.append('')
    def handle_endtag(self, t):
        if t in ('style', 'script', 'head'): self.skip = max(0, self.skip - 1)
        if t == 'blockquote': self.q = max(0, self.q - 1); self.out.append('')
        if t in ('p', 'div', 'li', 'tr'): self.out.append('')
    def handle_data(self, d):
        if self.skip: return
        if self.q and not self.out[-1]: self.out[-1] = '> '
        self.out[-1] += d
def html2text(h):
    x = _H2T(); x.feed(h); return re.sub(r'\n{3,}', '\n\n', '\n'.join(l.rstrip() for l in x.out))
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
    if not any(k in human.lower() for k in ('inbox', 'spam', 'спам', 'входящ', 'sent', 'отправ')): continue
    if M.select(f'"{raw}"', readonly=True)[0] != 'OK': continue
    ids = set()
    if words == ['ALL']:
        typ, data = M.search(None, f'(SINCE {since})')
        if data and data[0]: ids.update(data[0].split())
    for w in (words if words != ['ALL'] else []):
        for fld in ('FROM', 'TO', 'CC', 'SUBJECT'):
            typ, data = M.search(None, f'(SINCE {since})', fld, f'"{w}"')
            if data and data[0]: ids.update(data[0].split())
    ids = sorted(ids, key=int)
    print(f'\n=== {human}: писем со словами {words} за {days} дн.: {len(ids)}')
    for i in ids[-60:]:
        typ, msg = M.fetch(i, '(BODY.PEEK[])'); e = email.message_from_bytes(msg[0][1])
        print(f"--- {dec(e['Date'])} | от {dec(e['From'])} | кому {dec(e['To'])}\n    тема: {dec(e['Subject'])}")
        body, html = '', ''
        for part in e.walk():
            ct = part.get_content_type()
            if ct == 'text/plain' and not body:
                body = part.get_payload(decode=True).decode(part.get_content_charset() or 'utf-8', 'replace')
            elif ct == 'text/html' and not html:
                html = part.get_payload(decode=True).decode(part.get_content_charset() or 'utf-8', 'replace')
        if not body.strip() and html:
            body = html2text(html)
        lines, q = [], 0
        for l in body.strip().splitlines():
            if l.lstrip().startswith('>'): q += 1; continue
            if q: lines.append(f'[> {q} строк цитаты]'); q = 0
            lines.append(l)
        if q: lines.append(f'[> {q} строк цитаты]')
        print(f"    Message-ID: {e['Message-ID']}  In-Reply-To: {e['In-Reply-To']}")
        print('    ' + '\n    '.join(lines[:80]))
M.logout()

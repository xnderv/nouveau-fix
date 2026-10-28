#!/usr/bin/env python3
# Письма от списка рассылки nouveau в ящике (IMAP Яндекса, только чтение, флаги не меняются).
# Пароль (пароль приложения Яндекса) вводится в терминале при запуске и нигде не сохраняется.
#   python3 tools/mail-check.py [дней=3] [слово поиска=freedesktop]
import imaplib, email, getpass, sys, datetime, re
from email.header import decode_header, make_header
days = int(sys.argv[1]) if len(sys.argv) > 1 else 3
word = sys.argv[2] if len(sys.argv) > 2 else 'freedesktop'
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
    typ, data = M.search(None, f'(SINCE {since})', 'OR', f'FROM "{word}"', f'SUBJECT "{word}"')
    ids = data[0].split() if data and data[0] else []
    print(f'\n=== {human}: писем с «{word}» за {days} дн.: {len(ids)}')
    for i in ids[-12:]:
        typ, msg = M.fetch(i, '(BODY.PEEK[])'); e = email.message_from_bytes(msg[0][1])
        print(f"--- {dec(e['Date'])} | от {dec(e['From'])} | кому {dec(e['To'])}\n    тема: {dec(e['Subject'])}")
        body = ''
        for part in e.walk():
            if part.get_content_type() == 'text/plain':
                body = part.get_payload(decode=True).decode(part.get_content_charset() or 'utf-8', 'replace'); break
        print('    ' + '\n    '.join(body.strip().splitlines()[:14]))
M.logout()

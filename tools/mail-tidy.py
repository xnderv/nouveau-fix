#!/usr/bin/env python3
# Уборка писем рассылки nouveau в ящике (IMAP Яндекса). Пароль приложения вводится в терминале и нигде не сохраняется.
#   python3 -I tools/mail-tidy.py            — только список: какие письма рассылки «наши», какие «чужие» (ничего не меняет)
#   python3 -I tools/mail-tidy.py --apply    — «чужие» переносятся в Корзину (не удаляются: вернуть можно из Корзины)
# «Наше»: письмо от нас; мы в «Кому»/«Копии»; ответ в ветке нашего письма (In-Reply-To/References содержат идентификатор
# нашего письма — из «Отправленных» или вида …-xnderv@yandex.com от git send-email). «Чужое»: остальное с List-Id рассылки nouveau.
# Папки: «Входящие» и «Архив». Флаги прочтения не меняются.
import email, getpass, imaplib, re, sys
from email.header import decode_header, make_header
USER = 'xnderv@yandex.com'
LIST = 'nouveau.lists.freedesktop.org'
APPLY = '--apply' in sys.argv
def dec(s):
    try: return str(make_header(decode_header(s or '')))
    except Exception: return s or ''
def utf7(b):
    try: return b.decode('imap4-utf-7')
    except Exception: return b.decode('latin1')
M = imaplib.IMAP4_SSL('imap.yandex.ru', 993)
M.login(USER, getpass.getpass(f'Пароль приложения Яндекс для {USER} (не отображается): '))
names = {}
for b in M.list()[1]:
    m = re.search(rb'"([^"]+)"$|(\S+)$', b); raw = (m.group(1) or m.group(2)); names[utf7(raw).lower()] = raw.decode('latin1')
def folder(*keys):
    return next((raw for h, raw in names.items() if any(k in h for k in keys)), None)
INBOX, ARCH, SENT, TRASH = folder('inbox', 'входящ'), folder('archive', 'архив'), folder('sent', 'отправ'), folder('trash', 'корзин', 'удал')
# наши идентификаторы писем — из «Отправленных»
ours = set()
M.select(f'"{SENT}"', readonly=True)
typ, d = M.uid('SEARCH', None, 'ALL')
for uid in d[0].split()[-2000:]:
    typ, h = M.uid('FETCH', uid, '(BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)])')
    mid = email.message_from_bytes(h[0][1]).get('Message-ID', '').strip()
    if mid: ours.add(mid)
def is_ours(msg):
    frm, to, cc = (msg.get(k, '') for k in ('From', 'To', 'Cc'))
    if USER in frm.lower(): return 'наше письмо'
    if USER in (to + ' ' + cc).lower(): return 'адресовано нам'
    refs = set(re.findall(r'<[^>]+>', (msg.get('In-Reply-To', '') + ' ' + msg.get('References', ''))))
    if refs & ours or any('xnderv@yandex.com' in r for r in refs): return 'ответ в нашей ветке'
    return None
report = []; move = {}
for f in (INBOX, ARCH):
    if not f: continue
    M.select(f'"{f}"', readonly=not APPLY)
    typ, d = M.uid('SEARCH', None, 'HEADER', 'List-Id', LIST)
    for uid in d[0].split():
        typ, h = M.uid('FETCH', uid, '(BODY.PEEK[HEADER.FIELDS (FROM TO CC SUBJECT DATE MESSAGE-ID IN-REPLY-TO REFERENCES LIST-ID)])')
        msg = email.message_from_bytes(h[0][1])
        why = is_ours(msg)
        report.append((utf7(f.encode('latin1')), msg.get('Date', '')[:25], dec(msg.get('From', ''))[:30], dec(msg.get('Subject', ''))[:90], why))
        if not why: move.setdefault(f, []).append(uid)
keep = [r for r in report if r[4]]; drop = [r for r in report if not r[4]]
print(f'Письма рассылки {LIST}: всего {len(report)}, наших {len(keep)}, чужих {len(drop)}')
print('\n=== ОСТАЮТСЯ (наши):')
for r in keep: print(f'  [{r[0]}] {r[1]} | {r[2]} | {r[3]}  — {r[4]}')
print('\n=== В КОРЗИНУ (чужие):' if APPLY else '\n=== ПОЙДУТ В КОРЗИНУ при --apply (чужие):')
for r in drop: print(f'  [{r[0]}] {r[1]} | {r[2]} | {r[3]}')
if APPLY and move:
    for f, uids in move.items():
        M.select(f'"{f}"', readonly=False)
        s = b','.join(uids).decode()
        typ, _ = M.uid('COPY', s, f'"{TRASH}"')
        if typ != 'OK': print('СТОП: не удалось скопировать в Корзину, ничего не трогаю'); break
        M.uid('STORE', s, '+FLAGS', r'(\Deleted)')
        try: M.uid('EXPUNGE', s)          # только эти письма (UIDPLUS); копии уже лежат в Корзине
        except Exception:                  # общий EXPUNGE не делаем: он стёр бы и чужие письма с пометкой «удалено»
            print(f'Сервер не умеет удалять по номерам: в папке {f} письма помечены, но остались; копии — в Корзине'); continue
    print(f'\nПеренесено в Корзину: {len(drop)}. Вернуть — из Корзины в почте.')
M.logout()

#!/bin/bash
# СТУПЕНЬ 2: решение о режимах в драйвере (патч 0004, параметр lab_gov).
#   govtest.sh shadow [МИН] — шаг 2а, ТЕНЬ: драйвер считает решения по ответам прошивки PMU и только пишет
#                     в журнал, куда бы переключил; переключает по-прежнему служба. Сначала 2 цикла
#                     нагрузка/покой (окно glmark2), потом МИН минут (по умолчанию 10) обычной работы.
#                     В конце — сверка: каждое переключение службы против решения драйвера (±3 с).
#   govtest.sh shadow [МИН] log — то же + ПОСЕКУНДНАЯ запись загрузки у драйвера и у службы
#                     (служба пишет, пока есть файл /run/gpu-autoclock.debug); при расхождении
#                     показываются 35 секунд перед ним с обеих сторон.
#   govtest.sh act [МИН] — шаг 2б: драйвер ПЕРЕКЛЮЧАЕТ САМ (lab_gov=2). Служба на время опыта
#                     ОСТАНОВЛЕНА (её параметры остаются в драйвере до перезагрузки). 2 цикла нагрузка/покой,
#                     потом МИН минут (по умолчанию 10) обычной работы. Проверка: каждое решение выполнено
#                     (режим стал нужным, ret 0), ошибок нет. В конце регулятор выключается, служба запускается.
#   govtest.sh off   — выключить регулятор и опрос (и запустить службу, если она остановлена).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; KIT="$(dirname "$HERE")"; mkdir -p "$KIT/results"
P=/sys/module/nouveau/parameters
[ -e "$P/lab_gov" ] || { echo "--- СТОП: в драйвере нет lab_gov — нужен новый драйвер (lab.sh install) и перезагрузка"; exit 1; }
case "${1:-}" in
shadow)
    MIN="${2:-10}"; [[ "$MIN" =~ ^[0-9]+$ ]] || { echo "Минуты числом"; exit 1; }
    DBG=0; [ "${3:-}" = log ] && DBG=1
    LOG="$KIT/results/govshadow-$(date +%Y%m%d-%H%M%S).txt"
    sudo -v || exit 1
    systemctl is-active --quiet gpu-autoclock.service || { echo "--- СТОП: служба не работает — в тени сравнивать не с чем"; exit 1; }
    ERR='nouveau.*(ERROR|FAULT|fault|timeout|TIMEOUT|wtf)'
    E0="$(journalctl -k -b 0 --no-pager | grep -cE "$ERR" || true)"
    T0="$(date '+%F %T')"
    echo "Тень регулятора $T0, отпечаток $(md5sum "$0" | cut -c1-8), ядро $(uname -r), $MIN мин" | tee "$LOG"
    if [ "$DBG" = 1 ]; then
        grep -q 'gpu-autoclock.debug' /usr/local/sbin/gpu-autoclock.py || { echo "--- СТОП: установленная служба не умеет посекундную запись — сначала: bash ~/Home/nouveau-fix/daily/autoclock.sh install"; exit 1; }
        sudo touch /run/gpu-autoclock.debug; echo "  посекундная запись включена (драйвер и служба)" | tee -a "$LOG"
    fi
    sudo sh -c "echo 20300000 > $P/lab_perf_ticks; echo 1000 > $P/lab_perf_ms; echo $DBG > $P/lab_perf_log; echo 1 > $P/lab_gov"
    sleep 2; journalctl -k -b 0 --no-pager --since "$T0" | grep -E 'LAB (perf|gov):' | sed -E 's/.*nouveau [^ ]+ /  /' | tee -a "$LOG"
    G="$(command -v glmark2-wayland || command -v glmark2 || true)"
    for r in 1 2; do
        echo "  $(date +%T) нагрузка 20 с"; "$G" --run-forever -s 1600x900 -b refract >/dev/null 2>&1 & GP=$!; sleep 20; kill $GP 2>/dev/null; wait $GP 2>/dev/null
        echo "  $(date +%T) покой 40 с"; sleep 40
    done
    echo "  $(date +%T) теперь $MIN мин обычной работы — пользуйся компьютером как обычно (браузер, видео, Cursor)."
    echo "  Окно терминала не закрывай. Досрочно закончить: Ctrl+C один раз — сверка всё равно будет."
    trap 'echo "  (досрочно)"' INT
    sleep "$((MIN * 60))" || true
    trap - INT
    sudo sh -c "echo 0 > $P/lab_gov; echo 0 > $P/lab_perf_ms; echo 0 > $P/lab_perf_log"; sudo rm -f /run/gpu-autoclock.debug
    E1="$(journalctl -k -b 0 --no-pager | grep -cE "$ERR" || true)"
    python3 - "$T0" <<'EOF' 2>&1 | tee -a "$LOG"
import subprocess, sys, re, datetime
t0 = sys.argv[1]
def j(args):
    return subprocess.run(['journalctl', '-b', '0', '--no-pager', '-o', 'short-iso-precise', '--since', t0] + args,
                          capture_output=True, text=True).stdout.splitlines()
ts = lambda l: datetime.datetime.fromisoformat(l.split()[0])
svc = [(ts(l), re.search(r'-> (\w\w)', l).group(1), l.split(': ', 1)[1]) for l in j(['-u', 'gpu-autoclock.service']) if ' -> ' in l]
gov = [(ts(l), re.search(r'ТЕНЬ -> (\w\w)', l).group(1), l.split('ТЕНЬ ', 1)[1]) for l in j(['-k']) if 'LAB gov: ТЕНЬ' in l]
print(f'--- переключений службы: {len(svc)}, решений драйвера (тень): {len(gov)}')
used = set(); ok = 0
for t, m, txt in svc:
    k = next((i for i, (tg, mg, _) in enumerate(gov) if i not in used and mg == m and abs((tg - t).total_seconds()) <= 3), None)
    if k is None:
        print(f'  ✗ {t:%H:%M:%S} служба -> {m}: у драйвера такого решения нет  [{txt.strip()[:60]}]')
    else:
        used.add(k); ok += 1
        print(f'  ✓ {t:%H:%M:%S} служба -> {m}, драйвер -> {gov[k][1]} в {gov[k][0]:%H:%M:%S} ({(gov[k][0] - t).total_seconds():+.1f} с)')
for i, (tg, mg, txt) in enumerate(gov):
    if i not in used:
        print(f'  ✗ {tg:%H:%M:%S} драйвер -> {mg}: у службы такого переключения нет  [{txt.strip()[:60]}]')
print(f'--- совпало {ok} из {len(svc)} переключений службы; лишних решений драйвера: {len(gov) - len(used)}')
# посекундные ряды (если писались): 35 секунд перед первыми двумя расхождениями
sl = [(ts(l), l) for l in j(['-u', 'gpu-autoclock.service']) if 'загрузка' in l and '‰ (графика' in l]
dl = [(ts(l), l) for l in j(['-k']) if 'LAB perf: графика' in l]
if sl and dl:
    miss = sorted([t for t, m, _ in svc if not any(abs((tg - t).total_seconds()) <= 3 and mg == m for tg, mg, _ in gov)] +
                  [tg for i, (tg, mg, _) in enumerate(gov) if i not in used])
    for t in miss[:2]:
        print(f'--- посекундно перед расхождением в {t:%H:%M:%S} (слева служба, справа драйвер):')
        a = [x for x in sl if 0 <= (t - x[0]).total_seconds() <= 35]
        b = [x for x in dl if 0 <= (t - x[0]).total_seconds() <= 35]
        for k in range(max(len(a), len(b))):
            L = R = ''
            if k < len(a):
                m = re.search(r'загрузка (\d+)‰.*режим (\w+) hi (\d+) mid (\d+) low (\d+)', a[k][1])
                L = f'{a[k][0]:%H:%M:%S.%f}'[:12] + f'  {int(m.group(1))/10:5.1f}%  {m.group(2)} low {m.group(5)}'
            if k < len(b):
                m = re.search(r'графика (\d+)‰, видео (\d+)‰', b[k][1])
                R = f'{b[k][0]:%H:%M:%S.%f}'[:12] + f'  {max(int(m.group(1)), int(m.group(2)))/10:5.1f}%'
            print(f'  {L:40s} | {R}')
EOF
    echo "ошибок драйвера за опыт: $((E1 - E0)); регулятор и опрос выключены (замеры в прошивке остаются)" | tee -a "$LOG"
    echo "Лог: $LOG" ;;
act)
    MIN="${2:-10}"; [[ "$MIN" =~ ^[0-9]+$ ]] || { echo "Минуты числом"; exit 1; }
    LOG="$KIT/results/govact-$(date +%Y%m%d-%H%M%S).txt"
    sudo -v || exit 1
    [ "$(cat $P/lab_mem_replay 2>/dev/null)" = 15 ] && [ "$(cat $P/lab_mem_op13 2>/dev/null)" = 1 ] && [ "$(cat $P/lab_gpc_seq 2>/dev/null)" = 13 ] \
      || { echo "--- СТОП: параметры смены частот не выставлены (служба их ставит при старте) — запусти службу и повтори"; exit 1; }
    ERR='nouveau.*(ERROR|FAULT|fault|timeout|TIMEOUT|wtf)'
    E0="$(journalctl -k -b 0 --no-pager | grep -cE "$ERR" || true)"
    T0="$(date '+%F %T')"
    echo "Регулятор в драйвере $T0, отпечаток $(md5sum "$0" | cut -c1-8), ядро $(uname -r), $MIN мин" | tee "$LOG"
    sudo systemctl stop gpu-autoclock.service && echo "  служба остановлена — решает только драйвер" | tee -a "$LOG"
    sudo sh -c "echo 20300000 > $P/lab_perf_ticks; echo 1000 > $P/lab_perf_ms; echo 0 > $P/lab_perf_log; echo 2 > $P/lab_gov"
    sleep 2; journalctl -k -b 0 --no-pager --since "$T0" | grep -E 'LAB gov:' | sed -E 's/.*nouveau [^ ]+ /  /' | tee -a "$LOG"
    G="$(command -v glmark2-wayland || command -v glmark2 || true)"
    for r in 1 2; do
        echo "  $(date +%T) нагрузка 20 с"; "$G" --run-forever -s 1600x900 -b refract >/dev/null 2>&1 & GP=$!; sleep 20; kill $GP 2>/dev/null; wait $GP 2>/dev/null
        echo "  $(date +%T) покой 40 с"; sleep 40
    done
    echo "  $(date +%T) теперь $MIN мин обычной работы — пользуйся компьютером как обычно. Терминал не закрывай; досрочно — Ctrl+C один раз."
    trap 'echo "  (досрочно)"' INT
    sleep "$((MIN * 60))" || true
    trap - INT
    sudo sh -c "echo 0 > $P/lab_gov; echo 0 > $P/lab_perf_ms"
    sudo systemctl start gpu-autoclock.service && echo "  регулятор выключен, служба снова запущена" | tee -a "$LOG"
    E1="$(journalctl -k -b 0 --no-pager | grep -cE "$ERR" || true)"
    echo "--- решения драйвера:" | tee -a "$LOG"
    journalctl -k -b 0 --no-pager --since "$T0" | grep 'LAB gov: ->' | sed -E 's/^(\S+ \S+ \S+).*LAB gov: /  \1 /' | tee -a "$LOG"
    N="$(journalctl -k -b 0 --no-pager --since "$T0" | grep -c 'LAB gov: ->' || true)"
    BAD="$(journalctl -k -b 0 --no-pager --since "$T0" | grep 'LAB gov: ->' | awk '{ m=""; r=""; for (i=1;i<=NF;i++) { if ($i=="->") m=$(i+1); if ($i=="теперь") r=$(i+1); if ($i=="ret") rc=$(i+1) } if (m!=r || rc!="0,") print }' | wc -l)"
    echo "--- переключений: $N, не выполнено: $BAD, ошибок драйвера: $((E1 - E0))" | tee -a "$LOG"
    [ "$N" -gt 0 ] && [ "$BAD" = 0 ] && [ "$((E1 - E0))" = 0 ] && echo "=== Шаг 2б: драйвер переключает режимы сам ✅" | tee -a "$LOG" || echo "=== Шаг 2б: есть отличия — пришли вывод" | tee -a "$LOG"
    echo "Лог: $LOG" ;;
off)
    sudo sh -c "echo 0 > $P/lab_gov; echo 0 > $P/lab_perf_ms"; echo "Регулятор и опрос выключены"
    systemctl is-active --quiet gpu-autoclock.service || { sudo systemctl start gpu-autoclock.service && echo "Служба запущена"; } ;;
*) sed -n '2,8p' "$0"; exit 1 ;;
esac

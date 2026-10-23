#!/bin/bash
# «УЧЁТ ЗАГРУЗКИ В ПРОШИВКЕ PMU» (патч 0004) — по одному шагу за раз:
#   perftest.sh check   — шаг 1а: после перезагрузки процесс в прошивке СПИТ. Проверка, что всё как раньше:
#                         параметры на нуле, команд прошивке не было, служба переключает режимы, ошибок нет.
#   perftest.sh start   — шаг 1б: ВКЛЮЧИТЬ замеры в прошивке (каждые ~100 мс) и 60 с наблюдать
#                         с нагрузкой: смена частот (в той же прошивке) работает, ошибок нет. Опрос НЕ включается.
#   perftest.sh compare — шаг 1в: включить ОПРОС из драйвера и сверить с прямым подсчётом:
#                         10 с покоя, 20 с нагрузки (glmark2), 10 с покоя. В конце опрос выключается.
#   perftest.sh stop    — выключить замеры и опрос (прошивка снова спит).
# Режимы карты этот опыт НЕ трогает — их по-прежнему переключает служба.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; KIT="$(dirname "$HERE")"; mkdir -p "$KIT/results"
P=/sys/module/nouveau/parameters
LOG="$KIT/results/perftest-$(date +%Y%m%d-%H%M%S).txt"
[ -e "$P/lab_perf_ticks" ] || { echo "--- СТОП: в драйвере нет lab_perf_ticks — нужен драйвер с патчем 0004 (lab.sh install) и перезагрузка"; exit 1; }
ERR='nouveau.*(ERROR|FAULT|fault|timeout|TIMEOUT|wtf)'
errs() { journalctl -k -b 0 --no-pager | grep -cE "$ERR" || true; }
case "${1:-}" in
check)
    echo "=== Шаг 1а: прошивка с процессом учёта, процесс спит"
    ok=1
    for k in lab_perf_ticks lab_perf_ms; do v="$(cat $P/$k)"; [ "$v" = 0 ] && echo "  ✓ $k = 0" || { echo "  ✗ $k = $v (должно быть 0)"; ok=0; }; done
    n="$(journalctl -k -b 0 --no-pager | grep -c 'LAB perf:' || true)"
    [ "$n" = 0 ] && echo "  ✓ команд прошивке не было — процесс учёта спит" || { echo "  ✗ были команды прошивке ($n)"; ok=0; }
    echo "  загрузка прошивки PMU: $(journalctl -k -b 0 --no-pager | grep -iE 'nouveau.*pmu' | tail -n 3 | sed -E 's/.*nouveau [^ ]+ //' | tr '\n' ' ')"
    sw="$(journalctl -u gpu-autoclock.service -b 0 --no-pager | grep -c ' -> ' || true)"
    bad="$(journalctl -u gpu-autoclock.service -b 0 --no-pager | grep -c 'не та\|СТОП' || true)"
    echo "  служба: переключений с загрузки $sw, сбоев $bad"; [ "$bad" = 0 ] || ok=0
    journalctl -u gpu-autoclock.service -b 0 --no-pager | grep ' -> ' | tail -n 5 | sed -E 's/^.*python3\[[0-9]+\]: /    /'
    e="$(errs)"; echo "  ошибок драйвера с загрузки: $e"; [ "$e" = 0 ] || { journalctl -k -b 0 --no-pager | grep -E "$ERR" | tail -n 5; ok=0; }
    [ "$sw" -gt 0 ] || echo "  (переключений ещё не было — дай карте поработать: открой видео или браузер и запусти проверку ещё раз)"
    [ "$ok" = 1 ] && echo "=== Шаг 1а: всё как раньше ✅" || echo "=== Шаг 1а: есть отличия — пришли вывод"
    exit 0 ;;
start)
    echo "=== Шаг 1б: включаю замеры в прошивке (период 20300000 тактов ~ 100 мс), 60 с наблюдения с нагрузкой"
    sudo -v || exit 1
    E0="$(errs)"; S0="$(journalctl -u gpu-autoclock.service -b 0 --no-pager | grep -c ' -> ' || true)"
    sudo sh -c "echo 20300000 > $P/lab_perf_ticks"; sleep 2
    journalctl -k -b 0 --no-pager | grep 'LAB perf:' | tail -n 1 | sed -E 's/.*nouveau [^ ]+ /  /'
    G="$(command -v glmark2-wayland || command -v glmark2 || true)"
    for r in 1 2; do
        echo "  $(date +%T) нагрузка 20 с (служба должна поднять 0f)"; "$G" --run-forever -s 1600x900 -b refract >/dev/null 2>&1 & GP=$!; sleep 20; kill $GP 2>/dev/null; wait $GP 2>/dev/null
        echo "  $(date +%T) покой 20 с (служба должна опустить режим)"; sleep 20
    done
    E1="$(errs)"; S1="$(journalctl -u gpu-autoclock.service -b 0 --no-pager | grep -c ' -> ' || true)"
    journalctl -u gpu-autoclock.service -b 0 --no-pager | grep ' -> ' | tail -n "$((S1 - S0))" | sed -E 's/^.*python3\[[0-9]+\]: /    /'
    bad="$(journalctl -u gpu-autoclock.service -b 0 --no-pager | grep -c 'не та\|СТОП' || true)"
    echo "  переключений за опыт: $((S1 - S0)), сбоев службы: $bad, ошибок драйвера: $((E1 - E0))"
    [ "$((E1 - E0))" = 0 ] && [ "$bad" = 0 ] && [ "$((S1 - S0))" -gt 0 ] && echo "=== Шаг 1б: замеры в прошивке не мешают смене частот ✅ (замеры оставлены включёнными до перезагрузки)" \
      || echo "=== Шаг 1б: есть отличия — пришли вывод (выключить замеры: bash ~/Home/nouveau-fix/lab/perftest.sh stop)"
    exit 0 ;;
stop)
    sudo sh -c "echo 0 > $P/lab_perf_ms; echo 0 > $P/lab_perf_ticks"; sleep 2
    journalctl -k -b 0 --no-pager | grep 'LAB perf:' | tail -n 1 | sed -E 's/.*nouveau [^ ]+ /  /'
    echo "Опрос и замеры выключены"; exit 0 ;;
compare) ;;
*) sed -n '2,10p' "$0"; exit 1 ;;
esac
[ "$(cat $P/lab_perf_ticks)" -gt 0 ] || { echo "--- СТОП: замеры в прошивке не включены — сначала шаг 1б: bash ~/Home/nouveau-fix/lab/perftest.sh start"; exit 1; }
G="$(command -v glmark2-wayland || command -v glmark2 || true)"
[ -n "$G" ] || { echo "--- СТОП: нет glmark2"; exit 1; }
sudo -v || exit 1
E0="$(errs)"
echo "Сверка учёта загрузки $(date '+%F %T'), отпечаток $(md5sum "$0" | cut -c1-8), ядро $(uname -r)" | tee "$LOG"
echo "  прошивка PMU при загрузке: $(journalctl -k -b 0 --no-pager | grep -E 'nouveau.*pmu' | tail -n 2 | sed -E 's/.*nouveau [^ ]+ //' | tr '\n' ' ')" | tee -a "$LOG"
sudo sh -c "echo 0 > $P/lab_perf_log; echo 1000 > $P/lab_perf_ms"
sleep 2.5
( sleep 11.5; "$G" --run-forever -s 1600x900 -b shading:shading=phong -b bump:bump-render=high-poly -b refract >/dev/null 2>&1 & GP=$!; sleep 20; kill $GP 2>/dev/null; wait $GP 2>/dev/null ) &
sudo python3 - <<'EOF' 2>&1 | tee -a "$LOG"
import glob, mmap, os, struct, time
P = '/sys/module/nouveau/parameters/'
rp = lambda n: int(open(P + n).read())
dev = next(d for d in glob.glob('/sys/bus/pci/devices/*')
           if open(d + '/vendor').read().strip() == '0x10de' and open(d + '/class').read().startswith('0x03'))
fd = os.open(dev + '/resource0', os.O_RDONLY | os.O_SYNC)
bar = mmap.mmap(fd, 16 << 20, mmap.MAP_SHARED, mmap.PROT_READ)
cnt = lambda i: struct.unpack_from('<I', bar, 0x10a508 + i * 0x10)[0] & 0x7fffffff
ac = lambda: next((l.split('AC: ')[1].strip() for l in open(glob.glob('/sys/kernel/debug/dri/*/pstate')[0]) if l.startswith('AC')), '?')
print(' сек  фаза      | прошивка PMU: графика  видео замеров | напрямую: графика  видео | режим')
prev = [cnt(1), cnt(3), cnt(7)]; worst = 0
for s in range(1, 41):
    time.sleep(1.0)
    now = [cnt(1), cnt(3), cnt(7)]
    d = [(now[i] - prev[i]) & 0x7fffffff for i in range(3)]; prev = now
    vid_d, gr_d = (1000 * d[0] // max(d[2], 1), 1000 * d[1] // max(d[2], 1))
    gr_p, vid_p, n = rp('lab_perf_gr'), rp('lab_perf_vid'), rp('lab_perf_samples')
    if 12 < s < 31 or s < 10 or s > 33:
        worst = max(worst, abs(gr_p - gr_d))
    ph = 'покой' if s <= 10 or s > 30 else 'нагрузка'
    print(f'{s:4d}  {ph:9s} |         {gr_p/10:5.1f}%  {vid_p/10:5.1f}%   {n:3d}   |      {gr_d/10:5.1f}%  {vid_d/10:5.1f}% | {ac()}', flush=True)
print(f'наибольшее расхождение графики (вне переходных секунд): {worst/10:.1f} п.п.')
EOF
wait
sudo sh -c "echo 0 > $P/lab_perf_ms"
E1="$(errs)"
echo "ошибок драйвера за опыт: $((E1 - E0))" | tee -a "$LOG"
echo "опрос выключен (lab_perf_ms=0), замеры в прошивке остаются включёнными. Лог: $LOG"

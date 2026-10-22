#!/bin/bash
# ОПЫТ «ОПЕРАЦИЯ 0x34»: одна переменная — lab_mem_op34 (ожидание остановки вывода изображения после паузы
# 0x611200 и ПЕРЕД остановом доступа к видеопамяти, как делает nouveau на gt215). Гипотеза: без него смена
# памяти может совпасть с чтением кадра/курсора из видеопамяти (зависание 21.10 18:16 — три смены за 26 с).
#   op34test.sh on  [N]  — включить ожидание и сделать N (по умолчанию 6) циклов 07 -> 0f -> 07 под нагрузкой
#   op34test.sh off [N]  — то же с выключенным ожиданием (контроль, как было)
# На время опыта регулятор в драйвере выключается и в конце включается обратно. ВО ВРЕМЯ ОПЫТА ДВИГАЙ МЫШЬ
# и таскай окно — нужна активность вывода изображения. Если экран встанет: Alt+PrtSc, затем S, B.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; KIT="$(dirname "$HERE")"; mkdir -p "$KIT/results"
P=/sys/module/nouveau/parameters
[ -e "$P/lab_mem_op34" ] || { echo "--- СТОП: в драйвере нет lab_mem_op34 — нужен lab.sh install и перезагрузка"; exit 1; }
case "${1:-}" in on) V=1;; off) V=0;; *) sed -n '2,8p' "$0"; exit 1;; esac
N="${2:-6}"
G="$(command -v glmark2-wayland || command -v glmark2 || true)"; [ -n "$G" ] || { echo "--- СТОП: нет glmark2"; exit 1; }
sudo -v || exit 1
PS="$(ls /sys/kernel/debug/dri/*/pstate 2>/dev/null | head -n1)"; [ -n "$PS" ] || PS="$(sudo sh -c 'ls /sys/kernel/debug/dri/*/pstate' | head -n1)"
LOG="$KIT/results/op34-$V-$(date +%Y%m%d-%H%M%S).txt"
ERR='nouveau.*(ERROR|FAULT|fault|timeout|TIMEOUT|wtf)'
errs() { journalctl -k -b 0 --no-pager | grep -cE "$ERR" || true; }
GOV="$(cat $P/lab_gov)"; E0="$(errs)"
echo "Опыт op34=$V, $N циклов, $(date '+%F %T'), ядро $(uname -r)" | tee "$LOG"
sudo sh -c "echo 0 > $P/lab_gov; echo $V > $P/lab_mem_op34"
"$G" --run-forever -s 1600x900 -b refract >/dev/null 2>&1 & GP=$!
sleep 3
for i in $(seq 1 "$N"); do
    for m in 0f 07; do
        sudo sh -c "echo $m > '$PS'"; sleep 0.3
        A="$(sudo grep '^AC' "$PS")"
        L="$(journalctl -k -b 0 --no-pager | grep 'LAB replay .*выполнен' | tail -n 2 | sed -E 's/.*LAB replay ([^:]+): выполнен за ([0-9]+) мкс.*0x611200=([0-9a-f]+).*/\1: \2 мкс, 0x611200=\3/' | tr '\n' ';')"
        echo "  $(date +%T) цикл $i -> $m: $A | $L" | tee -a "$LOG"; sync
        sleep 7
    done
done
kill $GP 2>/dev/null; wait $GP 2>/dev/null
E1="$(errs)"
sudo sh -c "echo $GOV > $P/lab_gov"
echo "ошибок драйвера за опыт: $((E1 - E0)); регулятор снова lab_gov=$GOV; lab_mem_op34 оставлен = $V. Лог: $LOG" | tee -a "$LOG"

#!/bin/bash
# ТЕСТ 95 (18.11), модуль build-1117i. Домен 7 VBIOS (0x00e9e0, такт дисплея — тест 91) ставится по уровню, как у NVIDIA:
# lab_e9e0=2 — поле A из частоты домена 7 VBIOS (270 / 405 / 540 МГц на 03 / 07 / 0f). Одно отличие от службы (lab_e9e0=0).
#   1) сверка: 03 -> 07 -> 0f -> 07 -> 03, по журналу — поле A по VBIOS против таблицы этой карты (ждём 0a / 06 / 04 и совпадение)
#      и значение 0x00e9e0 после смены; при расхождении — стоп, ключ возвращается;
#   2) обычная работа: регулятор драйвера включён, нагрузка браузером C циклов (gov94.sh), сбои считаются как в тесте 94.
# В конце lab_e9e0 возвращается в 0 (как в службе).
#   bash ~/Home/nouveau-fix/lab/e9gov95.sh [C=30]     — в терминале рабочего стола; 30 циклов ≈ 45 минут
set -uo pipefail
PRM=/sys/module/nouveau/parameters; HERE="$(cd "$(dirname "$0")" && pwd)"
C="${1:-30}"
[ -e "$PRM/lab_e9e0_probe" ] || { echo "Нужен модуль build-1117i"; exit 1; }
pgrep -f "hangtest|core9|night93|disp91|gov94|cntr[78]|fsrm8|pmubr|big83" >/dev/null && { echo "Идёт другой тест — дождитесь конца"; exit 1; }
[ "$(cat $PRM/lab_gov)" = 2 ] && [ "$(cat $PRM/lab_order)" = 1 ] || { echo "Служба не на целевом наборе — сначала autoclock.sh install"; exit 1; }
OUT=~/Home/nouveau-fix/results/test95-$(date +%Y%m%d-%H%M%S).txt
say() { echo "$(date +%T) $*" | tee -a "$OUT"; }
w() { sudo sh -c "echo $2 > $PRM/$1"; }
sudo -v || exit 1
( while sleep 50; do sudo -n -v 2>/dev/null || exit; done ) & KEEP=$!   # 18.11: без продления возврат ключа ждал пароль
E0=$(cat $PRM/lab_e9e0)
trap 'kill $KEEP 2>/dev/null; w lab_e9e0 "$E0"; w lab_gov 2; say "прервано — ключи возвращены"; exit 1' INT TERM
PS="$(sudo sh -c 'ls /sys/kernel/debug/dri/*/pstate | head -n 1')"
say "тест 95: C=$C; $(uname -r), модуль $(cat /sys/module/nouveau/srcversion), загрузка $(uptime -s)"
say "--- 1. сверка поля A по уровням"
w lab_gov 0; sudo sh -c "echo 03 > $PS"; sleep 2
T0=$(date "+%F %T"); w lab_e9e0 2
for l in 07 0f 07 03; do sudo sh -c "echo $l > $PS"; sleep 2; done
journalctl -k -b 0 --no-pager --since "$T0" | grep -E "LAB e9e0 из VBIOS|LAB xbar после" | sed -E 's/^.*clk: LAB //' | tee -a "$OUT"
BAD=$(journalctl -k -b 0 --no-pager --since "$T0" | grep "LAB e9e0 из VBIOS" | sed -E 's/.*поле A ([0-9a-f]+) .*дала бы ([0-9a-f]+)$/\1 \2/' | awk '$1!=$2' | wc -l)
GOT=$(journalctl -k -b 0 --no-pager --since "$T0" | grep -c "LAB e9e0 из VBIOS")
if [ "$GOT" -lt 4 ] || [ "$BAD" -gt 0 ]; then
  say "--- сверка не сошлась (строк $GOT из 4, расхождений $BAD) — стоп"; kill $KEEP 2>/dev/null; w lab_e9e0 "$E0"; w lab_gov 2; exit 1
fi
say "сверка: 4 смены, поле A по VBIOS совпадает с таблицей"
say "--- 2. обычная работа под регулятором, $C циклов"
w lab_gov 2
bash "$HERE/gov94.sh" "$C" 2>&1 | tee -a "$OUT"
w lab_e9e0 "$E0"
kill $KEEP 2>/dev/null
say "=== конец; lab_e9e0 возвращён в $E0"
grep -E "тест 9[45]|сверка|=== итог|---" "$OUT" > "$OUT.sum"
echo "Результат: $OUT"

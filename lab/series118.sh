#!/bin/bash
# ОПЫТ 118 (22.11), модуль 1122c (ядро 7.0.0-44, загрузка LAB). Безопасная серия на время отсутствия, две части:
#   А — темп регулятора как у NVIDIA (lab_gov_nv=1) на ТРЁХ уровнях, gov94 C циклов (на двух уровнях — опыты 114–115);
#   Б — запись NVIDIA 0x022680 = 0x80000000 | байт 0x0c уровня VBIOS (lab_nv_22680), вероятно — настройка PCIe по уровню.
#       Прибор: биты ошибок PCIe (Device Status: исправимая / неисправимая / фатальная / неподдерживаемый запрос) у карты и у
#       порта процессора — перед прогоном сбрасываются (запись 1 в биты), после — читаются; скорость линии на 03 и 0f.
#       Прогоны чередуются: без записи, с записью, без, с — по N подъёмов 03 -> 0f со спуском через 07 под нагрузкой (FAST).
# Стоп на ошибке GPU или вечном застревании. Ключи в конце — как были.
#   bash ~/Home/nouveau-fix/lab/series118.sh [C=40] [N=200]   — в терминале рабочего стола; ≈ 1 ч + 4 × 10 мин
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; PRM=/sys/module/nouveau/parameters
[ -e "$PRM/lab_nv_22680" ] && [ -e "$PRM/lab_gov_nv" ] || { echo "Нет lab_nv_22680/lab_gov_nv — нужен наш модуль (safeboot.sh lab)"; exit 1; }
C="${1:-40}"; N="${2:-200}"
OUT=~/Home/nouveau-fix/results/test118-$(date +%Y%m%d-%H%M%S).txt
say() { echo "$(date +%T) $*" | tee -a "$OUT"; sync; }
w() { sudo sh -c "echo $2 > $PRM/$1"; }
sudo -v || exit 1
( while sleep 50; do sudo -n -v 2>/dev/null || exit; done ) & KEEP=$!
GPU=01:00.0; RP="$(basename "$(dirname "$(readlink -f /sys/bus/pci/devices/0000:$GPU)")" | sed 's/^0000://')"
K0="lab_gov_nv=$(cat $PRM/lab_gov_nv) lab_nv_22680=$(cat $PRM/lab_nv_22680) lab_gov=$(cat $PRM/lab_gov)"
restore() { for kv in $K0; do w "${kv%%=*}" "${kv#*=}"; done; kill $KEEP 2>/dev/null; }
trap 'say "прервано — ключи возвращены"; restore; exit 1' INT TERM
devsta() { sudo setpci -s "$1" CAP_EXP+0x0a.w; }   # биты 0 исправимая, 1 неисправимая, 2 фатальная, 3 неподдерживаемый запрос
devclr() { sudo setpci -s "$1" CAP_EXP+0x0a.w=000f; }
link() { cat /sys/bus/pci/devices/0000:$GPU/current_link_speed; }
say "опыт 118: $(uname -r), модуль $(cat /sys/module/nouveau/srcversion), загрузка $(uptime -s); ключи: $K0; порт процессора $RP"

say "--- А: темп NVIDIA на трёх уровнях (lab_gov_nv=1), $C циклов 45/45 с"
T="$(date "+%F %T")"; w lab_gov_nv 1
bash "$HERE/gov94.sh" "$C" 45 45 > /dev/null 2>&1
f="$(ls -t ~/Home/nouveau-fix/results/test94-*.txt | head -n 1)"
say "    файл $(basename "$f"): $(grep -E '=== итог' "$f" | sed -E 's/^.{8} //')"
say "    переходы: $(sudo journalctl -k -b 0 --no-pager --since "$T" | grep -oE 'LAB gov: -> [0-9a-f]{2}' | sort | uniq -c | tr '\n' ' '); тайм-аутов PMU: $(cat $PRM/lab_perf_timeouts)"
w lab_gov_nv 0
grep -qE '=== итог: .*вечных 0, ошибок GPU 0' "$f" || { say "    ошибка — стоп"; restore; exit 1; }

say "--- Б: 0x022680 с прибором PCIe, 4 прогона по $N подъёмов"
PS="$(sudo sh -c 'ls /sys/kernel/debug/dri/*/pstate | head -n 1')"
for v in 0 1 0 1; do
  w lab_gov 0; w lab_nv_22680 "$v"
  sudo sh -c "echo 03 > $PS"; sleep 2; l03="$(link)"; sudo sh -c "echo 0f > $PS"; sleep 2; l0f="$(link)"; sudo sh -c "echo 03 > $PS"; sleep 2
  devclr "$GPU"; devclr "$RP"; a0="$(devsta "$GPU")/$(devsta "$RP")"
  T="$(date "+%F %T")"
  FAST=1 LOW=03 HIGH=0f MID=07 bash "$HERE/hangtest.sh" "$N" > /dev/null 2>&1; rc=$?
  a1="$(devsta "$GPU")/$(devsta "$RP")"
  e="$(sudo journalctl -k -b 0 --no-pager --since "$T" | grep -cE 'Xid|FAULT|DATA_ERROR|ТАЙМ-АУТ|ОСТАЛСЯ НА PLL')"
  say "    0x022680 = $v: код $rc, ошибок в журнале $e; биты ошибок PCIe карта/порт: после сброса $a0, после прогона $a1; линия на 03 $l03, на 0f $l0f; записей 0x022680 в журнале $(sudo journalctl -k -b 0 --no-pager --since "$T" | grep -c '22680')"
  [ "$rc" = 2 ] && { say "    зависание графики — стоп"; break; }
done
restore; trap - INT TERM
say "=== конец; ключи возвращены: $K0"
grep -E "опыт 118|^.{8} ---|файл|переходы|0x022680 =|стоп|=== конец" "$OUT" > "$OUT.sum"
echo "Результат: $OUT"

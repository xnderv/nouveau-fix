#!/bin/bash
# ТЕСТ 94 (18.11): служба gpu-autoclock на целевом наборе (после autoclock.sh install), переключает САМ РЕГУЛЯТОР драйвера
# (lab_gov=2), как в обычной работе. Скрипт только включает и выключает нагрузку браузером (страница hangload.html, как в
# hangtest): C циклов «нагрузка L с / покой I с». Ключи службы не трогает. Считает по журналу ядра переходы регулятора
# и сбои: застревания переключателя (подъём/спуск), вечные застревания, ошибки GPU. Стоп на вечном застревании или ошибке.
#   bash ~/Home/nouveau-fix/lab/gov94.sh [C=40] [L=45] [I=45]     — в терминале рабочего стола; 40 циклов ≈ 60 минут
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; PRM=/sys/module/nouveau/parameters
C="${1:-40}"; L="${2:-45}"; I="${3:-45}"
pgrep -f "hangtest|core9|night93|disp91|cntr[78]|fsrm8|pmubr|big83" >/dev/null && { echo "Идёт другой тест — дождитесь конца"; exit 1; }
[ "$(cat $PRM/lab_gov)" = 2 ] || { echo "Регулятор не включён (lab_gov=$(cat $PRM/lab_gov)) — служба не на месте?"; exit 1; }
[ "$(cat $PRM/lab_order)" = 1 ] && [ "$(cat $PRM/lab_vbios_src)" = 1 ] || { echo "Служба не на целевом наборе (lab_order/lab_vbios_src не 1) — сначала autoclock.sh install"; exit 1; }
OUT=~/Home/nouveau-fix/results/test94-$(date +%Y%m%d-%H%M%S).txt
say() { echo "$(date +%T) $*" | tee -a "$OUT"; }
T0=$(date "+%F %T")
k() { journalctl -k --no-pager --since "$T0" | grep -cE "$1"; }
LP=""
stopload() { [ -n "$LP" ] && { kill "$LP" 2>/dev/null; wait "$LP" 2>/dev/null; LP=""; }; }
trap 'stopload; say "прервано"; exit 1' INT TERM
B="$(command -v yandex-browser || command -v chromium || command -v google-chrome || true)"; [ -n "$B" ] || { echo "Браузер не найден"; exit 1; }
PROF="$HOME/.cache/nouveau-gov94-profile"
say "тест 94: $C циклов (нагрузка $L с / покой $I с); $(uname -r), модуль $(cat /sys/module/nouveau/srcversion), загрузка $(uptime -s)"
say "ключи: lab_gov=$(cat $PRM/lab_gov) lab_mem=$(cat $PRM/lab_mem) lab_order=$(cat $PRM/lab_order) lab_vbios_src=$(cat $PRM/lab_vbios_src) lab_pll_keep=$(cat $PRM/lab_pll_keep) lab_xbar=$(cat $PRM/lab_xbar) lab_e9e0=$(cat $PRM/lab_e9e0) lab_therm_wait_nv=$(cat $PRM/lab_therm_wait_nv)"
for c in $(seq 1 "$C"); do
  rm -rf "$PROF"; mkdir -p "$PROF"
  "$B" --user-data-dir="$PROF" --no-first-run --no-default-browser-check --disable-sync --new-window --app="file://$HERE/hangload.html" >/dev/null 2>&1 & LP=$!
  sleep "$L"; stopload; sleep "$I"
  P=$(k "LAB pstate [0-9]: done ret 0"); U=$(k "ТАЙМ-АУТ делитель -> PLL"); D=$(k "ТАЙМ-АУТ PLL -> делитель"); S=$(k "ОСТАЛСЯ НА PLL")
  E=$(k "DATA_ERROR|FAULT at|Xid|killed|g84_bar_flush")
  say "цикл $c/$C: переходов регулятора $P, застреваний подъёма $U, спуска $D, вечных $S, ошибок GPU $E; сейчас $(cat /sys/kernel/debug/dri/*/pstate 2>/dev/null | grep '^AC' || echo '?')"
  [ "$S" -gt 0 ] && { say "--- вечное застревание — стоп"; break; }
  [ "$E" -gt 0 ] && { say "--- ошибка GPU — стоп"; break; }
done
stopload
say "=== итог: переходов $(k "LAB pstate [0-9]: done ret 0"), застреваний подъёма $(k "ТАЙМ-АУТ делитель -> PLL"), спуска $(k "ТАЙМ-АУТ PLL -> делитель"), вечных $(k "ОСТАЛСЯ НА PLL"), ошибок GPU $(k "DATA_ERROR|FAULT at|Xid|killed|g84_bar_flush")"
grep -E "тест 94|ключи|=== итог|---" "$OUT" > "$OUT.sum"
echo "Результат: $OUT"

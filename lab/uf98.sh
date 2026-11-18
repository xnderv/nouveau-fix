#!/bin/bash
# ТЕСТ 98 (18.11), модуль build-1118a (ключ lab_disp_uf). Зачем NVIDIA держит бит 0 в 0x610300 (дисплей) всё время перехода?
# Версия: защищает картинку — во время смены частот (особенно памяти) дисплей не успевает выбрать данные кадра (недогруз).
# Прибор — липкий признак недогруза выходов дисплея (как в тесте 91): перед каждым переходом сбрасывается, после — читается.
# Прогоны чередуются, чтобы дрейф не смешался с ключом: без бита, с битом, без бита, с битом — по N подъёмов 03 -> 0f со
# спуском через 07 под нагрузкой (FAST). Набор службы как есть; регулятор на время теста выключен. Предсказание версии:
# без бита — недогруз на части переходов (на тех, где меняется память), с битом — нет или заметно меньше.
#   bash ~/Home/nouveau-fix/lab/uf98.sh [N=200]     — в терминале рабочего стола; около 35 минут
set -uo pipefail
PRM=/sys/module/nouveau/parameters; HERE="$(cd "$(dirname "$0")" && pwd)"
N="${1:-200}"
[ -e "$PRM/lab_disp_uf" ] || { echo "Нет lab_disp_uf — нужен модуль build-1118a"; exit 1; }
pgrep -f "hangtest|core9|night93|disp91|gov94|e9gov95|up96|nvx97|cntr[78]|fsrm8|pmubr|big83" >/dev/null && { echo "Идёт другой тест — дождитесь конца"; exit 1; }
[ "$(cat $PRM/lab_nv_up07)" = 1 ] && [ "$(cat $PRM/lab_e9e0)" = 2 ] || { echo "Служба не на наборе 18.11 — сначала autoclock.sh install"; exit 1; }
OUT=~/Home/nouveau-fix/results/test98-$(date +%Y%m%d-%H%M%S).txt
say() { echo "$(date +%T) $*" | tee -a "$OUT"; }
w() { sudo sh -c "echo $2 > $PRM/$1"; }
sudo -v || exit 1
( while sleep 50; do sudo -n -v 2>/dev/null || exit; done ) & KEEP=$!
G0=$(cat $PRM/lab_gov); D0=$(cat $PRM/lab_nv_disphold); F0=$(cat $PRM/lab_disp_uf)
restore() { w lab_disp_uf "$F0"; w lab_nv_disphold "$D0"; w lab_gov "$G0"; kill $KEEP 2>/dev/null; }
trap 'say "прервано — ключи возвращаю"; restore; exit 1' INT TERM
cnt() { journalctl -k -b 0 --no-pager | grep -c "$1"; }
gerr() { journalctl -k -b 0 --no-pager | grep -cE "DATA_ERROR|FAULT at|Xid|killed|g84_bar_flush"; }
STOP=0
run() {   # $1 — 0/1 бит 0x610300
  local T0 S0 E0 RC t0 i0 J
  w lab_nv_disphold "$1"
  T0=$(date "+%F %T"); S0=$(cnt "ОСТАЛСЯ НА PLL"); E0=$(gerr)
  t0=$(cat $PRM/lab_disp_uf_trans); i0=$(cat $PRM/lab_disp_uf_idle)
  FAST=1 LOW=03 HIGH=0f MID=07 bash "$HERE/hangtest.sh" "$N" >> "$OUT" 2>&1; RC=$?
  J=$(journalctl -k -b 0 --no-pager --since "$T0" | grep "LAB disp_uf: переход")
  say "=== итог: 0x610300 бит $1 — код $RC; переходов $(echo "$J" | grep -c .), с недогрузом за переход $(( $(cat $PRM/lab_disp_uf_trans) - t0 )), недогруз в покое между переходами $(( $(cat $PRM/lab_disp_uf_idle) - i0 )); вечных $(( $(cnt "ОСТАЛСЯ НА PLL") - S0 )), ошибок GPU $(( $(gerr) - E0 ))"
  for p in "0 -> 2" "2 -> 1" "1 -> 0"; do
    say "    $p: переходов $(echo "$J" | grep -c "переход $p "), недогруз $(echo "$J" | grep "переход $p " | grep -c НЕДОГРУЗ)"
  done
  [ "$RC" = 2 ] && { say "--- зависание графики — стоп"; STOP=1; }
  [ "$(cnt "ОСТАЛСЯ НА PLL")" -gt "$S0" ] && { say "--- вечное застревание — стоп"; STOP=1; }
  return 0
}
PS="$(sudo sh -c 'ls /sys/kernel/debug/dri/*/pstate | head -n 1')"
say "тест 98: N=$N по 4 прогона; $(uname -r), модуль $(cat /sys/module/nouveau/srcversion), загрузка $(uptime -s)"
say "номера уровней в журнале: 0 = 03, 1 = 07, 2 = 0f"
w lab_gov 0; sudo sh -c "echo 03 > $PS"; sleep 2; w lab_disp_uf 1
say "подготовка: $(sudo grep '^AC' "$PS")"
for b in 0 1 0 1; do
  [ $STOP = 0 ] || break
  say "--- прогон: 0x610300 бит $b"; run "$b"
done
restore
say "=== конец; ключи возвращены"
grep -E "тест 98|номера|подготовка|=== итог|^.{8}     [0-9]|^.{8} ---" "$OUT" > "$OUT.sum"
echo "СВОДКА:"; cat "$OUT.sum"
echo "Результат: $OUT"

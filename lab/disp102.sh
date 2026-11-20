#!/bin/bash
# ТЕСТ 102 (20.11), модуль от build-1118a (прибор lab_disp_uf). Правило «такт дисплея уровня ≥ частоты пикселей активных выходов»
# на одном мониторе (docs/2026-11-18/core-audit.md, конец). Такт дисплея (домен 7 VBIOS) у нас 270 / 405 / 540 МГц на 03 / 07 / 0f.
#   контроль: 2560x1440@60 (241,5 МГц) — меньше 270, недогруза не должно быть ни на одном уровне;
#   опыт:     1920x1080@120 (297 МГц) — больше 270: предсказание — недогруз на 03, чисто на 07 и 0f.
# На каждом режиме: 0f -> 07 -> 03 -> 07 -> 0f, по 8 с на уровне. Прибор: липкий признак «был недогруз» перед каждым переходом
# (= за время на прошлом уровне) и за сам переход. Режим монитора ставится ВРЕМЕННО и в конце возвращается (после
# перезагрузки вернётся сам). Монитор на 297 МГц может показать «нет сигнала» — на тест это не влияет (картинку не смотрим).
#   bash ~/Home/nouveau-fix/lab/disp102.sh     — в терминале рабочего стола (Remmina); около 2 минут
set -uo pipefail
PRM=/sys/module/nouveau/parameters; HERE="$(cd "$(dirname "$0")" && pwd)"
[ -e "$PRM/lab_disp_uf" ] || { echo "Нет lab_disp_uf — нужен модуль от build-1118a"; exit 1; }
pgrep -f "hangtest|gov94|auto101|core1|pre99" >/dev/null && { echo "Идёт другой тест — дождитесь конца"; exit 1; }
OUT=~/Home/nouveau-fix/results/test102-$(date +%Y%m%d-%H%M%S).txt
say() { echo "$(date +%T) $*" | tee -a "$OUT"; }
w() { sudo sh -c "echo $2 > $PRM/$1"; }
sudo -v || exit 1
MODE0="$(python3 "$HERE/monmode.py" | awk '{print $2}')"
G0=$(cat $PRM/lab_gov); U0=$(cat $PRM/lab_disp_uf)
restore() { python3 "$HERE/monmode.py" "$MODE0" >/dev/null 2>&1; w lab_disp_uf "$U0"; w lab_gov "$G0"; }
trap 'say "прервано — возвращаю режим и ключи"; restore; exit 1' INT TERM
PS="$(sudo sh -c 'ls /sys/kernel/debug/dri/*/pstate | head -n 1')"
say "тест 102: $(uname -r), модуль $(cat /sys/module/nouveau/srcversion), монитор сейчас $MODE0"
w lab_gov 0; w lab_disp_uf 1
run() {   # $1 — режим, $2 — частота пикселей
  local T0
  say "--- режим $1 ($2 МГц): $(python3 "$HERE/monmode.py" "$1")"
  sleep 6
  sudo sh -c "echo 0f > $PS"; sleep 4
  T0=$(date "+%F %T")
  for l in 07 03 07 0f; do sudo sh -c "echo $l > $PS"; sleep 8; done
  sudo sh -c "echo 07 > $PS"; sleep 1
  journalctl -k -b 0 --no-pager --since "$T0" | grep "LAB disp_uf: переход" | sed -E 's/^.*LAB disp_uf: //' | tee -a "$OUT"
  journalctl -k -b 0 --no-pager --since "$T0" | grep "LAB disp_uf: переход" | python3 -c '
import sys, re
name = {0: "03", 1: "07", 2: "0f"}
for line in sys.stdin:
    m = re.search(r"переход (-?\d+) -> (\d+).*до ([0-9a-f]+) ([0-9a-f]+), за переход ([0-9a-f]+) ([0-9a-f]+)", line)
    if not m: continue
    a, b = int(m[1]), int(m[2]); d0, t0 = int(m[3], 16), int(m[5], 16)
    print(f"    на уровне {name.get(a, a)} (8 с): {\"НЕДОГРУЗ\" if d0 & 0x10 else \"чисто\"};  переход {name.get(a, a)} -> {name.get(b, b)}: {\"НЕДОГРУЗ\" if t0 & 0x10 else \"чисто\"}")
' | tee -a "$OUT"
}
run "$MODE0" "241,5"
run "1920x1080@120.000" "297"
restore
say "=== конец; режим монитора $(python3 "$HERE/monmode.py" | awk '{print $2}'), ключи возвращены"
grep -E "тест 102|---|на уровне|=== конец" "$OUT" > "$OUT.sum"
echo "Результат: $OUT"

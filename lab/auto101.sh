#!/bin/bash
# ТЕСТ 101 (19.11), модуль build-1119b (= 1119a + три правки nouveau в clk/base.c): всё, что выставляла служба gpu-autoclock, теперь — значения по умолчанию в драйвере;
# замеры загрузки (период 100 мс по такту PMU), регулятор и тепловые пороги (из VBIOS) включаются сами. Служба ВЫКЛЮЧЕНА.
#   1) сверка: каждый ключ, который ставила служба (daily/gpu-autoclock.py, PARAMS и ключи регулятора), — в драйвере то же
#      значение; в журнале — команда прошивке начать замеры и «регулятор включён»;
#   2) обычная работа под регулятором: C циклов нагрузки браузером (gov94.sh), как тест 94.
# Перед тестом: модуль build-1119b установлен, служба выключена (sudo systemctl disable --now gpu-autoclock), перезагрузка.
#   bash ~/Home/nouveau-fix/lab/auto101.sh [C=40]     — в терминале рабочего стола; около часа
set -uo pipefail
PRM=/sys/module/nouveau/parameters; HERE="$(cd "$(dirname "$0")" && pwd)"
C="${1:-40}"
OUT=~/Home/nouveau-fix/results/test101-$(date +%Y%m%d-%H%M%S).txt
say() { echo "$(date +%T) $*" | tee -a "$OUT"; }
systemctl is-active --quiet gpu-autoclock && { echo "Служба gpu-autoclock работает — тест про драйвер без неё: sudo systemctl disable --now gpu-autoclock и перезагрузка"; exit 1; }
say "тест 101: $(uname -r), модуль $(cat /sys/module/nouveau/srcversion), загрузка $(uptime -s), служба: $(systemctl is-enabled gpu-autoclock 2>/dev/null)"
say "--- 1. ключи драйвера против значений службы"
BAD=$(python3 -I - "$HERE/../daily/gpu-autoclock.py" "$PRM" <<'EOF'
import re, sys, os
svc = open(sys.argv[1]).read(); prm = sys.argv[2]
i = svc.index('PARAMS = {'); j = svc.index('\n}\n', i)
P = dict(re.findall(r"'(lab_[a-z0-9_]+)':\s*'([^']*)'", svc[i:j]))
P.update({'lab_gov': '2', 'lab_perf_ms': '1000', 'lab_perf_log': '0'})
norm = lambda v: {'Y': '1', 'N': '0'}.get(v, v)
bad = 0
for k, v in sorted(P.items()):
    f = os.path.join(prm, k)
    if not os.path.exists(f):
        print(f'  {k}: нет в модуле'); bad += 1; continue
    got = norm(open(f).read().strip())
    if got != v:
        print(f'  {k}: драйвер {got}, служба {v}'); bad += 1
print(f'  сверено {len(P)} ключей, расхождений {bad}')
EOF
)
echo "$BAD" | tee -a "$OUT"
say "автоматические: lab_perf_ticks=$(cat $PRM/lab_perf_ticks) (-1 = по такту PMU), lab_gov_hot=$(cat $PRM/lab_gov_hot) lab_gov_crit=$(cat $PRM/lab_gov_crit) (-1 = из VBIOS)"
journalctl -k -b 0 --no-pager | grep -E "LAB perf: прошивке дана команда начать|LAB gov: включён|нет сценариев памяти" | head -3 | sed -E 's/^.*(pmu|clk): //' | tee -a "$OUT"
say "сейчас: $(sudo cat /sys/kernel/debug/dri/*/pstate 2>/dev/null | grep '^AC' || echo '? (нужен sudo для pstate)')"
say "--- 2. обычная работа под регулятором, $C циклов"
bash "$HERE/gov94.sh" "$C" 2>&1 | tee -a "$OUT"
say "=== конец"
grep -E "тест 101|сверено|расхожд|: драйвер|нет в модуле|автоматические|прошивке|включён|=== итог|---" "$OUT" > "$OUT.sum"
echo "Результат: $OUT"

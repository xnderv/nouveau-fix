#!/bin/bash
# ОПЫТ «СОН И ПРОБУЖДЕНИЕ» на лабораторном драйвере.
#   sleep.sh 03|07|0f [СЕК] — поставить режим, уснуть (rtcwake, сам проснётся через СЕК, по умолчанию 20 с),
#   после пробуждения проверить: какой режим и частота памяти, ошибки драйвера в журнале, остались ли
#   настройки счётчиков загрузки PMU (их ставит служба автопереключения), снимки регистров памяти до/после.
#   Затем проверочный круг переключений 07 -> 0f -> 07 -> 03 — работает ли смена частот после сна.
# На время опыта служба автопереключения останавливается и в конце запускается снова.
# Порядок по риску: сначала 03 (память на стартовой 135), потом 07, потом 0f.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="$(dirname "$HERE")"
P="${1:-}"; SEC="${2:-20}"
case "$P" in 03|07|0f) ;; *) echo "Использование: sleep.sh 03|07|0f [секунд сна]"; exit 1;; esac
[[ "$SEC" =~ ^[0-9]+$ ]] && [ "$SEC" -ge 10 ] || { echo "Секунд сна — число не меньше 10"; exit 1; }
PRM=/sys/module/nouveau/parameters
declare -A MEM=([03]=135 [07]=324 [0f]=2004)

mkdir -p "$KIT/results"; TS="$(date +%Y%m%d-%H%M%S)"
LOG="$KIT/results/sleep-$P-$TS.txt"; SN="$KIT/results/sleep-$P-$TS-regs.txt"
say() { echo "$*" | tee -a "$LOG"; sync; }
ac() { sudo sh -c 'grep "^AC" /sys/kernel/debug/dri/*/pstate | head -n 1'; }
setp() { sudo sh -c "f=\$(ls /sys/kernel/debug/dri/*/pstate | head -n1); echo $1 > \"\$f\""; sleep 2; }
errs() { journalctl -k -b 0 --no-pager | grep -cE 'nouveau.*(ERROR|FAULT|fault|timeout|TIMEOUT|failed)' || true; }
pmu() {  # настройки счётчиков PMU (как их ставит служба) и прирост «все такты» за 1 с
    sudo python3 - <<'EOF'
import glob, mmap, os, struct, time
dev = next(d for d in glob.glob('/sys/bus/pci/devices/*')
           if open(d + '/vendor').read().strip() == '0x10de' and open(d + '/class').read().startswith('0x03'))
fd = os.open(dev + '/resource0', os.O_RDONLY | os.O_SYNC)
bar = mmap.mmap(fd, 16 << 20, mmap.MAP_SHARED, mmap.PROT_READ)
rd = lambda a: struct.unpack_from('<I', bar, a)[0]
want = {0x10a514: 0x70, 0x10a534: 0x180001, 0x10a544: 0x80, 0x10a554: 0x20000000, 0x10a57c: 3}
bad = [f'{a:06x}={rd(a):08x}(нужно {v:08x})' for a, v in want.items() if rd(a) != v]
c0 = rd(0x10a578) & 0x7fffffff; time.sleep(1); c1 = rd(0x10a578) & 0x7fffffff
print(('настройки счётчиков на месте' if not bad else 'настройки счётчиков ПОТЕРЯНЫ: ' + ' '.join(bad))
      + f'; счётчик тактов за 1 с: {(c1 - c0) & 0x7fffffff}')
EOF
}

echo "=== СОН И ПРОБУЖДЕНИЕ из режима $P (сон $SEC с)"
sudo -v || exit 1
# --- окружение
ok=1
if [ "$(modinfo -n nouveau)" = "/lib/modules/$(uname -r)/updates/nouveau-fix/nouveau.ko" ] && [ -e "$PRM/lab_mem_replay" ]; then echo "  ✓ лабораторный драйвер загружен"; else echo "  ✗ лабораторный драйвер НЕ загружен"; ok=0; fi
for kv in lab_mem_replay=15 lab_mem_op13=1 lab_gpc_seq=13 lab_mem_order=Y lab_mem=Y; do
    k="${kv%=*}"; v="${kv#*=}"; a="$(cat "$PRM/$k" 2>/dev/null || echo НЕТ)"
    [ "$a" = "$v" ] || { [ "$v" = Y ] && [ "$a" = 1 ]; } && printf '  ✓ %-15s = %s\n' "$k" "$a" || { printf '  ✗ %-15s = %s (нужно %s)\n' "$k" "$a" "$v"; ok=0; }
done
MS="$(cat /sys/power/mem_sleep 2>/dev/null || echo '?')"; echo "  вид сна: $MS (в скобках — текущий; deep = настоящий S3, карта обесточивается)"
command -v rtcwake >/dev/null && echo "  ✓ rtcwake есть" || { echo "  ✗ нет rtcwake"; ok=0; }
lsmod | grep -q '^ramoops' && echo "  ✓ ловушка ramoops включена" || echo "  ⚠ ловушка ramoops не загружена (опыт можно, но при падении улова не будет)"
[ "$ok" = 1 ] || { echo "--- СТОП: окружение не то (служба автопереключения ставит эти настройки — она запущена?). Опыт не запускаю."; exit 1; }
SVC=0; systemctl is-active --quiet gpu-autoclock.service && SVC=1
echo "  служба автопереключения: $([ $SVC = 1 ] && echo 'работает — остановлю на время опыта' || echo 'не запущена')"
echo "--- Окружение верное"
echo "Что будет: режим $P -> сон $SEC с -> само проснётся -> проверки -> круг 07 0f 07 03 -> служба снова запущена."
echo "Если после сна экран не включится за 1 минуту — нажми кнопку питания один раз; не поможет — держи 5 с (выключение)."
read -r -p "Начинаем? Enter — да, Ctrl+C — отмена " _

{ echo "Сон из $P $(date '+%F %T'), отпечаток $(md5sum "$0" | cut -c1-8), ядро $(uname -r), вид сна $MS"; } > "$LOG"; sync
[ $SVC = 1 ] && sudo systemctl stop gpu-autoclock.service
fin() { [ $SVC = 1 ] && sudo systemctl start gpu-autoclock.service && say "служба автопереключения снова запущена"; say "Лог: $LOG"; say "Регистры: $SN"; }

# --- до сна
setp "$P"; A="$(ac)"
case "$A" in *"memory ${MEM[$P]} MHz"*) say "до сна: ${A#*AC: } ✓";; *) say "--- СТОП: режим $P не встал: $A"; fin; exit 1;; esac
say "до сна: $(pmu)"
sudo python3 "$HERE/regsnap.py" "до сна $P" "$SN" >/dev/null
E0="$(errs)"; T0="$(date '+%F %T')"
say "$(date +%T) засыпаю на $SEC с..."
sudo rtcwake -m mem -s "$SEC" >/dev/null 2>&1; RC=$?
sleep 5
say "$(date +%T) проснулся (rtcwake вернул $RC)"

# --- после сна
A="$(ac)"; R="✗"; case "$A" in *"memory ${MEM[$P]} MHz"*) R="✓ тот же режим";; esac
say "после сна: ${A#*AC: } $R"
say "после сна: $(pmu)"
sudo python3 "$HERE/regsnap.py" "после сна $P" "$SN" >/dev/null
E1="$(errs)"; say "ошибок драйвера в журнале за сон: $((E1 - E0))"
say "--- журнал драйвера с момента сна (главное):"
journalctl -k -b 0 --no-pager --since "$T0" | grep -E 'nouveau|PM: (suspend|resume)|ACPI: PM' \
  | grep -E 'LAB (replay|pstate [0-9]+: (memory|done))|resum|suspend|ERROR|FAULT|fault|timeout|failed|init|PM:' \
  | sed -E 's/^.*kernel: //' | tail -n 40 | tee -a "$LOG"
D="$(python3 - "$SN" <<'EOF'
import sys
s, cur = {}, None
for l in open(sys.argv[1]):
    if l.startswith('### '): cur = l.split()[1] + ' ' + l.split()[2]; s[cur] = {}
    elif cur and len(l.split()) == 2 and not l.startswith('#'): a, v = l.split(); s[cur][a] = v
k = list(s)
if len(k) == 2:
    a, b = s[k[0]], s[k[1]]
    d = [f'{r}: {a[r]} -> {b.get(r)}' for r in a if a[r] != b.get(r)]
    print(f'регистров памяти изменилось за сон: {len(d)} из {len(a)}' + ('' if not d else '\n  ' + '\n  '.join(d[:20])))
EOF
)"; say "$D"

# --- проверочный круг переключений после сна
say "--- круг переключений после сна:"
ok=1
for Q in 07 0f 07 03; do
    setp "$Q"; A="$(ac)"; E="$(errs)"
    R="✗"; case "$A" in *"memory ${MEM[$Q]} MHz"*) R="✓";; esac
    [ "$E" -gt "$E1" ] && R="$R ошибки журнала: $((E - E1))"
    say "$(date +%T) -> $Q: ${A#*AC: } $R"
    case "$R" in "✓") ;; *) ok=0; say "--- СТОП круга: переход не удался"; break;; esac
done
[ "$ok" = 1 ] && say "=== Сон из $P: круг после сна прошёл ✅ (посмотри, были ли на экране артефакты)" || say "=== Сон из $P: есть сбой — пришли этот лог"
fin

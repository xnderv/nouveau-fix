#!/bin/bash
# СБОР ДАННЫХ О ВИДЕОКАРТЕ для проекта nouveau-fix — только чтение, в системе ничего не меняется.
# Снимает образ VBIOS вашей карты NVIDIA, коды PCI, уровни производительности nouveau, печатает разбор таблиц VBIOS,
# задаёт несколько вопросов о карте и с вашего согласия собирает всё в один архив в домашнем каталоге.
# Архив никуда не отправляется — вы отправляете его сами (см. README, раздел «Помочь проекту»).
# В архив не попадают имя компьютера, имя пользователя и пути домашнего каталога.
#   bash tools/card-report.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; KIT="$(dirname "$HERE")"
say() { printf '%s\n' "$*"; }
ask() { local a; read -r -p "$1 " a; printf '%s' "$a"; }

say "nouveau-fix card report — read-only (только чтение). Nothing on your system is changed."
say ""

# 1. карта NVIDIA (если их несколько — спросить)
mapfile -t GPUS < <(for d in /sys/bus/pci/devices/*; do
    [ "$(cat "$d/vendor" 2>/dev/null)" = 0x10de ] && case "$(cat "$d/class" 2>/dev/null)" in 0x03*) echo "$d";; esac; done)
[ "${#GPUS[@]}" -gt 0 ] || { say "No NVIDIA graphics card found (видеокарта NVIDIA не найдена)."; exit 1; }
DEV="${GPUS[0]}"
if [ "${#GPUS[@]}" -gt 1 ]; then
    for i in "${!GPUS[@]}"; do say "  $i: $(basename "${GPUS[$i]}") $(lspci -s "$(basename "${GPUS[$i]}")" 2>/dev/null | cut -d' ' -f2-)"; done
    n="$(ask "Which card? (какая карта?) [0]")"; DEV="${GPUS[${n:-0}]}"
fi
BDF="$(basename "$DEV")"
ID="$(sed 's/0x//' "$DEV/vendor"):$(sed 's/0x//' "$DEV/device")"
SUB="$(sed 's/0x//' "$DEV/subsystem_vendor"):$(sed 's/0x//' "$DEV/subsystem_device")"
DRV="$(basename "$(readlink "$DEV/driver" 2>/dev/null)" 2>/dev/null)"
say "Card (карта): $BDF  $ID  subsystem $SUB  driver: ${DRV:-none}"
say "$(lspci -nn -s "$BDF" 2>/dev/null | cut -d' ' -f2-)"
say ""
say "Reading the VBIOS needs root once (для чтения VBIOS нужен пароль sudo)."
sudo -v || exit 1

OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT

# 2. образ VBIOS: через debugfs nouveau (рабочая копия, с которой работает драйвер), иначе — ПЗУ карты через sysfs.
# /sys/kernel/debug доступен только root: список каталогов берём через sudo, а не шаблоном оболочки (24.10: шаблон без
# прав не раскрывался, и скрипт молча брал сырое ПЗУ — в нём таблицы лежат иначе и разбор выходит пустым).
got=""
for n in $(sudo sh -c 'ls -d /sys/kernel/debug/dri/* 2>/dev/null'); do
    if sudo grep -qs "$BDF" "$n/name" && sudo test -e "$n/vbios.rom"; then
        sudo cat "$n/vbios.rom" > "$OUT/vbios.rom" && got="nouveau debugfs ($n)"
        sudo cat "$n/pstate" > "$OUT/pstate.txt" 2>/dev/null
        break
    fi
done
if [ -z "$got" ] && [ -e "$DEV/rom" ]; then
    sudo sh -c "echo 1 > '$DEV/rom'; cat '$DEV/rom' > '$OUT/vbios.rom'; echo 0 > '$DEV/rom'" 2>/dev/null && got="PCI ROM (sysfs)"
fi
if [ -z "$got" ] || [ "$(head -c 2 "$OUT/vbios.rom" 2>/dev/null | od -An -tx1 | tr -d ' ')" != 55aa ]; then
    say "Could not read the VBIOS (не удалось прочитать VBIOS)."
    say "With nouveau loaded it is in /sys/kernel/debug/dri/*/vbios.rom; on Windows GPU-Z can save it (Save BIOS)."
    exit 1
fi
sudo chown "$(id -u):$(id -g)" "$OUT"/* 2>/dev/null
say "VBIOS: $(stat -c %s "$OUT/vbios.rom") bytes, read via $got"
echo "vbios source: $got" > "$OUT/source.txt"
case "$got" in PCI*) say "Note: this is the raw ROM; its tables may not decode. If you can, load nouveau and run again."
                     say "(Это сырое ПЗУ — таблицы в нём могут не разобраться. По возможности запустите снова под nouveau.)";; esac

# 3. системные сведения (без имени машины и пользователя)
{
    echo "card: $BDF $ID subsystem $SUB driver ${DRV:-none}"
    lspci -nn -s "$BDF"
    sudo lspci -vv -s "$BDF" 2>/dev/null | grep -E "Subsystem|LnkCap|LnkSta|Kernel driver|Kernel modules"
    echo "kernel: $(uname -r)"
    echo "distro: $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-?}")"
    [ -r /sys/module/nouveau/version ] && echo "nouveau module version: $(cat /sys/module/nouveau/version)"
    echo "nouveau module file: $(modinfo -n nouveau 2>/dev/null | sed "s|$HOME|~|")"
} > "$OUT/system.txt"
sudo dmesg 2>/dev/null | grep -iE "nouveau|nvidia|NVRM" | tail -n 200 | sed "s/$(hostname)/host/g; s|$HOME|~|g; s/$USER/user/g" > "$OUT/dmesg.txt"

# 4. разбор таблиц VBIOS
python3 -I "$KIT/lab/vbios-survey.py" --text "$OUT/vbios.rom" > "$OUT/summary.txt" 2>&1
say ""
say "=== VBIOS summary (разбор таблиц) ==="
cat "$OUT/summary.txt"
[ -s "$OUT/pstate.txt" ] && { say "=== nouveau performance levels (уровни nouveau) ==="; cat "$OUT/pstate.txt"; }
say ""

# 5. вопросы о карте
say "A few questions about the card (несколько вопросов о карте). Empty answer = don't know (пусто — не знаю)."
{
    echo "board vendor and model (as on the box/sticker): $(ask "Board vendor and model, e.g. Gigabyte GV-N560OC-1GI (производитель и модель с коробки/наклейки):")"
    echo "cooling: $(ask "Cooling: 1 fan / 2 fans / 3 fans / blower / passive / water (охлаждение: 1/2/3 вентилятора, турбина, пассивное, вода):")"
    echo "factory overclock: $(ask "Factory overclocked? yes / no / don't know (заводской разгон: да/нет/не знаю):")"
    echo "VBIOS ever flashed or edited: $(ask "Was this VBIOS ever flashed or edited? yes / no / don't know (перепрошивался ли VBIOS):")"
    echo "how it behaves with nouveau: $(ask "Anything we should know: hangs, artifacts, noise, temperature (что стоит знать: зависания, артефакты, шум, температура):")"
} > "$OUT/answers.txt"
say ""

# 6. согласие
say "Consent (согласие):"
say "  The VBIOS image is used only for research in the nouveau-fix project. The image itself is never published;"
say "  only values from its tables (frequencies, timings, flags) may appear in the project, without your name."
say "  (Образ VBIOS используется только для исследования в проекте nouveau-fix. Сам образ не публикуется; в проекте могут"
say "  появиться только значения из его таблиц — частоты, тайминги, флаги — без вашего имени.)"
c="$(ask "Do you agree? (согласны?) [y/N]")"
case "$c" in y|Y|yes|д|Д|да|Да) ;; *) say "No consent — nothing is saved (нет согласия — ничего не сохранено)."; exit 0;; esac
echo "consent: yes, $(date -u +%F)" >> "$OUT/answers.txt"

ARC="$HOME/nouveau-fix-card-${ID/:/-}-${SUB/:/-}-$(date +%Y%m%d).tar.gz"
tar czf "$ARC" -C "$OUT" .
say ""
say "Saved (сохранено): $ARC ($(stat -c %s "$ARC") bytes)"
say "Next (дальше): open a \"Card data\" issue on GitHub and paste summary.txt there; send the archive itself as the README says."
say "(откройте на GitHub заявку «Card data» и вставьте туда summary.txt; сам архив отправьте, как написано в README)"

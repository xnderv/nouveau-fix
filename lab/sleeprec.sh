#!/bin/bash
# «РЕГИСТРАТОР СНА» — постоянный бортовой самописец для редкого сбоя (21.10 17:34: systemd-sleep застрял
# после заморозки сеанса и до команды ядру, т.е. на «крючках сна»; повторить по заказу не удалось).
# При КАЖДОМ засыпании systemd сам запускает самописца: 5 раз в секунду он пишет, какие крючки сна
# (/usr/lib/systemd/system-sleep/*) сейчас выполняются и сколько, где ждут, кто в состоянии D, что делает
# служба автопереключения. Запись сразу сбрасывается на диск — переживает Reset. После пробуждения самописец
# останавливается. Хранятся 20 последних записей в /var/log/sleeprec/. Только читает, ничего не меняет.
#   sleeprec.sh install   — поставить (пароль)
#   sleeprec.sh show [N]  — показать последнюю (или N-ю с конца) запись кратко
#   sleeprec.sh remove    — убрать
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN=/usr/local/sbin/sleeprec-watch; UNIT=/etc/systemd/system/sleeprec.service; DIR=/var/log/sleeprec
case "${1:-}" in
install)
    sudo tee "$BIN" >/dev/null <<'EOF'
#!/bin/bash
# самописец сна (ставится ~/nouveau-fix/lab/sleeprec.sh install)
DIR=/var/log/sleeprec; mkdir -p "$DIR"
ls -1t "$DIR"/*.txt 2>/dev/null | tail -n +20 | xargs -r rm -f
W="$DIR/$(date +%Y%m%d-%H%M%S).txt"
SPID="$(systemctl show -p MainPID --value gpu-autoclock.service 2>/dev/null)"
{ echo "### самописец сна $(date '+%F %T.%N' | cut -c1-23), ядро $(uname -r)"
  echo "крючки: $(ls /usr/lib/systemd/system-sleep /etc/systemd/system-sleep 2>/dev/null | tr '\n' ' ')"
  echo "служба автопереключения: pid ${SPID:-нет}"; } > "$W"; sync "$W"
declare -A FIRST
while true; do
  T="$(date +%T.%N | cut -c1-12)"; OUT=""
  for p in $(pgrep -x systemd-sleep); do
    OUT+="systemd-sleep $p: $(awk '/^State/{print $2}' /proc/$p/status 2>/dev/null) ждёт: $(cat /proc/$p/wchan 2>/dev/null)"$'\n'
    for c in $(pgrep -P "$p"); do
      for g in $c $(pgrep -P "$c"); do
        CMD="$(tr '\0' ' ' < /proc/$g/cmdline 2>/dev/null | cut -c1-120)"; [ -n "$CMD" ] || continue
        [ -n "${FIRST[$g]:-}" ] || FIRST[$g]="$(date +%s.%N)"
        AGE="$(echo "$(date +%s.%N) - ${FIRST[$g]}" | bc 2>/dev/null | cut -c1-5)"
        OUT+="  $g [$AGE с] $CMD | $(awk '/^State/{print $2}' /proc/$g/status 2>/dev/null) | ждёт: $(cat /proc/$g/wchan 2>/dev/null)"$'\n'
        for k in $(pgrep -P "$g"); do
          OUT+="     └ $k $(tr '\0' ' ' < /proc/$k/cmdline 2>/dev/null | cut -c1-120) | $(awk '/^State/{print $2}' /proc/$k/status 2>/dev/null) | ждёт: $(cat /proc/$k/wchan 2>/dev/null)"$'\n'
        done
      done
    done
  done
  D="$(ps -eo pid,stat,wchan:30,args --no-headers | awk '$2 ~ /^D/' | cut -c1-160)"
  [ -n "$D" ] && OUT+="$(sed 's/^/D: /' <<<"$D")"$'\n'
  [ -n "$SPID" ] && [ -d "/proc/$SPID" ] && OUT+="служба: $(awk '/^State/{print $2}' /proc/$SPID/status) ждёт: $(cat /proc/$SPID/wchan)"$'\n'
  printf '=== %s\n%s' "$T" "$OUT" >> "$W"; sync "$W"
  sleep 0.2
done
EOF
    sudo chmod 0755 "$BIN"
    sudo tee "$UNIT" >/dev/null <<EOF
[Unit]
Description=Самописец сна: что делают крючки сна (диагностика, ~/nouveau-fix/lab/sleeprec.sh)
Before=sleep.target
StopWhenUnneeded=yes

[Service]
Type=exec
ExecStart=$BIN
TimeoutStopSec=5

[Install]
WantedBy=sleep.target
EOF
    command -v bc >/dev/null || echo "⚠ нет программы bc — время работы крючков писаться не будет (остальное — да)"
    sudo systemctl daemon-reload && sudo systemctl enable sleeprec.service && echo "=== Самописец сна поставлен: включается сам при каждом засыпании."
    ;;
show)
    N="${2:-1}"; F="$(sudo ls -1t "$DIR"/*.txt 2>/dev/null | sed -n "${N}p")"
    [ -n "$F" ] || { echo "Записей нет"; exit 1; }
    echo "--- $F ($(sudo grep -c '^===' "$F") отметок)"
    sudo head -n 3 "$F"
    echo "--- отметки, где что-то происходило (первые 25 и последние 25):"
    sudo awk '/^===/{t=$0; next} {print t" | "$0}' "$F" | grep -v '| служба: S' | head -n 25
    echo "..."
    sudo awk '/^===/{t=$0; next} {print t" | "$0}' "$F" | grep -v '| служба: S' | tail -n 25
    ;;
remove)
    sudo systemctl disable sleeprec.service 2>/dev/null; sudo rm -f "$UNIT" "$BIN"; sudo systemctl daemon-reload
    echo "Самописец убран (записи остались в $DIR)" ;;
*) sed -n '2,9p' "$0"; exit 1;;
esac

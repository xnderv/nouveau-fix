#!/bin/bash
# Меню стенда Ubuntu 10.04: всё делается одной цифрой, набирать команды не нужно. Запускается само при входе на tty1
# (~/.bash_profile кладёт lucid-disk.sh put). Текст латиницей: кириллица в консоли 10.04 может не отображаться.
HERE="$(cd "$(dirname "$0")" && pwd)"
nvver() {
  local f; f="$(find "/lib/modules/$(uname -r)" -name nvidia.ko 2>/dev/null | head -n 1)"
  [ -n "$f" ] && grep -ao 'Kernel Module  *[0-9][0-9.]*' "$f" | head -n 1 | awk '{print $NF}'
}
while true; do
  clear
  NV="$(nvver)"
  echo "=================================================================="
  echo "  NVIDIA 270 stand  |  Ubuntu 10.04, kernel $(uname -r)"
  echo "  Installed NVIDIA driver: ${NV:-none}"
  if [ -e /tmp/stand-card-used ]; then
    echo "  Card already used in this boot ($(cat /tmp/stand-card-used | tr -cd '[:alnum:]. ')) - reboot before recording"
  else
    echo "  Card is clean (fresh boot) - ready to record"
  fi
  echo "  Recordings:"
  ls -d "$HERE"/out-* 2>/dev/null | sed 's|.*/out-|     |' || true
  echo "=================================================================="
  echo "   1   Install driver 270.26"
  echo "   2   Install driver 270.41.06"
  echo "   3   RECORD with the installed driver (~9 min, do not touch)"
  echo "   4   Reboot   (F12 -> ST120FN0 = back to this menu; no F12 = main Ubuntu)"
  echo "   5   Power off"
  echo "   0   Exit to command line"
  echo
  read -r -n 1 -p "  Press a digit: " k; echo; echo
  case "$k" in
    1) sudo "$HERE/install-nvidia-lucid.sh" 270.26 ;;
    2) sudo "$HERE/install-nvidia-lucid.sh" 270.41.06 ;;
    3) sudo "$HERE/run-trace-lucid.sh" ;;
    4) sudo reboot; sleep 120 ;;
    5) sudo poweroff; sleep 120 ;;
    0) exit 0 ;;
    *) continue ;;
  esac
  echo
  read -r -p "  Press Enter to return to the menu " _
done

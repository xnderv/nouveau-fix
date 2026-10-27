#!/bin/bash
# ТОЛЬКО ЧТЕНИЕ регистров через resource0 (как regdump4.py) + переключение уровня через pstate (как в hangtest.sh).
# 27.10: на стенде 2011 в двух загрузках, где 270.x падал на старте X (Xid 38 FECS, Xid 32), блок 0x1320e8–0x132124 перед
# загрузкой драйвера был «живой» (0x132124 = 1, слова не ffffffff); во всех 13 удачных — ffffffff и 0x132124 = 0.
# Вопрос: когда этот блок оживает в 22.04 — после перехода памяти на 2004? на 135? — и гаснет ли обратно.
# Запуск: bash ~/Home/nouveau-fix/lab/memunit-probe.sh   (sudo спросит пароль; ~20 с; регулятор возвращается)
set -u
PRM=/sys/module/nouveau/parameters
PSF="$(sudo sh -c 'ls /sys/kernel/debug/dri/*/pstate' | head -n1)"
rd() { sudo python3 -I - <<'PY'
import mmap, os, glob
d=[x for x in glob.glob('/sys/bus/pci/devices/*') if open(x+'/vendor').read().strip()=='0x10de' and open(x+'/class').read().startswith('0x03')][0]
fd=os.open(d+'/resource0', os.O_RDONLY|os.O_SYNC); m=mmap.mmap(fd, 16<<20, mmap.MAP_SHARED, mmap.PROT_READ)
w=lambda r: int.from_bytes(m[r:r+4],'little')
print('    132124=%08x  1320e8..13210c: %s  132100=%08x 132000=%08x' % (w(0x132124), ' '.join('%08x'%w(r) for r in range(0x1320e8,0x132110,4)), w(0x132100), w(0x132000)))
PY
}
ac() { sudo sh -c "grep '^AC' '$PSF'" | sed 's/^AC: //'; }
G0="$(cat $PRM/lab_gov)"; sudo sh -c "echo 0 > $PRM/lab_gov"
echo "$(date +%T) сейчас: $(ac) (lab_mem=$(cat $PRM/lab_mem))"; rd
for lv in 07 0f 07 03 07; do sudo sh -c "echo $lv > '$PSF'"; sleep 3; echo "$(date +%T) после $lv: $(ac)"; rd; done
sudo sh -c "echo $G0 > $PRM/lab_gov"; echo "регулятор возвращён (lab_gov=$G0)"

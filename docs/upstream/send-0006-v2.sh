#!/bin/bash
# Отправка v2 патча 0006 (вентилятор) после ответа Martin Roukala 29.10: короче описание, его Acked-by.
# Строку подписи печатает сам автор (Documentation/process/coding-assistants.rst: ИИ-ассистент её не ставит).
# Запуск: bash ~/Home/nouveau-fix/docs/upstream/send-0006-v2.sh   (дальше git send-email спросит y и пароль приложения)
set -euo pipefail
cd "$(dirname "$0")"
P=v2-0006-drm-nouveau-therm-mask-pwm-update-bit.patch
echo "Патч v2 0006: описание из одного абзаца + строка про ИИ-ассистента, подробности под ---, Acked-by Мартина."
echo "Напечатай свою строку подписи целиком, как в образце, и нажми Enter:"
echo "    Signed-off-by: Alex <xnderv@yandex.com>"
read -r -p "> " SOB
[[ "$SOB" =~ ^Signed-off-by:\ [^\<]+\ \<[^\>]+@[^\>]+\>$ ]] || { echo "Строка не похожа на подпись — ничего не отправлено."; exit 1; }
OUT="$(mktemp --suffix=.patch)"; trap 'rm -f "$OUT"' EXIT
sed "s|^@@SOB@@\$|$SOB|" "$P" > "$OUT"
grep -q '@@SOB@@' "$OUT" && { echo "Подпись не подставилась — ничего не отправлено."; exit 1; }
cd ~/Home/nouveau-fix
git send-email --to='Lyude Paul <lyude@redhat.com>' --to='Danilo Krummrich <dakr@kernel.org>' \
  --cc='Martin Roukala <martin.roukala@mupuf.org>' --cc=dri-devel@lists.freedesktop.org \
  --cc=nouveau@lists.freedesktop.org --cc=linux-kernel@vger.kernel.org "$OUT"

#!/bin/bash
# Ответ в ветку 0006 (письмо 25.10.2026 13:16 ушло без подписи автора): короткое письмо со строкой Signed-off-by.
# Строку подписи вводит сам автор — по правилам ядра (Documentation/process/coding-assistants.rst) ИИ-ассистент её не
# ставит: подпись означает, что человек прочитал патч и отвечает за него.
# Запуск: bash ~/Home/nouveau-fix/docs/upstream/reply-0006-signoff.sh
set -euo pipefail
MSGID='<20261025101640.49779-1-xnderv@yandex.com>'
echo "Это ответ в ветку письма 0006 ($MSGID): «забыл подпись, вот она»."
echo "Напечатай свою строку подписи целиком, как в образце, и нажми Enter:"
echo "    Signed-off-by: Alex <xnderv@yandex.com>"
read -r -p "> " SOB
if ! [[ "$SOB" =~ ^Signed-off-by:\ [^\<]+\ \<[^\>]+@[^\>]+\>$ ]]; then
    echo "Строка не похожа на образец — ничего не отправлено. Запусти ещё раз."; exit 1
fi
F="$(mktemp --suffix=.txt)"
cat > "$F" <<EOF
From: Alex <xnderv@yandex.com>
Subject: Re: [PATCH] drm/nouveau/therm: mask the update bit when reading back the fan PWM duty

I forgot to add my sign-off to this patch, sorry about that:

$SOB
EOF
echo; echo "===== письмо ====="; cat "$F"; echo "=================="; echo
git send-email --suppress-cc=all --in-reply-to="$MSGID" \
  --to='Lyude Paul <lyude@redhat.com>' --to='Danilo Krummrich <dakr@kernel.org>' \
  --cc=dri-devel@lists.freedesktop.org --cc=nouveau@lists.freedesktop.org \
  --cc=linux-kernel@vger.kernel.org --cc=stable@vger.kernel.org --cc=xnderv@yandex.com \
  "$F"
rm -f "$F"

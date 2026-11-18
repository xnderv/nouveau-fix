#!/bin/bash
# Напоминание (ping) по двум патчам, на которые сопровождающие не ответили (по lore на 18.11.2026 ответов нет):
#   0001 v2 (23.10) — idle the channel before destroying an engine object via abi16;
#   0006 v2 (29.10, Acked-by Martin Roukala) — mask the update bit when reading back the fan PWM duty.
# Оба патча 18.11 проверены: накладываются на torvalds/linux master без правок.
# Письма — ответы в свои ветки (In-Reply-To), те же адресаты. Перед отправкой каждое письмо печатается и спрашивается «да».
#   bash ~/Home/nouveau-fix/docs/upstream/ping-2026-11-18.sh
set -euo pipefail
send() {   # $1 Message-ID ветки, $2 тема, $3 текст, остальное — доп. копии
  local id="$1" subj="$2" body="$3"; shift 3
  local F; F="$(mktemp --suffix=.txt)"
  printf 'From: Alex <xnderv@yandex.com>\nSubject: Re: %s\n\n%s\n' "$subj" "$body" > "$F"
  echo; echo "===== ответ в ветку $id ====="; cat "$F"; echo "=================="
  read -r -p "Отправить это письмо? (да/нет) " a
  if [ "$a" = "да" ]; then
    git send-email --suppress-cc=all --in-reply-to="$id" \
      --to='Lyude Paul <lyude@redhat.com>' --to='Danilo Krummrich <dakr@kernel.org>' \
      --cc=dri-devel@lists.freedesktop.org --cc=nouveau@lists.freedesktop.org \
      --cc=linux-kernel@vger.kernel.org "$@" --cc=xnderv@yandex.com "$F"
  else
    echo "Не отправлено."
  fi
  rm -f "$F"
}

send '<20261023152332.9420-2-xnderv@yandex.com>' \
  '[PATCH v2] drm/nouveau: idle the channel before destroying an engine object via abi16' \
'Hi,

Gentle ping on this one. v2 addresses the review comment on v1 (wait for
the scheduler job queue to drain before idling the channel). It still
applies cleanly to current mainline (checked today, 2026-11-18).

Is there anything else you would like me to change?

Thanks,
Alex'

send '<20261029130012.21738-1-xnderv@yandex.com>' \
  '[PATCH v2] drm/nouveau/therm: mask the update bit when reading back the fan PWM duty' \
'Hi,

Gentle ping on this one. v2 trims the commit message as Martin asked
and carries his Acked-by. It still applies cleanly to current mainline
(checked today, 2026-11-18).

Thanks,
Alex' \
  --cc='Martin Roukala <martin.roukala@mupuf.org>' --cc=stable@vger.kernel.org

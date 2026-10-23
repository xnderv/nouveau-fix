# Ответ на замечание Sashiko AI к v1 (черновик, отправляется как ответ в ту же ветку)

Кому: ответ на письмо Sashiko (Reply-All: списки + сопровождающие остаются в копии).
Тема сохраняется: Re: [PATCH] drm/nouveau: idle the channel before destroying an engine object via abi16

```
Thanks, the race is real.

Legacy PUSHBUF submissions take cli->mutex (nouveau_abi16_get()), so they
are serialized with nouveau_abi16_ioctl_del(), which is why the Chromium
case was fixed by the plain nouveau_channel_idle().  With VM_BIND the
EXEC jobs are pushed from the scheduler workqueue without cli->mutex, so
emitting a fence from the ioctl could indeed race with
nouveau_exec_job_run(), and jobs still queued in the entity would not be
covered by the fence at all.

v2 waits for the channel's scheduler to drain first (the same job-list
wait nouveau_sched_fini() already does, factored out as
nouveau_sched_wait_idle()), then idles the channel.  New EXEC
submissions cannot sneak in meanwhile because the EXEC ioctl also holds
cli->mutex.
```

Отправка v2 (после ответа): из каталога репозитория

```
git send-email --suppress-cc=all --in-reply-to='<20261023144219.46478-1-xnderv@yandex.com>' \
  --to='Lyude Paul <lyude@redhat.com>' --to='Danilo Krummrich <dakr@kernel.org>' \
  --cc='Karol Herbst <kherbst@redhat.com>' --cc=nouveau@lists.freedesktop.org \
  --cc=dri-devel@lists.freedesktop.org --cc=linux-kernel@vger.kernel.org --cc=xnderv@yandex.com \
  docs/upstream/v2-0001-drm-nouveau-idle-channel-before-engobj-dtor.patch
```

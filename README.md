# whisper-railway

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/whisper-stt-api-or-just-updated-transcri?referralCode=Z1xivh&utm_medium=integration&utm_source=template&utm_campaign=generic)

**Deploy on Railway:** [Whisper STT API template](https://railway.com/deploy/whisper-stt-api-or-just-updated-transcri?referralCode=Z1xivh&utm_medium=integration&utm_source=template&utm_campaign=generic)

Wrapper image for the Railway template **Whisper STT API** — [Speaches](https://github.com/speaches-ai/speaches)
0.9.0-rc.3 (faster-whisper / CTranslate2) serving the OpenAI-compatible
`/v1/audio/transcriptions` and `/v1/audio/translations` endpoints.

Image: `ghcr.io/bon5co/whisper-railway:0.9.0-rc.3`

## What this adds to the upstream image

Everything here was measured against the upstream image on the same host,
`--cpus 2 --memory 2g`, transcribing the same 60.9 s WAV with
`Systran/faster-whisper-small` at `int8`.

1. **The model is baked into the image.** Speaches does not download a model on
   demand: a deploy whose cache is empty answers `404 Model 'Systran/faster-whisper-small'
   is not installed locally` to every transcription request, while the container
   stays healthy and `/v1/models` lists only `silero_vad_v5`. Because a Railway
   volume is a bind mount that hides whatever the image build wrote underneath
   it, the weights are baked to `/opt/speaches-models/hub` and copied onto the
   volume by the entrypoint on first boot.
2. **The CTranslate2 thread pool is sized from the cgroup.**
   `WhisperConfig.cpu_threads` defaults to `0`, which lets CTranslate2 pick a
   thread count from the cores it can see — the host's, not the container's
   (`nproc` reported 5 inside a `--cpus 2` container). Warm transcriptions of the
   same file measured 15.03 s / 14.35 s unset versus 11.54 s / 11.69 s pinned to
   the quota.
3. **The volume is repaired and the server runs unprivileged.** Railway mounts
   volumes as uid 0 and the image runs as `ubuntu` (uid 1000), so the entrypoint
   chowns the cache and `setpriv`s down instead of running the whole server as
   root.
4. **`$PORT` is honoured.** The image bakes `UVICORN_PORT=8000`; Railway's HTTP
   healthcheck dials the port it injects, so the entrypoint binds that instead.
5. **It refuses to boot without `API_KEY`.** Speaches only installs its auth
   dependency when a key is configured, so an empty key publishes every audio
   endpoint to whoever finds the URL.

## Environment

| Variable | Default | Notes |
|---|---|---|
| `API_KEY` | — | Required. Bearer token for every `/v1/*` route. |
| `PORT` | injected by Railway | Bound by the entrypoint. |
| `WHISPER__CPU_THREADS` | cgroup quota | Set explicitly to override. |
| `STT_MODEL_TTL` | `-1` | Keep the model resident. |
| `ENABLE_UI` | `false` | The Gradio playground is served without auth. |

## Local run

```
docker run --rm -p 8000:8000 -e API_KEY=secret -e PORT=8000 \
  -v speaches-cache:/home/ubuntu/.cache/huggingface/hub \
  ghcr.io/bon5co/whisper-railway:0.9.0-rc.3

curl -s -X POST http://localhost:8000/v1/audio/transcriptions \
  -H "Authorization: Bearer secret" \
  -F file=@audio.wav -F model=Systran/faster-whisper-small -F response_format=text
```

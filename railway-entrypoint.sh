#!/usr/bin/env bash
# Railway entrypoint for the Speaches (faster-whisper) speech-to-text API.
#
# Four jobs, in order:
#   1. Refuse to boot without an API key — every route in Speaches is open when
#      `API_KEY` is unset, and an open transcription endpoint on a public URL is
#      somebody else's free CPU.
#   2. Size the CTranslate2 thread pool from the container's cgroup quota.
#      `WhisperConfig.cpu_threads` defaults to 0, which makes CTranslate2 pick a
#      thread count from the number of cores it can SEE — the host's, not the
#      cgroup's — and the resulting oversubscription costs real wall-clock on
#      every request.
#   3. Seed the baked model cache onto the volume, then repair the volume's
#      ownership and drop back to the image's `ubuntu` user (uid 1000). Railway
#      mounts volumes as uid 0, which is why every competing listing sets
#      `RAILWAY_RUN_UID=0` and runs the whole server as root instead.
#   4. Bind the port Railway injected, so the platform's HTTP healthcheck (which
#      dials the injected port, not the domain's target port) reaches the app.
set -euo pipefail

log() { echo "[railway-entrypoint] $*"; }

HF_CACHE="${HF_HUB_CACHE:-/home/ubuntu/.cache/huggingface/hub}"
BAKED_CACHE="/opt/speaches-models/hub"
APP_UID=1000
APP_GID=1000

# ---------------------------------------------------------------- 1. API key
if [ -z "${API_KEY:-}" ]; then
    log "FATAL: API_KEY is empty. Speaches applies its auth dependency only when"
    log "       API_KEY is set, so booting without one would publish /v1/audio/*"
    log "       to anyone who finds the URL. Set API_KEY and redeploy."
    exit 1
fi

# ------------------------------------------------------------------ 2. threads
# cpu.max is "<quota> <period>" (cgroup v2) or the string "max" when unlimited.
cpu_quota() {
    local line quota period
    if [ -r /sys/fs/cgroup/cpu.max ]; then
        read -r quota period < /sys/fs/cgroup/cpu.max || return 1
        [ "$quota" = "max" ] && return 1
        echo $(( (quota + period - 1) / period ))
        return 0
    fi
    if [ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us ] && [ -r /sys/fs/cgroup/cpu/cpu.cfs_period_us ]; then
        quota=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us)
        period=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)
        [ "$quota" -le 0 ] && return 1
        echo $(( (quota + period - 1) / period ))
        return 0
    fi
    return 1
}

VISIBLE_CPUS="$(nproc)"
if CPUS="$(cpu_quota)"; then
    :
else
    CPUS="$VISIBLE_CPUS"
    log "no cgroup cpu quota found, falling back to the visible core count"
fi
[ "$CPUS" -lt 1 ] && CPUS=1

export WHISPER__CPU_THREADS="${WHISPER__CPU_THREADS:-$CPUS}"
export OMP_NUM_THREADS="${OMP_NUM_THREADS:-$CPUS}"
export MKL_NUM_THREADS="${MKL_NUM_THREADS:-$CPUS}"
export OPENBLAS_NUM_THREADS="${OPENBLAS_NUM_THREADS:-$CPUS}"
log "cpu: visible=$VISIBLE_CPUS quota=$CPUS -> WHISPER__CPU_THREADS=$WHISPER__CPU_THREADS OMP_NUM_THREADS=$OMP_NUM_THREADS"

# ------------------------------------------------------- 3. models + ownership
mkdir -p "$HF_CACHE"

# A Railway volume is a bind mount: it HIDES whatever the image build wrote
# under its path. The models are therefore baked outside the mount and copied
# in on every boot, skipping anything already present.
if [ -d "$BAKED_CACHE" ]; then
    seeded=0
    for src in "$BAKED_CACHE"/*; do
        [ -e "$src" ] || continue
        name="$(basename "$src")"
        if [ ! -e "$HF_CACHE/$name" ]; then
            cp -r "$src" "$HF_CACHE/$name"
            seeded=$((seeded + 1))
        fi
    done
    log "baked models: seeded=$seeded present=$(ls -1 "$HF_CACHE" | wc -l)"
fi

if [ "$(id -u)" = "0" ]; then
    chown -R "$APP_UID:$APP_GID" "$HF_CACHE"
    log "volume $HF_CACHE owner=$(stat -c %u:%g "$HF_CACHE") (repaired), dropping to uid $APP_UID"
    DROP=1
else
    log "already running as $(id -u):$(id -g), not repairing volume ownership"
    DROP=0
fi

# --------------------------------------------------------------------- 4. port
# Railway injects PORT into every service and its HTTP healthcheck dials that
# injected port. The image bakes UVICORN_PORT=8000, so without this line the
# server listens on 8000 while the healthcheck knocks on 8080.
export UVICORN_PORT="${PORT:-${UVICORN_PORT:-8000}}"
export UVICORN_HOST="${UVICORN_HOST:-0.0.0.0}"
log "listening on ${UVICORN_HOST}:${UVICORN_PORT}"

if [ "$DROP" = "1" ]; then
    exec setpriv --reuid="$APP_UID" --regid="$APP_GID" --clear-groups "$@"
fi
exec "$@"

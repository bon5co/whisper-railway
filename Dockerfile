# Whisper speech-to-text API for Railway.
#
# Upstream is Speaches (OpenAI-compatible /v1/audio/* server on top of
# faster-whisper). This wrapper adds three things a plain image reference
# cannot: the STT model baked into the image so the first request after a
# deploy answers instead of downloading, a CTranslate2 thread pool sized from
# the container's cgroup quota, and a volume whose ownership is repaired
# before the server drops back to the image's non-root user.
FROM ghcr.io/speaches-ai/speaches:0.9.0-rc.3-cpu

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends util-linux \
    && rm -rf /var/lib/apt/lists/*

# Bake the default STT model OUTSIDE the volume's mount path. A Railway volume
# is a bind mount and hides anything the image build left underneath it, so the
# entrypoint copies from here onto the volume on first boot.
ENV BAKED_MODEL="Systran/faster-whisper-small"
RUN HF_HUB_CACHE=/opt/speaches-models/hub \
    /home/ubuntu/speaches/.venv/bin/python -c "\
from huggingface_hub import snapshot_download; \
snapshot_download('${BAKED_MODEL}')" \
    && chown -R ubuntu:ubuntu /opt/speaches-models

# Defaults that belong to the image, not to the deploy form. A template
# variable holding a literal is dropped at generate time and republishes as a
# blank required field, so everything with one sane value lives here.
ENV ENABLE_UI=false \
    LOG_LEVEL=info \
    STT_MODEL_TTL=-1 \
    TTS_MODEL_TTL=300 \
    WHISPER__INFERENCE_DEVICE=cpu \
    WHISPER__COMPUTE_TYPE=int8 \
    HF_HUB_DISABLE_TELEMETRY=1 \
    DO_NOT_TRACK=1

COPY railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh
RUN chmod +x /usr/local/bin/railway-entrypoint.sh

EXPOSE 8000
ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]
CMD ["uvicorn", "--factory", "speaches.main:create_app"]

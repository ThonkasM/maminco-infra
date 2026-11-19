# syntax=docker/dockerfile:1
# =============================================================================
# maminco-ai — FastAPI forecasting service (single source of truth)
# Build context: ../maminco-ai (the app repo has no Dockerfile of its own)
#   docker build -f docker/ai.Dockerfile ../maminco-ai
#
# All runtime dependencies ship as binary wheels (pinned in requirements.txt),
# so no compiler toolchain is installed.
#
# Base image pinning: the tag is fixed. To pin by digest as well, pass
#   --build-arg PYTHON_IMAGE=python:<tag>@sha256:<digest>
# =============================================================================
ARG PYTHON_IMAGE=python:3.12.12-slim-bookworm

FROM ${PYTHON_IMAGE} AS builder
ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
COPY requirements.txt ./
RUN pip install --only-binary=:all: -r requirements.txt

FROM ${PYTHON_IMAGE} AS runtime
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH" \
    AI_MODEL_DIR=/app/data/models
WORKDIR /app
RUN apt-get update \
    && apt-get install -y --no-install-recommends tini \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 --no-create-home appuser \
    && mkdir -p /app/data/models \
    && chown -R appuser:appuser /app/data
COPY --from=builder /opt/venv /opt/venv
COPY --chown=appuser:appuser app ./app
USER appuser
EXPOSE 8000
HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=5 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=4).status == 200 else 1)"
ENTRYPOINT ["/usr/bin/tini", "-s", "--"]
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]

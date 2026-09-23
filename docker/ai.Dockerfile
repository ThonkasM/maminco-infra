# syntax=docker/dockerfile:1
# =============================================================================
# maminco-ai — FastAPI ML service (uvicorn app.main:app)
# Build context: ../maminco-ai   (the app repo; keeps it untouched)
#   docker build -f docker/ai.Dockerfile ../maminco-ai
#
# Assumes the standard layout: requirements.txt, app/main.py and an optional
# requirements-dev.txt (dev/test only).
# =============================================================================

# --- build stage: produce a self-contained virtualenv -----------------------
FROM python:3.11-slim AS builder

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app

# Build deps for wheels that need to compile (numpy/scipy/pandas, etc.).
RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential \
    && rm -rf /var/lib/apt/lists/*

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY requirements.txt ./
RUN pip install --upgrade pip && pip install -r requirements.txt

# --- runtime stage -----------------------------------------------------------
FROM python:3.11-slim AS runner

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH" \
    PORT=8000

WORKDIR /app

# libgomp1 is commonly needed by scikit-learn / xgboost style wheels.
RUN apt-get update \
    && apt-get install -y --no-install-recommends libgomp1 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/venv /opt/venv

# Non-root service account.
RUN useradd --create-home --uid 10001 appuser
COPY --chown=appuser:appuser . .
USER appuser

EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]

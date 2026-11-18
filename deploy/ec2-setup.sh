#!/usr/bin/env bash
# =============================================================================
# Maminco — EC2 bootstrap/setup (run ON the instance, as ec2-user)
# =============================================================================
# Installs Docker + Compose (if missing), clones/updates the repositories,
# creates .env from the template, and brings the stack up.
#
# Usage (on the instance):
#   curl -fsSL <raw-url>/deploy/ec2-setup.sh | bash
#   # or, after cloning:
#   PUBLIC_HOST=ec2-1-2-3-4.compute.amazonaws.com ./deploy/ec2-setup.sh
#
# Environment overrides:
#   APP_DIR          default /opt/maminco
#   GITHUB_BASE_URL  default https://github.com/ThonkasM
#   GIT_BRANCH       default main
#   PUBLIC_HOST      if set, used to fill DOMAIN and the public URLs in .env
#   PUBLIC_SCHEME    https (default) or http (dev / before the certificate exists)
#   COMPOSE_VERSION  pinned Docker Compose release (checksums below)
# =============================================================================
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/maminco}"
GITHUB_BASE_URL="${GITHUB_BASE_URL:-https://github.com/ThonkasM}"
GIT_BRANCH="${GIT_BRANCH:-main}"
PUBLIC_HOST="${PUBLIC_HOST:-}"
PUBLIC_SCHEME="${PUBLIC_SCHEME:-https}"
COMPOSE_VERSION="${COMPOSE_VERSION:-v5.1.0}"
COMPOSE_SHA256_AARCH64="da671ae15b4d7c68c38b572a2e9ceba89f09657d2682c2d2e34ad6db828e7442"
COMPOSE_SHA256_X86_64="5633cb21e06a7c88c7ca48a9334d3d0f7f892e9605ae9e9a45f9a095d4ffceb8"
REPOS=(maminco-infra maminco-backend maminco-frontend maminco-ai)

log()  { printf '\033[36m[setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[warn ]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# 1. Docker + Compose
# -----------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
    log "Installing Docker..."
    if command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y docker git
    elif command -v yum >/dev/null 2>&1; then
        sudo yum install -y docker git
    else
        die "Unsupported distro: need dnf or yum."
    fi
    sudo systemctl enable --now docker
else
    log "Docker already installed: $(docker --version)"
fi

if ! docker compose version >/dev/null 2>&1; then
    log "Installing Docker Compose plugin..."
    case "$(uname -m)" in
        aarch64) ARCH=aarch64; SHA="${COMPOSE_SHA256_AARCH64}" ;;
        x86_64)  ARCH=x86_64;  SHA="${COMPOSE_SHA256_X86_64}" ;;
        *)       die "Unsupported architecture: $(uname -m)" ;;
    esac
    [ "${COMPOSE_VERSION}" = "v5.1.0" ] || die "Checksums are only embedded for v5.1.0; update this script to bump."
    sudo mkdir -p /usr/libexec/docker/cli-plugins
    curl -fsSL \
        "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-${ARCH}" \
        -o /tmp/docker-compose
    echo "${SHA}  /tmp/docker-compose" | sha256sum -c -
    sudo install -m 0755 /tmp/docker-compose /usr/libexec/docker/cli-plugins/docker-compose
    rm -f /tmp/docker-compose
fi

if ! docker info >/dev/null 2>&1; then
    warn "Current user cannot talk to the Docker daemon yet."
    warn "Log out and back in (docker group), or prefix commands with sudo."
fi

COMPOSE="docker compose"
if ! docker info >/dev/null 2>&1; then
    COMPOSE="sudo docker compose"
fi

# -----------------------------------------------------------------------------
# 2. Repositories
# -----------------------------------------------------------------------------
mkdir -p "${APP_DIR}"
cd "${APP_DIR}"

for repo in "${REPOS[@]}"; do
    if [ -d "${APP_DIR}/${repo}/.git" ]; then
        log "Updating ${repo}..."
        git -C "${APP_DIR}/${repo}" fetch --quiet origin
        git -C "${APP_DIR}/${repo}" checkout --quiet "${GIT_BRANCH}"
        git -C "${APP_DIR}/${repo}" pull --ff-only --quiet origin "${GIT_BRANCH}"
    else
        log "Cloning ${repo}..."
        if ! git clone --branch "${GIT_BRANCH}" "${GITHUB_BASE_URL}/${repo}.git" "${APP_DIR}/${repo}"; then
            warn "Skipping ${repo} (clone failed — does it exist yet?)"
        fi
    fi
done

INFRA_DIR="${APP_DIR}/maminco-infra"
[ -d "${INFRA_DIR}" ] || die "maminco-infra was not cloned into ${APP_DIR}."
cd "${INFRA_DIR}"

# -----------------------------------------------------------------------------
# 3. Environment file
# -----------------------------------------------------------------------------
set_env() {
    sed -i.bak "s#^$1=.*#$1=$2#" .env && rm -f .env.bak
}

if [ ! -f .env ]; then
    log "Creating .env from .env.example and generating secrets..."
    cp .env.example .env
    chmod 600 .env

    for var in POSTGRES_PASSWORD JWT_SECRET INTERNAL_SERVICE_TOKEN AI_DB_PASSWORD; do
        set_env "${var}" "$(openssl rand -hex 32)"
    done

    if [ -n "${PUBLIC_HOST}" ]; then
        set_env DOMAIN "${PUBLIC_HOST}"
        set_env CORS_ORIGIN "${PUBLIC_SCHEME}://${PUBLIC_HOST}"
        set_env NEXT_PUBLIC_API_URL "${PUBLIC_SCHEME}://${PUBLIC_HOST}"
        set_env NEXT_PUBLIC_SOCKET_URL "${PUBLIC_SCHEME}://${PUBLIC_HOST}"
        set_env NEXT_PUBLIC_SITE_URL "${PUBLIC_SCHEME}://${PUBLIC_HOST}"
    else
        warn "PUBLIC_HOST not set: public URLs still point to http://localhost."
    fi
else
    log ".env already exists, leaving it untouched."
fi

# -----------------------------------------------------------------------------
# 4. Build + start
# -----------------------------------------------------------------------------
COMPOSE_FILES="-f docker-compose.yml"
if [ "${PUBLIC_SCHEME}" = "http" ]; then
    COMPOSE_FILES="${COMPOSE_FILES} -f docker-compose.dev.yml"
fi

log "Building and starting the stack..."
${COMPOSE} ${COMPOSE_FILES} up -d --build --wait

log "Stack status:"
${COMPOSE} ps

if [ "${PUBLIC_SCHEME}" = "https" ]; then
    log "Done. HTTPS needs a certificate first: see docs/DEPLOYMENT.md (TLS)."
else
    log "Done. nginx is serving HTTP on port 80."
fi

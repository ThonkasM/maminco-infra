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
#   PUBLIC_HOST      if set, used to fill NEXT_PUBLIC_* in .env
# =============================================================================
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/maminco}"
GITHUB_BASE_URL="${GITHUB_BASE_URL:-https://github.com/ThonkasM}"
GIT_BRANCH="${GIT_BRANCH:-main}"
PUBLIC_HOST="${PUBLIC_HOST:-}"
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
        aarch64) ARCH=aarch64 ;;
        x86_64)  ARCH=x86_64 ;;
        *)       ARCH=x86_64 ;;
    esac
    sudo mkdir -p /usr/libexec/docker/cli-plugins
    sudo curl -fsSL \
        "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${ARCH}" \
        -o /usr/libexec/docker/cli-plugins/docker-compose
    sudo chmod +x /usr/libexec/docker/cli-plugins/docker-compose
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
if [ ! -f .env ]; then
    log "Creating .env from .env.example..."
    cp .env.example .env

    if [ -n "${PUBLIC_HOST}" ]; then
        sed -i.bak \
            -e "s#^NEXT_PUBLIC_API_URL=.*#NEXT_PUBLIC_API_URL=http://${PUBLIC_HOST}#" \
            -e "s#^NEXT_PUBLIC_SOCKET_URL=.*#NEXT_PUBLIC_SOCKET_URL=http://${PUBLIC_HOST}#" \
            -e "s#^CORS_ORIGIN=.*#CORS_ORIGIN=http://${PUBLIC_HOST}#" \
            .env
        rm -f .env.bak
    fi

    warn "Review ${INFRA_DIR}/.env — JWT_SECRET and INTERNAL_SERVICE_TOKEN still need real values."
else
    log ".env already exists, leaving it untouched."
fi

# -----------------------------------------------------------------------------
# 4. Build + start
# -----------------------------------------------------------------------------
log "Building and starting the stack..."
${COMPOSE} up -d --build

log "Stack status:"
${COMPOSE} ps

log "Done. nginx is serving on port 80."
if [ -n "${PUBLIC_HOST}" ]; then
    log "Open http://${PUBLIC_HOST}"
fi

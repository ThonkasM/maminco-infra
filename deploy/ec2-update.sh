#!/usr/bin/env bash
# =============================================================================
# Maminco — update/redeploy a single service on the EC2 host
# =============================================================================
# Pulls the latest code for the owning repo and rebuilds just that one service.
#
# Usage (on the instance, from anywhere):
#   ./deploy/ec2-update.sh backend
#   ./deploy/ec2-update.sh frontend
#   ./deploy/ec2-update.sh ai
#   ./deploy/ec2-update.sh all          # update every app repo + rebuild all
#
# Environment overrides:
#   APP_DIR     default /opt/maminco
#   GIT_BRANCH  default main
# =============================================================================
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/maminco}"
GIT_BRANCH="${GIT_BRANCH:-main}"
INFRA_DIR="${APP_DIR}/maminco-infra"

# service -> owning repository (migrate runs automatically before the backend)
declare -A REPO_FOR_SERVICE=(
    [backend]=maminco-backend
    [frontend]=maminco-frontend
    [ai]=maminco-ai
    [postgres]=maminco-infra
    [nginx]=maminco-infra
)

log() { printf '\033[36m[update]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    echo "Usage: $0 <backend|frontend|ai|postgres|nginx|all>"
    exit 1
}

[ $# -eq 1 ] || usage
SERVICE="$1"

[ -d "${INFRA_DIR}" ] || die "Infra repo not found at ${INFRA_DIR}."
cd "${INFRA_DIR}"

COMPOSE="docker compose"
if ! docker info >/dev/null 2>&1; then
    COMPOSE="sudo docker compose"
fi

pull_repo() {
    local repo="$1"
    local dir="${APP_DIR}/${repo}"
    if [ ! -d "${dir}/.git" ]; then
        echo "  - ${repo}: not a git checkout, skipping pull"
        return 0
    fi
    log "Pulling ${repo} (${GIT_BRANCH})..."
    git -C "${dir}" fetch --quiet origin
    git -C "${dir}" checkout --quiet "${GIT_BRANCH}"
    git -C "${dir}" pull --ff-only origin "${GIT_BRANCH}"
}

if [ "${SERVICE}" = "all" ]; then
    for repo in maminco-infra maminco-backend maminco-frontend maminco-ai; do
        pull_repo "${repo}"
    done
    log "Rebuilding and recreating the whole stack..."
    ${COMPOSE} up -d --build --remove-orphans
else
    REPO="${REPO_FOR_SERVICE[${SERVICE}]:-}"
    [ -n "${REPO}" ] || usage
    pull_repo "${REPO}"

    if [ "${SERVICE}" = "backend" ]; then
        log "Applying database migrations..."
        ${COMPOSE} build migrate
        ${COMPOSE} run --rm migrate
    fi

    log "Rebuilding service '${SERVICE}'..."
    # --build rebuilds the image for this service; --force-recreate swaps it in.
    ${COMPOSE} up -d --build --force-recreate --no-deps "${SERVICE}"

    # Reconnecting the reverse proxy keeps nginx upstreams fresh after rebuild.
    if [ "${SERVICE}" != "nginx" ]; then
        log "Reloading nginx..."
        ${COMPOSE} up -d --no-deps nginx >/dev/null 2>&1 || true
    fi
fi

log "Done. Current status:"
${COMPOSE} ps

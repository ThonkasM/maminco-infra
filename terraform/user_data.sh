#!/bin/bash
# =============================================================================
# Maminco — EC2 first-boot provisioning (Amazon Linux 2023)
# Rendered by Terraform via templatefile(); shell variables are escaped as $${..}
# =============================================================================
set -euxo pipefail

PROJECT_NAME="${project_name}"
REPO_BASE_URL="${repo_base_url}"
GIT_BRANCH="${git_branch}"

APP_DIR="/opt/maminco"

# -----------------------------------------------------------------------------
# 1. Base packages + Docker engine
# -----------------------------------------------------------------------------
dnf update -y
dnf install -y docker git curl tar

systemctl enable --now docker

# -----------------------------------------------------------------------------
# 2. Docker Compose v2 CLI plugin
# -----------------------------------------------------------------------------
case "$$(uname -m)" in
    aarch64) COMPOSE_ARCH="aarch64" ;;
    x86_64)  COMPOSE_ARCH="x86_64" ;;
    *)       COMPOSE_ARCH="x86_64" ;;
esac

mkdir -p /usr/libexec/docker/cli-plugins
curl -fsSL \
    "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$${COMPOSE_ARCH}" \
    -o /usr/libexec/docker/cli-plugins/docker-compose
chmod +x /usr/libexec/docker/cli-plugins/docker-compose
docker compose version

# -----------------------------------------------------------------------------
# 3. Allow the default user to run docker without sudo
# -----------------------------------------------------------------------------
usermod -aG docker ec2-user || true

# -----------------------------------------------------------------------------
# 4. Optionally clone the repositories side by side
#    Layout: /opt/maminco/{maminco-infra,maminco-backend,maminco-frontend,maminco-ai}
#    (compose build contexts reference ../maminco-* — this layout makes them work)
# -----------------------------------------------------------------------------
mkdir -p "$${APP_DIR}"
chown ec2-user:ec2-user "$${APP_DIR}"

if [ -n "$${REPO_BASE_URL}" ]; then
    for repo in maminco-infra maminco-backend maminco-frontend maminco-ai; do
        if [ ! -d "$${APP_DIR}/$${repo}" ]; then
            sudo -u ec2-user \
                git clone --branch "$${GIT_BRANCH}" \
                "$${REPO_BASE_URL}/$${repo}.git" "$${APP_DIR}/$${repo}" || \
                echo "WARN: could not clone $${repo} (it may not exist yet)"
        fi
    done
fi

# -----------------------------------------------------------------------------
# 5. Print a friendly hint in the boot log
# -----------------------------------------------------------------------------
echo "==============================================================="
echo " Maminco $${PROJECT_NAME} bootstrap complete."
echo " Next steps:"
echo "   sudo -iu ec2-user"
echo "   cd $${APP_DIR}/maminco-infra"
echo "   cp .env.example .env && vi .env"
echo "   make up        # or: docker compose up -d --build"
echo "==============================================================="

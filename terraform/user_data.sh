#!/bin/bash
# =============================================================================
# Maminco — EC2 first-boot provisioning (Amazon Linux 2023)
# Rendered by Terraform via templatefile(); shell variables are escaped as $${..}
# Runs once (user_data changes are ignored after creation).
# =============================================================================
set -euxo pipefail

PROJECT_NAME="${project_name}"
REPO_BASE_URL="${repo_base_url}"
GIT_BRANCH="${git_branch}"
COMPOSE_VERSION="${compose_ver}"
COMPOSE_SHA256="${compose_sha256}"
DATA_DEVICE="${data_device}"
SWAP_SIZE_MB="${swap_size_mb}"

APP_DIR="/opt/maminco"
DATA_DIR="/data"

# -----------------------------------------------------------------------------
# 1. Swap (2 GiB host) and base packages
# -----------------------------------------------------------------------------
if [ "$${SWAP_SIZE_MB}" -gt 0 ] && [ ! -f /swapfile ]; then
    dd if=/dev/zero of=/swapfile bs=1M count="$${SWAP_SIZE_MB}"
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo "/swapfile none swap sw 0 0" >> /etc/fstab
fi

dnf update -y
dnf install -y docker git tar

# -----------------------------------------------------------------------------
# 2. Data volume: wait for the attachment, format only if empty, mount at /data
# -----------------------------------------------------------------------------
for _ in $(seq 1 60); do
    [ -b "$${DATA_DEVICE}" ] && break
    sleep 5
done
[ -b "$${DATA_DEVICE}" ] || { echo "Data volume $${DATA_DEVICE} did not appear"; exit 1; }

if ! blkid "$${DATA_DEVICE}" >/dev/null 2>&1; then
    mkfs.xfs -L maminco-data "$${DATA_DEVICE}"
fi

mkdir -p "$${DATA_DIR}"
if ! grep -q "LABEL=maminco-data" /etc/fstab; then
    echo "LABEL=maminco-data $${DATA_DIR} xfs defaults,nofail 0 2" >> /etc/fstab
fi
mount -a
mkdir -p "$${DATA_DIR}/docker"

# -----------------------------------------------------------------------------
# 3. Docker engine with its data-root on the data volume
# -----------------------------------------------------------------------------
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<JSON
{
  "data-root": "$${DATA_DIR}/docker",
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
JSON
systemctl enable --now docker

# -----------------------------------------------------------------------------
# 4. Docker Compose CLI plugin — pinned version, checksum verified
# -----------------------------------------------------------------------------
case "$(uname -m)" in
    aarch64) COMPOSE_ARCH="aarch64" ;;
    x86_64)  COMPOSE_ARCH="x86_64" ;;
    *)       echo "Unsupported architecture"; exit 1 ;;
esac

mkdir -p /usr/libexec/docker/cli-plugins
curl -fsSL \
    "https://github.com/docker/compose/releases/download/$${COMPOSE_VERSION}/docker-compose-linux-$${COMPOSE_ARCH}" \
    -o /tmp/docker-compose
echo "$${COMPOSE_SHA256}  /tmp/docker-compose" | sha256sum -c -
install -m 0755 /tmp/docker-compose /usr/libexec/docker/cli-plugins/docker-compose
rm -f /tmp/docker-compose
BUILDX_ARCH="arm64"
[ "$${COMPOSE_ARCH}" = "x86_64" ] && BUILDX_ARCH="amd64"
curl -fsSL "https://github.com/docker/buildx/releases/download/v0.19.3/buildx-v0.19.3.linux-$${BUILDX_ARCH}" \
    -o /usr/libexec/docker/cli-plugins/docker-buildx
chmod 0755 /usr/libexec/docker/cli-plugins/docker-buildx
docker compose version

usermod -aG docker ec2-user || true

# -----------------------------------------------------------------------------
# 5. Optionally clone the repositories side by side
#    Layout: /opt/maminco/{maminco-infra,maminco-backend,maminco-frontend,maminco-ai}
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

echo "==============================================================="
echo " Maminco $${PROJECT_NAME} bootstrap complete."
echo " Next steps (see docs/DEPLOYMENT.md):"
echo "   sudo -iu ec2-user"
echo "   cd $${APP_DIR}/maminco-infra"
echo "   cp .env.example .env && vi .env      # every secret: openssl rand -hex 32"
echo "   make up                              # TLS site (issue the cert first)"
echo "==============================================================="

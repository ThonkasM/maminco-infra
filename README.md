# Maminco Infra

Infrastructure and deployment for **Maminco**, a restaurant POS system. This
repository contains **no application code** — only Docker, nginx, Terraform,
CI templates and deployment documentation for the four Maminco services.

> Goal: a **low-cost, single-host AWS deployment** — one small EC2 instance
> running the whole stack via Docker Compose, with nginx terminating TLS on
> 443 (HTTP only for development). No ALB, no RDS, no NAT gateway. Cheap enough
> for a student project.

## Services

| Service            | Tech                              | Port (internal) | Notes |
| ------------------ | --------------------------------- | --------------- | ----- |
| `maminco-backend`  | NestJS 11 + Prisma 6 + socket.io  | 3000            | REST at `/api/*`, socket.io |
| `maminco-frontend` | Next.js 16 (App Router)           | 3001            | SSR + middleware → needs Node |
| `maminco-ai`       | FastAPI (uvicorn)                 | 8000            | ML/forecast service |
| `maminco-mobile`   | Expo / EAS                        | —               | Not containerized |
| `postgres`         | PostgreSQL 16 (Alpine)            | 5432            | Data volume |
| `migrate`          | backend image, `migrate` target   | —               | One-shot `prisma migrate deploy` |
| `nginx`            | nginx 1.28 (Alpine)               | **80/443** (public) | TLS, reverse proxy + WS |

## Architecture (single host)

```mermaid
flowchart LR
    Browser["Browser / POS device"]
    subgraph EC2["EC2 t4g.small · Amazon Linux 2023"]
        NX["nginx :80 → :443"]
        FE["frontend :3001\nNext.js"]
        BE["backend :3000\nNestJS"]
        AI["ai :8000\nFastAPI"]
        PG[("postgres :5432")]
        NX -->|"/"| FE
        NX -->|"/api"| BE
        NX -->|"/socket.io (ws)"| BE
        BE -->|SQL| PG
        AI -->|SQL| PG
        BE -->|"HTTP + INTERNAL_SERVICE_TOKEN"| AI
    end
    Browser -->|HTTPS/WSS| NX
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full diagram.

## Repository layout

```
maminco-infra/
├── docker-compose.yml        # postgres, migrate, backend, ai, frontend, nginx (+ certbot profile)
├── docker-compose.dev.yml    # override: HTTP-only nginx for development
├── .env.example              # variables (secrets empty on purpose)
├── Makefile                  # up / up-dev / down / logs / rebuild / seed / tf-up …
├── nginx/
│   ├── conf.d/00-common.conf # upstreams, rate-limit zones, server_tokens off, gzip
│   ├── snippets/             # locations, security headers, proxy headers
│   └── templates/            # https.conf.template (default) and http.conf.template
├── docker/                   # the ONLY Dockerfiles (single source of truth)
│   ├── backend.Dockerfile    # targets: runtime, migrate
│   ├── frontend.Dockerfile   # Next.js standalone
│   ├── ai.Dockerfile         # Python 3.12, no compiler (maminco-ai has no Dockerfile)
│   ├── <name>.Dockerfile.dockerignore   # picked up by BuildKit automatically
│   └── postgres/10-ai-readonly.sh       # creates the read-only AI role
├── deploy/                   # ec2-setup.sh (generates secrets), ec2-update.sh
├── terraform/                # VPC, EC2, data EBS + DLM snapshots, SG, IAM (+ optional S3/CloudFront)
│   └── backend.tf.example    # remote S3 state
├── ci/                       # workflow + dependabot templates for backend/frontend/ai
├── .github/                  # real CI (infra-ci.yml) and dependabot.yml
├── .hadolint.yaml  .tflint.hcl  .trivyignore
└── docs/                     # ARCHITECTURE, DEPLOYMENT, DATA-MODEL, FLOWS, LOGGING
```

## Quick start (local, Docker, HTTP)

```bash
cp .env.example .env     # fill the empty secrets: openssl rand -hex 32 (each one different)
make up-dev              # HTTP on http://localhost (TLS site: `make up`, see DEPLOYMENT.md)
make logs SERVICE=backend
```

Compose refuses to start until `POSTGRES_PASSWORD`, `JWT_SECRET`,
`INTERNAL_SERVICE_TOKEN` and `AI_DB_PASSWORD` are set. Migrations run in the
one-shot `migrate` service; the seed (well-known test users) only runs with
`SEED=true` (`make seed`).

The app repos must be checked out **as siblings** of this one:

```
development/
├── maminco-infra/       <- you are here
├── maminco-backend/
├── maminco-frontend/
└── maminco-ai/
```

Compose builds each app with `context: ../maminco-<app>` and the Dockerfile
from `docker/` in this repo. Each Dockerfile has a sibling
`<Dockerfile>.dockerignore` that BuildKit applies automatically to the context,
so nothing has to be copied into the app repos. Base images use fixed tags;
pass `--build-arg NODE_DIGEST=sha256:...` (or `PYTHON_DIGEST`) to pin a digest.

Open <http://localhost>. The first admin user is created with
`POST /api/auth/register-first-admin` (only works while no users exist).

## Deploy to AWS (short version)

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # edit region; SSH stays closed unless allowed_ssh_cidr is set
terraform init && terraform apply

# then, on the instance (SSH or SSM):
cd /opt/maminco/maminco-infra
cp .env.example .env && vi .env    # or run deploy/ec2-setup.sh, which generates the secrets
# issue the TLS certificate once (DEPLOYMENT.md §8), then:
make up
```

Full walkthrough, including rollback: [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).
Spanish onboarding: [ONBOARDING.md](ONBOARDING.md).

## Cost (ballpark, us-east-1, on-demand)

| Item | Cost |
| ---- | ---- |
| EC2 `t4g.small` | ~$12.3/mo (use `t3.micro` for free tier) |
| 2 x 20 GiB gp3 EBS (root + data) | ~$3.2/mo |
| Public IPv4 address (Elastic IP) | ~$3.65/mo ($0.005/h, charged since 2024) |
| EBS snapshots (DLM, 7 daily) | ~$0.5-1/mo |
| S3 + CloudFront (optional) | usage-based, off by default |
| **Total** | **~$20/mo** |

> Stop the instance when not in use (`aws ec2 stop-instances`) to save compute
> cost; the EBS volumes persist, and the public IPv4 keeps being billed.

## Environment variables (key ones)

| Variable | Used by | Notes |
| -------- | ------- | ----- |
| `POSTGRES_PASSWORD` | postgres | **required**, no default |
| `AI_DB_PASSWORD` | postgres init, ai | **required**; password of the read-only `maminco_ai` role |
| `JWT_SECRET` | backend | **required**, min 32 chars |
| `INTERNAL_SERVICE_TOKEN` | backend & ai | **required**, >= 32 chars, identical on both sides |
| `CORS_ORIGIN` | backend | **required**, public origin(s), comma-separated |
| `NEXT_PUBLIC_API_URL` / `_SOCKET_URL` / `_SITE_URL` | frontend | **build args**; origin only, no `/api` |
| `DOMAIN` | nginx | TLS site name and certificate path |
| `REPORT_TIMEZONE` / `AI_TIMEZONE` | backend / ai | business time zone (default `America/La_Paz`) |
| `SEED` | migrate | `true` only for demo data |

`AI_INTERNAL_SERVICE_TOKEN` is derived from `INTERNAL_SERVICE_TOKEN` by compose.
Full reference with comments: [.env.example](.env.example).

## Conventions / invariants

- **Token invariant:** backend `INTERNAL_SERVICE_TOKEN` == ai `AI_INTERNAL_SERVICE_TOKEN`.
- **Frontend is not static:** middleware requires a Node server
  (`output: 'standalone'`, `node server.js`). S3/CloudFront is optional and only
  for static assets/backups.
- **Schema:** committed Prisma migrations, applied with `prisma migrate deploy`
  by the one-shot `migrate` service (never `db push`).
- **Single Dockerfile source:** `docker/*.Dockerfile` here; the app repos carry none.
- Each app lives in its **own git repository**; commit per repository.

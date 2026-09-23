# Deployment

Step-by-step guide to deploy Maminco to a single low-cost EC2 instance, plus
rollback and teardown.

## 0. Prerequisites

- AWS account + credentials configured (`aws configure`, or `AWS_PROFILE`)
- Terraform ≥ 1.5
- SSH key pair in the target region (optional — SSM works without one)
- Network access to clone the four GitHub repos
- The app repos (`maminco-backend`, `maminco-frontend`, `maminco-ai`) exist

## 1. Provision the infrastructure (Terraform)

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

- `aws_region` — pick one close to your users
- `instance_type` — `t4g.small` (default) or `t3.micro` (free tier)
- `instance_architecture` — `arm64` for `t4g.*`, `x86_64` for `t3.*`
- `key_name` — your EC2 key pair (or leave unset and use SSM)
- `allowed_ssh_cidr` — **restrict to your IP** (`x.x.x.x/32`)
- `repo_base_url` / `git_branch` — used to clone repos at first boot

Then:

```bash
terraform init
terraform apply
```

Terraform creates: VPC, public subnet, Internet Gateway, route table, security
group (22/80/443), IAM role + SSM instance profile, the EC2 instance, an
Elastic IP, and — only if `enable_static_cdn = true` — an S3 bucket + CloudFront
distribution.

Note the outputs:

```
app_url         = "http://<elastic-ip>"
public_ip       = "<elastic-ip>"
ssh_command     = "ssh -i <key>.pem ec2-user@<ip>"
ssm_command     = "aws ssm start-session --target i-... "
```

## 2. First-boot provisioning (`user_data.sh`)

On boot, `user_data.sh` (rendered by Terraform) automatically:

1. installs Docker + the Compose v2 plugin,
2. adds `ec2-user` to the `docker` group,
3. clones the four repos into `/opt/maminco/`.

Watch progress: `ssh ec2-user@<ip> 'sudo tail -f /var/log/cloud-init-output.log'`.

## 3. Configure the environment

SSH (or SSM) into the instance and edit `.env`:

```bash
ssh -i <key>.pem ec2-user@<ip>
cd /opt/maminco/maminco-infra
cp .env.example .env
vi .env
```

Set at least:

```dotenv
POSTGRES_PASSWORD=<strong-db-password>
JWT_SECRET=<openssl rand -base64 48>
INTERNAL_SERVICE_TOKEN=<openssl rand -hex 32>
CORS_ORIGIN=http://<elastic-ip>
NEXT_PUBLIC_API_URL=http://<elastic-ip>
NEXT_PUBLIC_SOCKET_URL=http://<elastic-ip>
```

`INTERNAL_SERVICE_TOKEN` is automatically reused as `AI_INTERNAL_SERVICE_TOKEN`
by Compose. The `NEXT_PUBLIC_*` values are **build-time**, so they must be
correct before the first build.

> If you use `deploy/ec2-setup.sh` with `PUBLIC_HOST=<ip-or-domain>`, it fills
> `NEXT_PUBLIC_*` and `CORS_ORIGIN` for you after copying the template.

## 4. Build and start

```bash
cd /opt/maminco/maminco-infra
make up            # docker compose up -d --build
make ps
make logs SERVICE=backend
```

What happens on first boot: `postgres` becomes healthy → `backend` runs
`prisma db push` (creates the schema — no migrations are committed) and
`prisma db seed` (idempotent), then starts → `frontend` and `ai` start → `nginx`
serves port 80.

## 5. Bootstrap the first admin user

While no users exist:

```bash
curl -X POST http://<elastic-ip>/api/auth/register-first-admin \
  -H 'Content-Type: application/json' \
  -d '{"email":"admin@maminco.local","password":"<strong-password>","name":"Admin"}'
```

Then open <http://<elastic-ip>> and log in. (Adjust the body to match the DTO
in `maminco-backend`.)

## 6. Redeploy a single service

On the instance:

```bash
cd /opt/maminco/maminco-infra
./deploy/ec2-update.sh backend     # or: frontend | ai | all
```

This pulls the service's repo and rebuilds only that container with
`--force-recreate --no-deps`, then restarts nginx.

From CI, prefer building an image and pushing to ECR; for this project the
on-instance `git pull && compose up --build` flow is the cheapest and simplest.

## 7. Rollback

Because images are built locally, roll back by reverting the code and
rebuilding:

```bash
# On the instance, for a single service:
cd /opt/maminco/maminco-backend
git log --oneline -5                 # find the last good commit
git checkout <good-commit>
cd /opt/maminco/maminco-infra
docker compose up -d --build --force-recreate --no-deps backend
```

To roll back the whole stack to a known commit per repo, repeat for each repo
and run `docker compose up -d --build`.

Database safety:

- **Schema changes** are applied by `prisma db push`, which does **not** create
  migrations and can drop columns that no longer exist. Before risky deploys:
  ```bash
  docker compose exec postgres \
    pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" > ~/backup-$(date +%F).sql
  ```
- To restore: `cat backup.sql | docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"`.

Infrastructure rollback: use `terraform` state / version control; for a full
rebuild, `terraform destroy && terraform apply` (this deletes the instance and
its EBS data — back up first).

## 8. Optional: TLS / HTTPS

1. Point a domain at the Elastic IP.
2. Obtain certificates (e.g. certbot) and place them in `nginx/certs/`.
3. Uncomment the `443` port mapping and the certs volume in
   `docker-compose.yml`, and add a `listen 443 ssl;` server block in
   `nginx/default.conf`.
4. Set `NEXT_PUBLIC_*` and `CORS_ORIGIN` to the `https://` URL and rebuild the
   frontend (`./deploy/ec2-update.sh frontend`).

## 9. Teardown

```bash
cd terraform
terraform destroy
```

This removes all Terraform-managed resources. If `enable_static_cdn = true`,
the S3 bucket is created with `force_destroy = true`, so its contents are
deleted too. The `pgdata` volume lives on the instance's EBS volume and is
destroyed with the instance.

## 10. Troubleshooting

| Symptom | Likely cause | Fix |
| ------- | ------------ | --- |
| `make up` fails on backend | missing/invalid `JWT_SECRET` (< 32 chars) | fix `.env`, `make rebuild` |
| Browser network errors | wrong `NEXT_PUBLIC_API_URL` (localhost) | set public origin, rebuild frontend |
| AI returns 401 to backend | token mismatch | ensure `INTERNAL_SERVICE_TOKEN` == `AI_INTERNAL_SERVICE_TOKEN` |
| Tables missing | `prisma db push` did not run | `make logs SERVICE=backend`; `make rebuild` |
| `permission denied` on docker | user not in `docker` group | re-login, or use `sudo docker compose` |
| Port 80 unreachable | security group / nginx down | check SG ingress + `docker compose ps` |

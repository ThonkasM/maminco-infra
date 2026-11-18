# Deployment

Step-by-step guide to deploy Maminco to a single low-cost EC2 instance, plus
TLS, backups, rollback and teardown.

## 0. Prerequisites

- AWS account + credentials configured (`aws configure`, or `AWS_PROFILE`)
- Terraform >= 1.5 (>= 1.10 if you use the S3 native state lock)
- A DNS name you control, pointing to the instance (needed for TLS)
- Network access to clone the four GitHub repos
- The app repos exist; the frontend sets `output: 'standalone'` in
  `next.config.ts` and the backend honours `trust proxy` / shutdown hooks

SSH is optional: SSM Session Manager works without any key or open port.

## 1. Provision the infrastructure (Terraform)

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

- `aws_region`, `instance_type` (`t4g.small` default, `t3.micro` free tier) and
  `instance_architecture` (`arm64` for `t4g.*`, `x86_64` for `t3.*`)
- `allowed_ssh_cidr` — leave unset for **no SSH rule** (use SSM). Set it to
  your own `x.x.x.x/32` only if you need SSH; `0.0.0.0/0` is rejected.
- `key_name` — only if you use SSH
- `data_volume_size`, `backup_retention_days` (default 7), `swap_size_mb`
- `repo_base_url` / `git_branch` — used to clone repos at first boot

Optional remote state: `cp backend.tf.example backend.tf`, create the bucket as
described in that file, then `terraform init -migrate-state`.

```bash
terraform init
terraform apply
```

Terraform creates: VPC + public subnet + IGW, security group (80/443, SSH only
if allowed), IAM role + SSM profile, the EC2 instance (IMDSv2 required,
encrypted root disk), a **separate encrypted data EBS volume**
(`prevent_destroy`), a DLM policy that snapshots it daily, an Elastic IP, and
(only if `enable_static_cdn = true`) a versioned, encrypted S3 bucket +
CloudFront.

Outputs: `public_ip`, `app_url`, `ssm_command`, `ssh_command`, `data_volume_id`,
`backup_policy_id`.

Notes:

- The instance ignores later `ami` / `user_data` changes: a newer AMI never
  recreates the host. To rebuild it deliberately:
  `terraform apply -replace=aws_instance.app` (the data volume is re-attached
  and keeps the database).
- `terraform destroy` fails on the data volume by design (`prevent_destroy`).
  To really delete it, remove that lifecycle block first.

## 2. First-boot provisioning (`user_data.sh`)

Runs once. It: creates a swap file, waits for the data volume, formats it (only
if empty) and mounts it at `/data`, points Docker's `data-root` to
`/data/docker` (so the Postgres volume and certificates live on the data disk),
installs a **pinned Docker Compose** release verified by SHA-256, and clones the
four repos into `/opt/maminco/`.

Watch progress: `aws ssm start-session ...` then
`sudo tail -f /var/log/cloud-init-output.log`.

To bump Compose, change `compose_version` and the two `compose_sha256_*`
variables (checksums come from the release's `.sha256` assets) and the matching
constants in `deploy/ec2-setup.sh`.

## 3. Configure the environment

```bash
cd /opt/maminco/maminco-infra
cp .env.example .env && chmod 600 .env
```

Secrets are empty on purpose and have **no default**; compose aborts until all
are set. Generate each one separately:

```bash
openssl rand -hex 32   # POSTGRES_PASSWORD, JWT_SECRET, INTERNAL_SERVICE_TOKEN, AI_DB_PASSWORD
```

Then set the public values:

```dotenv
DOMAIN=pos.example.com
CORS_ORIGIN=https://pos.example.com
NEXT_PUBLIC_API_URL=https://pos.example.com
NEXT_PUBLIC_SOCKET_URL=https://pos.example.com
NEXT_PUBLIC_SITE_URL=https://pos.example.com
```

`NEXT_PUBLIC_*` are **build-time**: they must be right before the first build.
`deploy/ec2-setup.sh` (with `PUBLIC_HOST=pos.example.com`) does all of this,
generating the four secrets with `openssl`.

## 4. Build and start (HTTP first, to get a certificate)

nginx's default site needs certificates, so the first start is HTTP-only:

```bash
make up-dev        # docker-compose.yml + docker-compose.dev.yml
make ps
make logs SERVICE=backend
```

What happens: `postgres` healthy (first init creates the read-only `maminco_ai`
role) -> `migrate` runs `prisma migrate deploy` and exits 0 -> `backend` starts
-> `frontend` -> `nginx`. `ai` starts in parallel. The seed does **not** run
unless `SEED=true` (it creates well-known test users: never on a real tenant).

## 5. Bootstrap the first admin user

```bash
curl -X POST http://localhost/api/auth/register-first-admin \
  -H 'Content-Type: application/json' \
  -d '{"email":"admin@example.com","password":"<strong-password>","name":"Admin"}'
```

(Adjust the body to the DTO in `maminco-backend`.)

## 6. Redeploy a single service

```bash
cd /opt/maminco/maminco-infra
./deploy/ec2-update.sh backend     # or: frontend | ai | all
```

Pulls the service's repo and rebuilds only that container. For `backend` it
first runs the one-shot `migrate` service. Add `SEED=true` only deliberately.

## 7. Rollback and backups

Images are built on the host, so roll back by reverting the code and rebuilding:

```bash
cd /opt/maminco/maminco-backend && git checkout <good-commit>
cd /opt/maminco/maminco-infra
docker compose build backend migrate && docker compose run --rm migrate
docker compose up -d --force-recreate --no-deps backend
```

Migrations are forward-only (`migrate deploy`); a code rollback that needs an
older schema requires restoring a backup.

**Automatic backups:** AWS DLM snapshots the data volume daily (07:00 UTC,
`backup_retention_days` kept). Snapshots are crash-consistent; Postgres
recovers via WAL. To restore: create a volume from a snapshot, stop the stack,
swap the attached volume (or `terraform import` the new one) and start again.

**Logical backup** before risky changes:

```bash
docker compose exec -T postgres sh -c 'pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB"' > ~/backup-$(date +%F).sql
cat backup.sql | docker compose exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
```

Existing volume created before the read-only AI role existed? Run
`docker compose exec -e AI_DB_PASSWORD=... postgres sh /docker-entrypoint-initdb.d/10-ai-readonly.sh`.

## 8. TLS (Let's Encrypt with certbot)

Prerequisites: DNS `A` record for `DOMAIN` -> `public_ip`; ports 80/443 open.

1. Start in HTTP mode (step 4: `make up-dev`). nginx serves
   `/.well-known/acme-challenge/` from the shared `acme-webroot` volume.
2. Issue the certificate (stored in the `letsencrypt` volume):

   ```bash
   docker compose --profile certbot run --rm certbot certonly \
     --webroot -w /var/www/certbot -d "$DOMAIN" \
     --email you@example.com --agree-tos --no-eff-email
   ```
3. Switch to the TLS site: `make up` (same as
   `docker compose up -d --build`). Port 80 now only redirects to HTTPS and
   answers `/healthz`; HSTS and the security headers are sent.
4. Renewal (certificates last 90 days). Add to root's crontab:

   ```cron
   17 3 * * * cd /opt/maminco/maminco-infra && docker compose --profile certbot run --rm certbot renew --quiet && docker compose exec nginx nginx -s reload
   ```
5. Make sure `CORS_ORIGIN` and `NEXT_PUBLIC_*` use the `https://` origin and the
   frontend was rebuilt (`./deploy/ec2-update.sh frontend`).

Use `--staging` with certbot while testing to avoid Let's Encrypt rate limits.

## 9. Teardown

```bash
cd terraform
terraform destroy
```

Fails on the data volume (`prevent_destroy`) unless you remove that guard;
snapshots created by DLM are not deleted with the volume. The optional S3
bucket is created with `force_destroy = false`: empty it first.

## 10. Troubleshooting

| Symptom | Likely cause | Fix |
| ------- | ------------ | --- |
| `docker compose` says `required variable ... is missing` | empty secret in `.env` | `openssl rand -hex 32` and set it |
| `migrate` exits non-zero | DB unreachable or a failed migration | `docker compose logs migrate` |
| nginx restarts: `cannot load certificate` | TLS site without a certificate | `make up-dev`, issue the cert (§8) |
| Browser network errors | wrong `NEXT_PUBLIC_API_URL` | set the public origin, rebuild frontend |
| AI exits at boot (`internal_service_token`) | token missing, < 32 chars or placeholder | fix `INTERNAL_SERVICE_TOKEN` |
| AI returns 401 to backend | token mismatch | compose derives both from `INTERNAL_SERVICE_TOKEN`; recreate both |
| AI cannot read tables | role created before tables, volume pre-dates the script | run the init script manually (§7) |
| Containers OOM-killed | 2 GiB host | check `docker stats`, swap, limits in compose |
| `permission denied` on docker | user not in `docker` group | re-login, or `sudo docker compose` |

## 11. Public domain: Route 53 + CloudFront (`maminco.lat`)

Topology: `Browser -> Route 53 -> CloudFront (app) -> origin.maminco.lat (EC2 / nginx, HTTPS)`;
`media.maminco.lat -> CloudFront (media) -> S3 products/`. CloudFront is a CDN and
reverse proxy, **not** a load balancer: there is still a single origin.

1. **Register** `maminco.lat` at a registrar (not done by Terraform).
2. In `terraform.tfvars`: `enable_cdn_and_dns = true`, `domain_name = "maminco.lat"`,
   `origin_verify_secret = "$(openssl rand -hex 32)"` (and `enable_media_bucket = true` if used).
3. **Create the zone first** so you can delegate it:

   ```bash
   terraform apply -target=aws_route53_zone.main
   terraform output name_servers
   ```
4. At the registrar, set the four `name_servers` as the domain's NS (delegation). Wait until
   `dig NS maminco.lat +short` returns them (minutes to hours).
5. `terraform apply`. The ACM certificates (us-east-1) validate by DNS records created in the
   zone; the apply waits until they are issued, then creates the distributions and the alias
   records for the apex, `www` and `media`. CloudFront takes several minutes to deploy.
6. On the host `.env`: `DOMAIN=origin.maminco.lat`, `ORIGIN_VERIFY_SECRET=<same secret>`,
   `CORS_ORIGIN=https://maminco.lat`, `NEXT_PUBLIC_API_URL=https://maminco.lat`
   (and the other `NEXT_PUBLIC_*` with that origin), `ASSETS_BASE_URL=https://media.maminco.lat`
   (value of `media_base_url`). Rebuild the frontend.
7. Issue the origin certificate (§8) for `origin.maminco.lat` (the A record to the Elastic IP
   already exists; port 80 stays open for the ACME challenge). Then `make up`.
   Security group: 443 is only open to the CloudFront origin-facing managed prefix list,
   and nginx answers 403 without the `X-Origin-Verify` header.

First-deploy checklist: NS delegated; certificates `ISSUED`; `https://maminco.lat` and
`https://www.maminco.lat` load; `/api/...` and a socket.io connection work through CloudFront
(WebSocket support must be verified in the real environment); `/_next/static/*` returns
`x-cache: Hit from cloudfront` on the second request; a product image loads from
`https://media.maminco.lat`; `reports/` returns 403 from the CDN; direct `https://<ip>` is refused.

Notes: nginx's per-IP rate limits see CloudFront addresses (the real client is in
`X-Forwarded-For` / `CloudFront-Viewer-Address`); tune before relying on them. Cost drivers:
hosted zone (monthly fee), DNS queries, CloudFront requests and data transfer, ACM is free;
see the public AWS price pages.


## Teardown and updates (quick reference)

- **Remove everything Maminco from AWS:** `./deploy/teardown.sh` (asks for `DELETE-maminco`; empties the media
  bucket, lifts `prevent_destroy`, runs `terraform destroy` and lists any resource still tagged
  `Project=maminco`, which must print nothing). Every resource carries `Project=maminco`, so it never touches
  other projects in the account.
- **Ship a fix:** push to `main` in the owning repo, then on the instance
  `./deploy/ec2-update.sh backend|frontend|ai|all` (`aws ssm start-session --target <instance_id>`). The frontend
  rebuilds because `NEXT_PUBLIC_*` are build-time.
- **Current state (first deploy):** HTTP on the Elastic IP, `enable_cdn_and_dns=false`. When `maminco.lat`
  is ready, follow the CDN/DNS section above and update `.env` (`CORS_ORIGIN`, `NEXT_PUBLIC_*`, `DOMAIN`), then
  `./deploy/ec2-update.sh all`.

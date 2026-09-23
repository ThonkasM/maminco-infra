# AGENTS.md — maminco-infra

Infrastructure-only repository. **Never add application code here.** The apps
(`maminco-backend`, `maminco-frontend`, `maminco-ai`) are separate git repos
checked out as siblings; the Dockerfiles here only build them from outside.

## Ground rules

- Each Maminco app is its **own git repo**. Commit changes per repository —
  never mix app and infra changes in one commit.
- Do not modify files under `../maminco-backend`, `../maminco-frontend`,
  `../maminco-ai`, `../maminco-mobile`.
- Keep the deployment **cheap**: one small EC2 host, no ALB/RDS/NAT.
- Prefer editing existing files; keep English identifiers in infra files.

## Ports & routing

| Service | Port | Exposed |
| ------- | ---- | ------- |
| nginx | 80 (443 optional) | public |
| frontend | 3001 | internal |
| backend | 3000 | internal (`/api/*`, `/socket.io`) |
| ai | 8000 | internal |
| postgres | 5432 | internal |

Routes: `/` → frontend, `/api` → backend, `/socket.io` → backend (WebSocket).

## Invariants

- `INTERNAL_SERVICE_TOKEN` (backend) **==** `AI_INTERNAL_SERVICE_TOKEN` (ai).
- `NEXT_PUBLIC_API_URL` / `NEXT_PUBLIC_SOCKET_URL` are **build-time** args and
  are **origins only** (no trailing slash, no `/api`).
- Postgres schema bootstrap uses `prisma db push` — there are no committed
  migrations. Seed (`prisma db seed`) must stay idempotent.
- Frontend requires a Node server (middleware); it is **not** static.

## Commands

```bash
make up            # start stack          make down        # stop stack
make rebuild       # rebuild + recreate   make seed        # run prisma seed
make logs SERVICE=backend
make tf-up         # terraform apply      make tf-destroy  # terraform destroy
```

Validate before committing:

```bash
docker compose config --quiet          # compose syntax (no daemon needed)
terraform -chdir=terraform fmt -check  # formatting
terraform -chdir=terraform validate    # config validity (after init)
```

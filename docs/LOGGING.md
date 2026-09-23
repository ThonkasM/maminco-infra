# Logging

Two layers, both bounded so the small EC2 host never runs out of disk:

1. **Container logs (stdout)** — captured by Docker with the `json-file` driver, rotated via the
   `x-logging` anchor in `docker-compose.yml` (`max-size: 10m`, `max-file: 3`). Inspect with
   `make logs SERVICE=backend` (or `docker compose logs -f backend`).
2. **App logs in PostgreSQL** — the backend persists its logs to the `system_logs` table with a
   **3-day retention** enforced by a daily cron and a row cap; view/clean them from the web
   `/settings` page or the mobile “Sistema” tab. See `../maminco-backend/docs/LOGGING.md`.

## Why not one big log file

- A local file grows unbounded and needs its own rotation; the Docker driver already rotates.
- The DB copy is bounded (retention + cap) and is what the admin UI queries.
- For longer history, switch the Docker driver to `awslogs` (CloudWatch) without app changes.

## Related

- Backend retention/env vars: `maminco-backend/docs/LOGGING.md`.
- Health/monitoring endpoint (public): `GET /api/system/health`.

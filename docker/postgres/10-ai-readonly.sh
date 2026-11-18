#!/bin/sh
# Creates a read-only role for maminco-ai. Runs once, on first initialisation
# of an empty data volume (docker-entrypoint-initdb.d). For an existing volume
# run it manually:
#   docker compose exec -e AI_DB_PASSWORD=... postgres sh /docker-entrypoint-initdb.d/10-ai-readonly.sh
set -eu

: "${AI_DB_PASSWORD:?AI_DB_PASSWORD is required}"

psql -v ON_ERROR_STOP=1 \
    --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
    -v pw="$AI_DB_PASSWORD" -v db="$POSTGRES_DB" -v owner="$POSTGRES_USER" <<'SQL'
CREATE ROLE maminco_ai LOGIN PASSWORD :'pw' NOSUPERUSER NOCREATEDB NOCREATEROLE;
ALTER ROLE maminco_ai SET default_transaction_read_only = on;
GRANT CONNECT ON DATABASE :"db" TO maminco_ai;
GRANT USAGE ON SCHEMA public TO maminco_ai;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO maminco_ai;
ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" IN SCHEMA public GRANT SELECT ON TABLES TO maminco_ai;
SQL

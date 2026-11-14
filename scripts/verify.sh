#!/usr/bin/env bash
set -euo pipefail

echo '== Containers =='
docker compose ps

echo
echo '== Database and pgvector =='
docker compose exec -T postgres sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT extname, extversion FROM pg_extension WHERE extname = '\''vector'\'';"'
docker compose exec -T postgres sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT tablename FROM pg_tables WHERE schemaname = '\''public'\'' ORDER BY tablename;"'
docker compose exec -T postgres sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT '\''[1,2,3]'\''::vector(3) <-> '\''[4,5,6]'\''::vector(3) AS euclidean_distance;"'

echo
echo '== Bucket initializer logs =='
docker compose logs minio-init

echo '== Finished. Open MinIO console at http://localhost:9001 (or configured host port) =='

# Video Search — Local Data Infrastructure

This folder sets up PostgreSQL 17 + pgvector and MinIO for the distributed video search project. **It does not start RabbitMQ, Redis, FastAPI or any ML workers yet.**

## 1. Prerequisites

Install Docker Desktop (or Docker Engine with Compose v2). Confirm:

```bash
docker --version
docker compose version
```

## 2. Configure

```bash
cp .env.example .env
```

Edit `.env`: replace both example passwords. `.env` is in `.gitignore`; never commit it. All ports are bound to `127.0.0.1` for local-only access. If ports 5433, 9000 or 9001 are busy, change the host port variables in `.env`.

## 3. Start

```bash
docker compose config --quiet
docker compose up -d
# Watch until minio-init has completed:
docker compose ps -a
docker compose logs minio-init
```

Expected: `postgres` and `minio` healthy; `minio-init` exits with code 0 after creating bucket `videos`. An exited initializer is expected, not an error.

## 4. Verify

```bash
./scripts/verify.sh
```

The schema includes `videos`, `segments`, `transcripts` and `frames` (512-dimensional CLIP embeddings). The vector extension and tables are created automatically **only on first database initialization**, while the bucket creation is idempotent.

Interactively inspect PostgreSQL:

```bash
docker compose exec postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
```

Then try `\dt`, `\dx`, and `SELECT '[1,2,3]'::vector <-> '[4,5,6]'::vector;`. Use `\q` to exit.

MinIO console: <http://localhost:9001> (unless changed in `.env`). Log in with the `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` from `.env` and confirm that the `videos` bucket exists. Upload a small MP4 manually in the browser to check persistence.

## 5. How future services connect

**From your laptop:** PostgreSQL `localhost:5433`; MinIO API `http://localhost:9000`.

**From a container in the same Compose project:** PostgreSQL `postgres:5432`; MinIO API `http://minio:9000` (not localhost). Use the environment variables in your FastAPI and worker settings, for example:

```text
DATABASE_HOST=postgres
DATABASE_PORT=5432
S3_ENDPOINT_URL=http://minio:9000
S3_BUCKET=videos
S3_REGION=us-east-1
S3_USE_SSL=false
```

For boto3 configure S3 path-style addressing. Store the MP4 bytes in MinIO under a key such as `raw/{video_id}/original.mp4`; store that key, metadata and status in PostgreSQL. Do not publish large media bytes through RabbitMQ.

## 6. Common operations

```bash
docker compose ps -a              # status
docker compose logs -f postgres    # PostgreSQL logs
docker compose logs -f minio       # MinIO logs
docker compose restart             # restart services
docker compose down                # stop/remove containers; KEEP data volumes
docker compose up -d               # start them again; data remains
```

**Destructive reset — permanently deletes stored videos and the database:**

```bash
docker compose down -v
```

Then `docker compose up -d` to recreate the empty volumes, extension, schema and bucket.

## 7. Notes / limitations

- The SQL files in `db/init/` run only on a **brand-new** PostgreSQL data volume. Changing them later will not migrate an existing database; use migration tooling such as Alembic in the application layer.
- The `minio-init` uses the MinIO Client `mc` image; its `latest` tag is convenient for the short-lived local initializer. Pin it to a tested release/digest when making a reproducible release.
- The credentials are **development-only**. Do not reuse them in production or expose PostgreSQL, MinIO management ports or root credentials publicly. On GKE, use private services and managed secrets; this local Compose configuration is not production-ready.
- If a public S3 URL for `localhost:9000` is returned to browsers or used in remote deployments, it will not work outside this laptop. Later generate appropriately addressed presigned URLs or serve authenticated clips through the API.
- The included schema is deliberately minimal; model dimension and schema should be versioned as the pipeline evolves.

# Distributed Video Search - End-to-End Implementation Guide

This guide is a step-by-step plan to build the project described in [`README.md`](../README.md) (working spec) and informed by [`Distributed_Video_Search_Proposal_v4.docx.md`](../Distributed_Video_Search_Proposal_v4.docx.md). When the two differ, **prefer the README defaults** unless the team deliberately changes them, and update the README when you do.

> **Core idea:** upload videos -> segment and index in parallel (visual embeddings + transcripts) -> answer natural-language queries, including ordered/temporal events, with `(video_id, start_sec, end_sec)` results. Build a thin vertical slice first, then add intelligence, scale, and experiments.

---

## 0. Before you write code

### 0.1 Align on scope and the "source of truth"
- [ ] Read `README.md` end-to-end, especially **§3 Tech stack**, **§4 How it works**, **§5 Interfaces and data**, **§9 Evaluation plan**, **§10 Plan**.
- [ ] Decide on the baseline stack (README-proposed, recommended to start):
  - **Queue:** RabbitMQ (`segment_tasks`, DLQ, manual ack, prefetch 1-2)
  - **KV/locking/cache:** Redis (`claim:*`, `job:*:progress`, `cache:search:*`)
  - **DB + vector search:** PostgreSQL + pgvector (+ GIN/tsvector for transcripts)
  - **Object storage:** MinIO locally, S3/GCS later
  - **ML:** pretrained CLIP (e.g. `ViT-B/32`, 512-dim) + Whisper (start with `base`/`small`)
  - **API:** FastAPI (REST) + internal service calls as needed (gRPC/Protobuf can be added per README)
  - **Processing:** Python, ffmpeg, PySceneDetect
- [ ] Note intentional simplifications vs proposal: README uses Redis claims instead of etcd, pgvector instead of Milvus, timeline merge in-app/job instead of Spark-first. Treat Spark/OCR/VLM/Milvus/KEDA as stretch or later swaps (README §11).
- [ ] Pick 1-2 minute sample videos and one "known answer" query for fast iteration.

### 0.2 Repo and conventions (do early)
- [ ] Create the proposed layout (empty modules are fine initially):
  ```text
  docs/  proto/  services/{api,worker,planner,search}/  db/  k8s/  eval/  scripts/
  ```
- [ ] Add `.gitignore`, `.env.example` (no secrets committed), `docker-compose.yml` placeholder.
- [ ] Agree on conventions from README §12: feature branches + PR review, idempotent tasks, structured logs with `video_id, segment_id, worker_id`, pin `config_version` (sampling params + model versions).
- [ ] Choose a Python packaging approach (e.g. per-service `pyproject.toml`/`requirements.txt` or a shared workspace) and a formatter/linter.

### 0.3 Local prerequisites
- Docker Desktop (or Docker Engine) + Compose
- Python 3.10+ (for scripts/local service dev), ffmpeg installed locally for quick tests
- (Later) GPU access for faster CLIP/Whisper; **develop and debug on CPU with tiny videos first** (README §8, §11)

**Definition of "ready":** you can run containers locally and everyone can reproduce the same environment from `.env.example`.

---

## 1. Build order: what to build first and why

Build **bottom-up infrastructure + a minimal end-to-end vertical slice** before adaptive sampling, LLM planning, or Kubernetes. This de-risks integration and gives you a debuggable baseline.

**Recommended order:**
1. **Local platform (Compose):** Postgres+pgvector, Redis, RabbitMQ, MinIO - so every service has dependencies.
2. **Data contracts:** DB schema (`videos`, `segments`, `frames`, etc.) and task message shape (start JSON or Protobuf per README §5.2).
3. **Object storage client + upload path:** save raw video, create job/segment records.
4. **API skeleton:** `POST /videos`, `GET /videos/{id}/status`, `GET /health`.
5. **Queue + single worker (fixed-rate indexing):** segment video, publish tasks, consume, extract frames at fixed FPS, compute CLIP embeddings, write to DB, ack.
6. **Basic search:** embed query text with CLIP, pgvector similarity over frames/scenes, return top moments.
7. **Reliability basics:** Redis claim, idempotent upserts, retries/DLQ, status tracking.
8. **Adaptive indexing + Whisper + timeline** (Phase 2).
9. **Query planner + temporal reranker** (Phase 3).
10. **Kubernetes + scaling/failure experiments** (Phase 3-4).

> **Rule of thumb:** do not start with the LLM planner or fancy reranking. First prove: *upload -> indexed -> searchable*.

---

## 2. Phase 1 - Baseline vertical slice (local, fixed-rate)

**Goal (README §10):** Upload API, storage, queue, one worker type, CLIP embeddings in PostgreSQL, basic search with fixed-rate sampling, all running locally.

### Step 1.1 - Docker Compose stack
- [ ] In `docker-compose.yml`, add services:
  - `postgres` with **pgvector** image (e.g. `pgvector/pgvector:pg16`)
  - `redis`
  - `rabbitmq` (with management plugin for debugging: ports 5672, 15672)
  - `minio` (+ optional init job/bucket creation)
  - placeholders for `api` and `worker` (can start as local processes, then containerize)
- [ ] Configure volumes for persistence, healthchecks, and a shared network.
- [ ] Create `.env.example` with `DATABASE_URL`, `REDIS_URL`, `RABBITMQ_URL`, `S3_ENDPOINT/BUCKET/ACCESS_KEY/SECRET_KEY`, `CLIP_MODEL`, `EMBED_DIM`, `FIXED_FPS`, `SEGMENT_SEC`, `SEGMENT_OVERLAP_SEC`, etc.
- [ ] Verify: `docker compose up -d` and you can connect to each dependency.

**Checkpoint:** all infra healthy; RabbitMQ UI reachable.

### Step 1.2 - Database schema and migrations
- [ ] Create `db/schema.sql` (and a simple migration mechanism or init script) based on README §5.4:
  - `videos(video_id PK, uri, duration_sec, status, created_at)`
  - `segments(video_id, segment_id, start_sec, end_sec, status, attempt, worker_id, updated_at, PRIMARY KEY(video_id, segment_id))`
  - `frames(video_id, segment_id, ts_sec, scene_id, embedding vector(512), PRIMARY KEY(video_id, segment_id, ts_sec))` (adjust dim to model)
  - Minimal `scenes`/`transcripts`/`timeline` can be stubbed now and completed in Phase 2.
- [ ] Enable `CREATE EXTENSION vector;` and add indexes later (start without HNSW for tiny data; add HNSW/IVFFlat once you have rows).
- [ ] Decide ID strategy (`uuid` or string like `v42`) and status enums (`PENDING|PROCESSING|DONE|FAILED`).

**Checkpoint:** schema applies cleanly on a fresh DB.

### Step 1.3 - Shared models/contracts
- [ ] Define the task payload (README §5.3): `video_id, segment_id, start_sec, end_sec, video_uri, attempt, config_version`.
  - Start with JSON over RabbitMQ for speed; add `proto/SegmentTask.proto` when stabilizing interfaces.
- [ ] Define a small shared library/helpers for: config loading, DB session, S3/MinIO client, logging formatter that always emits `video_id, segment_id, worker_id`.

**Checkpoint:** one place to change config and logging format.

### Step 1.4 - Object storage and video ingest
- [ ] Implement MinIO/S3 helpers: `upload_raw_video`, `download_segment_or_video`, (later) `upload_clip`.
- [ ] On upload: store file under a deterministic key (e.g. `videos/{video_id}/raw.mp4`), probe duration with `ffprobe`.
- [ ] Decide segmentation strategy: fixed-length windows (e.g. 30s) with overlap (e.g. 2-4s) per README §4.1.

**Checkpoint:** can upload/download a file programmatically and read duration.

### Step 1.5 - API service (`services/api`)
- [ ] Implement FastAPI endpoints (README §5.1):
  - `GET /health` -> liveness
  - `POST /videos` -> accept upload (multipart), save to MinIO, insert `videos` + `segments` rows, publish one task per segment to RabbitMQ, return `video_id`
  - `GET /videos/{video_id}/status` -> segments total/done/failed (from DB and/or Redis `job:{video_id}:progress`)
  - `POST /search` -> stub initially, then wire to basic search
- [ ] Publish durable messages to `segment_tasks`; consider queue length/overflow policy per README §5.6 (can be configured in RabbitMQ defs).
- [ ] Update Redis progress hash on enqueue for fast status reads.

**Checkpoint:** uploading a short video creates DB rows and N messages in RabbitMQ.

### Step 1.6 - Worker service (`services/worker`) - fixed-rate indexing
Build the worker in small, testable steps:
- [ ] **Consume:** connect to RabbitMQ, `prefetch=1`, manual ack; parse task.
- [ ] **Claim (basic):** `SET claim:{video_id}:{segment_id} NX EX 60` in Redis (README §5.5); renew/heartbeat for long jobs; release/let expire appropriately.
- [ ] **Idempotency check:** if segment already `DONE` in DB, ack and skip (critical for redelivery).
- [ ] **Fetch media:** download video/segment range (or stream via ffmpeg using time offsets).
- [ ] **Fixed-rate frame extraction:** use ffmpeg/PIL/OpenCV to sample at e.g. 1 FPS within `[start_sec, end_sec)`.
- [ ] **Embeddings:** load pretrained CLIP once per worker process; compute image embeddings for sampled frames (normalize vectors).
- [ ] **Persist:** upsert `frames` rows `(video_id, segment_id, ts_sec, embedding)` and mark segment `DONE`; on failure mark `FAILED`, increment attempt, nack/requeue per policy.
- [ ] **Ack only after DB commit** (README §4.4).
- [ ] **Progress:** increment Redis `job:{video_id}:done` or `failed`.
- [ ] Log processing time per segment and all actions with `video_id, segment_id, worker_id`.

**Checkpoint:** with 1 worker, a 1-2 min video reaches all segments `DONE` and `frames` table populated.

### Step 1.7 - Basic search (frame-level, no planner yet)
- [ ] Add a search module/service (`services/search` or inside API initially):
  - Encode query text with the **same CLIP model**.
  - Run pgvector similarity query over `frames` (optionally aggregate to short windows/scenes later).
  - Return top-k `{video_id, start_sec, end_sec, score}`; `clip_url` can be a placeholder or generated on-demand.
- [ ] Implement `POST /search` per README §5.1.
- [ ] (Optional now) Redis cache `cache:search:{hash}` with short TTL.

**Checkpoint:** a known visual query (e.g. "red car") returns a plausible time range for your sample video.

### Step 1.8 - Phase 1 hardening and tests
- [ ] **Unit tests:** fixed sampling count/gaps logic (where applicable), timestamp math with overlaps.
- [ ] **End-to-end test:** `scripts/upload_sample.py` + `scripts/search.py` (README §7) assert known query hits expected range (with tolerance).
- [ ] **Failure sanity check:** kill worker mid-segment and confirm redelivery + idempotent completion (no duplicate frame rows for same key).
- [ ] Containerize `api` and `worker` in Compose so `docker compose up --build` runs the full baseline (README §7).

**Phase 1 exit criteria:** README §10 "Definition of done" items 1-2 partially satisfied for fixed-rate baseline; pipeline reproducible locally.

---

## 3. Phase 2 - Adaptive indexing, speech, and timelines

**Goal (README §10):** Whisper transcripts, frame selection rule, timelines built from vision and speech.

### Step 2.1 - Adaptive frame selection rule
- [ ] Implement the deterministic algorithm from README §4.2 in a pure, testable function/module:
  - Inputs: decoded low-res/grayscale frames or diffs, `THRESHOLD`, `MIN_GAP`, `MAX_GAP`.
  - Use `mean pixel difference` or histogram distance; detect scene cuts via PySceneDetect or thresholded diff.
  - Record `config_version` including these params.
- [ ] **Unit tests** with hand-made frame sequences: static (≈1 per `MAX_GAP`), high motion (capped by `MIN_GAP`), slow drift (accumulation triggers).
- [ ] Add a config flag to switch `fixed` vs `adaptive` sampling for Experiment B.

**Checkpoint:** same segment + settings => identical selected timestamps.

### Step 2.2 - Speech with Whisper
- [ ] Extract audio per segment (ffmpeg) and run Whisper; store segments in `transcripts(video_id, segment_id, start_sec, end_sec, text, tsv)`.
- [ ] Add GIN index on `transcripts.tsv` and/or store `tsvector` for full-text search.
- [ ] Ensure transcript timestamps are in **global video time** (offset by segment start; handle overlap carefully).

**Checkpoint:** transcripts searchable and aligned roughly to video time.

### Step 2.3 - Scenes and timeline construction
- [ ] Populate `scenes` (scene boundaries + mean embedding) if useful for coarse-to-fine search (README §4.3 step 6).
- [ ] Build `timeline` entries merging speech and visual intervals per video (README §4.1 step 4, §5.4): trigger when all segments `DONE` (worker-side check or a small aggregator job/task).
- [ ] Handle segment overlaps/boundaries so events spanning cuts are joined.

**Checkpoint:** each fully indexed video has a coherent timeline; search can use transcript-heavy queries.

### Step 2.4 - Multimodal basic search
- [ ] Extend retrieval to combine CLIP similarity and PostgreSQL full-text rank (even before planner, allow simple weighting).

**Phase 2 exit criteria:** adaptive vs fixed sampling switchable; vision+speech indexed; timelines available.

---

## 4. Phase 3 - Temporal/sequential search and deployment

**Goal (README §10):** Query planner and temporal reranker; move to Kubernetes with Redis claims.

### Step 3.1 - Query planner (`services/planner`)
- [ ] Implement planner output schema (README §5.3): ordered `events` with `weights {visual, speech}` and `relations {before, after, max_gap_sec}`.
- [ ] LLM path: prompt to emit strict JSON; validate schema.
- [ ] **Fallback:** on LLM failure/invalid JSON, treat query as a single event (README §5.2 fallback note).
- [ ] Cache planner results if helpful.

**Checkpoint:** simple, compositional, and temporal queries produce sensible structured plans.

### Step 3.2 - Coarse-to-fine retrieval and reranker (`services/search`)
- [ ] For each event: retrieve candidates (scenes -> frames) using modality weights.
- [ ] Implement reranking per README §5.7: find ordered sequence `t1 < ... < tn` satisfying gaps, maximize `sum(event_score_i) - lambda * sum(gap_i)`; return `[t1-pad, tn+pad]`.
- [ ] This is where "sequence of events" correctness lives - write thorough unit tests with hand-made timelines (README §8).

**Checkpoint:** a labeled two-event temporal query beats plain frame-only search on your eval set (README §10 DoD).

### Step 3.3 - Kubernetes deployment
- [ ] Write manifests in `k8s/`: Deployments/Services for API, worker; Stateful/managed or external services for Postgres/Redis/RabbitMQ/MinIO (or managed cloud equivalents).
- [ ] Configure secrets/configmaps from env vars; resource requests/limits; GPU node pool for workers (T4 class) per README §2.
- [ ] Validate Redis claim behavior and RabbitMQ ack/redelivery in-cluster.
- [ ] Manual scaling of worker replicas (1,2,4) for experiments (autoscaling/KEDA is stretch).

**Checkpoint:** same end-to-end flow works on the cluster for a small test video.

---

## 5. Phase 4 - Evaluation, reliability, and performance

**Goal (README §10):** Run experiments A-D, scripted and unattended.

### Step 4.1 - Dataset and labels
- [ ] Prepare ~10 hours mix (lectures + activity clips, e.g. Charades-STA subset) as feasible (README §9).
- [ ] Create `eval/queries.jsonl` (30-40 labeled queries: simple/compositional/temporal) with ground-truth `start_sec/end_sec`.
- [ ] Split validation (tune `THRESHOLD, MIN_GAP, MAX_GAP`) vs test (report).

### Step 4.2 - Experiment scripts (`eval/`, `scripts/`)
- [ ] **A. Scaling:** run with 1/2/4 workers; record indexed hours/hour, GPU use, queue length over time.
- [ ] **B. Adaptive indexing:** compare fixed 1 FPS, uniform-at-same-budget, adaptive at several thresholds; measure embeddings count, GPU time, storage, Recall@K; plot accuracy vs cost (README §9 note: beating same-budget uniform matters).
- [ ] **C. Temporal search:** frame-only vs ordered-event; Recall@K and temporal IoU/overlap per query level.
- [ ] **D. Failure recovery:** kill a worker mid-indexing; measure recovery time, segments redone, and verify final index equals no-failure run (hash/count checks or deterministic comparison).

**Checkpoint:** reproducible scripts, saved metrics/artifacts, plots for report.

### Step 4.3 - Observability and debugging aids
- [ ] Ensure traceable structured logs everywhere; capture RabbitMQ queue depth/unacked; optionally basic Prometheus/Grafana if time permits (proposal mentions them).

---

## 6. Phase 5 - Wrap-up
- [ ] Final report with methods, experiment results, honest discussion of limitations.
- [ ] Demo script/flow: upload -> status -> temporal query -> returned clip/time range.
- [ ] Clean docs, pin `config_version`, ensure README reflects any `(proposed)` changes.

---

## 7. Suggested timeline & parallel workstreams (team of 3)

Align to README §10 streams: **(1) Infra/API/storage/queue/Redis/K8s**, **(2) Worker/indexing/CLIP/Whisper/sampling**, **(3) Timeline/planner/search/reranker**. Everyone shares eval/report.

| Order | Focus | Stream 1 (Infra) | Stream 2 (Indexing) | Stream 3 (Search/Timeline) |
|---|---|---|---|---|
| Week 1 | Foundations | Compose stack, MinIO, DB schema/migrations, env/config | ffmpeg segmentation + fixed frame extraction prototype | search contract, pgvector query spike |
| Week 2 | Vertical slice | `POST /videos`, status, RabbitMQ publish/DLQ settings | worker consume/claim/CLIP embed/upsert/ack | basic `POST /search` (frame similarity) |
| Week 3 | Baseline complete | containerize services, e2e scripts, progress tracking | fixed-rate pipeline stable, idempotency/recovery | result formatting, clip URL strategy |
| Week 4 | Phase 2 | transcript/timeline tables, job-complete trigger support | adaptive sampling rule + tests, Whisper integration | timeline merge logic, multimodal scoring |
| Week 5 | Phase 3 | K8s manifests, secrets, manual scaling | worker perf/tuning, config_version discipline | planner + temporal reranker + unit tests |
| Week 6 | Phase 4-5 | experiment infra/scaling runs | sampling sweeps & cost metrics | temporal eval, plots, demo/report polish |

*Adjust to your course calendar; the dependency order matters more than exact weeks.*

---

## 8. Practical tips and common pitfalls
- **Always ack after persist:** prevents data loss; combine with idempotent upserts on `(video_id, segment_id[, ts_sec])` to make duplicates harmless.
- **Overlap handling:** subtract overlap when computing global timelines/results or dedupe by timestamp to avoid double-counting.
- **Model/dimension consistency:** CLIP variant determines embedding size (README §5.4 shows 512 for ViT-B/32); changing models requires schema/config migration.
- **Global timestamps:** store/return times relative to the original video, not segment-local, for search results.
- **Start tiny:** 1-2 min videos, 1 worker, CPU if needed - debug logic before spending GPU/cloud budget (README §11 risk plan).
- **Cut scope in order if behind:** per README §11 (e.g. drop 4-worker run keep 1/2, simplify query levels/baselines) while preserving a working, measurable core.
- **Keep README updated:** when a `(proposed)` choice becomes decided, record it.

## 9. "First week" concrete checklist (quick start)
- [ ] `docker compose up` brings up Postgres(pgvector), Redis, RabbitMQ, MinIO.
- [ ] `db/schema.sql` applied; can insert/query a dummy video and segment.
- [ ] `POST /videos` stores an mp4 in MinIO and enqueues segment tasks.
- [ ] Worker consumes one task, extracts fixed-rate frames, writes CLIP embeddings, marks `DONE`.
- [ ] `POST /search` with a simple text query returns at least one result row from pgvector.
- [ ] One script demonstrates upload + poll status + search end-to-end.

Once this works, every subsequent feature (adaptive sampling, Whisper, planner, reranker, K8s, experiments) is an incremental, testable extension of a working system.

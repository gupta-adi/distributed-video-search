-- Foundation schema for the video search service. This is a starting point,
-- not a substitute for versioned migrations when the application evolves.

CREATE TABLE IF NOT EXISTS videos (
    video_id UUID PRIMARY KEY,
    object_key TEXT NOT NULL UNIQUE,
    filename TEXT NOT NULL,
    duration_sec DOUBLE PRECISION,
    status TEXT NOT NULL DEFAULT 'UPLOADED'
        CHECK (status IN ('UPLOADED', 'INDEXING', 'READY', 'FAILED')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS segments (
    video_id UUID NOT NULL REFERENCES videos(video_id) ON DELETE CASCADE,
    segment_id INTEGER NOT NULL,
    start_sec DOUBLE PRECISION NOT NULL,
    end_sec DOUBLE PRECISION NOT NULL,
    status TEXT NOT NULL DEFAULT 'PENDING'
        CHECK (status IN ('PENDING', 'PROCESSING', 'DONE', 'FAILED')),
    attempt INTEGER NOT NULL DEFAULT 0,
    worker_id TEXT,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (video_id, segment_id),
    CHECK (segment_id >= 0),
    CHECK (start_sec >= 0),
    CHECK (end_sec > start_sec)
);

CREATE TABLE IF NOT EXISTS transcripts (
    transcript_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    video_id UUID NOT NULL,
    segment_id INTEGER NOT NULL,
    start_sec DOUBLE PRECISION NOT NULL,
    end_sec DOUBLE PRECISION NOT NULL,
    text TEXT NOT NULL,
    search_vector TSVECTOR GENERATED ALWAYS AS (to_tsvector('english', text)) STORED,
    FOREIGN KEY (video_id, segment_id)
        REFERENCES segments(video_id, segment_id) ON DELETE CASCADE,
    CHECK (end_sec > start_sec)
);

CREATE INDEX IF NOT EXISTS transcripts_fulltext_idx
ON transcripts USING GIN (search_vector);

-- CLIP ViT-B/32 uses 512 dimensions. Change via a migration if the model changes.
CREATE TABLE IF NOT EXISTS frames (
    video_id UUID NOT NULL,
    segment_id INTEGER NOT NULL,
    timestamp_sec DOUBLE PRECISION NOT NULL,
    embedding VECTOR(512) NOT NULL,
    PRIMARY KEY (video_id, segment_id, timestamp_sec),
    FOREIGN KEY (video_id, segment_id)
        REFERENCES segments(video_id, segment_id) ON DELETE CASCADE
);

-- Exact vector search works even without an ANN index; add HNSW after loading data
-- and profiling your retrieval needs.

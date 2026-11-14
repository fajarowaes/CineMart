CREATE SCHEMA IF NOT EXISTS project_staging;
CREATE SCHEMA IF NOT EXISTS project_dw;
CREATE SCHEMA IF NOT EXISTS project_reporting;

-- Equivalent of bronze_movies: raw API records, untouched
CREATE TABLE IF NOT EXISTS project_staging.raw_movies (
    raw_id            BIGSERIAL PRIMARY KEY,
    pulled_at         TIMESTAMPTZ,
    source_endpoint   TEXT,
    source_collection TEXT NOT NULL,          -- full_load | trending | changed
    source_file       TEXT NOT NULL,
    raw_record        JSONB NOT NULL,
    record_hash       TEXT NOT NULL,
    batch_id          TEXT NOT NULL,
    load_timestamp    TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (batch_id, source_file, record_hash)   -- same role as your bronze MERGE key
);

CREATE TABLE IF NOT EXISTS project_staging.etl_audit_log (
    log_id               BIGSERIAL PRIMARY KEY,
    layer_processed      TEXT,
    load_type            TEXT,
    batch_id             TEXT,
    parameter_processed  TEXT,
    execution_start_time TIMESTAMPTZ,
    execution_end_time   TIMESTAMPTZ,
    status               TEXT,
    rows_inserted        BIGINT,
    rows_updated         BIGINT,
    rows_quarantined     BIGINT,
    error_message        TEXT
);

CREATE TABLE IF NOT EXISTS project_staging.etl_quarantine (
    raw_id         BIGINT NOT NULL REFERENCES project_staging.raw_movies(raw_id),
    reject_reason  TEXT   NOT NULL,
    quarantined_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (raw_id, reject_reason)
);


CREATE OR REPLACE FUNCTION project_staging.clean_text(t text) RETURNS text AS $$
    SELECT NULLIF(btrim(regexp_replace(t, '\s+', ' ', 'g')), '');
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION project_staging.safe_int(t text) RETURNS bigint AS $$
BEGIN RETURN t::bigint; EXCEPTION WHEN others THEN RETURN NULL; END $$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION project_staging.safe_numeric(t text) RETURNS numeric AS $$
BEGIN RETURN t::numeric; EXCEPTION WHEN others THEN RETURN NULL; END $$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION project_staging.safe_date(t text) RETURNS date AS $$
BEGIN RETURN t::date; EXCEPTION WHEN others THEN RETURN NULL; END $$ LANGUAGE plpgsql IMMUTABLE;

CREATE TABLE IF NOT EXISTS project_staging.stg_movie (
    tmdb_id               BIGINT PRIMARY KEY,
    movie_nk              TEXT NOT NULL,
    movie_title           TEXT NOT NULL,
    original_title        TEXT,
    release_date          DATE,
    release_year          INT,
    running_time_min      INT,
    release_status        TEXT NOT NULL,
    primary_genre         TEXT,
    franchise             TEXT NOT NULL,
    primary_country       TEXT,
    primary_language      TEXT,
    primary_distributor   TEXT NOT NULL,
    distributor_id        TEXT NOT NULL,
    production_budget_usd NUMERIC(14,2),
    revenue_usd           NUMERIC(14,2),
    vote_average          DOUBLE PRECISION,
    vote_count            INT,
    popularity            DOUBLE PRECISION,
    imdb_id               TEXT,
    is_adult              BOOLEAN,
    source_collection     TEXT,
    pulled_at             TIMESTAMPTZ,
    batch_id              TEXT,
    load_ts               TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS project_staging.stg_movie_trending (
    tmdb_id       BIGINT NOT NULL,
    snapshot_date DATE   NOT NULL,
    popularity    DOUBLE PRECISION,
    vote_average  DOUBLE PRECISION,
    vote_count    INT,
    pulled_at     TIMESTAMPTZ,
    batch_id      TEXT,
    load_ts       TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (tmdb_id, snapshot_date)
);







-- 4a. Quarantine records with no usable id or title
INSERT INTO project_staging.etl_quarantine (raw_id, reject_reason)
SELECT raw_id,
       CASE WHEN project_staging.safe_int(raw_record->>'id') IS NULL THEN 'NULL_ID' ELSE 'NULL_TITLE' END
FROM project_staging.raw_movies
WHERE source_collection IN ('full_load','changed')
  AND (project_staging.safe_int(raw_record->>'id') IS NULL
       OR project_staging.clean_text(raw_record->>'title') IS NULL)
ON CONFLICT DO NOTHING;

-- 4b. Clean + deduplicate + upsert
WITH base AS (
    SELECT r.batch_id, r.source_collection, r.load_timestamp,
           COALESCE(r.pulled_at, r.load_timestamp) AS pulled_at,
           r.raw_record AS j,
           project_staging.safe_int(r.raw_record->>'id')              AS tmdb_id,
           project_staging.clean_text(r.raw_record->>'title')         AS movie_title,
           project_staging.safe_date(r.raw_record->>'release_date')   AS release_date,
           project_staging.safe_numeric(r.raw_record->>'budget')      AS budget,
           project_staging.safe_numeric(r.raw_record->>'revenue')     AS revenue,
           project_staging.safe_int(r.raw_record->>'runtime')         AS runtime,
           project_staging.clean_text(r.raw_record->'production_companies'->0->>'name') AS dist_name
    FROM project_staging.raw_movies r
    WHERE r.source_collection IN ('full_load','changed')
),
ranked AS (
    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY tmdb_id
               ORDER BY pulled_at DESC,
                        CASE source_collection WHEN 'changed' THEN 1 ELSE 2 END,
                        load_timestamp DESC) AS rn
    FROM base
    WHERE tmdb_id IS NOT NULL AND movie_title IS NOT NULL
)
INSERT INTO project_staging.stg_movie
  (tmdb_id, movie_nk, movie_title, original_title, release_date, release_year, running_time_min,
   release_status, primary_genre, franchise, primary_country, primary_language,
   primary_distributor, distributor_id, production_budget_usd, revenue_usd,
   vote_average, vote_count, popularity, imdb_id, is_adult, source_collection, pulled_at, batch_id)
SELECT tmdb_id,
       lower(movie_title) || '|' || COALESCE(release_date::text, 'unknown'),
       movie_title,
       project_staging.clean_text(j->>'original_title'),
       release_date,
       EXTRACT(YEAR FROM release_date)::int,
       CASE WHEN runtime BETWEEN 1 AND 600 THEN runtime::int END,
       CASE WHEN release_date <= CURRENT_DATE OR j->>'status' = 'Released' THEN 'Released' ELSE 'Upcoming' END,
       initcap(project_staging.clean_text(j->'genres'->0->>'name')),
       COALESCE(project_staging.clean_text(
           regexp_replace(COALESCE(j->'belongs_to_collection'->>'name',''), '\s+Collection$', '')), 'No Franchise'),
       initcap(project_staging.clean_text(j->'production_countries'->0->>'name')),
       initcap(COALESCE(project_staging.clean_text(j->'spoken_languages'->0->>'english_name'),
                        project_staging.clean_text(j->>'original_language'))),
       COALESCE(dist_name, 'Unknown'),
       COALESCE(uppzr(regexp_replace(regexp_replace(lower(dist_name), '[^a-z0-9]+', '_', 'g'), '^_|_$', '', 'g')), 'UNKNOWN'),
       CASE WHEN budget  > 0 THEN budget  END,      -- TMDB uses 0 for "unknown"
       CASE WHEN revenue > 0 THEN revenue END,
       project_staging.safe_numeric(j->>'vote_average')::double precision,
       project_staging.safe_int(j->>'vote_count')::int,
       project_staging.safe_numeric(j->>'popularity')::double precision,
       project_staging.clean_text(j->>'imdb_id'),
       CASE WHEN j->>'adult' IN ('true','false') THEN (j->>'adult')::boolean END,
       source_collection, pulled_at, batch_id
FROM ranked
WHERE rn = 1
ON CONFLICT (tmdb_id) DO UPDATE SET
    movie_nk = EXCLUDED.movie_nk, movie_title = EXCLUDED.movie_title, original_title = EXCLUDED.original_title,
    release_date = EXCLUDED.release_date, release_year = EXCLUDED.release_year,
    running_time_min = EXCLUDED.running_time_min, release_status = EXCLUDED.release_status,
    primary_genre = EXCLUDED.primary_genre, franchise = EXCLUDED.franchise,
    primary_country = EXCLUDED.primary_country, primary_language = EXCLUDED.primary_language,
    primary_distributor = EXCLUDED.primary_distributor, distributor_id = EXCLUDED.distributor_id,
    production_budget_usd = EXCLUDED.production_budget_usd, revenue_usd = EXCLUDED.revenue_usd,
    vote_average = EXCLUDED.vote_average, vote_count = EXCLUDED.vote_count, popularity = EXCLUDED.popularity,
    imdb_id = EXCLUDED.imdb_id, is_adult = EXCLUDED.is_adult, source_collection = EXCLUDED.source_collection,
    pulled_at = EXCLUDED.pulled_at, batch_id = EXCLUDED.batch_id, load_ts = now()
WHERE EXCLUDED.pulled_at >= project_staging.stg_movie.pulled_at;   -- never let an older pull overwrite a newer one




INSERT INTO project_staging.stg_movie_trending
  (tmdb_id, snapshot_date, popularity, vote_average, vote_count, pulled_at, batch_id)
SELECT tmdb_id, snapshot_date, popularity, vote_average, vote_count, pulled_at, batch_id
FROM (
    SELECT DISTINCT ON (tmdb_id, snapshot_date)
           project_staging.safe_int(raw_record->>'id')                                  AS tmdb_id,
           COALESCE(pulled_at, load_timestamp)::date                                    AS snapshot_date,
           project_staging.safe_numeric(raw_record->>'popularity')::double precision    AS popularity,
           project_staging.safe_numeric(raw_record->>'vote_average')::double precision  AS vote_average,
           project_staging.safe_int(raw_record->>'vote_count')::int                     AS vote_count,
           COALESCE(pulled_at, load_timestamp)                                          AS pulled_at,
           batch_id
    FROM project_staging.raw_movies
    WHERE source_collection = 'trending'
      AND project_staging.safe_int(raw_record->>'id') IS NOT NULL
    ORDER BY tmdb_id, snapshot_date, COALESCE(pulled_at, load_timestamp) DESC
) t
ON CONFLICT (tmdb_id, snapshot_date) DO UPDATE SET
    popularity = EXCLUDED.popularity, vote_average = EXCLUDED.vote_average,
    vote_count = EXCLUDED.vote_count, pulled_at = EXCLUDED.pulled_at,
    batch_id = EXCLUDED.batch_id, load_ts = now()
WHERE EXCLUDED.pulled_at >= project_staging.stg_movie_trending.pulled_at;






SELECT 'raw_movies' AS tbl, COUNT(*) FROM project_staging.raw_movies
UNION ALL SELECT 'stg_movie', COUNT(*) FROM project_staging.stg_movie
UNION ALL SELECT 'stg_movie_trending', COUNT(*) FROM project_staging.stg_movie_trending
UNION ALL SELECT 'etl_quarantine', COUNT(*) FROM project_staging.etl_quarantine;

SELECT source_collection, COUNT(*) FROM project_staging.raw_movies GROUP BY 1;
SELECT * FROM project_staging.stg_movie LIMIT 20;
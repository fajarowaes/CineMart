-- 01_schemas_and_raw.sql
-- Creates the three project schemas, the two raw landing tables (TMDB JSON + Kaggle CSV), and the ETL control tables.
-- Safe to re-run (all statements are IF NOT EXISTS).

CREATE SCHEMA IF NOT EXISTS project_staging;
CREATE SCHEMA IF NOT EXISTS project_dw;
CREATE SCHEMA IF NOT EXISTS project_reporting;

-- Raw API records, stored untouched (JSONB). Equivalent of the Databricks bronze table.
CREATE TABLE IF NOT EXISTS project_staging.raw_movies (
    raw_id            BIGSERIAL PRIMARY KEY,
    pulled_at         TIMESTAMPTZ,
    source_endpoint   TEXT,
    source_collection TEXT        NOT NULL,          -- full_load | trending | changed
    source_file       TEXT        NOT NULL,
    raw_record        JSONB       NOT NULL,
    record_hash       TEXT        NOT NULL,
    batch_id          TEXT        NOT NULL,
    load_timestamp    TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (source_file, record_hash)                -- re-loading the same file never duplicates rows
);

-- Raw Kaggle CSV rows (movies_dataset.csv), every column kept as text exactly as in the file.
CREATE TABLE IF NOT EXISTS project_staging.raw_csv_movies (
    source_row              INT         PRIMARY KEY,      -- line order in the CSV file (1 = first data row)
    csv_idx                 TEXT,                         -- the unnamed first column of the CSV
    comparisons             TEXT,
    creative_type           TEXT,
    domestic_box_office     TEXT,
    domestic_releases       TEXT,
    domestic_share          TEXT,
    franchise               TEXT,
    genre                   TEXT,
    infl_adj_dom_bo         TEXT,
    international_box_office TEXT,
    international_releases  TEXT,
    keywords                TEXT,
    languages               TEXT,
    legs                    TEXT,
    mpaa_rating             TEXT,
    opening_weekend         TEXT,
    production_budget       TEXT,
    production_companies    TEXT,
    production_countries    TEXT,
    production_method       TEXT,
    running_time            TEXT,
    source                  TEXT,
    theater_counts          TEXT,
    video_release           TEXT,
    worldwide_box_office    TEXT,
    title                   TEXT,
    est_blu_ray_sales       TEXT,
    total_est_video_sales   TEXT,
    est_dvd_sales           TEXT,
    batch_id                TEXT,
    load_timestamp          TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- One row per pipeline step per run
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

-- Raw records that cannot be loaded into staging (both sources)
CREATE TABLE IF NOT EXISTS project_staging.etl_quarantine (
    source_system  TEXT        NOT NULL,      -- TMDB | CSV
    source_key     TEXT        NOT NULL,      -- TMDB: raw_id, CSV: source_row
    reject_reason  TEXT        NOT NULL,
    quarantined_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (source_system, source_key, reject_reason)
);

-- Data quality results (written by 09_data_quality.sql)
CREATE TABLE IF NOT EXISTS project_staging.etl_dq_results (
    dq_id       BIGSERIAL PRIMARY KEY,
    run_label   TEXT        NOT NULL,
    category    TEXT        NOT NULL,   -- Completeness | Accuracy | Integrity | Reconciliation | Volume | Cross-source
    check_name  TEXT        NOT NULL,
    table_name  TEXT        NOT NULL,
    failed_rows BIGINT      NOT NULL,
    total_rows  BIGINT      NOT NULL,
    severity    TEXT        NOT NULL,   -- ERROR (must be 0) | INFO (reported only)
    status      TEXT        NOT NULL,   -- PASS | FAIL | INFO
    checked_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

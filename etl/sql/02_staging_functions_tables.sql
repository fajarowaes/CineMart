-- 02_staging_functions_tables.sql
-- Safe-cast helpers (return NULL instead of failing) and the cleaned staging tables.

CREATE OR REPLACE FUNCTION project_staging.clean_text(t text) RETURNS text AS $$
    SELECT NULLIF(btrim(regexp_replace(t, '\s+', ' ', 'g')), '');
$$ LANGUAGE sql IMMUTABLE;

-- Standardize case: trim, collapse spaces, and fix ALL-UPPER or all-lower text to Proper Case.
-- Text that is already mixed case (e.g. 'United States of America', 'TV Movie') is left as it is.
CREATE OR REPLACE FUNCTION project_staging.std_case(t text) RETURNS text AS $$
    SELECT CASE WHEN c IS NULL THEN NULL
                WHEN c = lower(c) OR c = upper(c) THEN initcap(c)
                ELSE c END
    FROM (SELECT project_staging.clean_text(t) AS c) x;
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION project_staging.safe_int(t text) RETURNS bigint AS $$
BEGIN RETURN t::bigint; EXCEPTION WHEN others THEN RETURN NULL; END $$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION project_staging.safe_numeric(t text) RETURNS numeric AS $$
BEGIN RETURN t::numeric; EXCEPTION WHEN others THEN RETURN NULL; END $$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION project_staging.safe_date(t text) RETURNS date AS $$
BEGIN RETURN t::date; EXCEPTION WHEN others THEN RETURN NULL; END $$ LANGUAGE plpgsql IMMUTABLE;

-- TMDB: one row per movie (latest version wins). Used to enrich the CSV movies.
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

CREATE INDEX IF NOT EXISTS ix_stg_movie_match ON project_staging.stg_movie (lower(movie_title), release_year);

-- ---------- CSV helpers ----------
-- '$23,837,227 (3.1% of total gross)' -> 23837227 ; zero or no amount -> NULL
CREATE OR REPLACE FUNCTION project_staging.parse_money(t text) RETURNS numeric AS $$
    SELECT NULLIF(NULLIF(regexp_replace(COALESCE(substring(t from '\$\s*([0-9][0-9,]*(?:\.[0-9]+)?)'), ''), ',', '', 'g'), '')::numeric, 0);
$$ LANGUAGE sql IMMUTABLE;

-- 'June 16th, 1995 (Wide) by Warner Bros.' -> 1995-06-16 ; ('May, 1975' has no day -> NULL)
CREATE OR REPLACE FUNCTION project_staging.parse_release_date(t text) RETURNS date AS $$
DECLARE m text[];
BEGIN
    m := regexp_match(t, '^\s*([A-Z][a-z]+) (\d{1,2})(?:st|nd|rd|th), (\d{4})');
    IF m IS NULL THEN RETURN NULL; END IF;
    RETURN to_date(m[1] || ' ' || m[2] || ' ' || m[3], 'FMMonth FMDD YYYY');
EXCEPTION WHEN others THEN RETURN NULL;
END $$ LANGUAGE plpgsql IMMUTABLE;

-- Text of the FIRST domestic release entry only (entries are glued together without a separator in the CSV)
CREATE OR REPLACE FUNCTION project_staging.first_release_entry(t text) RETURNS text AS $$
    SELECT substr(t, 1, 1) || regexp_replace(substr(t, 2),
        '(?:January|February|March|April|May|June|July|August|September|October|November|December)(?: \d{1,2}(?:st|nd|rd|th))?, \d{4}.*$', '');
$$ LANGUAGE sql IMMUTABLE;

-- ---------- CSV: one row per movie (duplicates removed) ----------
CREATE TABLE IF NOT EXISTS project_staging.stg_csv_movie (
    source_row               INT PRIMARY KEY,
    movie_id                 TEXT NOT NULL UNIQUE,         -- natural key: lower(title) | release_date
    movie_title              TEXT NOT NULL,
    release_date             DATE NOT NULL,
    release_year             INT  NOT NULL,
    mpaa_rating              VARCHAR(10),
    running_time_min         INT,
    creative_type            TEXT,
    genre                    TEXT,
    franchise                TEXT NOT NULL,
    production_method        TEXT,
    source_type              TEXT,
    primary_country          TEXT,
    primary_language         TEXT,
    production_budget_usd    NUMERIC(14,2),
    distributor_name         TEXT NOT NULL,
    distributor_id           TEXT NOT NULL,
    opening_theaters         INT,
    max_theaters             INT,
    avg_run_weeks            NUMERIC(5,1),
    release_pattern          VARCHAR(20),
    release_status           VARCHAR(20) NOT NULL,
    domestic_revenue_usd     NUMERIC(14,2),
    international_revenue_usd NUMERIC(14,2),
    infl_adj_domestic_usd    NUMERIC(14,2),
    opening_weekend_usd      NUMERIC(14,2),
    dvd_sales_usd            NUMERIC(14,2),
    bluray_sales_usd         NUMERIC(14,2),
    csv_worldwide_usd        NUMERIC(14,2),               -- kept only for the reconciliation check
    batch_id                 TEXT,
    load_ts                  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- CSV movie -> TMDB movie (same title and release year; most-voted TMDB record wins)
CREATE TABLE IF NOT EXISTS project_staging.stg_movie_tmdb_match (
    movie_id TEXT   PRIMARY KEY,
    tmdb_id  BIGINT NOT NULL
);

-- ---------- Supplementary extracts (generated in 05_seed_supplementary.sql) ----------
CREATE TABLE IF NOT EXISTS project_staging.stg_theater_run (
    movie_id               TEXT NOT NULL,
    territory_code         TEXT NOT NULL,
    snapshot_date          DATE NOT NULL,                 -- month-end
    distributor_id         TEXT NOT NULL,
    active_theater_count   INT  NOT NULL,
    period_revenue_usd     NUMERIC(14,2) NOT NULL,
    cumulative_revenue_usd NUMERIC(14,2) NOT NULL,
    PRIMARY KEY (movie_id, territory_code, snapshot_date)
);

CREATE TABLE IF NOT EXISTS project_staging.stg_promotion (
    promotion_code TEXT PRIMARY KEY,
    promotion_name TEXT NOT NULL,
    promotion_type TEXT NOT NULL,
    campaign_phase TEXT
);

CREATE TABLE IF NOT EXISTS project_staging.stg_promotion_event (
    event_id       TEXT PRIMARY KEY,
    event_date     DATE NOT NULL,
    promotion_code TEXT NOT NULL,
    movie_id       TEXT NOT NULL,
    territory_code TEXT NOT NULL,
    distributor_id TEXT NOT NULL
);

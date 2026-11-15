-- 03_load_stg_tmdb_movie.sql
-- TMDB raw -> staging (used to enrich the CSV movies): quarantine bad records, then clean, deduplicate and upsert movies.
-- Cleaning rules: trim/collapse whitespace, ALL-UPPER/all-lower genre, country and language fixed to Proper Case (mixed case kept), 0 budget/revenue -> NULL,
-- runtime outside 1-600 -> NULL, empty franchise -> 'No Franchise', empty distributor -> 'Unknown'.

-- 3a. Quarantine records with no usable id or title
INSERT INTO project_staging.etl_quarantine (source_system, source_key, reject_reason)
SELECT 'TMDB', raw_id::text,
       CASE WHEN project_staging.safe_int(raw_record->>'id') IS NULL THEN 'NULL_ID' ELSE 'NULL_TITLE' END
FROM project_staging.raw_movies
WHERE source_collection IN ('full_load', 'changed')
  AND (project_staging.safe_int(raw_record->>'id') IS NULL
       OR project_staging.clean_text(raw_record->>'title') IS NULL)
ON CONFLICT DO NOTHING;

-- 3b. Clean + deduplicate + upsert
WITH base AS (
    SELECT r.batch_id, r.source_collection, r.load_timestamp,
           COALESCE(r.pulled_at, r.load_timestamp) AS pulled_at,
           r.raw_record AS j,
           project_staging.safe_int(r.raw_record->>'id')            AS tmdb_id,
           project_staging.clean_text(r.raw_record->>'title')       AS movie_title,
           project_staging.safe_date(r.raw_record->>'release_date') AS release_date,
           project_staging.safe_numeric(r.raw_record->>'budget')    AS budget,
           project_staging.safe_numeric(r.raw_record->>'revenue')   AS revenue,
           project_staging.safe_int(r.raw_record->>'runtime')       AS runtime,
           project_staging.clean_text(r.raw_record->'production_companies'->0->>'name') AS dist_name
    FROM project_staging.raw_movies r
    WHERE r.source_collection IN ('full_load', 'changed')
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
       project_staging.std_case(j->'genres'->0->>'name'),
       COALESCE(project_staging.clean_text(
           regexp_replace(COALESCE(j->'belongs_to_collection'->>'name', ''), '\s+Collection$', '')), 'No Franchise'),
       project_staging.std_case(j->'production_countries'->0->>'name'),
       project_staging.std_case(COALESCE(j->'spoken_languages'->0->>'english_name',
                                         j->>'original_language')),
       COALESCE(dist_name, 'Unknown'),
       COALESCE(NULLIF(upper(regexp_replace(regexp_replace(lower(dist_name), '[^a-z0-9]+', '_', 'g'), '^_|_$', '', 'g')), ''),
                'UNKNOWN'),
       CASE WHEN budget  > 0 THEN budget  END,
       CASE WHEN revenue > 0 THEN revenue END,
       project_staging.safe_numeric(j->>'vote_average')::double precision,
       project_staging.safe_int(j->>'vote_count')::int,
       project_staging.safe_numeric(j->>'popularity')::double precision,
       project_staging.clean_text(j->>'imdb_id'),
       CASE WHEN j->>'adult' IN ('true', 'false') THEN (j->>'adult')::boolean END,
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
WHERE EXCLUDED.pulled_at >= project_staging.stg_movie.pulled_at;   -- an older pull never overwrites a newer one

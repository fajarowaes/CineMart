-- 04_load_stg_csv_movie.sql
-- Kaggle CSV raw -> cleaned staging (one row per movie), then link each movie to TMDB.
-- Cleaning rules: trim/collapse spaces, ALL-UPPER/all-lower text fixed to Proper Case, '$1,234 (note)' -> number,
-- zero amounts -> NULL, runtime outside 1-600 -> NULL, empty franchise -> 'No Franchise', missing distributor -> 'Unknown',
-- rows without title or release date -> quarantine, duplicate movies (same title + release date) -> one row kept.

-- 4a. Quarantine rows that cannot become a movie
INSERT INTO project_staging.etl_quarantine (source_system, source_key, reject_reason)
SELECT 'CSV', source_row::text,
       CASE WHEN project_staging.clean_text(title) IS NULL THEN 'NULL_TITLE' ELSE 'NO_RELEASE_DATE' END
FROM project_staging.raw_csv_movies
WHERE project_staging.clean_text(title) IS NULL
   OR project_staging.parse_release_date(domestic_releases) IS NULL
ON CONFLICT DO NOTHING;

-- 4b. Clean + deduplicate (staging is rebuilt on every run)
TRUNCATE project_staging.stg_movie_tmdb_match, project_staging.stg_csv_movie;

WITH parsed AS (
    SELECT r.source_row, r.batch_id,
           project_staging.clean_text(r.title)                                   AS movie_title,
           project_staging.parse_release_date(r.domestic_releases)               AS release_date,
           project_staging.first_release_entry(r.domestic_releases)              AS first_entry,
           substring(r.mpaa_rating from '^\s*(NC-17|PG-13|PG|G|R|Not Rated|Unrated)') AS mpaa_rating,
           project_staging.safe_int(substring(r.running_time from '([0-9]+)'))   AS runtime,
           project_staging.std_case(r.creative_type)                             AS creative_type,
           project_staging.std_case(r.genre)                                     AS genre,
           project_staging.clean_text(r.franchise)                               AS franchise,
           project_staging.std_case(r.production_method)                         AS production_method,
           project_staging.std_case(r.source)                                    AS source_type,
           project_staging.std_case(split_part(r.production_countries, ',', 1))  AS primary_country,
           project_staging.std_case(split_part(r.languages, ',', 1))             AS primary_language,
           project_staging.parse_money(r.production_budget)                      AS budget,
           project_staging.safe_int(replace(substring(r.theater_counts from '^([0-9,]+) opening theaters'), ',', ''))   AS opening_theaters,
           project_staging.safe_int(replace(substring(r.theater_counts from '/([0-9,]+) max'), ',', ''))               AS max_theaters,
           project_staging.safe_numeric(substring(r.theater_counts from '([0-9.]+) weeks average'))                    AS avg_run_weeks,
           project_staging.parse_money(r.domestic_box_office)                    AS dom_rev,
           project_staging.parse_money(r.international_box_office)               AS intl_rev,
           project_staging.parse_money(r.infl_adj_dom_bo)                        AS infl_adj,
           project_staging.parse_money(r.opening_weekend)                        AS opening_wknd,
           project_staging.parse_money(r.est_dvd_sales)                          AS dvd,
           project_staging.parse_money(r.est_blu_ray_sales)                      AS bluray,
           project_staging.parse_money(r.worldwide_box_office)                   AS ww
    FROM project_staging.raw_csv_movies r
),
valid AS (
    SELECT p.*,
           project_staging.clean_text(regexp_replace(regexp_replace(substring(first_entry from '\) by (.*)$'), ',\s*released as.*$', ''), '\s*\(.*$', '')) AS dist_name
    FROM parsed p
    WHERE movie_title IS NOT NULL AND release_date IS NOT NULL
),
ranked AS (
    SELECT v.*,
           ROW_NUMBER() OVER (
               PARTITION BY lower(movie_title), release_date
               ORDER BY (CASE WHEN dom_rev IS NOT NULL THEN 1 ELSE 0 END + CASE WHEN intl_rev IS NOT NULL THEN 1 ELSE 0 END
                       + CASE WHEN budget IS NOT NULL THEN 1 ELSE 0 END + CASE WHEN genre IS NOT NULL THEN 1 ELSE 0 END
                       + CASE WHEN opening_theaters IS NOT NULL THEN 1 ELSE 0 END + CASE WHEN dist_name IS NOT NULL THEN 1 ELSE 0 END) DESC,
                        source_row) AS rn
    FROM valid v
)
INSERT INTO project_staging.stg_csv_movie
  (source_row, movie_id, movie_title, release_date, release_year, mpaa_rating, running_time_min, creative_type, genre,
   franchise, production_method, source_type, primary_country, primary_language, production_budget_usd,
   distributor_name, distributor_id, opening_theaters, max_theaters, avg_run_weeks, release_pattern, release_status,
   domestic_revenue_usd, international_revenue_usd, infl_adj_domestic_usd, opening_weekend_usd, dvd_sales_usd,
   bluray_sales_usd, csv_worldwide_usd, batch_id)
SELECT source_row,
       lower(movie_title) || '|' || release_date::text,
       movie_title, release_date, EXTRACT(YEAR FROM release_date)::int,
       mpaa_rating,
       CASE WHEN runtime BETWEEN 1 AND 600 THEN runtime::int END,
       creative_type, genre,
       COALESCE(franchise, 'No Franchise'),
       production_method, source_type, primary_country, primary_language, budget,
       COALESCE(dist_name, 'Unknown'),
       COALESCE(NULLIF(upper(regexp_replace(regexp_replace(lower(dist_name), '[^a-z0-9]+', '_', 'g'), '^_|_$', '', 'g')), ''), 'UNKNOWN'),
       opening_theaters::int, max_theaters::int, avg_run_weeks,
       CASE WHEN opening_theaters >= 600 THEN 'Wide'
            WHEN opening_theaters IS NOT NULL THEN 'Limited'
            WHEN first_entry ~ '\(Wide\)' THEN 'Wide'
            WHEN first_entry ~ '\(Limited\)' THEN 'Limited' END,
       CASE WHEN release_date <= CURRENT_DATE THEN 'Released' ELSE 'Upcoming' END,
       dom_rev, intl_rev, infl_adj, opening_wknd, dvd, bluray, ww, batch_id
FROM ranked
WHERE rn = 1;

-- 4c. Link CSV movies to TMDB (same title + release year; the TMDB record with the most votes wins)
INSERT INTO project_staging.stg_movie_tmdb_match (movie_id, tmdb_id)
SELECT DISTINCT ON (c.movie_id) c.movie_id, t.tmdb_id
FROM project_staging.stg_csv_movie c
JOIN project_staging.stg_movie t
  ON lower(t.movie_title) = lower(c.movie_title) AND t.release_year = c.release_year
ORDER BY c.movie_id, t.vote_count DESC NULLS LAST, t.tmdb_id;

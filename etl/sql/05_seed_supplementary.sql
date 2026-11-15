-- 05_seed_supplementary.sql
-- The CSV has no monthly theater series and no promotion data, so these two supplementary extracts are GENERATED
-- (Phase 2 Option B: synthetic data). Rules are deterministic, so every run gives the same rows.
-- Real inputs: release date, opening theaters, average run weeks, domestic revenue, genre, distributor from stg_csv_movie.

TRUNCATE project_staging.stg_theater_run, project_staging.stg_promotion_event, project_staging.stg_promotion;

-- ---------------------------------------------------------------------------------------------
-- A. Theater-run snapshot: one row per movie, territory (Domestic) and month-end of the theatrical run.
--    Run length = average run weeks / 4.345 rounded up (1-6 months). Revenue halves every month and the
--    last month takes the rounding remainder, so the final cumulative revenue = domestic box office exactly.
--    Active theaters wind down linearly from the opening theater count.
-- ---------------------------------------------------------------------------------------------
INSERT INTO project_staging.stg_theater_run
  (movie_id, territory_code, snapshot_date, distributor_id, active_theater_count, period_revenue_usd, cumulative_revenue_usd)
WITH base AS (
    SELECT movie_id, distributor_id, release_date, opening_theaters, domestic_revenue_usd AS dom,
           LEAST(6, GREATEST(1, CEIL(COALESCE(avg_run_weeks, 4) / 4.345)))::int AS n
    FROM project_staging.stg_csv_movie
    WHERE domestic_revenue_usd > 0 AND opening_theaters > 0
),
months AS (
    SELECT b.*, k,
           (date_trunc('month', b.release_date) + (k + 1) * interval '1 month' - interval '1 day')::date AS snapshot_date,
           ROUND(b.dom * power(0.5, k) / (2 * (1 - power(0.5, b.n))), 2)                              AS raw_period
    FROM base b CROSS JOIN LATERAL generate_series(0, b.n - 1) k
),
calc AS (
    SELECT m.*,
           COALESCE(SUM(raw_period) OVER (PARTITION BY movie_id ORDER BY k ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS prev_cum
    FROM months m
)
SELECT movie_id, 'DOM', snapshot_date, distributor_id,
       GREATEST(1, ROUND(opening_theaters * (n - k)::numeric / n))::int,
       CASE WHEN k = n - 1 THEN dom - prev_cum ELSE raw_period END,
       CASE WHEN k = n - 1 THEN dom ELSE prev_cum + raw_period END
FROM calc;

-- ---------------------------------------------------------------------------------------------
-- B. Promotions (11) and promotion events
-- ---------------------------------------------------------------------------------------------
INSERT INTO project_staging.stg_promotion (promotion_code, promotion_name, promotion_type, campaign_phase) VALUES
 ('FEST_CANNES',   'Cannes Film Festival Screening',  'Festival Screening', 'Pre-Release'),
 ('FEST_SUNDANCE', 'Sundance Film Festival Screening','Festival Screening', 'Pre-Release'),
 ('FEST_TIFF',     'Toronto Film Festival Screening', 'Festival Screening', 'Pre-Release'),
 ('FEST_VENICE',   'Venice Film Festival Screening',  'Festival Screening', 'Pre-Release'),
 ('FEST_SXSW',     'SXSW Film Festival Screening',    'Festival Screening', 'Pre-Release'),
 ('PREM_HOLLYWOOD','Hollywood Red Carpet Premiere',   'Premiere',           'Opening'),
 ('PREM_LONDON',   'London Premiere',                 'Premiere',           'Opening'),
 ('TRL_THEATRICAL','Theatrical Trailer Campaign',     'Trailer Campaign',   'Pre-Release'),
 ('TRL_SUPERBOWL', 'Super Bowl Trailer Spot',         'Trailer Campaign',   'Pre-Release'),
 ('AWD_OSCAR',     'Oscar Awards Campaign',           'Awards Campaign',    'Post-Release'),
 ('AWD_GLOBES',    'Golden Globes Awards Campaign',   'Awards Campaign',    'Post-Release');

-- Event rules (one event = one promotion, one movie, one territory):
--   Wide releases:            trailer campaign 30 days before release (Domestic) and Hollywood premiere 1 day before
--   Wide + international:     London premiere 1 day before release (International)
--   Domestic >= 100 M USD:    Super Bowl trailer spot 60 days before release (Domestic)
--   Drama/Documentary/Thriller/Black Comedy: about 1 in 5 movies screened at one festival, 30-89 days before release
--   Drama with domestic >= 20 M USD: Oscar campaign 60 days after release; with domestic >= 50 M also Golden Globes
-- "Random" choices use md5(movie_id + code) so they are repeatable.
INSERT INTO project_staging.stg_promotion_event (event_id, event_date, promotion_code, movie_id, territory_code, distributor_id)
WITH ev AS (
    SELECT movie_id, distributor_id, 'TRL_THEATRICAL' AS code, 'DOM' AS terr, release_date - 30 AS dt
    FROM project_staging.stg_csv_movie WHERE release_pattern = 'Wide'
    UNION ALL SELECT movie_id, distributor_id, 'PREM_HOLLYWOOD', 'DOM', release_date - 1
    FROM project_staging.stg_csv_movie WHERE release_pattern = 'Wide'
    UNION ALL SELECT movie_id, distributor_id, 'PREM_LONDON', 'INTL', release_date - 1
    FROM project_staging.stg_csv_movie WHERE release_pattern = 'Wide' AND international_revenue_usd > 0
    UNION ALL SELECT movie_id, distributor_id, 'TRL_SUPERBOWL', 'DOM', release_date - 60
    FROM project_staging.stg_csv_movie WHERE domestic_revenue_usd >= 100000000
    UNION ALL SELECT movie_id, distributor_id,
           (ARRAY['FEST_CANNES','FEST_SUNDANCE','FEST_TIFF','FEST_VENICE','FEST_SXSW'])[1 + get_byte(decode(md5(movie_id || 'F'), 'hex'), 1) % 5],
           CASE WHEN get_byte(decode(md5(movie_id || 'F'), 'hex'), 1) % 5 IN (1, 4) THEN 'DOM' ELSE 'INTL' END,
           release_date - (30 + get_byte(decode(md5(movie_id || 'D'), 'hex'), 2) % 60)
    FROM project_staging.stg_csv_movie
    WHERE genre IN ('Drama', 'Documentary', 'Thriller/Suspense', 'Black Comedy')
      AND get_byte(decode(md5(movie_id || 'F'), 'hex'), 0) < 52
    UNION ALL SELECT movie_id, distributor_id, 'AWD_OSCAR', 'DOM', release_date + 60
    FROM project_staging.stg_csv_movie WHERE genre = 'Drama' AND domestic_revenue_usd >= 20000000
    UNION ALL SELECT movie_id, distributor_id, 'AWD_GLOBES', 'DOM', release_date + 60
    FROM project_staging.stg_csv_movie WHERE genre = 'Drama' AND domestic_revenue_usd >= 50000000
)
SELECT 'EVT-' || code || '-' || substr(md5(movie_id || code || terr), 1, 10), dt, code, movie_id, terr, distributor_id
FROM ev;

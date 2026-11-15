-- 09_data_quality.sql
-- Completeness, accuracy, integrity, reconciliation, volume and cross-source checks. One INSERT, so all rows share a run_label.
-- ERROR checks must return 0 failed rows; INFO checks are reported only.

WITH checks (category, check_name, table_name, failed_rows, total_rows, severity) AS (

  -- ===== COMPLETENESS =====
  SELECT 'Completeness', 'movie_title is not null', 'stg_csv_movie',
         (SELECT count(*) FROM project_staging.stg_csv_movie WHERE movie_title IS NULL),
         (SELECT count(*) FROM project_staging.stg_csv_movie), 'ERROR'
  UNION ALL SELECT 'Completeness', 'release_date is not null', 'stg_csv_movie',
         (SELECT count(*) FROM project_staging.stg_csv_movie WHERE release_date IS NULL),
         (SELECT count(*) FROM project_staging.stg_csv_movie), 'ERROR'
  UNION ALL SELECT 'Completeness', 'movie_title is not null', 'dim_movie',
         (SELECT count(*) FROM project_dw.dim_movie WHERE movie_title IS NULL),
         (SELECT count(*) FROM project_dw.dim_movie), 'ERROR'
  UNION ALL SELECT 'Completeness', 'release_date is not null', 'dim_movie',
         (SELECT count(*) FROM project_dw.dim_movie WHERE release_date IS NULL),
         (SELECT count(*) FROM project_dw.dim_movie), 'ERROR'
  UNION ALL SELECT 'Completeness', 'revenue_usd is not null', 'fact_box_office_sales',
         (SELECT count(*) FROM project_dw.fact_box_office_sales WHERE revenue_usd IS NULL),
         (SELECT count(*) FROM project_dw.fact_box_office_sales), 'ERROR'
  UNION ALL SELECT 'Completeness', 'genre missing', 'dim_movie',
         (SELECT count(*) FROM project_dw.dim_movie WHERE genre IS NULL),
         (SELECT count(*) FROM project_dw.dim_movie), 'INFO'
  UNION ALL SELECT 'Completeness', 'mpaa_rating missing', 'dim_movie',
         (SELECT count(*) FROM project_dw.dim_movie WHERE mpaa_rating IS NULL),
         (SELECT count(*) FROM project_dw.dim_movie), 'INFO'
  UNION ALL SELECT 'Completeness', 'production_budget_usd missing', 'dim_movie',
         (SELECT count(*) FROM project_dw.dim_movie WHERE production_budget_usd IS NULL),
         (SELECT count(*) FROM project_dw.dim_movie), 'INFO'
  UNION ALL SELECT 'Completeness', 'running_time_min missing', 'dim_movie',
         (SELECT count(*) FROM project_dw.dim_movie WHERE running_time_min IS NULL),
         (SELECT count(*) FROM project_dw.dim_movie), 'INFO'
  UNION ALL SELECT 'Completeness', 'distributor Unknown', 'dim_movie (via stg_csv_movie)',
         (SELECT count(*) FROM project_staging.stg_csv_movie WHERE distributor_id = 'UNKNOWN'),
         (SELECT count(*) FROM project_staging.stg_csv_movie), 'INFO'
  UNION ALL SELECT 'Completeness', 'movies without a TMDB link', 'dim_movie',
         (SELECT count(*) FROM project_dw.dim_movie WHERE tmdb_id IS NULL),
         (SELECT count(*) FROM project_dw.dim_movie), 'INFO'

  -- ===== ACCURACY =====
  UNION ALL SELECT 'Accuracy', 'revenue_usd is greater than 0', 'fact_box_office_sales',
         (SELECT count(*) FROM project_dw.fact_box_office_sales WHERE revenue_usd <= 0),
         (SELECT count(*) FROM project_dw.fact_box_office_sales), 'ERROR'
  UNION ALL SELECT 'Accuracy', 'opening weekend is not above domestic revenue', 'fact_box_office_sales',
         (SELECT count(*) FROM project_dw.fact_box_office_sales WHERE opening_weekend_revenue_usd > revenue_usd),
         (SELECT count(*) FROM project_dw.fact_box_office_sales WHERE opening_weekend_revenue_usd IS NOT NULL), 'ERROR'
  UNION ALL SELECT 'Accuracy', 'revenue reconciliation: staging total = fact total', 'fact_box_office_sales',
         (SELECT CASE WHEN (SELECT COALESCE(SUM(COALESCE(domestic_revenue_usd,0)+COALESCE(international_revenue_usd,0)+COALESCE(dvd_sales_usd,0)+COALESCE(bluray_sales_usd,0)),0) FROM project_staging.stg_csv_movie) = (SELECT COALESCE(SUM(revenue_usd),0) FROM project_dw.fact_box_office_sales) THEN 0 ELSE 1 END),
         1, 'ERROR'
  UNION ALL SELECT 'Accuracy', 'snapshot final cumulative revenue = domestic box office in sales fact', 'fact_theater_run_snapshot',
         (SELECT count(*) FROM (SELECT s.movie_key, MAX(s.cumulative_revenue_usd) AS cum FROM project_dw.fact_theater_run_snapshot s GROUP BY s.movie_key) x JOIN (SELECT f.movie_key, SUM(f.revenue_usd) AS dom FROM project_dw.fact_box_office_sales f JOIN project_dw.dim_territory t ON t.territory_key=f.territory_key JOIN project_dw.dim_release_channel ch ON ch.channel_key=f.channel_key WHERE t.territory_code='DOM' AND ch.channel_code='THEATRICAL' GROUP BY f.movie_key) y USING (movie_key) WHERE x.cum <> y.dom),
         (SELECT count(DISTINCT movie_key) FROM project_dw.fact_theater_run_snapshot), 'ERROR'
  UNION ALL SELECT 'Accuracy', 'sum of period revenue = final cumulative revenue per movie', 'fact_theater_run_snapshot',
         (SELECT count(*) FROM (SELECT movie_key FROM project_dw.fact_theater_run_snapshot GROUP BY movie_key HAVING SUM(period_revenue_usd) <> MAX(cumulative_revenue_usd)) x),
         (SELECT count(DISTINCT movie_key) FROM project_dw.fact_theater_run_snapshot), 'ERROR'
  UNION ALL SELECT 'Accuracy', 'active_theater_count is greater than 0', 'fact_theater_run_snapshot',
         (SELECT count(*) FROM project_dw.fact_theater_run_snapshot WHERE active_theater_count <= 0),
         (SELECT count(*) FROM project_dw.fact_theater_run_snapshot), 'ERROR'
  UNION ALL SELECT 'Accuracy', 'snapshot dates are month-end dates', 'fact_theater_run_snapshot',
         (SELECT count(*) FROM project_dw.fact_theater_run_snapshot s JOIN project_dw.dim_date d ON d.date_key=s.date_key WHERE d.full_date <> (date_trunc('month', d.full_date) + interval '1 month' - interval '1 day')::date),
         (SELECT count(*) FROM project_dw.fact_theater_run_snapshot), 'ERROR'
  UNION ALL SELECT 'Accuracy', 'runtime within 1-600 minutes', 'dim_movie',
         (SELECT count(*) FROM project_dw.dim_movie WHERE running_time_min NOT BETWEEN 1 AND 600),
         (SELECT count(*) FROM project_dw.dim_movie), 'ERROR'
  UNION ALL SELECT 'Accuracy', 'mpaa_rating is a valid value', 'dim_movie',
         (SELECT count(*) FROM project_dw.dim_movie WHERE mpaa_rating NOT IN ('G','PG','PG-13','R','NC-17','Not Rated','Unrated')),
         (SELECT count(*) FROM project_dw.dim_movie WHERE mpaa_rating IS NOT NULL), 'ERROR'
  UNION ALL SELECT 'Accuracy', 'text standardized (no edge or double spaces in title)', 'stg_csv_movie',
         (SELECT count(*) FROM project_staging.stg_csv_movie WHERE movie_title <> btrim(movie_title) OR movie_title ~ '\s{2,}'),
         (SELECT count(*) FROM project_staging.stg_csv_movie), 'ERROR'
  UNION ALL SELECT 'Accuracy', 'budget is not negative', 'dim_movie',
         (SELECT count(*) FROM project_dw.dim_movie WHERE production_budget_usd < 0),
         (SELECT count(*) FROM project_dw.dim_movie), 'ERROR'

  -- ===== INTEGRITY =====
  UNION ALL SELECT 'Integrity', 'fact rows without matching dim_date', 'fact_box_office_sales',
         (SELECT count(*) FROM project_dw.fact_box_office_sales f LEFT JOIN project_dw.dim_date x ON x.date_key = f.date_key WHERE x.date_key IS NULL),
         (SELECT count(*) FROM project_dw.fact_box_office_sales), 'ERROR'
  UNION ALL SELECT 'Integrity', 'fact rows without matching dim_movie', 'fact_box_office_sales',
         (SELECT count(*) FROM project_dw.fact_box_office_sales f LEFT JOIN project_dw.dim_movie x ON x.movie_key = f.movie_key WHERE x.movie_key IS NULL),
         (SELECT count(*) FROM project_dw.fact_box_office_sales), 'ERROR'
  UNION ALL SELECT 'Integrity', 'fact rows without matching dim_distributor', 'fact_box_office_sales',
         (SELECT count(*) FROM project_dw.fact_box_office_sales f LEFT JOIN project_dw.dim_distributor x ON x.distributor_key = f.distributor_key WHERE x.distributor_key IS NULL),
         (SELECT count(*) FROM project_dw.fact_box_office_sales), 'ERROR'
  UNION ALL SELECT 'Integrity', 'fact rows without matching dim_territory', 'fact_box_office_sales',
         (SELECT count(*) FROM project_dw.fact_box_office_sales f LEFT JOIN project_dw.dim_territory x ON x.territory_key = f.territory_key WHERE x.territory_key IS NULL),
         (SELECT count(*) FROM project_dw.fact_box_office_sales), 'ERROR'
  UNION ALL SELECT 'Integrity', 'fact rows without matching dim_release_channel', 'fact_box_office_sales',
         (SELECT count(*) FROM project_dw.fact_box_office_sales f LEFT JOIN project_dw.dim_release_channel x ON x.channel_key = f.channel_key WHERE x.channel_key IS NULL),
         (SELECT count(*) FROM project_dw.fact_box_office_sales), 'ERROR'
  UNION ALL SELECT 'Integrity', 'fact rows without matching dim_date', 'fact_theater_run_snapshot',
         (SELECT count(*) FROM project_dw.fact_theater_run_snapshot f LEFT JOIN project_dw.dim_date x ON x.date_key = f.date_key WHERE x.date_key IS NULL),
         (SELECT count(*) FROM project_dw.fact_theater_run_snapshot), 'ERROR'
  UNION ALL SELECT 'Integrity', 'fact rows without matching dim_movie', 'fact_theater_run_snapshot',
         (SELECT count(*) FROM project_dw.fact_theater_run_snapshot f LEFT JOIN project_dw.dim_movie x ON x.movie_key = f.movie_key WHERE x.movie_key IS NULL),
         (SELECT count(*) FROM project_dw.fact_theater_run_snapshot), 'ERROR'
  UNION ALL SELECT 'Integrity', 'fact rows without matching dim_territory', 'fact_theater_run_snapshot',
         (SELECT count(*) FROM project_dw.fact_theater_run_snapshot f LEFT JOIN project_dw.dim_territory x ON x.territory_key = f.territory_key WHERE x.territory_key IS NULL),
         (SELECT count(*) FROM project_dw.fact_theater_run_snapshot), 'ERROR'
  UNION ALL SELECT 'Integrity', 'fact rows without matching dim_distributor', 'fact_theater_run_snapshot',
         (SELECT count(*) FROM project_dw.fact_theater_run_snapshot f LEFT JOIN project_dw.dim_distributor x ON x.distributor_key = f.distributor_key WHERE x.distributor_key IS NULL),
         (SELECT count(*) FROM project_dw.fact_theater_run_snapshot), 'ERROR'
  UNION ALL SELECT 'Integrity', 'fact rows without matching dim_date', 'fact_promotion_coverage',
         (SELECT count(*) FROM project_dw.fact_promotion_coverage f LEFT JOIN project_dw.dim_date x ON x.date_key = f.date_key WHERE x.date_key IS NULL),
         (SELECT count(*) FROM project_dw.fact_promotion_coverage), 'ERROR'
  UNION ALL SELECT 'Integrity', 'fact rows without matching dim_movie', 'fact_promotion_coverage',
         (SELECT count(*) FROM project_dw.fact_promotion_coverage f LEFT JOIN project_dw.dim_movie x ON x.movie_key = f.movie_key WHERE x.movie_key IS NULL),
         (SELECT count(*) FROM project_dw.fact_promotion_coverage), 'ERROR'
  UNION ALL SELECT 'Integrity', 'fact rows without matching dim_territory', 'fact_promotion_coverage',
         (SELECT count(*) FROM project_dw.fact_promotion_coverage f LEFT JOIN project_dw.dim_territory x ON x.territory_key = f.territory_key WHERE x.territory_key IS NULL),
         (SELECT count(*) FROM project_dw.fact_promotion_coverage), 'ERROR'
  UNION ALL SELECT 'Integrity', 'fact rows without matching dim_distributor', 'fact_promotion_coverage',
         (SELECT count(*) FROM project_dw.fact_promotion_coverage f LEFT JOIN project_dw.dim_distributor x ON x.distributor_key = f.distributor_key WHERE x.distributor_key IS NULL),
         (SELECT count(*) FROM project_dw.fact_promotion_coverage), 'ERROR'
  UNION ALL SELECT 'Integrity', 'fact rows without matching dim_promotion', 'fact_promotion_coverage',
         (SELECT count(*) FROM project_dw.fact_promotion_coverage f LEFT JOIN project_dw.dim_promotion x ON x.promotion_key = f.promotion_key WHERE x.promotion_key IS NULL),
         (SELECT count(*) FROM project_dw.fact_promotion_coverage), 'ERROR'
  UNION ALL SELECT 'Integrity', 'movie_id (natural key) unique in dim_movie', 'dim_movie',
         (SELECT count(*) - count(DISTINCT movie_id) FROM project_dw.dim_movie),
         (SELECT count(*) FROM project_dw.dim_movie), 'ERROR'
  UNION ALL SELECT 'Integrity', 'distributor_id (natural key) unique in dim_distributor', 'dim_distributor',
         (SELECT count(*) - count(DISTINCT distributor_id) FROM project_dw.dim_distributor),
         (SELECT count(*) FROM project_dw.dim_distributor), 'ERROR'
  UNION ALL SELECT 'Integrity', 'staging movies missing from dim_movie', 'dim_movie',
         (SELECT count(*) FROM project_staging.stg_csv_movie s LEFT JOIN project_dw.dim_movie m ON m.movie_id=s.movie_id WHERE m.movie_key IS NULL),
         (SELECT count(*) FROM project_staging.stg_csv_movie), 'ERROR'
  UNION ALL SELECT 'Integrity', 'promotion events refer to existing movies and promotions', 'stg_promotion_event',
         (SELECT count(*) FROM project_staging.stg_promotion_event e WHERE NOT EXISTS (SELECT 1 FROM project_staging.stg_csv_movie m WHERE m.movie_id=e.movie_id) OR NOT EXISTS (SELECT 1 FROM project_staging.stg_promotion p WHERE p.promotion_code=e.promotion_code)),
         (SELECT count(*) FROM project_staging.stg_promotion_event), 'ERROR'

  -- ===== RECONCILIATION =====
  UNION ALL SELECT 'Reconciliation', 'distinct valid raw CSV movies = stg_csv_movie rows', 'stg_csv_movie',
         ABS((SELECT count(*) FROM (SELECT DISTINCT lower(project_staging.clean_text(title)), project_staging.parse_release_date(domestic_releases) FROM project_staging.raw_csv_movies WHERE project_staging.clean_text(title) IS NOT NULL AND project_staging.parse_release_date(domestic_releases) IS NOT NULL) x) - (SELECT count(*) FROM project_staging.stg_csv_movie)),
         (SELECT count(*) FROM project_staging.stg_csv_movie), 'ERROR'
  UNION ALL SELECT 'Reconciliation', 'revenue lines in staging = fact_box_office_sales rows', 'fact_box_office_sales',
         ABS((SELECT count(*) FROM project_staging.stg_csv_movie c CROSS JOIN LATERAL (VALUES (c.domestic_revenue_usd),(c.international_revenue_usd),(c.dvd_sales_usd),(c.bluray_sales_usd)) v(a) WHERE v.a IS NOT NULL) - (SELECT count(*) FROM project_dw.fact_box_office_sales)),
         (SELECT count(*) FROM project_dw.fact_box_office_sales), 'ERROR'
  UNION ALL SELECT 'Reconciliation', 'stg_theater_run rows = fact_theater_run_snapshot rows', 'fact_theater_run_snapshot',
         ABS((SELECT count(*) FROM project_staging.stg_theater_run) - (SELECT count(*) FROM project_dw.fact_theater_run_snapshot)),
         (SELECT count(*) FROM project_dw.fact_theater_run_snapshot), 'ERROR'
  UNION ALL SELECT 'Reconciliation', 'stg_promotion_event rows = fact_promotion_coverage rows', 'fact_promotion_coverage',
         ABS((SELECT count(*) FROM project_staging.stg_promotion_event) - (SELECT count(*) FROM project_dw.fact_promotion_coverage)),
         (SELECT count(*) FROM project_dw.fact_promotion_coverage), 'ERROR'

  -- ===== VOLUME =====
  UNION ALL SELECT 'Volume', 'dim_date has 100+ rows', 'dim_date',
         (SELECT CASE WHEN count(*) >= 100 THEN 0 ELSE 1 END FROM project_dw.dim_date),
         (SELECT count(*) FROM project_dw.dim_date), 'ERROR'
  UNION ALL SELECT 'Volume', 'dim_movie has 100+ rows', 'dim_movie',
         (SELECT CASE WHEN count(*) >= 100 THEN 0 ELSE 1 END FROM project_dw.dim_movie),
         (SELECT count(*) FROM project_dw.dim_movie), 'ERROR'
  UNION ALL SELECT 'Volume', 'dim_distributor has 100+ rows', 'dim_distributor',
         (SELECT CASE WHEN count(*) >= 100 THEN 0 ELSE 1 END FROM project_dw.dim_distributor),
         (SELECT count(*) FROM project_dw.dim_distributor), 'ERROR'
  UNION ALL SELECT 'Volume', 'fact_box_office_sales has 10,000+ rows', 'fact_box_office_sales',
         (SELECT CASE WHEN count(*) >= 10000 THEN 0 ELSE 1 END FROM project_dw.fact_box_office_sales),
         (SELECT count(*) FROM project_dw.fact_box_office_sales), 'ERROR'
  UNION ALL SELECT 'Volume', 'fact_theater_run_snapshot has 10,000+ rows', 'fact_theater_run_snapshot',
         (SELECT CASE WHEN count(*) >= 10000 THEN 0 ELSE 1 END FROM project_dw.fact_theater_run_snapshot),
         (SELECT count(*) FROM project_dw.fact_theater_run_snapshot), 'ERROR'
  UNION ALL SELECT 'Volume', 'fact_promotion_coverage has 10,000+ rows', 'fact_promotion_coverage',
         (SELECT CASE WHEN count(*) >= 10000 THEN 0 ELSE 1 END FROM project_dw.fact_promotion_coverage),
         (SELECT count(*) FROM project_dw.fact_promotion_coverage), 'ERROR'

  -- ===== CROSS-SOURCE =====
  UNION ALL SELECT 'Cross-source', 'CSV worldwide box office differs from domestic + international', 'stg_csv_movie',
         (SELECT count(*) FROM project_staging.stg_csv_movie WHERE csv_worldwide_usd IS NOT NULL AND ABS(csv_worldwide_usd - (COALESCE(domestic_revenue_usd,0)+COALESCE(international_revenue_usd,0))) > 1),
         (SELECT count(*) FROM project_staging.stg_csv_movie WHERE csv_worldwide_usd IS NOT NULL), 'INFO'
  UNION ALL SELECT 'Cross-source', 'TMDB revenue differs from CSV worldwide by more than 25 percent', 'stg_csv_movie vs stg_movie',
         (SELECT count(*) FROM project_staging.stg_csv_movie c JOIN project_staging.stg_movie_tmdb_match m ON m.movie_id=c.movie_id JOIN project_staging.stg_movie t ON t.tmdb_id=m.tmdb_id WHERE t.revenue_usd IS NOT NULL AND c.csv_worldwide_usd IS NOT NULL AND ABS(t.revenue_usd - c.csv_worldwide_usd) > 0.25 * c.csv_worldwide_usd),
         (SELECT count(*) FROM project_staging.stg_csv_movie c JOIN project_staging.stg_movie_tmdb_match m ON m.movie_id=c.movie_id JOIN project_staging.stg_movie t ON t.tmdb_id=m.tmdb_id WHERE t.revenue_usd IS NOT NULL AND c.csv_worldwide_usd IS NOT NULL), 'INFO'
)
INSERT INTO project_staging.etl_dq_results
  (run_label, category, check_name, table_name, failed_rows, total_rows, severity, status)
SELECT 'DQ_' || to_char(now(), 'YYYYMMDD_HH24MISS'),
       category, check_name, table_name, failed_rows::bigint, total_rows::bigint, severity,
       CASE WHEN severity = 'ERROR' THEN CASE WHEN failed_rows = 0 THEN 'PASS' ELSE 'FAIL' END ELSE 'INFO' END
FROM checks;

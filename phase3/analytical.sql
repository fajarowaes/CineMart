-- =====================================================================================
-- 01_analytical_queries.sql
-- CineMart Box Office Data Warehouse (PostgreSQL)  |  Analytical SQL Layer
--
-- Aggregations used: SUM, AVG, COUNT (plus window functions for growth / ranking).
-- Source: star schema in project_dw  (built by etl/sql/06..08 of the CineMart repo).
--
-- Terminology mapping (retail wording in the brief -> CineMart star schema):
--   Revenue  -> fact_box_office_sales.revenue_usd
--   Region   -> dim_territory   (DOM = Domestic US/Canada, INTL = International)
--   Category -> dim_movie.genre
--   Product  -> dim_movie.movie_title
--   Channel  -> dim_release_channel (Theatrical, DVD, Blu-ray)
--   Customer -> dim_distributor (the studio / distributor that releases the film)
--
-- Notes on the data
--   * Revenue rows are dated on the movie RELEASE DATE, so "monthly revenue" means
--     "revenue of the films released in that month".
--   * Home-video revenue exists for the Domestic territory only.
--   * Run with:  psql -d CineMart -f 01_analytical_queries.sql
-- =====================================================================================

SET search_path TO project_dw, public;


-- -------------------------------------------------------------------------------------
-- A1. MONTHLY REVENUE with month-over-month GROWTH   (Month | Revenue | Growth)
--     Theatrical channel, all territories. LAG() looks at the previous *calendar* month
--     that has data; growth is NULL for the first month.
-- -------------------------------------------------------------------------------------
WITH monthly AS (
    SELECT  make_date(d.year, d.month, 1)  AS month_start,
            SUM(f.revenue_usd)             AS revenue
    FROM    fact_box_office_sales f
    JOIN    dim_date            d  ON d.date_key    = f.date_key
    JOIN    dim_release_channel ch ON ch.channel_key = f.channel_key
    WHERE   ch.channel_group = 'Theatrical'
    GROUP BY make_date(d.year, d.month, 1)
)
SELECT  to_char(month_start, 'YYYY-MM')                                   AS month,
        revenue,
        ROUND(100.0 * (revenue - LAG(revenue) OVER w)
                    / NULLIF(LAG(revenue) OVER w, 0), 2)                  AS growth_pct
FROM    monthly
WHERE   month_start >= DATE '2015-01-01'          -- modern window keeps the output readable
WINDOW  w AS (ORDER BY month_start)
ORDER BY month_start;


-- -------------------------------------------------------------------------------------
-- A2. YEARLY REVENUE with year-over-year growth and running total
-- -------------------------------------------------------------------------------------
WITH yearly AS (
    SELECT  d.year,
            COUNT(DISTINCT f.movie_key)  AS movies,
            COUNT(*)                     AS revenue_lines,
            SUM(f.revenue_usd)           AS revenue,
            AVG(f.revenue_usd)           AS avg_revenue_per_line
    FROM    fact_box_office_sales f
    JOIN    dim_date            d  ON d.date_key    = f.date_key
    JOIN    dim_release_channel ch ON ch.channel_key = f.channel_key
    WHERE   ch.channel_group = 'Theatrical'
    GROUP BY d.year
)
SELECT  year, movies, revenue_lines, revenue,
        ROUND(avg_revenue_per_line, 2)                                          AS avg_revenue_per_line,
        ROUND(100.0 * (revenue - LAG(revenue) OVER (ORDER BY year))
                    / NULLIF(LAG(revenue) OVER (ORDER BY year), 0), 2)          AS yoy_growth_pct,
        SUM(revenue) OVER (ORDER BY year)                                       AS running_total
FROM    yearly
WHERE   year >= 2000
ORDER BY year;


-- -------------------------------------------------------------------------------------
-- A3. REVENUE BY CHANNEL (Theatrical vs DVD vs Blu-ray): SUM, AVG, COUNT
-- -------------------------------------------------------------------------------------
SELECT  ch.channel_name,
        COUNT(*)                                   AS revenue_lines,
        COUNT(DISTINCT f.movie_key)                AS movies,
        SUM(f.revenue_usd)                         AS total_revenue,
        ROUND(AVG(f.revenue_usd), 2)               AS avg_revenue_per_line,
        ROUND(100.0 * SUM(f.revenue_usd)
              / SUM(SUM(f.revenue_usd)) OVER (), 2) AS share_of_total_pct
FROM    fact_box_office_sales f
JOIN    dim_release_channel ch ON ch.channel_key = f.channel_key
GROUP BY ch.channel_name
ORDER BY total_revenue DESC;


-- -------------------------------------------------------------------------------------
-- A4. REVENUE BY REGION (Domestic vs International), theatrical only
-- -------------------------------------------------------------------------------------
SELECT  t.territory_name,
        COUNT(*)                         AS revenue_lines,
        SUM(f.revenue_usd)               AS total_revenue,
        ROUND(AVG(f.revenue_usd), 2)     AS avg_revenue_per_movie,
        ROUND(100.0 * SUM(f.revenue_usd)
              / SUM(SUM(f.revenue_usd)) OVER (), 2) AS share_pct
FROM    fact_box_office_sales f
JOIN    dim_territory       t  ON t.territory_key = f.territory_key
JOIN    dim_release_channel ch ON ch.channel_key  = f.channel_key
WHERE   ch.channel_group = 'Theatrical'
GROUP BY t.territory_name
ORDER BY total_revenue DESC;


-- -------------------------------------------------------------------------------------
-- A5. GENRE (CATEGORY) PERFORMANCE: movies, total and average revenue per movie
--     Revenue is summed per movie first so AVG is "average per movie", not per fact row.
-- -------------------------------------------------------------------------------------
WITH per_movie AS (
    SELECT  COALESCE(m.genre, 'Unknown') AS genre,
            f.movie_key,
            SUM(f.revenue_usd)           AS movie_revenue
    FROM    fact_box_office_sales f
    JOIN    dim_movie            m  ON m.movie_key    = f.movie_key
    JOIN    dim_release_channel  ch ON ch.channel_key = f.channel_key
    WHERE   ch.channel_group = 'Theatrical'
    GROUP BY COALESCE(m.genre, 'Unknown'), f.movie_key
)
SELECT  genre,
        COUNT(*)                        AS movies,
        SUM(movie_revenue)              AS total_revenue,
        ROUND(AVG(movie_revenue), 2)    AS avg_revenue_per_movie,
        MAX(movie_revenue)              AS best_movie_revenue
FROM    per_movie
GROUP BY genre
ORDER BY total_revenue DESC;


-- -------------------------------------------------------------------------------------
-- A6. TOP 10 MOVIES BY WORLDWIDE THEATRICAL REVENUE
-- -------------------------------------------------------------------------------------
SELECT  RANK() OVER (ORDER BY SUM(f.revenue_usd) DESC) AS revenue_rank,
        m.movie_title,
        m.release_date,
        COALESCE(m.genre, 'Unknown')                   AS genre,
        SUM(f.revenue_usd)                             AS worldwide_revenue
FROM    fact_box_office_sales f
JOIN    dim_movie            m  ON m.movie_key    = f.movie_key
JOIN    dim_release_channel  ch ON ch.channel_key = f.channel_key
WHERE   ch.channel_group = 'Theatrical'
GROUP BY m.movie_key, m.movie_title, m.release_date, m.genre
ORDER BY worldwide_revenue DESC
LIMIT 10;


-- -------------------------------------------------------------------------------------
-- A7. MPAA RATING: movie count, average revenue and average budget
--     (budget is NULL for ~64% of movies; AVG ignores NULLs, COUNT(col) shows coverage)
-- -------------------------------------------------------------------------------------
WITH per_movie AS (
    SELECT  m.movie_key,
            COALESCE(m.mpaa_rating, 'Unrated/Unknown') AS mpaa_rating,
            m.production_budget_usd,
            SUM(f.revenue_usd)                          AS movie_revenue
    FROM    fact_box_office_sales f
    JOIN    dim_movie            m  ON m.movie_key    = f.movie_key
    JOIN    dim_release_channel  ch ON ch.channel_key = f.channel_key
    WHERE   ch.channel_group = 'Theatrical'
    GROUP BY m.movie_key, m.mpaa_rating, m.production_budget_usd
)
SELECT  mpaa_rating,
        COUNT(*)                                AS movies,
        COUNT(production_budget_usd)            AS movies_with_budget,
        ROUND(AVG(movie_revenue), 2)            AS avg_revenue,
        ROUND(AVG(production_budget_usd), 2)    AS avg_budget,
        SUM(movie_revenue)                      AS total_revenue
FROM    per_movie
GROUP BY mpaa_rating
ORDER BY total_revenue DESC;


-- -------------------------------------------------------------------------------------
-- A8. DISTRIBUTOR CLASS (Major vs Independent): customer-style concentration analysis
-- -------------------------------------------------------------------------------------
SELECT  COALESCE(di.distributor_class, 'Unclassified')  AS distributor_class,
        COUNT(DISTINCT di.distributor_key)              AS distributors,
        COUNT(DISTINCT f.movie_key)                     AS movies,
        SUM(f.revenue_usd)                              AS total_revenue,
        ROUND(AVG(f.revenue_usd), 2)                    AS avg_revenue_per_line,
        ROUND(100.0 * SUM(f.revenue_usd)
              / SUM(SUM(f.revenue_usd)) OVER (), 2)     AS share_pct
FROM    fact_box_office_sales f
JOIN    dim_distributor di ON di.distributor_key = f.distributor_key
GROUP BY COALESCE(di.distributor_class, 'Unclassified')
ORDER BY total_revenue DESC;


-- -------------------------------------------------------------------------------------
-- A9. OPENING WEEKEND vs TOTAL (domestic theatrical): how front-loaded is each genre?
-- -------------------------------------------------------------------------------------
SELECT  COALESCE(m.genre, 'Unknown')                        AS genre,
        COUNT(*)                                            AS movies,
        ROUND(AVG(f.opening_weekend_revenue_usd), 2)        AS avg_opening_weekend,
        ROUND(AVG(f.revenue_usd), 2)                        AS avg_domestic_total,
        ROUND(100.0 * SUM(f.opening_weekend_revenue_usd)
              / NULLIF(SUM(f.revenue_usd), 0), 2)           AS opening_share_pct
FROM    fact_box_office_sales f
JOIN    dim_movie            m  ON m.movie_key    = f.movie_key
JOIN    dim_territory        t  ON t.territory_key = f.territory_key
JOIN    dim_release_channel  ch ON ch.channel_key = f.channel_key
WHERE   t.territory_code = 'DOM'
  AND   ch.channel_group = 'Theatrical'
  AND   f.opening_weekend_revenue_usd IS NOT NULL
GROUP BY COALESCE(m.genre, 'Unknown')
HAVING  COUNT(*) >= 20
ORDER BY opening_share_pct DESC;


-- -------------------------------------------------------------------------------------
-- A10. THEATER RUN SNAPSHOT: average / peak theaters and period revenue per territory
--      active_theater_count is semi-additive, so we AVG / MAX it and never SUM it over time.
-- -------------------------------------------------------------------------------------
SELECT  t.territory_name,
        COUNT(*)                              AS monthly_snapshots,
        COUNT(DISTINCT s.movie_key)           AS movies_tracked,
        ROUND(AVG(s.active_theater_count), 1) AS avg_active_theaters,
        MAX(s.active_theater_count)           AS peak_active_theaters,
        SUM(s.period_revenue_usd)             AS total_period_revenue
FROM    fact_theater_run_snapshot s
JOIN    dim_territory t ON t.territory_key = s.territory_key
GROUP BY t.territory_name
ORDER BY total_period_revenue DESC;


-- -------------------------------------------------------------------------------------
-- A11. PROMOTION ACTIVITY: event counts by promotion type (factless fact => COUNT only)
-- -------------------------------------------------------------------------------------
SELECT  p.promotion_type,
        COUNT(*)                     AS events,
        COUNT(DISTINCT f.movie_key)  AS movies_covered,
        ROUND(1.0 * COUNT(*) / NULLIF(COUNT(DISTINCT f.movie_key), 0), 2) AS events_per_movie
FROM    fact_promotion_coverage f
JOIN    dim_promotion p ON p.promotion_key = f.promotion_key
GROUP BY p.promotion_type
ORDER BY events DESC;


-- -------------------------------------------------------------------------------------
-- A12. RETURN ON BUDGET BY GENRE (only movies with a known budget)
-- -------------------------------------------------------------------------------------
WITH per_movie AS (
    SELECT  COALESCE(m.genre, 'Unknown') AS genre,
            m.movie_key,
            m.production_budget_usd      AS budget,
            SUM(f.revenue_usd)           AS revenue
    FROM    fact_box_office_sales f
    JOIN    dim_movie            m  ON m.movie_key    = f.movie_key
    JOIN    dim_release_channel  ch ON ch.channel_key = f.channel_key
    WHERE   ch.channel_group = 'Theatrical'
      AND   m.production_budget_usd > 0
    GROUP BY COALESCE(m.genre, 'Unknown'), m.movie_key, m.production_budget_usd
)
SELECT  genre,
        COUNT(*)                                   AS movies,
        SUM(revenue)                               AS total_revenue,
        SUM(budget)                                AS total_budget,
        ROUND(SUM(revenue) / NULLIF(SUM(budget), 0), 2) AS revenue_to_budget_ratio,   -- ratio of sums
        ROUND(AVG(revenue / budget), 2)            AS avg_movie_roi                  -- mean of per-movie ratios
        -- CAUTION: avg_movie_roi is skewed by tiny-budget outliers (e.g. Comedy shows ~843).
        -- Prefer revenue_to_budget_ratio (ratio of sums) when comparing genres.
FROM    per_movie
GROUP BY genre
HAVING  COUNT(*) >= 10
ORDER BY revenue_to_budget_ratio DESC;
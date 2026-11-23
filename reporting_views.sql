-- =====================================================================================
-- 03_reporting_views.sql
-- CineMart Box Office Data Warehouse (PostgreSQL)  |  Reporting Views
--
-- Creates three business-facing views in the project_reporting schema (same schema as the
-- repo's existing views in etl/sql/10_reporting_views.sql, with which they do not clash):
--
--   project_reporting.vw_monthly_sales        monthly revenue by channel, with MoM growth
--   project_reporting.vw_customer_analysis    one row per distributor (the "customer" of the studio
--                                             ecosystem: the party that buys and releases the film)
--   project_reporting.vw_product_performance  one row per movie (the "product")
--
-- Design rules followed by all three views
--   * Each fact table is aggregated to the view's grain BEFORE it is joined, so a movie that has
--     many theatre snapshots or promotion events never multiplies its revenue (no fan-out).
--   * Additive measures are SUMmed; the semi-additive active_theater_count is MAXed, never summed over time.
--   * NULL attributes are shown as 'Unknown' so the views can be pivoted or filtered safely.
--   * Safe to re-run (CREATE OR REPLACE).     Run with:  psql -d CineMart -f 03_reporting_views.sql
-- =====================================================================================

CREATE SCHEMA IF NOT EXISTS project_reporting;


-- -------------------------------------------------------------------------------------
-- VIEW 1: vw_monthly_sales
-- Grain: one row per calendar month x channel group (Theatrical / Home Video).
-- Revenue is dated on the movie release date, i.e. "revenue of films released that month".
-- Growth: month-over-month % vs the previous month that has data in the SAME channel group.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW project_reporting.vw_monthly_sales AS
WITH monthly AS (
    SELECT  make_date(d.year, d.month, 1)           AS month_start,
            d.year,
            d.month,
            d.month_name,
            ch.channel_group,
            COUNT(*)                                AS revenue_lines,
            COUNT(DISTINCT f.movie_key)             AS movies_released,
            SUM(f.revenue_usd)                      AS revenue_usd,
            AVG(f.revenue_usd)                      AS avg_revenue_per_line_usd
    FROM    project_dw.fact_box_office_sales f
    JOIN    project_dw.dim_date            d  ON d.date_key     = f.date_key
    JOIN    project_dw.dim_release_channel ch ON ch.channel_key = f.channel_key
    GROUP BY make_date(d.year, d.month, 1), d.year, d.month, d.month_name, ch.channel_group
)
SELECT  month_start,
        to_char(month_start, 'YYYY-MM')                                            AS month,
        year,
        month                                                                      AS month_number,
        month_name,
        channel_group,
        revenue_lines,
        movies_released,
        revenue_usd,
        ROUND(avg_revenue_per_line_usd, 2)                                         AS avg_revenue_per_line_usd,
        LAG(revenue_usd) OVER (PARTITION BY channel_group ORDER BY month_start)    AS prev_month_revenue_usd,
        ROUND(100.0 * (revenue_usd - LAG(revenue_usd) OVER (PARTITION BY channel_group ORDER BY month_start))
              / NULLIF(LAG(revenue_usd) OVER (PARTITION BY channel_group ORDER BY month_start), 0), 2)
                                                                                   AS growth_pct,
        SUM(revenue_usd) OVER (PARTITION BY channel_group, year ORDER BY month_start)
                                                                                   AS ytd_revenue_usd
FROM    monthly;

COMMENT ON VIEW project_reporting.vw_monthly_sales IS
    'Monthly revenue by channel group with month-over-month growth and year-to-date total.';


-- -------------------------------------------------------------------------------------
-- VIEW 2: vw_customer_analysis
-- Grain: one row per distributor. The warehouse has no end-consumer table, so the distributor
-- (the studio / label that buys the rights and releases the film) is the customer entity.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW project_reporting.vw_customer_analysis AS
WITH sales AS (
    SELECT  f.distributor_key,
            COUNT(DISTINCT f.movie_key)                                              AS movies_distributed,
            SUM(f.revenue_usd)                                                       AS total_revenue_usd,
            SUM(f.revenue_usd) FILTER (WHERE ch.channel_group = 'Theatrical')        AS theatrical_revenue_usd,
            SUM(f.revenue_usd) FILTER (WHERE ch.channel_group = 'Home Video')        AS home_video_revenue_usd,
            SUM(f.revenue_usd) FILTER (WHERE t.territory_code = 'DOM')               AS domestic_revenue_usd,
            SUM(f.revenue_usd) FILTER (WHERE t.territory_code = 'INTL')              AS international_revenue_usd,
            MIN(d.year)                                                              AS first_release_year,
            MAX(d.year)                                                              AS last_release_year
    FROM    project_dw.fact_box_office_sales f
    JOIN    project_dw.dim_release_channel ch ON ch.channel_key   = f.channel_key
    JOIN    project_dw.dim_territory       t  ON t.territory_key  = f.territory_key
    JOIN    project_dw.dim_date            d  ON d.date_key       = f.date_key
    GROUP BY f.distributor_key
),
runs AS (
    SELECT  distributor_key,
            MAX(active_theater_count)            AS peak_active_theaters,
            ROUND(AVG(active_theater_count), 1)  AS avg_active_theaters
    FROM    project_dw.fact_theater_run_snapshot
    GROUP BY distributor_key
),
promos AS (
    SELECT  distributor_key,
            COUNT(*)                             AS promotion_events
    FROM    project_dw.fact_promotion_coverage
    GROUP BY distributor_key
)
SELECT  di.distributor_key,
        di.distributor_name,
        COALESCE(di.distributor_class, 'Unclassified')                              AS distributor_class,
        s.movies_distributed,
        s.total_revenue_usd,
        COALESCE(s.theatrical_revenue_usd, 0)                                       AS theatrical_revenue_usd,
        COALESCE(s.home_video_revenue_usd, 0)                                       AS home_video_revenue_usd,
        COALESCE(s.domestic_revenue_usd, 0)                                         AS domestic_revenue_usd,
        COALESCE(s.international_revenue_usd, 0)                                    AS international_revenue_usd,
        ROUND(s.total_revenue_usd / NULLIF(s.movies_distributed, 0), 2)             AS avg_revenue_per_movie_usd,
        ROUND(100.0 * s.total_revenue_usd / SUM(s.total_revenue_usd) OVER (), 3)    AS revenue_share_pct,
        RANK() OVER (ORDER BY s.total_revenue_usd DESC)                             AS revenue_rank,
        RANK() OVER (PARTITION BY COALESCE(di.distributor_class, 'Unclassified')
                     ORDER BY s.total_revenue_usd DESC)                             AS rank_in_class,
        s.first_release_year,
        s.last_release_year,
        COALESCE(r.peak_active_theaters, 0)                                         AS peak_active_theaters,
        r.avg_active_theaters,
        COALESCE(p.promotion_events, 0)                                             AS promotion_events,
        CASE WHEN 100.0 * SUM(s.total_revenue_usd) OVER (ORDER BY s.total_revenue_usd DESC)
                       / SUM(s.total_revenue_usd) OVER () <= 80 THEN 'Top 80% of revenue'
             ELSE 'Long tail' END                                                   AS revenue_segment
FROM    sales s
JOIN    project_dw.dim_distributor di ON di.distributor_key = s.distributor_key
LEFT JOIN runs   r ON r.distributor_key = s.distributor_key
LEFT JOIN promos p ON p.distributor_key = s.distributor_key;

COMMENT ON VIEW project_reporting.vw_customer_analysis IS
    'Distributor (customer) analysis: revenue, mix, rank, share, theatre footprint and promotion activity.';


-- -------------------------------------------------------------------------------------
-- VIEW 3: vw_product_performance
-- Grain: one row per movie (the "product"). Revenue by channel and region, opening weekend
-- strength, return on budget, ranks overall and within genre, and theatre / promotion footprint.
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW project_reporting.vw_product_performance AS
WITH sales AS (
    SELECT  f.movie_key,
            SUM(f.revenue_usd)                                                       AS total_revenue_usd,
            SUM(f.revenue_usd) FILTER (WHERE ch.channel_group = 'Theatrical')        AS theatrical_revenue_usd,
            SUM(f.revenue_usd) FILTER (WHERE ch.channel_group = 'Home Video')        AS home_video_revenue_usd,
            SUM(f.revenue_usd) FILTER (WHERE ch.channel_group = 'Theatrical'
                                         AND t.territory_code = 'DOM')               AS domestic_theatrical_usd,
            SUM(f.revenue_usd) FILTER (WHERE ch.channel_group = 'Theatrical'
                                         AND t.territory_code = 'INTL')              AS international_theatrical_usd,
            SUM(f.opening_weekend_revenue_usd)                                       AS opening_weekend_usd
    FROM    project_dw.fact_box_office_sales f
    JOIN    project_dw.dim_release_channel ch ON ch.channel_key  = f.channel_key
    JOIN    project_dw.dim_territory       t  ON t.territory_key = f.territory_key
    GROUP BY f.movie_key
),
runs AS (
    SELECT  movie_key,
            MAX(active_theater_count)  AS peak_active_theaters,
            COUNT(*)                   AS months_in_release
    FROM    project_dw.fact_theater_run_snapshot
    GROUP BY movie_key
),
promos AS (
    SELECT  movie_key,
            COUNT(*)                   AS promotion_events
    FROM    project_dw.fact_promotion_coverage
    GROUP BY movie_key
)
SELECT  m.movie_key,
        m.movie_title,
        m.release_date,
        EXTRACT(YEAR FROM m.release_date)::int                                       AS release_year,
        COALESCE(m.genre, 'Unknown')                                                 AS genre,
        COALESCE(m.mpaa_rating, 'Unknown')                                           AS mpaa_rating,
        m.franchise,
        m.production_budget_usd,
        s.total_revenue_usd,
        COALESCE(s.theatrical_revenue_usd, 0)                                        AS theatrical_revenue_usd,
        COALESCE(s.home_video_revenue_usd, 0)                                        AS home_video_revenue_usd,
        COALESCE(s.domestic_theatrical_usd, 0)                                       AS domestic_theatrical_usd,
        COALESCE(s.international_theatrical_usd, 0)                                  AS international_theatrical_usd,
        s.opening_weekend_usd,
        ROUND(100.0 * s.opening_weekend_usd / NULLIF(s.domestic_theatrical_usd, 0), 2) AS opening_weekend_pct_of_domestic,
        ROUND(s.theatrical_revenue_usd / NULLIF(m.production_budget_usd, 0), 2)      AS revenue_to_budget_ratio,
        RANK() OVER (ORDER BY s.theatrical_revenue_usd DESC NULLS LAST)              AS theatrical_rank_overall,
        RANK() OVER (PARTITION BY COALESCE(m.genre, 'Unknown')
                     ORDER BY s.theatrical_revenue_usd DESC NULLS LAST)              AS theatrical_rank_in_genre,
        NTILE(10) OVER (ORDER BY s.theatrical_revenue_usd DESC NULLS LAST)           AS revenue_decile,   -- 1 = top 10%
        COALESCE(r.peak_active_theaters, 0)                                          AS peak_active_theaters,
        COALESCE(r.months_in_release, 0)                                             AS months_in_release,
        COALESCE(p.promotion_events, 0)                                              AS promotion_events
FROM    project_dw.dim_movie m
JOIN    sales s ON s.movie_key = m.movie_key
LEFT JOIN runs   r ON r.movie_key = m.movie_key
LEFT JOIN promos p ON p.movie_key = m.movie_key;

COMMENT ON VIEW project_reporting.vw_product_performance IS
    'Movie (product) performance: revenue by channel/region, opening weekend, ROI, ranks, deciles, theatre and promotion footprint.';


-- -------------------------------------------------------------------------------------
-- Quick usage examples
-- -------------------------------------------------------------------------------------
-- SELECT month, channel_group, revenue_usd, growth_pct FROM project_reporting.vw_monthly_sales
--  WHERE year = 2019 AND channel_group = 'Theatrical' ORDER BY month_start;
--
-- SELECT distributor_name, total_revenue_usd, revenue_share_pct, revenue_rank
--   FROM project_reporting.vw_customer_analysis ORDER BY revenue_rank LIMIT 10;
--
-- SELECT movie_title, genre, theatrical_revenue_usd, revenue_to_budget_ratio, theatrical_rank_in_genre
--   FROM project_reporting.vw_product_performance WHERE theatrical_rank_in_genre <= 3 ORDER BY genre, theatrical_rank_in_genre;
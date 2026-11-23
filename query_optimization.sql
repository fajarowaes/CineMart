-- =====================================================================================
-- 04_query_optimization.sql
-- CineMart Box Office Data Warehouse (PostgreSQL)  |  Query Optimization & Indexing
--
-- Purpose:
--   Demonstrates before-and-after query tuning on the star schema in project_dw
--   (aligned with 01_analytical_queries.sql, 02_olap_queries.sql, and 03_reporting_views.sql).
--
-- Existing indexes from 06_dw_schema.sql:
--   * PKs on all dimension/fact tables
--   * ix_fbos_movie (fact_box_office_sales.movie_key)
--   * ix_fbos_date  (fact_box_office_sales.date_key)
--   * Missing indexes on remaining fact FKs (distributor_key, territory_key, channel_key)
--     and frequently filtered dimension attributes (genre, distributor_name, year).
--
-- How to run in pgAdmin Query Tool (connected to CineMart):
--   1. Highlight and execute STEP 1 (Reset) + STEP 2 (Before EXPLAIN ANALYZE) -> screenshot Cost & Execution Time.
--   2. Highlight and execute STEP 3 (CREATE INDEX + ANALYZE).
--   3. Highlight and execute STEP 4 (After EXPLAIN ANALYZE) -> screenshot improved Cost & Execution Time.
-- =====================================================================================

SET search_path TO project_dw, public;


-- -------------------------------------------------------------------------------------
-- STEP 1: RESET (ensures a clean baseline if you re-run the benchmark)
-- -------------------------------------------------------------------------------------
DROP INDEX IF EXISTS project_dw.ix_fbos_distributor;
DROP INDEX IF EXISTS project_dw.ix_fbos_territory;
DROP INDEX IF EXISTS project_dw.ix_fbos_channel;
DROP INDEX IF EXISTS project_dw.ix_fbos_date_channel_rev;
DROP INDEX IF EXISTS project_dw.ix_dim_movie_genre;
DROP INDEX IF EXISTS project_dw.ix_dim_dist_name;
DROP INDEX IF EXISTS project_dw.ix_dim_dist_class;
DROP INDEX IF EXISTS project_dw.ix_dim_date_year_month;

ANALYZE project_dw.fact_box_office_sales;
ANALYZE project_dw.dim_movie;
ANALYZE project_dw.dim_distributor;
ANALYZE project_dw.dim_date;


-- -------------------------------------------------------------------------------------
-- STEP 2: BEFORE INDEXING  (Run EXPLAIN ANALYZE and record Query Cost & Execution Time)
-- -------------------------------------------------------------------------------------

-- Q1 (Before): Multi-dimension star-schema slice (Distributor x Genre x Channel x Territory)
-- Without indexes on distributor_key, channel_key, territory_key, or dim_movie.genre,
-- PostgreSQL performs full Sequential Scans across fact_box_office_sales and dim_movie.
EXPLAIN (ANALYZE, BUFFERS)
SELECT  di.distributor_name,
        di.distributor_class,
        t.territory_name,
        ch.channel_name,
        COALESCE(m.genre, 'Unknown') AS genre,
        COUNT(*)                     AS revenue_lines,
        SUM(f.revenue_usd)           AS total_revenue,
        ROUND(AVG(f.revenue_usd), 2) AS avg_revenue
FROM    fact_box_office_sales f
JOIN    dim_distributor     di ON di.distributor_key = f.distributor_key
JOIN    dim_territory       t  ON t.territory_key    = f.territory_key
JOIN    dim_release_channel ch ON ch.channel_key     = f.channel_key
JOIN    dim_movie           m  ON m.movie_key        = f.movie_key
WHERE   di.distributor_name = 'Warner Bros.'
  AND   m.genre             = 'Action'
  AND   ch.channel_group    = 'Theatrical'
  AND   t.territory_code    = 'DOM'
GROUP BY di.distributor_name, di.distributor_class, t.territory_name, ch.channel_name, m.genre;


-- Q2 (Before): Monthly revenue trend query (mirrors A1 in 01_analytical_queries.sql
-- and vw_monthly_sales in 03_reporting_views.sql)
EXPLAIN (ANALYZE, BUFFERS)
SELECT  d.year,
        d.month,
        COUNT(*)           AS revenue_lines,
        SUM(f.revenue_usd) AS monthly_revenue
FROM    fact_box_office_sales f
JOIN    dim_date            d  ON d.date_key    = f.date_key
JOIN    dim_release_channel ch ON ch.channel_key = f.channel_key
WHERE   ch.channel_group = 'Theatrical'
  AND   d.year BETWEEN 2015 AND 2019
GROUP BY d.year, d.month
ORDER BY d.year, d.month;


-- -------------------------------------------------------------------------------------
-- STEP 3: CREATE INDEXES & REFRESH OPTIMIZER STATISTICS
-- -------------------------------------------------------------------------------------

-- Foreign-key indexes missing from 06_dw_schema.sql
CREATE INDEX ix_fbos_distributor ON project_dw.fact_box_office_sales (distributor_key);
CREATE INDEX ix_fbos_territory   ON project_dw.fact_box_office_sales (territory_key);
CREATE INDEX ix_fbos_channel     ON project_dw.fact_box_office_sales (channel_key);

-- Covering index for time-series + channel aggregations (enables Index-Only Scans)
CREATE INDEX ix_fbos_date_channel_rev
    ON project_dw.fact_box_office_sales (date_key, channel_key)
    INCLUDE (revenue_usd);

-- Dimension filter indexes
CREATE INDEX ix_dim_movie_genre      ON project_dw.dim_movie (genre);
CREATE INDEX ix_dim_dist_name        ON project_dw.dim_distributor (distributor_name);
CREATE INDEX ix_dim_dist_class       ON project_dw.dim_distributor (distributor_class);
CREATE INDEX ix_dim_date_year_month  ON project_dw.dim_date (year, month) INCLUDE (date_key);

-- Refresh planner statistics so PostgreSQL immediately uses the new indexes
ANALYZE project_dw.fact_box_office_sales;
ANALYZE project_dw.dim_movie;
ANALYZE project_dw.dim_distributor;
ANALYZE project_dw.dim_date;


-- -------------------------------------------------------------------------------------
-- STEP 4: AFTER INDEXING  (Re-run EXPLAIN ANALYZE and compare Cost & Execution Time)
-- -------------------------------------------------------------------------------------

-- Q1 (After): Uses ix_dim_dist_name + ix_fbos_distributor + ix_dim_movie_genre
EXPLAIN (ANALYZE, BUFFERS)
SELECT  di.distributor_name,
        di.distributor_class,
        t.territory_name,
        ch.channel_name,
        COALESCE(m.genre, 'Unknown') AS genre,
        COUNT(*)                     AS revenue_lines,
        SUM(f.revenue_usd)           AS total_revenue,
        ROUND(AVG(f.revenue_usd), 2) AS avg_revenue
FROM    fact_box_office_sales f
JOIN    dim_distributor     di ON di.distributor_key = f.distributor_key
JOIN    dim_territory       t  ON t.territory_key    = f.territory_key
JOIN    dim_release_channel ch ON ch.channel_key     = f.channel_key
JOIN    dim_movie           m  ON m.movie_key        = f.movie_key
WHERE   di.distributor_name = 'Warner Bros.'
  AND   m.genre             = 'Action'
  AND   ch.channel_group    = 'Theatrical'
  AND   t.territory_code    = 'DOM'
GROUP BY di.distributor_name, di.distributor_class, t.territory_name, ch.channel_name, m.genre;


-- Q2 (After): Uses ix_dim_date_year_month + covering index ix_fbos_date_channel_rev
EXPLAIN (ANALYZE, BUFFERS)
SELECT  d.year,
        d.month,
        COUNT(*)           AS revenue_lines,
        SUM(f.revenue_usd) AS monthly_revenue
FROM    fact_box_office_sales f
JOIN    dim_date            d  ON d.date_key    = f.date_key
JOIN    dim_release_channel ch ON ch.channel_key = f.channel_key
WHERE   ch.channel_group = 'Theatrical'
  AND   d.year BETWEEN 2015 AND 2019
GROUP BY d.year, d.month
ORDER BY d.year, d.month;

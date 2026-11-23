-- 13_query_optimization.sql
-- Requirement 3: Query Optimization (EXPLAIN ANALYZE Before & After Creating Indexes)
-- Run Step 1, then Step 2, then Step 3 separately in pgAdmin Query Tool to capture Before/After metrics.

-- ============================================================================
-- STEP 1: BEFORE INDEXING - Run EXPLAIN ANALYZE and record Cost & Execution Time
-- ============================================================================
EXPLAIN ANALYZE
SELECT
    di.distributor_class,
    t.territory_name,
    c.channel_name,
    m.genre,
    COUNT(f.release_contract_id) AS releases,
    SUM(f.revenue_usd)           AS total_revenue
FROM project_dw.fact_box_office_sales f
JOIN project_dw.dim_distributor di    ON f.distributor_key = di.distributor_key
JOIN project_dw.dim_territory t       ON f.territory_key   = t.territory_key
JOIN project_dw.dim_release_channel c ON f.channel_key     = c.channel_key
JOIN project_dw.dim_movie m           ON f.movie_key       = m.movie_key
WHERE di.distributor_class = 'Major'
  AND m.genre = 'Action'
  AND t.territory_code = 'DOM'
GROUP BY di.distributor_class, t.territory_name, c.channel_name, m.genre;


-- ============================================================================
-- STEP 2: CREATE INDEXES & REFRESH TABLE STATISTICS
-- ============================================================================
CREATE INDEX IF NOT EXISTS ix_fbos_distributor ON project_dw.fact_box_office_sales (distributor_key);
CREATE INDEX IF NOT EXISTS ix_fbos_territory   ON project_dw.fact_box_office_sales (territory_key);
CREATE INDEX IF NOT EXISTS ix_fbos_channel     ON project_dw.fact_box_office_sales (channel_key);
CREATE INDEX IF NOT EXISTS ix_dim_movie_genre  ON project_dw.dim_movie (genre);
CREATE INDEX IF NOT EXISTS ix_dim_dist_class   ON project_dw.dim_distributor (distributor_class);

ANALYZE project_dw.fact_box_office_sales;
ANALYZE project_dw.dim_movie;
ANALYZE project_dw.dim_distributor;


-- ============================================================================
-- STEP 3: AFTER INDEXING - Re-run EXPLAIN ANALYZE and compare Cost & Execution Time
-- ============================================================================
EXPLAIN ANALYZE
SELECT
    di.distributor_class,
    t.territory_name,
    c.channel_name,
    m.genre,
    COUNT(f.release_contract_id) AS releases,
    SUM(f.revenue_usd)           AS total_revenue
FROM project_dw.fact_box_office_sales f
JOIN project_dw.dim_distributor di    ON f.distributor_key = di.distributor_key
JOIN project_dw.dim_territory t       ON f.territory_key   = t.territory_key
JOIN project_dw.dim_release_channel c ON f.channel_key     = c.channel_key
JOIN project_dw.dim_movie m           ON f.movie_key       = m.movie_key
WHERE di.distributor_class = 'Major'
  AND m.genre = 'Action'
  AND t.territory_code = 'DOM'
GROUP BY di.distributor_class, t.territory_name, c.channel_name, m.genre;

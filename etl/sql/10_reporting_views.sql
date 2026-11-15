-- 10_reporting_views.sql
-- Reporting layer: business-friendly views over the star schema (they answer the Phase 1 business questions).

-- Q1: monthly theatrical box office by release year
CREATE OR REPLACE VIEW project_reporting.vw_monthly_theatrical_revenue AS
SELECT d.year, d.month, d.month_name, SUM(f.revenue_usd) AS theatrical_revenue_usd, COUNT(DISTINCT f.movie_key) AS movies
FROM project_dw.fact_box_office_sales f
JOIN project_dw.dim_date d ON d.date_key = f.date_key
JOIN project_dw.dim_release_channel ch ON ch.channel_key = f.channel_key
WHERE ch.channel_group = 'Theatrical'
GROUP BY d.year, d.month, d.month_name;

-- Q2: worldwide theatrical revenue per movie (domestic + international theatrical lines), ranked
CREATE OR REPLACE VIEW project_reporting.vw_top_movies_worldwide AS
SELECT m.movie_title, m.release_date, m.genre, SUM(f.revenue_usd) AS worldwide_theatrical_usd,
       RANK() OVER (ORDER BY SUM(f.revenue_usd) DESC) AS revenue_rank
FROM project_dw.fact_box_office_sales f
JOIN project_dw.dim_movie m ON m.movie_key = f.movie_key
JOIN project_dw.dim_release_channel ch ON ch.channel_key = f.channel_key
WHERE ch.channel_group = 'Theatrical'
GROUP BY m.movie_key, m.movie_title, m.release_date, m.genre;

-- Q3: domestic vs international share of theatrical revenue by year (ratio of sums)
CREATE OR REPLACE VIEW project_reporting.vw_domestic_vs_international AS
SELECT d.year,
       SUM(f.revenue_usd) FILTER (WHERE t.territory_code = 'DOM')  AS domestic_usd,
       SUM(f.revenue_usd) FILTER (WHERE t.territory_code = 'INTL') AS international_usd,
       ROUND(100.0 * SUM(f.revenue_usd) FILTER (WHERE t.territory_code = 'DOM') / NULLIF(SUM(f.revenue_usd), 0), 1) AS domestic_share_pct
FROM project_dw.fact_box_office_sales f
JOIN project_dw.dim_date d ON d.date_key = f.date_key
JOIN project_dw.dim_territory t ON t.territory_key = f.territory_key
JOIN project_dw.dim_release_channel ch ON ch.channel_key = f.channel_key
WHERE ch.channel_group = 'Theatrical'
GROUP BY d.year;

-- Q4: domestic home video vs theatrical revenue by MPAA rating
CREATE OR REPLACE VIEW project_reporting.vw_home_video_vs_theatrical AS
SELECT COALESCE(m.mpaa_rating, 'Unknown') AS mpaa_rating, ch.channel_group, SUM(f.revenue_usd) AS revenue_usd
FROM project_dw.fact_box_office_sales f
JOIN project_dw.dim_movie m ON m.movie_key = f.movie_key
JOIN project_dw.dim_territory t ON t.territory_key = f.territory_key
JOIN project_dw.dim_release_channel ch ON ch.channel_key = f.channel_key
WHERE t.territory_code = 'DOM'
GROUP BY COALESCE(m.mpaa_rating, 'Unknown'), ch.channel_group;

-- Q5: worldwide theatrical revenue by genre and distributor
CREATE OR REPLACE VIEW project_reporting.vw_distributor_genre_revenue AS
SELECT COALESCE(m.genre, 'Unknown') AS genre, di.distributor_name, SUM(f.revenue_usd) AS worldwide_theatrical_usd,
       RANK() OVER (PARTITION BY COALESCE(m.genre, 'Unknown') ORDER BY SUM(f.revenue_usd) DESC) AS rank_in_genre
FROM project_dw.fact_box_office_sales f
JOIN project_dw.dim_movie m ON m.movie_key = f.movie_key
JOIN project_dw.dim_distributor di ON di.distributor_key = f.distributor_key
JOIN project_dw.dim_release_channel ch ON ch.channel_key = f.channel_key
WHERE ch.channel_group = 'Theatrical'
GROUP BY COALESCE(m.genre, 'Unknown'), di.distributor_name;

-- Q6: return on budget by franchise (revenue summed per movie first; each movie budget counted once)
CREATE OR REPLACE VIEW project_reporting.vw_franchise_roi AS
WITH per_movie AS (
    SELECT m.movie_key, m.franchise, m.production_budget_usd AS budget, SUM(f.revenue_usd) AS revenue
    FROM project_dw.fact_box_office_sales f
    JOIN project_dw.dim_movie m ON m.movie_key = f.movie_key
    JOIN project_dw.dim_release_channel ch ON ch.channel_key = f.channel_key
    WHERE ch.channel_group = 'Theatrical' AND m.franchise <> 'No Franchise' AND m.production_budget_usd IS NOT NULL
    GROUP BY m.movie_key, m.franchise, m.production_budget_usd
)
SELECT franchise, COUNT(*) AS movies, SUM(revenue) AS revenue_usd, SUM(budget) AS budget_usd,
       ROUND(SUM(revenue) / NULLIF(SUM(budget), 0), 2) AS revenue_to_budget_ratio
FROM per_movie GROUP BY franchise;

-- Q7: theaters and cumulative revenue at each month-end of a movie's run
CREATE OR REPLACE VIEW project_reporting.vw_theater_run_by_month AS
SELECT m.movie_title, d.full_date AS month_end, s.active_theater_count, s.period_revenue_usd, s.cumulative_revenue_usd
FROM project_dw.fact_theater_run_snapshot s
JOIN project_dw.dim_movie m ON m.movie_key = s.movie_key
JOIN project_dw.dim_date d ON d.date_key = s.date_key;

-- Q8: active theaters per distributor at each quarter end (semi-additive: sum across movies at ONE month-end only)
CREATE OR REPLACE VIEW project_reporting.vw_distributor_theaters_quarter_end AS
SELECT di.distributor_name, d.year, d.quarter, d.full_date AS quarter_end, SUM(s.active_theater_count) AS active_theaters
FROM project_dw.fact_theater_run_snapshot s
JOIN project_dw.dim_distributor di ON di.distributor_key = s.distributor_key
JOIN project_dw.dim_date d ON d.date_key = s.date_key
WHERE d.month IN (3, 6, 9, 12)
GROUP BY di.distributor_name, d.year, d.quarter, d.full_date;

-- Q9: movies with no festival or premiere coverage in the Domestic territory
CREATE OR REPLACE VIEW project_reporting.vw_movies_without_dom_festival_premiere AS
SELECT m.movie_title, m.release_date, m.release_pattern
FROM project_dw.dim_movie m
WHERE NOT EXISTS (
    SELECT 1 FROM project_dw.fact_promotion_coverage f
    JOIN project_dw.dim_promotion p ON p.promotion_key = f.promotion_key
    JOIN project_dw.dim_territory t ON t.territory_key = f.territory_key
    WHERE f.movie_key = m.movie_key AND t.territory_code = 'DOM'
      AND p.promotion_type IN ('Festival Screening', 'Premiere'));

-- Q10: promotion events by type, franchise and quarter (COUNT only, no measure)
CREATE OR REPLACE VIEW project_reporting.vw_promotion_events_by_franchise AS
SELECT p.promotion_type, m.franchise, d.year, d.quarter, COUNT(*) AS events, COUNT(DISTINCT f.movie_key) AS movies_covered
FROM project_dw.fact_promotion_coverage f
JOIN project_dw.dim_promotion p ON p.promotion_key = f.promotion_key
JOIN project_dw.dim_movie m ON m.movie_key = f.movie_key
JOIN project_dw.dim_date d ON d.date_key = f.date_key
GROUP BY p.promotion_type, m.franchise, d.year, d.quarter;

CREATE OR REPLACE VIEW project_reporting.vw_dq_latest AS
SELECT run_label, category, check_name, table_name, failed_rows, total_rows, severity, status
FROM project_staging.etl_dq_results
WHERE run_label = (SELECT MAX(run_label) FROM project_staging.etl_dq_results);

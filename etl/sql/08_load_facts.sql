-- 08_load_facts.sql
-- Fact loading = business key -> surrogate key mapping. Staging rows carry business keys (movie_id, distributor_id,
-- territory_code, channel_code, promotion_code, dates); each is looked up in its dimension and only the surrogate
-- keys are stored in the fact. Loads are upserts, so re-running never duplicates rows.

-- ---------- 1. fact_box_office_sales (transaction): CSV amounts are unpivoted into one row per revenue line ----------
INSERT INTO project_dw.fact_box_office_sales
  (release_contract_id, date_key, movie_key, distributor_key, territory_key, channel_key,
   revenue_usd, inflation_adj_revenue_usd, opening_weekend_revenue_usd)
SELECT 'CSV' || lpad(c.source_row::text, 6, '0') || '-' || l.terr || '-' || l.chan,
       d.date_key, m.movie_key, di.distributor_key, t.territory_key, ch.channel_key,
       l.revenue, l.infl_adj, l.opening
FROM project_staging.stg_csv_movie c
CROSS JOIN LATERAL (VALUES
    ('DOM',  'THEATRICAL', c.domestic_revenue_usd,      c.infl_adj_domestic_usd, c.opening_weekend_usd),
    ('INTL', 'THEATRICAL', c.international_revenue_usd, NULL::numeric,           NULL::numeric),
    ('DOM',  'DVD',        c.dvd_sales_usd,             NULL::numeric,           NULL::numeric),
    ('DOM',  'BLURAY',     c.bluray_sales_usd,          NULL::numeric,           NULL::numeric)
) AS l(terr, chan, revenue, infl_adj, opening)
JOIN project_dw.dim_movie           m  ON m.movie_id        = c.movie_id
JOIN project_dw.dim_date            d  ON d.full_date       = c.release_date
JOIN project_dw.dim_distributor     di ON di.distributor_id = c.distributor_id
JOIN project_dw.dim_territory       t  ON t.territory_code  = l.terr
JOIN project_dw.dim_release_channel ch ON ch.channel_code   = l.chan
WHERE l.revenue IS NOT NULL
ON CONFLICT (release_contract_id) DO UPDATE SET
    date_key = EXCLUDED.date_key, movie_key = EXCLUDED.movie_key, distributor_key = EXCLUDED.distributor_key,
    territory_key = EXCLUDED.territory_key, channel_key = EXCLUDED.channel_key, revenue_usd = EXCLUDED.revenue_usd,
    inflation_adj_revenue_usd = EXCLUDED.inflation_adj_revenue_usd,
    opening_weekend_revenue_usd = EXCLUDED.opening_weekend_revenue_usd;

-- ---------- 2. fact_theater_run_snapshot (periodic snapshot) ----------
INSERT INTO project_dw.fact_theater_run_snapshot
  (date_key, movie_key, territory_key, distributor_key, active_theater_count, period_revenue_usd, cumulative_revenue_usd)
SELECT d.date_key, m.movie_key, t.territory_key, di.distributor_key,
       s.active_theater_count, s.period_revenue_usd, s.cumulative_revenue_usd
FROM project_staging.stg_theater_run s
JOIN project_dw.dim_date        d  ON d.full_date       = s.snapshot_date
JOIN project_dw.dim_movie       m  ON m.movie_id        = s.movie_id
JOIN project_dw.dim_territory   t  ON t.territory_code  = s.territory_code
JOIN project_dw.dim_distributor di ON di.distributor_id = s.distributor_id
ON CONFLICT (date_key, movie_key, territory_key, distributor_key) DO UPDATE SET
    active_theater_count = EXCLUDED.active_theater_count, period_revenue_usd = EXCLUDED.period_revenue_usd,
    cumulative_revenue_usd = EXCLUDED.cumulative_revenue_usd;

-- ---------- 3. fact_promotion_coverage (factless: keys only) ----------
INSERT INTO project_dw.fact_promotion_coverage
  (event_id, date_key, movie_key, territory_key, distributor_key, promotion_key)
SELECT e.event_id, d.date_key, m.movie_key, t.territory_key, di.distributor_key, p.promotion_key
FROM project_staging.stg_promotion_event e
JOIN project_dw.dim_date        d  ON d.full_date       = e.event_date
JOIN project_dw.dim_movie       m  ON m.movie_id        = e.movie_id
JOIN project_dw.dim_territory   t  ON t.territory_code  = e.territory_code
JOIN project_dw.dim_distributor di ON di.distributor_id = e.distributor_id
JOIN project_dw.dim_promotion   p  ON p.promotion_code  = e.promotion_code
ON CONFLICT (event_id) DO UPDATE SET
    date_key = EXCLUDED.date_key, movie_key = EXCLUDED.movie_key, territory_key = EXCLUDED.territory_key,
    distributor_key = EXCLUDED.distributor_key, promotion_key = EXCLUDED.promotion_key;

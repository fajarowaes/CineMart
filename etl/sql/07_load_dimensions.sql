-- 07_load_dimensions.sql
-- Loads the six dimensions. Each row gets a surrogate key (..._key) and keeps its natural key.
-- Loads are upserts keyed on the natural key, so re-running never creates duplicates and keys never change.

-- ---------- dim_date: every calendar day 1895-01-01 .. 2030-12-31 ----------
INSERT INTO project_dw.dim_date (date_key, full_date, year, quarter, quarter_name, month, month_name,
                                 day_of_month, day_name, is_weekend)
SELECT to_char(d, 'YYYYMMDD')::int, d::date,
       EXTRACT(YEAR FROM d)::int, EXTRACT(QUARTER FROM d)::int, 'Q' || EXTRACT(QUARTER FROM d)::int,
       EXTRACT(MONTH FROM d)::int, btrim(to_char(d, 'Month')), EXTRACT(DAY FROM d)::int, btrim(to_char(d, 'Day')),
       EXTRACT(ISODOW FROM d) IN (6, 7)
FROM generate_series(DATE '1895-01-01', DATE '2030-12-31', INTERVAL '1 day') d
ON CONFLICT (full_date) DO NOTHING;

-- ---------- dim_territory / dim_release_channel (small fixed lists) ----------
INSERT INTO project_dw.dim_territory (territory_code, territory_name, territory_group) VALUES
 ('DOM',  'Domestic (US and Canada)', 'North America'),
 ('INTL', 'International',            'Rest of World')
ON CONFLICT (territory_code) DO NOTHING;

INSERT INTO project_dw.dim_release_channel (channel_code, channel_name, channel_group) VALUES
 ('THEATRICAL', 'Theatrical Box Office',   'Theatrical'),
 ('DVD',        'Domestic DVD Sales',      'Home Video'),
 ('BLURAY',     'Domestic Blu-ray Sales',  'Home Video')
ON CONFLICT (channel_code) DO NOTHING;

-- ---------- dim_promotion ----------
INSERT INTO project_dw.dim_promotion (promotion_code, promotion_name, promotion_type, campaign_phase)
SELECT promotion_code, promotion_name, promotion_type, campaign_phase
FROM project_staging.stg_promotion
ON CONFLICT (promotion_code) DO UPDATE SET
    promotion_name = EXCLUDED.promotion_name, promotion_type = EXCLUDED.promotion_type,
    campaign_phase = EXCLUDED.campaign_phase;

-- ---------- dim_distributor (Major = the big six studios and their main labels, by exact name; everything else Independent) ----------
INSERT INTO project_dw.dim_distributor (distributor_id, distributor_name, distributor_class)
SELECT distributor_id, MIN(distributor_name),
       CASE WHEN distributor_id = 'UNKNOWN' THEN NULL
            WHEN lower(MIN(distributor_name)) IN ('walt disney', 'buena vista', 'warner bros.', 'universal',
                 'paramount pictures', '20th century fox', '20th century studios', 'sony pictures',
                 'sony/tristar', 'columbia') THEN 'Major'
            ELSE 'Independent' END
FROM project_staging.stg_csv_movie
GROUP BY distributor_id
ON CONFLICT (distributor_id) DO UPDATE SET
    distributor_name = EXCLUDED.distributor_name, distributor_class = EXCLUDED.distributor_class;

-- ---------- dim_movie: CSV movie + TMDB gap-fill (runtime, country, language) + TMDB link ----------
INSERT INTO project_dw.dim_movie
  (movie_id, movie_title, release_date, mpaa_rating, running_time_min, creative_type, genre, franchise,
   production_method, source_type, primary_country, primary_language, production_budget_usd,
   release_pattern, release_status, tmdb_id)
SELECT c.movie_id, c.movie_title, c.release_date, c.mpaa_rating,
       COALESCE(c.running_time_min, t.running_time_min),
       c.creative_type, c.genre, c.franchise, c.production_method, c.source_type,
       COALESCE(c.primary_country,
                CASE WHEN t.primary_country = 'United States of America' THEN 'United States' ELSE t.primary_country END),
       COALESCE(c.primary_language, t.primary_language),
       COALESCE(c.production_budget_usd, t.production_budget_usd),
       c.release_pattern, c.release_status, m.tmdb_id
FROM project_staging.stg_csv_movie c
LEFT JOIN project_staging.stg_movie_tmdb_match m ON m.movie_id = c.movie_id
LEFT JOIN project_staging.stg_movie t ON t.tmdb_id = m.tmdb_id
ON CONFLICT (movie_id) DO UPDATE SET
    movie_title = EXCLUDED.movie_title, release_date = EXCLUDED.release_date, mpaa_rating = EXCLUDED.mpaa_rating,
    running_time_min = EXCLUDED.running_time_min, creative_type = EXCLUDED.creative_type, genre = EXCLUDED.genre,
    franchise = EXCLUDED.franchise, production_method = EXCLUDED.production_method,
    source_type = EXCLUDED.source_type, primary_country = EXCLUDED.primary_country,
    primary_language = EXCLUDED.primary_language, production_budget_usd = EXCLUDED.production_budget_usd,
    release_pattern = EXCLUDED.release_pattern, release_status = EXCLUDED.release_status, tmdb_id = EXCLUDED.tmdb_id;

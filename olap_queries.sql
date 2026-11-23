-- =====================================================================================
-- 02_olap_queries.sql
-- CineMart Box Office Data Warehouse (PostgreSQL)  |  OLAP Queries: ROLLUP, CUBE, GROUPING SETS
--
-- Terminology mapping (brief -> CineMart):
--   Region   -> dim_territory.territory_name   (Domestic / International)
--   Category -> dim_movie.genre
--   Product  -> dim_movie.movie_title
--   Channel  -> dim_release_channel.channel_name
--
-- How to read the output
--   * In a ROLLUP / CUBE result a NULL in a grouping column means "all values" (a subtotal).
--   * Genuine NULLs in the data (e.g. a movie with no genre) are replaced with 'Unknown'
--     BEFORE grouping, so they can never be confused with a subtotal NULL.
--   * GROUPING(col) returns 1 when col was rolled up in that row. It drives the
--     row_type label and the ORDER BY so totals print directly under their group.
--   * Run with:  psql -d CineMart -f 02_olap_queries.sql
-- =====================================================================================

SET search_path TO project_dw, public;


-- -------------------------------------------------------------------------------------
-- O1. ROLLUP  Region -> Category -> Product      (full hierarchy, one release year)
--     Returns four kinds of rows:
--        Product Revenue  : region + category + product
--        Category Total   : region + category      (product rolled up)
--        Region Total     : region                 (category and product rolled up)
--        Grand Total      : everything rolled up
--     Scope: theatrical revenue of films released in 2019 and the 3 biggest genres by revenue,
--     so the product level stays readable. Remove the two WHERE filters for the full warehouse.
-- -------------------------------------------------------------------------------------
WITH base AS (
    SELECT  t.territory_name                      AS region,
            COALESCE(m.genre, 'Unknown')          AS category,
            m.movie_title                         AS product,
            f.revenue_usd
    FROM    fact_box_office_sales f
    JOIN    dim_movie            m  ON m.movie_key     = f.movie_key
    JOIN    dim_territory        t  ON t.territory_key = f.territory_key
    JOIN    dim_release_channel  ch ON ch.channel_key  = f.channel_key
    WHERE   ch.channel_group = 'Theatrical'
      AND   m.release_date >= DATE '2019-01-01' AND m.release_date < DATE '2020-01-01'
      AND   COALESCE(m.genre, 'Unknown') IN ('Action', 'Adventure', 'Comedy')
)
SELECT  CASE
            WHEN GROUPING(region, category, product) = 7 THEN 'Grand Total'
            WHEN GROUPING(category, product)         = 3 THEN 'Region Total'
            WHEN GROUPING(product)                   = 1 THEN 'Category Total'
            ELSE                                              'Product Revenue'
        END                                         AS row_type,
        COALESCE(region,   'ALL REGIONS')           AS region,
        COALESCE(category, 'ALL CATEGORIES')        AS category,
        COALESCE(product,  'ALL PRODUCTS')          AS product,
        SUM(revenue_usd)                            AS revenue
FROM    base
GROUP BY ROLLUP (region, category, product)
-- totals sort after their detail rows: grouping flag 0 (detail) before 1 (subtotal)
ORDER BY GROUPING(region), region,
         GROUPING(category), category,
         GROUPING(product), SUM(revenue_usd) DESC;
-- (GROUPING(a,b,c) with several arguments returns a bitmask: 7 = all three columns rolled up,
--  3 = the last two rolled up, 1 = only the last one rolled up.)


-- -------------------------------------------------------------------------------------
-- O2. ROLLUP  Region -> Category   (compact, ALL years, ALL genres)
-- -------------------------------------------------------------------------------------
SELECT  CASE
            WHEN GROUPING(t.territory_name, m.genre) = 3 THEN 'Grand Total'
            WHEN GROUPING(m.genre)                   = 1 THEN 'Region Total'
            ELSE                                              'Category Revenue'
        END                                          AS row_type,
        COALESCE(t.territory_name, 'ALL REGIONS')    AS region,
        COALESCE(m.genre, 'ALL CATEGORIES')          AS category,
        COUNT(DISTINCT f.movie_key)                  AS movies,
        SUM(f.revenue_usd)                           AS revenue
FROM    fact_box_office_sales f
JOIN    (SELECT movie_key, COALESCE(genre, 'Unknown') AS genre FROM dim_movie) m
                                   ON m.movie_key     = f.movie_key
JOIN    dim_territory        t  ON t.territory_key = f.territory_key
JOIN    dim_release_channel  ch ON ch.channel_key  = f.channel_key
WHERE   ch.channel_group = 'Theatrical'
GROUP BY ROLLUP (t.territory_name, m.genre)
ORDER BY GROUPING(t.territory_name), t.territory_name,
         GROUPING(m.genre), SUM(f.revenue_usd) DESC;


-- -------------------------------------------------------------------------------------
-- O3. ROLLUP  Year -> Quarter -> Month   (time hierarchy)
--     Rows: month detail, quarter subtotal, year subtotal, grand total (2017-2019).
-- -------------------------------------------------------------------------------------
SELECT  CASE
            WHEN GROUPING(d.year, d.quarter, d.month) = 7 THEN 'Grand Total'
            WHEN GROUPING(d.quarter, d.month)         = 3 THEN 'Year Total'
            WHEN GROUPING(d.month)                    = 1 THEN 'Quarter Total'
            ELSE                                               'Month'
        END                                  AS row_type,
        COALESCE(d.year::text,    'ALL')     AS year,
        COALESCE('Q' || d.quarter, 'ALL')    AS quarter,
        COALESCE(to_char(make_date(d.year, d.month, 1), 'Mon'), 'ALL') AS month,
        SUM(f.revenue_usd)                   AS revenue
FROM    fact_box_office_sales f
JOIN    dim_date            d  ON d.date_key     = f.date_key
JOIN    dim_release_channel ch ON ch.channel_key = f.channel_key
WHERE   ch.channel_group = 'Theatrical'
  AND   d.year BETWEEN 2017 AND 2019
GROUP BY ROLLUP (d.year, d.quarter, d.month)
ORDER BY GROUPING(d.year), d.year,
         GROUPING(d.quarter), d.quarter,
         GROUPING(d.month), d.month;


-- -------------------------------------------------------------------------------------
-- O4. CUBE  Region x Channel
--     CUBE produces every combination of the two dimensions:
--        region + channel | region only | channel only | grand total
--     Region (Domestic/International) is crossed with release channel (Theatrical/DVD/Blu-ray).
--     Note: home-video exists for Domestic only, so International x DVD/Blu-ray has no row.
-- -------------------------------------------------------------------------------------
WITH cube_result AS (
    SELECT  CASE
                WHEN GROUPING(t.territory_name, ch.channel_name) = 3 THEN 'Grand Total'
                WHEN GROUPING(t.territory_name) = 1                  THEN 'Channel Total (all regions)'
                WHEN GROUPING(ch.channel_name)  = 1                  THEN 'Region Total (all channels)'
                ELSE                                                      'Region x Channel'
            END                                           AS row_type,
            GROUPING(t.territory_name, ch.channel_name)   AS grouping_id,
            COALESCE(t.territory_name, 'ALL REGIONS')     AS region,
            COALESCE(ch.channel_name,  'ALL CHANNELS')    AS channel,
            COUNT(*)                                      AS revenue_lines,
            SUM(f.revenue_usd)                            AS revenue
    FROM    fact_box_office_sales f
    JOIN    dim_territory       t  ON t.territory_key = f.territory_key
    JOIN    dim_release_channel ch ON ch.channel_key  = f.channel_key
    GROUP BY CUBE (t.territory_name, ch.channel_name)
)
SELECT  row_type, region, channel, revenue_lines, revenue,
        -- GROUPING() is not allowed inside FILTER, so the share is computed here in the outer query
        ROUND(100.0 * revenue
              / MAX(revenue) FILTER (WHERE row_type = 'Grand Total') OVER (), 2) AS pct_of_grand_total
FROM    cube_result
ORDER BY grouping_id, region, channel;


-- -------------------------------------------------------------------------------------
-- O5. CUBE  Region x Channel x Distributor class    (three-dimension cube, 2010-2019)
--     8 grouping combinations. Use the GROUPING() bitmask to filter to the slice you need.
-- -------------------------------------------------------------------------------------
SELECT  COALESCE(t.territory_name, 'ALL REGIONS')                AS region,
        COALESCE(ch.channel_group, 'ALL CHANNELS')               AS channel_group,
        COALESCE(di.distributor_class, CASE WHEN GROUPING(di.distributor_class) = 1
                                            THEN 'ALL CLASSES' ELSE 'Unclassified' END) AS distributor_class,
        GROUPING(t.territory_name, ch.channel_group, di.distributor_class)             AS grouping_id,
        SUM(f.revenue_usd)                                       AS revenue
FROM    fact_box_office_sales f
JOIN    dim_date            d  ON d.date_key         = f.date_key
JOIN    dim_territory       t  ON t.territory_key    = f.territory_key
JOIN    dim_release_channel ch ON ch.channel_key     = f.channel_key
JOIN    dim_distributor     di ON di.distributor_key = f.distributor_key
WHERE   d.year BETWEEN 2010 AND 2019
GROUP BY CUBE (t.territory_name, ch.channel_group, di.distributor_class)
ORDER BY grouping_id, region, channel_group, distributor_class;


-- -------------------------------------------------------------------------------------
-- O6. GROUPING SETS  (choose exactly the aggregation levels you want, no more)
--     Three reports in one scan: by genre, by distributor class, and the grand total.
-- -------------------------------------------------------------------------------------
SELECT  CASE
            WHEN GROUPING(m.genre, di.distributor_class) = 3 THEN 'Grand Total'
            WHEN GROUPING(di.distributor_class) = 1          THEN 'By Genre'
            ELSE                                                  'By Distributor Class'
        END                                          AS report,
        COALESCE(m.genre, CASE WHEN GROUPING(m.genre) = 1 THEN '-' ELSE 'Unknown' END)               AS genre,
        COALESCE(di.distributor_class, CASE WHEN GROUPING(di.distributor_class) = 1 THEN '-' ELSE 'Unclassified' END) AS distributor_class,
        COUNT(DISTINCT f.movie_key)                  AS movies,
        SUM(f.revenue_usd)                           AS revenue
FROM    fact_box_office_sales f
JOIN    dim_movie           m  ON m.movie_key         = f.movie_key
JOIN    dim_distributor     di ON di.distributor_key  = f.distributor_key
JOIN    dim_release_channel ch ON ch.channel_key      = f.channel_key
WHERE   ch.channel_group = 'Theatrical'
GROUP BY GROUPING SETS ( (m.genre), (di.distributor_class), () )
ORDER BY GROUPING(m.genre, di.distributor_class), SUM(f.revenue_usd) DESC;
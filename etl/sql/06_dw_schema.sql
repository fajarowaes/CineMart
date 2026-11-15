-- 06_dw_schema.sql
-- Physical star schema (PostgreSQL) from Phase 1: 6 conformed dimensions + 3 fact tables.
-- Every dimension has an integer surrogate key (..._key) and keeps its natural/business key (UNIQUE).
-- Phase 1 names -> tables:  DimDate=dim_date, DimMovie=dim_movie, DimDistributor=dim_distributor, DimTerritory=dim_territory,
--   DimReleaseChannel=dim_release_channel, DimPromotion=dim_promotion, FactBoxOfficeSales=fact_box_office_sales,
--   FactTheaterRunSnapshot=fact_theater_run_snapshot, FactPromotionCoverage=fact_promotion_coverage

CREATE TABLE IF NOT EXISTS project_dw.dim_date (
    date_key     INT PRIMARY KEY,                 -- surrogate key, smart yyyymmdd
    full_date    DATE        NOT NULL UNIQUE,     -- natural key
    year         INT         NOT NULL,
    quarter      INT         NOT NULL,
    quarter_name VARCHAR(10) NOT NULL,
    month        INT         NOT NULL,
    month_name   VARCHAR(12) NOT NULL,
    day_of_month INT         NOT NULL,
    day_name     VARCHAR(12) NOT NULL,
    is_weekend   BOOLEAN     NOT NULL
);

CREATE TABLE IF NOT EXISTS project_dw.dim_movie (
    movie_key             INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,   -- surrogate key
    movie_id              VARCHAR(300) NOT NULL UNIQUE,                   -- natural key: lower(title) | release date
    movie_title           VARCHAR(255) NOT NULL,
    release_date          DATE         NOT NULL,
    mpaa_rating           VARCHAR(10),
    running_time_min      INT,
    creative_type         VARCHAR(50),
    genre                 VARCHAR(50),
    franchise             VARCHAR(100) NOT NULL,
    production_method     VARCHAR(50),
    source_type           VARCHAR(50),
    primary_country       VARCHAR(60),
    primary_language      VARCHAR(60),
    production_budget_usd NUMERIC(14,2),
    release_pattern       VARCHAR(20),
    release_status        VARCHAR(20)  NOT NULL,
    tmdb_id               BIGINT                                          -- link to the TMDB record (NULL when no match)
);

CREATE TABLE IF NOT EXISTS project_dw.dim_distributor (
    distributor_key   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    distributor_id    VARCHAR(60)  NOT NULL UNIQUE,
    distributor_name  VARCHAR(150) NOT NULL,
    distributor_class VARCHAR(20)
);

CREATE TABLE IF NOT EXISTS project_dw.dim_territory (
    territory_key   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    territory_code  VARCHAR(10) NOT NULL UNIQUE,
    territory_name  VARCHAR(60) NOT NULL,
    territory_group VARCHAR(30) NOT NULL
);

CREATE TABLE IF NOT EXISTS project_dw.dim_release_channel (
    channel_key   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    channel_code  VARCHAR(10) NOT NULL UNIQUE,
    channel_name  VARCHAR(40) NOT NULL,
    channel_group VARCHAR(30) NOT NULL
);

CREATE TABLE IF NOT EXISTS project_dw.dim_promotion (
    promotion_key  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    promotion_code VARCHAR(30)  NOT NULL UNIQUE,
    promotion_name VARCHAR(150) NOT NULL,
    promotion_type VARCHAR(40)  NOT NULL,
    campaign_phase VARCHAR(30)
);

-- Transaction fact. Grain: one row = the revenue of one movie in one territory through one release channel,
-- as distributed by one distributor, dated on the movie release date.
CREATE TABLE IF NOT EXISTS project_dw.fact_box_office_sales (
    release_contract_id         VARCHAR(80) PRIMARY KEY,                     -- degenerate dimension
    date_key                    INT NOT NULL REFERENCES project_dw.dim_date(date_key),
    movie_key                   INT NOT NULL REFERENCES project_dw.dim_movie(movie_key),
    distributor_key             INT NOT NULL REFERENCES project_dw.dim_distributor(distributor_key),
    territory_key               INT NOT NULL REFERENCES project_dw.dim_territory(territory_key),
    channel_key                 INT NOT NULL REFERENCES project_dw.dim_release_channel(channel_key),
    revenue_usd                 NUMERIC(14,2) NOT NULL,                      -- additive
    inflation_adj_revenue_usd   NUMERIC(14,2),                               -- additive, Domestic Theatrical only
    opening_weekend_revenue_usd NUMERIC(14,2)                                -- additive, Domestic Theatrical only
);

-- Periodic snapshot fact. Grain: one row = the status of one movie's theatrical run in one territory,
-- handled by one distributor, at the end of one calendar month.
CREATE TABLE IF NOT EXISTS project_dw.fact_theater_run_snapshot (
    date_key               INT NOT NULL REFERENCES project_dw.dim_date(date_key),      -- month-end
    movie_key              INT NOT NULL REFERENCES project_dw.dim_movie(movie_key),
    territory_key          INT NOT NULL REFERENCES project_dw.dim_territory(territory_key),
    distributor_key        INT NOT NULL REFERENCES project_dw.dim_distributor(distributor_key),
    active_theater_count   INT NOT NULL,                                       -- semi-additive
    period_revenue_usd     NUMERIC(14,2) NOT NULL,                             -- additive
    cumulative_revenue_usd NUMERIC(14,2) NOT NULL,                             -- semi-additive
    PRIMARY KEY (date_key, movie_key, territory_key, distributor_key)
);

-- Factless fact. Grain: one row = one promotion event that covered one movie in one territory,
-- run by one distributor, on one calendar date. No numeric measure.
CREATE TABLE IF NOT EXISTS project_dw.fact_promotion_coverage (
    event_id        VARCHAR(40) PRIMARY KEY,                                   -- degenerate dimension
    date_key        INT NOT NULL REFERENCES project_dw.dim_date(date_key),
    movie_key       INT NOT NULL REFERENCES project_dw.dim_movie(movie_key),
    territory_key   INT NOT NULL REFERENCES project_dw.dim_territory(territory_key),
    distributor_key INT NOT NULL REFERENCES project_dw.dim_distributor(distributor_key),
    promotion_key   INT NOT NULL REFERENCES project_dw.dim_promotion(promotion_key)
);

-- Indexes on the foreign keys used most in reports
CREATE INDEX IF NOT EXISTS ix_fbos_movie   ON project_dw.fact_box_office_sales (movie_key);
CREATE INDEX IF NOT EXISTS ix_fbos_date    ON project_dw.fact_box_office_sales (date_key);
CREATE INDEX IF NOT EXISTS ix_ftrs_movie   ON project_dw.fact_theater_run_snapshot (movie_key);
CREATE INDEX IF NOT EXISTS ix_fpc_movie    ON project_dw.fact_promotion_coverage (movie_key);
CREATE INDEX IF NOT EXISTS ix_fpc_promo    ON project_dw.fact_promotion_coverage (promotion_key);

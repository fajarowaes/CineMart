"""
load_raw.py  |  Extract + Load step
1. load_tmdb(): reads the TMDB API JSON files (full_load + incremental) and loads each movie record, untouched,
   into project_staging.raw_movies.
2. load_csv():  reads the Kaggle file movies_dataset.csv and loads every row, untouched (all columns as text),
   into project_staging.raw_csv_movies.
No cleaning happens here - that is done by the SQL scripts.

Run on its own:   python load_raw.py
Or via the runner: python run_etl.py
"""
import os, json, glob, hashlib, getpass
from datetime import datetime
import psycopg2
from psycopg2.extras import execute_values

# Repo layout:  CineMart/etl/python/load_raw.py   and   CineMart/data_tmdb/{full_load,incremental_load}/*.json
ROOT     = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))      # CineMart/
RAW_DIR  = os.environ.get("RAW_DIR", os.path.join(ROOT, "data_tmdb"))
FULL_DIR = os.path.join(RAW_DIR, "full_load")
INC_DIR  = os.path.join(RAW_DIR, "incremental_load")
CSV_FILE = os.environ.get("CSV_FILE", os.path.join(ROOT, "data_csv", "movies_dataset.csv"))

CSV_COLUMNS = ["idx", "comparisons", "creative_type", "domestic_box_office", "domestic_releases", "domestic_share",
               "franchise", "genre", "infl_adj_dom_bo", "international_box_office", "international_releases",
               "keywords", "languages", "legs", "mpaa_rating", "opening_weekend", "production_budget",
               "production_companies", "production_countries", "production_method", "running_time", "source",
               "theater_counts", "video_release", "worldwide_box_office", "title", "est_blu_ray_sales",
               "total_est_video_sales", "est_dvd_sales"]          # same order as the columns in movies_dataset.csv


def get_conn():
    """Connection settings come from environment variables; the password is asked for if not set."""
    return psycopg2.connect(
        host=os.environ.get("PGHOST", "localhost"),
        port=int(os.environ.get("PGPORT", "5432")),
        dbname=os.environ.get("PGDATABASE", "CineMart"),     # must match the database name in pgAdmin exactly
        user=os.environ.get("PGUSER", "postgres"),
        password=os.environ.get("PGPASSWORD") or getpass.getpass("PostgreSQL password: "),
    )


def rec_hash(rec):
    return hashlib.md5(json.dumps(rec, sort_keys=True).encode("utf-8")).hexdigest()


def parse_ts(value):
    """ISO string -> datetime, or None if it cannot be parsed (never fail the whole load on one bad timestamp)."""
    if not value:
        return None
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None


def extract_rows(path, batch_id):
    """One JSON file -> list of tuples, one per movie record."""
    with open(path, encoding="utf-8") as f:
        doc = json.load(f)
    fname, pulled_at, rows = os.path.basename(path), parse_ts(doc.get("pulled_at")), []

    def add(collection, endpoint, results):
        for r in results or []:
            if isinstance(r, str):                       # results may be stored as JSON strings
                try:
                    r = json.loads(r)
                except ValueError:
                    continue
            rows.append((pulled_at, endpoint, collection, fname, json.dumps(r), rec_hash(r), batch_id))

    if "results" in doc:
        add("full_load", doc.get("source_endpoint"), doc["results"])
    if "trending_today" in doc:
        add("trending", doc["trending_today"].get("source_endpoint"), doc["trending_today"].get("results"))
    if "changed_movies" in doc:
        add("changed", doc["changed_movies"].get("source_endpoint"), doc["changed_movies"].get("results"))
    return rows


def load_tmdb(conn, batch_id):
    """Load all JSON files. Returns (files_read, rows_read, rows_inserted). Re-running is safe: duplicates are skipped."""
    files = sorted(glob.glob(os.path.join(FULL_DIR, "*.json")) + glob.glob(os.path.join(INC_DIR, "*.json")))
    if not files:
        raise FileNotFoundError(f"No .json files found in:\n  {FULL_DIR}\n  {INC_DIR}")

    total_read = 0
    with conn.cursor() as cur:
        cur.execute("SELECT count(*) FROM project_staging.raw_movies")
        before = cur.fetchone()[0]
        for path in files:                       # one file at a time keeps memory use low (the files are ~90 MB each)
            rows = extract_rows(path, batch_id)
            total_read += len(rows)
            execute_values(cur, """
                INSERT INTO project_staging.raw_movies
                  (pulled_at, source_endpoint, source_collection, source_file, raw_record, record_hash, batch_id)
                VALUES %s
                ON CONFLICT (source_file, record_hash) DO NOTHING
            """, rows, template="(%s, %s, %s, %s, %s::jsonb, %s, %s)", page_size=1000)
            print(f"   loaded {os.path.basename(path)}: {len(rows)} records")
        cur.execute("SELECT count(*) FROM project_staging.raw_movies")
        after = cur.fetchone()[0]
    return len(files), total_read, after - before


def load_csv(conn, batch_id):
    """Load movies_dataset.csv. Returns (rows_read, rows_inserted). Re-running is safe: rows already loaded are skipped."""
    if not os.path.isfile(CSV_FILE):
        raise FileNotFoundError(f"CSV file not found: {CSV_FILE}")
    cols = ", ".join(CSV_COLUMNS)
    with conn.cursor() as cur:
        # work table (same columns as the file) so the whole file can be loaded with one fast COPY
        cur.execute("CREATE TABLE IF NOT EXISTS project_staging.csv_load_tmp (src_row BIGSERIAL, "
                    + ", ".join(f"{c} TEXT" for c in CSV_COLUMNS) + ")")
        cur.execute("TRUNCATE project_staging.csv_load_tmp RESTART IDENTITY")
        with open(CSV_FILE, encoding="utf-8", newline="") as f:
            cur.copy_expert(f"COPY project_staging.csv_load_tmp ({cols}) FROM STDIN WITH (FORMAT csv, HEADER true)", f)
        cur.execute("SELECT count(*) FROM project_staging.csv_load_tmp")
        rows_read = cur.fetchone()[0]
        cur.execute("SELECT count(*) FROM project_staging.raw_csv_movies")
        before = cur.fetchone()[0]
        insert_cols = ", ".join(["source_row", "csv_idx"] + CSV_COLUMNS[1:] + ["batch_id"])
        select_cols = ", ".join(["src_row", "idx"] + CSV_COLUMNS[1:])
        cur.execute(f"""INSERT INTO project_staging.raw_csv_movies ({insert_cols})
                        SELECT {select_cols}, %s FROM project_staging.csv_load_tmp
                        ON CONFLICT (source_row) DO NOTHING""", (batch_id,))
        cur.execute("SELECT count(*) FROM project_staging.raw_csv_movies")
        after = cur.fetchone()[0]
        cur.execute("TRUNCATE project_staging.csv_load_tmp")
    return rows_read, after - before


if __name__ == "__main__":
    batch = datetime.now().strftime("%Y%m%d_%H%M%S")
    connection = get_conn()
    try:
        n_files, n_rows, n_new = load_tmdb(connection, batch)
        connection.commit()
        print(f"TMDB: read {n_rows} records from {n_files} files | newly inserted: {n_new} | batch={batch}")
        c_rows, c_new = load_csv(connection, batch)
        connection.commit()
        print(f"CSV:  read {c_rows} rows | newly inserted: {c_new}")
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()

"""
run_etl.py  |  Runs the whole pipeline in order and logs every step to project_staging.etl_audit_log.

    TMDB JSON + Kaggle CSV -> raw tables -> staging -> dim_* -> fact_* -> data quality -> reporting views

Usage:  python run_etl.py
Needs:  pip install psycopg2-binary      (set PGPASSWORD to avoid the password prompt)
"""
import os, sys, time
from datetime import datetime
from load_raw import get_conn, load_tmdb, load_csv

SQL_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "sql"))

# (layer label, kind, file or None)
STEPS = [
    ("Setup: schemas + control tables",      "sql",       "01_schemas_and_raw.sql"),
    ("Setup: staging functions + tables",    "sql",       "02_staging_functions_tables.sql"),
    ("Extract+Load: TMDB JSON -> raw",       "load_tmdb", None),
    ("Extract+Load: Kaggle CSV -> raw",      "load_csv",  None),
    ("Staging: stg_movie (TMDB)",            "sql",       "03_load_stg_tmdb_movie.sql"),
    ("Staging: stg_csv_movie + TMDB match",  "sql",       "04_load_stg_csv_movie.sql"),
    ("Staging: supplementary extracts",      "sql",       "05_seed_supplementary.sql"),
    ("Setup: DW star schema",                "sql",       "06_dw_schema.sql"),
    ("DW: dimensions",                       "sql",       "07_load_dimensions.sql"),
    ("DW: facts",                            "sql",       "08_load_facts.sql"),
    ("Data quality checks",                  "sql",       "09_data_quality.sql"),
    ("Reporting: views",                     "sql",       "10_reporting_views.sql"),
]


def write_log(conn, layer, batch_id, param, start, status, inserted=0, err="NONE"):
    """Log in its own transaction so a FAILED step is still recorded."""
    with conn.cursor() as cur:
        cur.execute("""
            INSERT INTO project_staging.etl_audit_log
              (layer_processed, load_type, batch_id, parameter_processed, execution_start_time,
               execution_end_time, status, rows_inserted, rows_updated, rows_quarantined, error_message)
            VALUES (%s, 'all', %s, %s, %s, %s, %s, %s, 0, 0, %s)
        """, (layer, batch_id, param, start, datetime.now(), status, inserted, str(err)[:2000]))
    conn.commit()


def table_exists(conn, qualified):
    with conn.cursor() as cur:
        cur.execute("SELECT to_regclass(%s) IS NOT NULL", (qualified,))
        return cur.fetchone()[0]


def main():
    batch_id = datetime.now().strftime("%Y%m%d_%H%M%S")
    conn = get_conn()
    print(f"ETL run {batch_id}\n" + "-" * 60)
    t0 = time.time()

    for layer, kind, filename in STEPS:
        start = datetime.now()
        try:
            if kind == "sql":
                with open(os.path.join(SQL_DIR, filename), encoding="utf-8") as f:
                    sql = f.read()
                with conn.cursor() as cur:
                    cur.execute(sql)
                    inserted = max(cur.rowcount, 0)       # rows affected by the last statement of the script
                conn.commit()
                param = filename
            elif kind == "load_tmdb":
                n_files, n_rows, inserted = load_tmdb(conn, batch_id)
                conn.commit()
                param = f"{n_files} files, {n_rows} records read"
            else:
                n_rows, inserted = load_csv(conn, batch_id)
                conn.commit()
                param = f"movies_dataset.csv, {n_rows} rows read"

            write_log(conn, layer, batch_id, param, start, "SUCCESS", inserted)
            print(f"[OK]     {layer:<38} rows={inserted}")

        except Exception as e:
            conn.rollback()
            if table_exists(conn, "project_staging.etl_audit_log"):
                write_log(conn, layer, batch_id, filename or "raw load", start, "FAILED", 0, e)
            print(f"[FAILED] {layer}\n         {e}")
            conn.close()
            sys.exit(1)

    # ---- summary of this run's data quality results ----
    with conn.cursor() as cur:
        cur.execute("""
            SELECT category, check_name, table_name, failed_rows, total_rows, status
            FROM project_reporting.vw_dq_latest ORDER BY category, table_name, check_name
        """)
        results = cur.fetchall()
        counts = {}
        for t in ["project_staging.raw_csv_movies", "project_staging.stg_csv_movie", "project_staging.stg_movie",
                  "project_dw.dim_date", "project_dw.dim_movie", "project_dw.dim_distributor", "project_dw.dim_territory",
                  "project_dw.dim_release_channel", "project_dw.dim_promotion", "project_dw.fact_box_office_sales",
                  "project_dw.fact_theater_run_snapshot", "project_dw.fact_promotion_coverage", "project_staging.etl_quarantine"]:
            cur.execute(f"SELECT count(*) FROM {t}")
            counts[t.split(".")[1]] = cur.fetchone()[0]
    conn.close()

    print("\nData quality results\n" + "-" * 60)
    failed = 0
    for category, name, table, bad, total, status in results:
        failed += status == "FAIL"
        print(f"{status:<5} {category:<14} {table + ': ' + name:<75} {bad}/{total}")

    print("\nRow counts\n" + "-" * 60)
    for name, n in counts.items():
        print(f"{name:<28} {n:>10,}")
    print(f"\nDone in {time.time() - t0:.1f}s | data quality failures: {failed}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()

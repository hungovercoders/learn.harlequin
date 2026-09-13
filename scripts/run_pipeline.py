from pathlib import Path
import duckdb

# Ensure output directories exist before DuckDB writes files.
Path("data/clean").mkdir(parents=True, exist_ok=True)
Path("data/summary").mkdir(parents=True, exist_ok=True)

with duckdb.connect(":memory:") as con:
    for file in [
        "sql/pipeline/01_clean_events.sql",
        "sql/pipeline/02_daily_summary.sql",
    ]:
        con.execute(Path(file).read_text())

print("Pipeline complete")

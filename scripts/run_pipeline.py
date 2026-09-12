from pathlib import Path
import duckdb

DB_PATH = "analytics.duckdb"

con = duckdb.connect(DB_PATH)

for folder in [
    Path("data/clean"),
    Path("data/summary"),
]:
    folder.mkdir(parents=True, exist_ok=True)

steps = [
    "sql/pipeline/01_clean_events.sql",
    "sql/pipeline/02_daily_summary.sql",
]

for sql_file in steps:
    print(f"Running {sql_file}")
    sql = Path(sql_file).read_text()
    con.execute(sql)

print("Running quality checks")
quality_sql = Path("sql/pipeline/03_quality_checks.sql").read_text()

# Each quality statement can also be split into separate files if desired.
for statement in quality_sql.split(";"):
    statement = statement.strip()
    if statement:
        result = con.execute(statement).fetchdf()
        print(result)

con.close()
print("Pipeline complete.")

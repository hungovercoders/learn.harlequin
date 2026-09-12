-- Check for duplicate event IDs
SELECT
    event_id,
    COUNT(*) AS copies
FROM read_parquet('data/clean/events_clean.parquet')
GROUP BY event_id
HAVING COUNT(*) > 1;

-- Check for impossible negative revenue
SELECT *
FROM read_parquet('data/clean/events_clean.parquet')
WHERE revenue < 0;

-- Summary row count
SELECT COUNT(*) AS summary_rows
FROM read_parquet('data/summary/daily_event_summary.parquet');
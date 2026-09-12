COPY (
    SELECT
        event_id,
        CAST(event_timestamp AS TIMESTAMP) AS event_timestamp,
        CAST(event_timestamp AS DATE) AS event_date,
        customer_id,
        session_id,
        event_type,
        LOWER(device) AS device,
        UPPER(country) AS country,
        CAST(revenue AS DOUBLE) AS revenue
    FROM read_parquet('data/raw/events/*.parquet')
    WHERE event_id IS NOT NULL
      AND customer_id IS NOT NULL
      AND event_timestamp IS NOT NULL
)
TO 'data/clean/events_clean.parquet'
(FORMAT PARQUET);
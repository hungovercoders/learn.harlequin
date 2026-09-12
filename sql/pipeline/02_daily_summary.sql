COPY (
    SELECT
        event_date,
        event_type,
        device,
        country,

        COUNT(*) AS event_count,
        COUNT(DISTINCT customer_id) AS unique_customers,
        COUNT(DISTINCT session_id) AS unique_sessions,

        SUM(CASE WHEN event_type = 'purchase' THEN 1 ELSE 0 END)
            AS purchase_count,

        SUM(revenue) AS revenue,

        CASE
            WHEN COUNT(DISTINCT session_id) = 0 THEN 0
            ELSE COUNT(*) * 1.0 / COUNT(DISTINCT session_id)
        END AS events_per_session

    FROM read_parquet('data/clean/events_clean.parquet')

    GROUP BY
        event_date,
        event_type,
        device,
        country

    ORDER BY
        event_date,
        event_type
)
TO 'data/summary/daily_event_summary.parquet'
(FORMAT PARQUET);
COPY (
  select
    event_date, event_type, beer, device, country,
    count(*) as event_count,
    count(distinct customer_id) as unique_customers,
    count(distinct session_id) as unique_sessions,
    sum(revenue) as revenue
  from read_parquet('data/clean/events.parquet')
  group by 1,2,3,4,5
)
TO 'data/summary/daily_events.parquet' (FORMAT PARQUET);
COPY (
  select
    event_id,
    cast(event_timestamp as timestamp) as event_timestamp,
    cast(event_timestamp as date) as event_date,
    customer_id, session_id,
    lower(event_type) as event_type,
    lower(device) as device,
    upper(country) as country,
    cast(revenue as double) as revenue
  from read_parquet('data/raw/events/*.parquet')
  where event_id is not null and customer_id is not null
)
TO 'data/clean/events.parquet' (FORMAT PARQUET);
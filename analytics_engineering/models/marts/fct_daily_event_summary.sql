{{ config(materialized='view') }}

select
  event_date, event_type, device, country,
  count(*) as event_count,
  count(distinct customer_id) as unique_customers,
  count(distinct session_id) as unique_sessions,
  sum(revenue) as revenue
from {{ ref('stg_events') }}
group by 1,2,3,4
{{
  config(
    materialized='external',
    format='parquet',
    location=env_var('SUMMARY_LOCATION', '../data/daily_event_summary.parquet')
  )
}}

select *
from {{ ref('fct_daily_event_summary') }}

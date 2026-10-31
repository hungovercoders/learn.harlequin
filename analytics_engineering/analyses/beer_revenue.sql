select beer, sum(event_count) as purchases, round(sum(revenue),2) as revenue
from {{ ref('fct_daily_event_summary') }}
where event_type = 'purchase'
group by beer
order by revenue desc

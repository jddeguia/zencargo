-- models/mart/shipments/mart_fct_lane_performance.sql

-- Q2: Average lead time per mode of transport per trade lane.

select
    trade_lane,
    mode_of_transport,

    count(*)                                        as shipments,
    round(avg(actual_lead_time_days), 2)            as avg_actual_lead_time_days,
    round(avg(estimated_lead_time_days), 2)         as avg_estimated_lead_time_days,
    round(avg(lead_time_deviation_days), 2)         as avg_delay_days,

    sum(case when lead_time_deviation_days > 0 then 1 else 0 end)
        * 1.0 / count(*)                            as delay_rate

from {{ ref('mart_fct_shipments') }}
where trade_lane is not null
  and actual_lead_time_days is not null
  and actual_lead_time_days >= 0

group by all
order by trade_lane, mode_of_transport
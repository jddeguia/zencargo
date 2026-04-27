select
    trade_lane,
    mode_of_transport,

    count(*) as shipments,

    avg(actual_lead_time_days) as avg_actual_lead_time_days,
    avg(estimated_lead_time_days) as avg_estimated_lead_time_days,

    avg(lead_time_deviation_days) as avg_delay_days,

    sum(case when lead_time_deviation_days > 0 then 1 else 0 end)
        * 1.0 / count(*) as delay_rate

from {{ ref('mart_fct_shipments') }}

group by all
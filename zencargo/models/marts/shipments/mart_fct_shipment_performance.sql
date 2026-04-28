-- models/mart/shipments/mart_fct_shipment_performance.sql

-- Q3: Shipments where estimated collection→delivery lead time
--     differs from actual collection→delivery lead time.

select
    cargo_id,
    trade_lane,
    mode_of_transport,
    stage,

    estimated_collection_at,
    actual_collection_at,
    estimated_delivery_at,
    actual_delivery_at,

    actual_lead_time_days,
    estimated_lead_time_days,
    lead_time_deviation_days,

    case
        when lead_time_deviation_days > 0 then 'slower_than_estimated'
        when lead_time_deviation_days < 0 then 'faster_than_estimated'
        else 'on_time'
    end as performance_bucket,

    case
        when actual_lead_time_days <= estimated_lead_time_days then true
        else false
    end as is_on_time

from {{ ref('mart_fct_shipments') }}
where actual_lead_time_days is not null
  and actual_lead_time_days >= 0
  and lead_time_deviation_days is not null
  and abs(lead_time_deviation_days) > 0

order by abs(lead_time_deviation_days) desc
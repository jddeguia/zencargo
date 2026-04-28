-- models/mart/shipments/mart_fct_active_shipments.sql

-- Q1: How many active (non-delivered) shipments are currently in pipeline?

-- We take the latest stage per cargo_id (by requested_at) before filtering,
-- so a cargo that progressed from "booking requested" to "collected" is only
-- counted once at its latest stage.

with latest_stage_per_cargo as (

    select
        cargo_id,
        mode_of_transport,
        trade_lane,
        stage,
        is_delivered,
        requested_at,
        actual_collection_at,
        actual_delivery_at,

        row_number() over (
            partition by cargo_id
            order by requested_at desc nulls last
        ) as rn

    from {{ ref('mart_fct_shipments') }}

),

latest_only as (

    select * from latest_stage_per_cargo where rn = 1

)

select
    cargo_id,
    mode_of_transport,
    trade_lane,
    stage,
    requested_at,
    actual_collection_at,

    case
        when actual_collection_at is null then 'not_yet_collected'
        else 'in_transit'
    end as shipment_status

from latest_only
where is_delivered = false
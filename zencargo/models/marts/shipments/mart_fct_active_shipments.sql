select
    cargo_id,
    mode_of_transport,
    trade_lane,
    requested_at,

    actual_collection_at,
    actual_delivery_at,

    case
        when actual_delivery_at is null then 'active'
        when actual_collection_at is null then 'not_collected'
        else 'delivered'
    end as shipment_status

from {{ ref('mart_fct_shipments') }}
where actual_delivery_at is null
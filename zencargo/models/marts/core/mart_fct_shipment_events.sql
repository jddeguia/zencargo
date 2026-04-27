select
    cargo_id,
    'collection' as event_type,
    actual_collection_at as event_timestamp
from {{ ref('stg_shipments') }}
where actual_collection_at is not null

union all

select
    cargo_id,
    'delivery' as event_type,
    actual_delivery_at as event_timestamp
from {{ ref('stg_shipments') }}
where actual_delivery_at is not null
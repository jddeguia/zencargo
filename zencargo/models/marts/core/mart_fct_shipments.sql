-- models/marts/core/fct_shipments.sql

-- Fact table: one row per cargo_id + stage combination (a shipment can
-- appear with multiple stages in the source data representing lifecycle events).
-- Adds computed lead-time columns used by all three analytical queries.

with base as (

    select * from {{ ref('stg_shipments') }}

),

final as (

    select
        cargo_id,
        collection_location_id,
        delivered_location_id,

        mode_of_transport,
        stage_clean as stage,
        trade_lane,
        is_delivered,

        requested_at,
        estimated_collection_at,
        actual_collection_at,
        estimated_delivery_at,
        actual_delivery_at,

        revenue_date,
        vat_applicable,
        invoice_uploaded_at,

        -- Actual lead time
        case
            when actual_collection_at is not null
             and actual_delivery_at is not null
            then date_diff('day', actual_collection_at, actual_delivery_at)
        end as actual_lead_time_days,

        -- Estimated lead time
        case
            when estimated_collection_at is not null
             and estimated_delivery_at is not null
            then date_diff('day', estimated_collection_at, estimated_delivery_at)
        end as estimated_lead_time_days,

        -- Variance
        case
            when actual_collection_at is not null
             and actual_delivery_at is not null
             and estimated_collection_at is not null
             and estimated_delivery_at is not null
            then
                date_diff('day', actual_collection_at, actual_delivery_at)
              - date_diff('day', estimated_collection_at, estimated_delivery_at)
        end as lead_time_deviation_days

    from base

)

select * from final
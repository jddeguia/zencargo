-- models/staging/stg_shipments.sql

with source as (

    select * from {{ ref('raw_shipments_final') }}

),

cleaned as (

    select
        cargo_id,
        mode_of_transport,
        lower(trim(stage)) as stage_clean,

        try_cast(requested_timestamp as timestamp) as requested_at,

        collection_location_id,
        collection_location_street,
        collection_location_city,
        collection_location_country_code,

        try_cast(collected_latest_estimate_start_datetime_local as timestamp) as estimated_collection_at,
        try_cast(collected_occurred_at_local as timestamp) as actual_collection_at,

        delivered_location_id,
        delivered_location_street,
        delivered_location_city,
        delivered_location_country_code,

        try_cast(delivered_latest_estimate_timestamp as timestamp) as estimated_delivery_at,
        try_cast(delivered_occurred_at as timestamp) as actual_delivery_at,

        try_cast(revenue_date as date) as revenue_date,
        cast(vat_applicable as boolean) as vat_applicable,
        try_cast(invoice_uploaded_at as timestamp) as invoice_uploaded_at,

        case
            when collection_location_country_code is null
              or delivered_location_country_code is null
            then null
            else upper(collection_location_country_code)
                 || ' → '
                 || upper(delivered_location_country_code)
        end as trade_lane,

        case
            when lower(trim(stage)) like '%delivered%' then true
            else false
        end as is_delivered

    from source

)

select * from cleaned
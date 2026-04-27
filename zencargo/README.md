# Zencargo dbt Data Model — Assessment Solution

---

## 1. Data Model Design

### Observations from the source data

| Finding | Impact |
|---|---|
| `cargo_id` is **not unique** per row — same cargo appears with multiple stage values | Fact table rows = cargo × stage event |
| `stage` values are inconsistently cased (`l) Delivered`, `L) DELIVERED`, `l) delivered`) | Must normalise to lowercase before filtering |
| Several `collected_occurred_at_local` values have year **2035** — clearly data-entry errors | Nullify timestamps where year > 2030 |
| Some rows have `#ERROR!` as `cargo_id` — Excel formula leak in export | Exclude or treat as unknown cargo |
| `collection_location_id` and `deliveredLocationId` reference the same location pool | One shared `dim_locations` table |
| Modes observed: **Road, Air, Ocean, Rail** | Standard enum, worth a dbt `accepted_values` test |

---

### Entity-Relationship Overview

```
┌──────────────────────┐         ┌──────────────────────────────────┐
│   dim_locations      │         │        fct_shipments              │
│──────────────────────│         │──────────────────────────────────│
│ location_id (PK)     │◄────────│ collection_location_id (FK)       │
│ street               │         │ delivered_location_id  (FK)       │
│ city                 │◄────────│                                   │
│ country_code         │         │ cargo_id                          │
└──────────────────────┘         │ mode_of_transport                 │
                                 │ stage                             │
                                 │ is_delivered                      │
                                 │ trade_lane                        │
                                 │                                   │
                                 │ requested_at                      │
                                 │ estimated_collection_at           │
                                 │ actual_collection_at              │
                                 │ estimated_delivery_at             │
                                 │ actual_delivery_at                │
                                 │                                   │
                                 │ estimated_lead_time_days          │
                                 │ actual_lead_time_days             │
                                 │ lead_time_deviation_days          │
                                 │                                   │
                                 │ revenue_date                      │
                                 │ vat_applicable                    │
                                 │ invoice_uploaded_at               │
                                 └──────────────────────────────────┘
```

---

### Tables

#### `raw_shipments` (seed / source)
The flat file loaded as-is from the data source. All columns remain in their
original form. This is the single source of truth that all models derive from.

#### `stg_shipments` (staging view)
Cleans and standardises `raw_shipments`:
- Casts strings to proper `TIMESTAMP` / `DATE` types
- Normalises `stage` to lowercase
- Nullifies corrupt timestamps (year > 2030)
- Derives `trade_lane` (`"GB → PL"`) and boolean `is_delivered`

#### `dim_locations` (mart table)
Deduplicated lookup of every location referenced across collection and delivery
sides. Used for enriching reports or joining geographic reference data.

| Column | Type | Notes |
|---|---|---|
| `location_id` | VARCHAR | UUID, primary key |
| `street` | VARCHAR | |
| `city` | VARCHAR | |
| `country_code` | VARCHAR | ISO 2-letter code |

#### `fct_shipments` (mart table)
Central fact table. Adds three computed lead-time columns:

| Column | Type | Notes |
|---|---|---|
| `estimated_lead_time_days` | DECIMAL | `estimated_delivery_at − estimated_collection_at` |
| `actual_lead_time_days` | DECIMAL | `actual_delivery_at − actual_collection_at` |
| `lead_time_deviation_days` | DECIMAL | `actual − estimated`; positive = ran over |

---

## 2. dbt Project Structure

```
zencargo/
├── dbt_project.yml
├── profiles.yml
├── seeds/
│   └── raw_shipments.csv          ← source data loaded via dbt seed
└── models/
    ├── schema.yml                  ← docs + tests for all models
    ├── staging/
    │   └── stg_shipments.sql       ← cleaning + casting layer
    └── marts/
        ├── dim_locations.sql       ← location dimension
        ├── fct_shipments.sql       ← enriched fact table
        ├── q1_active_shipments_in_pipeline.sql
        ├── q2_avg_lead_time_by_mode_and_trade_lane.sql
        └── q3_lead_time_variance_shipments.sql
```

Run order (dbt resolves this via `ref()`):

```
raw_shipments (seed)
    └── stg_shipments
            ├── dim_locations
            ├── fct_shipments
            │       ├── q1_active_shipments_in_pipeline
            │       ├── q2_avg_lead_time_by_mode_and_trade_lane
            │       └── q3_lead_time_variance_shipments
```

To run the full project:
```bash
dbt seed          # loads raw_shipments.csv
dbt run           # builds all models
dbt test          # runs schema tests
```

---

## 3. Analytical Queries

### Q1 — Active (non-delivered) shipments in pipeline

```sql
-- models/marts/q1_active_shipments_in_pipeline.sql

with latest_stage_per_cargo as (
    select
        cargo_id,
        stage,
        is_delivered,
        mode_of_transport,
        trade_lane,
        requested_at,
        row_number() over (
            partition by cargo_id
            order by requested_at desc nulls last
        ) as rn
    from fct_shipments
),
latest_only as (
    select * from latest_stage_per_cargo where rn = 1
)
select
    count(*)                     as active_shipment_count,
    count(distinct trade_lane)   as unique_trade_lanes,
    count(distinct mode_of_transport) as unique_modes
from latest_only
where is_delivered = false
```

**Why we deduplicate:** The same `cargo_id` appears multiple times with
different `stage` values (e.g. first `a) Booking requested`, later
`e) Collected`). We take the *latest* stage per cargo to determine its
current status, then count those whose latest stage is not delivered.

---

### Q2 — Average lead time per mode of transport per trade lane

```sql
-- models/marts/q2_avg_lead_time_by_mode_and_trade_lane.sql

select
    mode_of_transport,
    trade_lane,
    count(*)                                 as shipment_count,
    round(avg(actual_lead_time_days), 2)     as avg_actual_lead_time_days,
    round(min(actual_lead_time_days), 2)     as min_actual_lead_time_days,
    round(max(actual_lead_time_days), 2)     as max_actual_lead_time_days,
    round(avg(estimated_lead_time_days), 2)  as avg_estimated_lead_time_days
from fct_shipments
where actual_lead_time_days is not null
  and actual_lead_time_days >= 0
group by 1, 2
order by mode_of_transport, avg_actual_lead_time_days desc
```

**Notes:**
- Lead time = `actual_delivery_at − actual_collection_at` in days
- Rows with missing timestamps or negative lead times (data anomalies) are excluded
- `trade_lane` is derived as `collection_country_code → delivered_country_code`

---

### Q3 — Shipments where estimated ≠ actual collection-to-delivery lead time

```sql
-- models/marts/q3_lead_time_variance_shipments.sql

select
    cargo_id,
    mode_of_transport,
    stage,
    trade_lane,
    estimated_collection_at,
    actual_collection_at,
    estimated_delivery_at,
    actual_delivery_at,
    round(estimated_lead_time_days, 2) as estimated_lead_time_days,
    round(actual_lead_time_days, 2)    as actual_lead_time_days,
    round(lead_time_deviation_days, 2) as lead_time_deviation_days,
    case
        when lead_time_deviation_days > 0 then 'slower_than_estimated'
        when lead_time_deviation_days < 0 then 'faster_than_estimated'
        else 'on_time'
    end                                as performance_flag
from fct_shipments
where lead_time_deviation_days is not null
  and abs(lead_time_deviation_days) > 0.01    -- 0.01 day ≈ 15 min tolerance
order by abs(lead_time_deviation_days) desc
```

**How deviation is calculated:**

```
lead_time_deviation_days =
    (actual_delivery_at   − actual_collection_at)
  − (estimated_delivery_at − estimated_collection_at)
```

A **positive** value means the shipment took longer than planned.
A **negative** value means it arrived faster than the estimate.

---

## 4. Key Data Quality Notes

| Issue | How it is handled |
|---|---|
| `collected_occurred_at_local` values with year 2035 | Nullified in `stg_shipments` via `CASE WHEN year > 2030 THEN NULL` |
| `cargo_id = '#ERROR!'` | These rows pass through but produce null lead times; excluded from aggregates naturally |
| Mixed case stage values | `lower(trim(stage))` in `stg_shipments`; `is_delivered` checks `LIKE '%delivered%'` |
| Shipments with no `actual_collection_at` (e.g. "Booking requested") | Lead time columns will be NULL; excluded from Q2/Q3 aggregates |
| Duplicate cargo_ids across stages | Q1 uses `ROW_NUMBER()` to evaluate latest stage only |
# dbt Lineage — Zencargo Shipments

A reference for the shipments data pipeline: sources, transformations, and marts.

---

## Lineage overview

```
raw_shipments_final  (seed / source)
        │
        ▼
  stg_shipments        staging layer — cleans types, derives trade_lane & is_delivered
        │
        ├──────────────────────────────────────┐
        ▼                                      ▼
 mart_fct_shipments                 mart_fct_shipment_events
 (core fact table)                  (unpivoted event timeline)
        │
        ├────────────────────┬───────────────────────────────┐
        ▼                    ▼                               ▼
mart_fct_active_shipments  mart_fct_lane_performance  mart_fct_shipment_performance
(Q1: pipeline count)       (Q2: lead time by lane)    (Q3: estimation accuracy)
```

---

## Models

### `stg_shipments`

**Path:** `models/staging/stg_shipments.sql`  
**Materialization:** view  
**Source:** `raw_shipments_final`

Entry point for all downstream models. Applies type coercions and derives two computed columns.

| Output column | Source column | Notes |
|---|---|---|
| `cargo_id` | `cargo_id` | Unchanged |
| `mode_of_transport` | `mode_of_transport` | Unchanged |
| `stage_clean` | `stage` | `lower(trim(...))` |
| `requested_at` | `requested_timestamp` | Cast to varchar → strip ` UTC` suffix → `try_cast` as timestamp |
| `collection_location_*` | Various | Passed through unchanged |
| `estimated_collection_at` | `collected_latest_estimate_start_datetime_local` | UTC strip + timestamp cast |
| `actual_collection_at` | `collected_occurred_at_local` | UTC strip + timestamp cast; **nullified if year > 2030** (corrupt data guard) |
| `delivered_location_*` | Various | Passed through unchanged |
| `estimated_delivery_at` | `delivered_latest_estimate_timestamp` | UTC strip + timestamp cast |
| `actual_delivery_at` | `delivered_occurred_at` | UTC strip + timestamp cast |
| `revenue_date` | `revenue_date` | `try_cast` as date |
| `vat_applicable` | `vat_applicable` | Cast to boolean |
| `invoice_uploaded_at` | `invoice_uploaded_at` | UTC strip + timestamp cast |
| `trade_lane` | Derived | `UPPER(collection_country) \|\| ' → ' \|\| UPPER(delivered_country)` — null when either code is missing |
| `is_delivered` | Derived | `true` when `stage_clean` contains `'delivered'` |

**Key data quality decisions:**
- All timestamp columns use `cast(... as varchar)` before `regexp_replace` because DuckDB may infer `TIMESTAMP` from the source, causing `regexp_replace` to fail on non-varchar input.
- `actual_collection_at` records with year > 2030 are set to `null` to suppress known corrupt timestamps (e.g. year 2035).

---

### `mart_fct_shipments`

**Path:** `models/marts/core/fct_shipments.sql`  
**Materialization:** table (recommended)  
**Depends on:** `stg_shipments`

Core fact table. One row per `cargo_id` + `stage` combination (a cargo can appear multiple times if it has multiple lifecycle stages in the source). Adds three computed lead-time columns consumed by all three analytical marts.

**Computed columns:**

| Column | Logic |
|---|---|
| `actual_lead_time_days` | `date_diff('day', actual_collection_at, actual_delivery_at)` — null if either timestamp is missing |
| `estimated_lead_time_days` | `date_diff('day', estimated_collection_at, estimated_delivery_at)` — null if either is missing |
| `lead_time_deviation_days` | `actual_lead_time_days - estimated_lead_time_days` — null unless all four timestamps are present; positive = slower than estimated |

---

### `mart_fct_shipment_events`

**Path:** `models/mart/shipments/mart_fct_shipment_events.sql`  
**Materialization:** view  
**Depends on:** `stg_shipments`

Unpivots three point-in-time timestamps into a long event timeline. Each cargo_id can appear up to three times.

| `event_type` | Source column | Filtered when |
|---|---|---|
| `requested` | `requested_at` | `requested_at is null` |
| `collection` | `actual_collection_at` | `actual_collection_at is null` |
| `delivery` | `actual_delivery_at` | `actual_delivery_at is null` |

Useful for: time-series analysis, funnel visualisation, and event-driven alerting.

---

### `mart_fct_active_shipments`

**Path:** `models/mart/shipments/mart_fct_active_shipments.sql`  
**Materialization:** view  
**Depends on:** `mart_fct_shipments`  
**Answers:** *How many active (non-delivered) shipments are currently in the pipeline?*

Uses `row_number()` partitioned by `cargo_id` (ordered by `requested_at desc`) to de-duplicate multi-stage cargo records — only the **latest stage** per cargo is retained before filtering.

**Output columns of note:**

| Column | Logic |
|---|---|
| `shipment_status` | `'not_yet_collected'` when `actual_collection_at` is null; otherwise `'in_transit'` |

**Filter applied:** `where is_delivered = false`

---

### `mart_fct_lane_performance`

**Path:** `models/mart/shipments/mart_fct_lane_performance.sql`  
**Materialization:** view  
**Depends on:** `mart_fct_shipments`  
**Answers:** *What is the average lead time per mode of transport per trade lane?*

Aggregates at `(trade_lane, mode_of_transport)` grain. Excludes rows where `trade_lane` is null, `actual_lead_time_days` is null, or `actual_lead_time_days < 0` (data quality guard).

**Output columns:**

| Column | Description |
|---|---|
| `shipments` | Count of shipments in the group |
| `avg_actual_lead_time_days` | Mean of `actual_lead_time_days`, rounded to 2dp |
| `avg_estimated_lead_time_days` | Mean of `estimated_lead_time_days`, rounded to 2dp |
| `avg_delay_days` | Mean of `lead_time_deviation_days`, rounded to 2dp |
| `delay_rate` | Proportion of shipments where `lead_time_deviation_days > 0` |

---

### `mart_fct_shipment_performance`

**Path:** `models/mart/shipments/mart_fct_shipment_performance.sql`  
**Materialization:** view  
**Depends on:** `mart_fct_shipments`  
**Answers:** *Which shipments deviated most from their estimated lead time?*

Row-level performance assessment. Excludes rows where lead-time metrics are null, negative, or where the deviation is exactly zero (i.e. only surfaces shipments that are measurably off-estimate). Results ordered by `abs(lead_time_deviation_days) desc` — worst deviations first.

**Derived columns:**

| Column | Logic |
|---|---|
| `performance_bucket` | `'slower_than_estimated'` / `'faster_than_estimated'` / `'on_time'` based on sign of deviation |
| `is_on_time` | `true` when `actual_lead_time_days <= estimated_lead_time_days` |

---

## Running the models

```bash
# Full refresh (recreate from source)
dbt run --select stg_shipments --full-refresh

# Run entire lineage from staging downward
dbt run --select stg_shipments+

# Run only the mart layer
dbt run --select mart_fct_shipments mart_fct_active_shipments mart_fct_lane_performance mart_fct_shipment_performance mart_fct_shipment_events
```

---

## Known issues / tech debt

- **Corrupt timestamps:** Years > 2030 in `actual_collection_at` are nullified in staging. The root cause in the upstream source has not been addressed.
- **Naming inconsistency:** Mart models live in two directories (`models/mart/shipments/` and `models/marts/core/`). These should be unified.
- **Multi-stage duplicates:** `mart_fct_shipments` is grain `cargo_id + stage`. Consumers that expect one row per cargo must apply their own deduplication (as `mart_fct_active_shipments` does).

{{
  config(
    materialized='incremental',
    incremental_strategy='merge',        -- IDEMPOTENT DEDUP, not update. Events are immutable facts, but the
                                          -- same interaction can arrive more than once (at-least-once delivery
                                          -- + the 3-day lookback re-scans already-loaded rows). append would
                                          -- INSERT those duplicates and break the grain; merge collapses them
                                          -- onto the existing key. (Alternative: append + qualify row_number().)
    unique_key='payment_event_id',        -- `id` is the ONLY always-populated unique column; payment_id is
                                          -- NULL at initiation, so it cannot serve as the merge key.
    partition_by={
      'field': 'created_at',
      'data_type': 'timestamp',
      'granularity': 'day'
    },
    cluster_by=['reservation_id']
  )
}}

-- stg_payments — one row per payment-provider INTERACTION (initiation | callback | resolution).
-- Grain = raw `id`, renamed payment_event_id. Payment-entity resolution is deferred to fct_payments.
-- =============================================================================================
-- INCREMENTAL PREDICATE & THE updated_at RISK
-- Volume: ~500K rows/month (~6M/year) -> a full refresh every run is wasteful; incremental is required.
--
-- Two risks drove the config above:
-- (1) Each payment produces 2-3 SEPARATE interaction rows (initiation/callback/resolution), each with its
--     own immutable payment_event_id. We are NOT updating rows. The risk is DUPLICATION: the same event can
--     arrive more than once (at-least-once delivery + the 3-day lookback below re-scans loaded rows). APPEND
--     would re-INSERT those -> several rows per payment_event_id -> grain broken -> revenue double-counted.
--     => incremental_strategy='merge' with unique_key=payment_event_id gives idempotent dedup: a repeat
--     event lands on its existing key instead of duplicating. (Alternative: append-only staging + dedup
--     downstream via qualify row_number() over(partition by payment_event_id ...). Merge front-loads it.)
-- (2) A strict `updated_at > MAX(updated_at)` boundary SILENTLY loses rows:
--       - updates landing mid-run (between reading MAX and the merge),
--       - clock skew / backfills stamping past timestamps,
--       - late-arriving provider-webhook mutations.
--     None of these error — the rows just never re-enter the model. => a LOOKBACK WINDOW re-scans the
--     last 3 days; merge makes reprocessing idempotent (re-reading a row simply upserts the same key).
--     Trade-off: "a few days of redundant scan buys the guarantee that boundary-timing and late
--     updates cannot be silently lost." Cheap insurance against silent revenue error.
--
-- Accepted limitation: HARD DELETES in the source are invisible to ANY incremental strategy — a
--   deleted row just stops arriving; nothing signals removal. Would need soft-deletes or a periodic
--   full-refresh reconciliation. Flagged, not solved, within the 4-hour budget.
--
-- Physical-design note (relevant at higher volume): we partition by created_at (IMMUTABLE — a row never
--   changes partition) but filter incrementally on updated_at, so the merge cannot prune partitions by
--   the predicate and scans the full target for matches. Fine at this volume; at 10x I'd revisit.
--   Partitioning by updated_at instead would be WORSE: it's mutable, so rows would hop partitions on
--   every update — an anti-pattern under merge.
-- =============================================================================================

with source as (
    select * from {{ source('raw', 'raw_payments') }}
),

renamed as (
    select
        id                          as payment_event_id,   -- always-populated row grain key
        nullif(payment_id, '')      as payment_id,          -- NULL until callback; NULLIF guards the seed's
                                                            -- empty-string loading so "unassigned" is a true NULL
        reservation_id,
        action,                                             -- initiation | callback | resolution
        status,                                             -- pending | processing | succeeded | failed | refunded
        cast(amount_usd as numeric) as amount_usd,          -- money as NUMERIC, never FLOAT: FLOAT64 rounding
                                                            -- (0.1 + 0.2 ...) corrupts summed revenue. NUMERIC is exact.
        payment_method,
        payment_policy,
        created_at,                                         -- immutable: when the interaction was first created
        updated_at                                          -- last time this interaction row was written/corrected;
                                                            -- drives the incremental predicate below
    from source
)

select * from renamed

{% if is_incremental() %}
-- Lookback window (NOT a strict MAX boundary) — see risk (2) above.
where updated_at > (
    select timestamp_sub(max(updated_at), interval 3 day)
    from {{ this }}
)
{% endif %}

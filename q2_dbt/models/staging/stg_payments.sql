{{
  config(
    materialized='incremental',
    incremental_strategy='merge',        -- upsert on the key so a re-delivered event doesn't duplicate
    unique_key='payment_event_id',       -- id is the only always-populated column; payment_id is null at initiation
    partition_by={
      'field': 'created_at',
      'data_type': 'timestamp',
      'granularity': 'day'
    },
    cluster_by=['reservation_id']
  )
}}

-- One row per payment-provider interaction (initiation/callback/resolution). Grain = raw id.
-- We resolve the actual payment entity later, in fct_payments.

-- merge, not append: a payment writes 2-3 rows and the same event can arrive twice (at-least-once
-- delivery + the lookback below re-reads rows). merge upserts on the key so we don't double-count;
-- append would insert the dupes.

-- lookback window instead of a strict updated_at > max(): a hard cutoff can miss updates that land
-- mid-run or arrive late. re-reading 3 days is cheap, and merge makes the re-read idempotent.

-- partition on created_at (never changes), not updated_at — rows mutate, so they'd hop partitions on
-- every update. hard deletes in the source we can't see here; noted, not handled.

with source as (
    select * from {{ source('raw', 'raw_payments') }}
),

renamed as (
    select
        id                          as payment_event_id,   -- always populated, this is the row key
        nullif(payment_id, '')      as payment_id,          -- empty string from the seed -> real null
        reservation_id,
        action,                                             -- initiation / callback / resolution
        status,                                             -- pending / processing / succeeded / failed / refunded
        cast(amount_usd as numeric) as amount_usd,          -- numeric, not float — float rounding breaks revenue sums
        payment_method,
        payment_policy,
        created_at,                                         -- when the interaction started (immutable)
        updated_at                                          -- last write; the incremental filter uses this
    from source
)

select * from renamed

{% if is_incremental() %}
-- 3-day lookback, not a hard max() cutoff — see note up top
where updated_at > (
    select timestamp_sub(max(updated_at), interval 3 day)
    from {{ this }}
)
{% endif %}

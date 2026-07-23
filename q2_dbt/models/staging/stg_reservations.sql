{{ config(materialized='view') }}

-- stg_reservations — derive discrete status-TRANSITION records from a daily snapshot.
-- In production the source is OVERWRITTEN nightly (no history); this model assumes snapshots have
-- been accumulated (multiple snapshot_dates retained). This is forensic inference from daily photos,
-- NOT ground truth — see snapshot_limitations.md for the five ways it is lossy, and the fix (source
-- status-change events, i.e. the Q1 bi_events design).
-- -------------------------------------------------------------------------------------------------

with source as (
    select * from {{ source('raw', 'raw_reservations') }}
),

ordered as (
    select
        reservation_id,
        status,
        company_id,
        traveler_id,
        cast(amount_usd as numeric) as amount_usd,
        snapshot_date,
        -- Previous status for this reservation, ordered by snapshot day. NULL on first appearance.
        lag(status) over (
            partition by reservation_id
            order by snapshot_date
        ) as previous_status
    from source
),

transitions as (
    select
        reservation_id,
        previous_status,
        status        as new_status,
        snapshot_date as transition_date,   -- DATE precision only: we know the DAY of a change, never the time
        company_id,
        traveler_id,
        amount_usd
    from ordered
    -- Emit ONLY rows where the status changed. IS DISTINCT FROM (BigQuery-native) handles the
    -- first-appearance NULL explicitly:
    --   (NULL IS DISTINCT FROM 'pending')     = TRUE  -> first snapshot emitted as "first observed"
    --   ('approved' IS DISTINCT FROM 'approved') = FALSE -> a repeated same-status day is suppressed
    where status is distinct from previous_status
)

select * from transitions

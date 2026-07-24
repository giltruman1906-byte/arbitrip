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
        snapshot_date as valid_from,        -- the DAY this status was first observed. DATE precision only:
                                            -- we know the day of a change, never the time.
        company_id,
        traveler_id,
        amount_usd
    from ordered
    -- Emit ONLY rows where the status changed. IS DISTINCT FROM (BigQuery-native) handles the
    -- first-appearance NULL explicitly:
    --   (NULL IS DISTINCT FROM 'pending')     = TRUE  -> first snapshot emitted as "first observed"
    --   ('approved' IS DISTINCT FROM 'approved') = FALSE -> a repeated same-status day is suppressed
    where status is distinct from previous_status
),

-- SCD TYPE-2 framing: turn discrete transitions into state INTERVALS [valid_from, valid_to).
-- valid_to = the day the NEXT transition was observed = the day this status ENDED. Computed with LEAD
-- over the already-filtered transitions (NOT lag over raw snapshots — that would give "yesterday", not
-- "when the next status began"). NULL valid_to = no later transition = the reservation's CURRENT state.
-- Interval is half-open: on valid_to the reservation is already in the next status, so
-- date_diff(valid_to, valid_from) = days spent in this status.
scd2 as (
    select
        reservation_id,
        previous_status,
        new_status,
        valid_from,
        lead(valid_from) over (
            partition by reservation_id
            order by valid_from
        ) as valid_to,
        (lead(valid_from) over (
            partition by reservation_id
            order by valid_from
        ) is null) as is_current,          -- TRUE = the reservation's latest known status
        company_id,
        traveler_id,
        amount_usd
    from transitions
)

select * from scd2

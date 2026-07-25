{{ config(materialized='view') }}

-- build status transitions out of a daily snapshot, shaped as SCD Type-2 intervals.
-- in prod the source is overwritten every night (no history); here we assume snapshots were kept.
-- this is reconstruction from daily photos, not ground truth — see snapshot_limitations.md.

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
        lag(status) over (                              -- yesterday's status for this reservation; null on first sight
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
        snapshot_date as valid_from,        -- day we first saw this status (day only, never the time)
        company_id,
        traveler_id,
        amount_usd
    from ordered
    -- keep only the days the status changed. is distinct from also emits the first appearance
    -- (null vs 'pending' is true), which we want as "first observed".
    where status is distinct from previous_status
),

-- turn each change into an interval [valid_from, valid_to). valid_to = the day the next status
-- started (via lead); null means this is the reservation's current status.
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
        ) is null) as is_current,          -- latest known status for the reservation
        company_id,
        traveler_id,
        amount_usd
    from transitions
)

select * from scd2

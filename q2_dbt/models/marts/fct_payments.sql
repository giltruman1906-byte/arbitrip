{{ config(materialized='table') }}

-- One row per payment, with its final status and a flag for a failed attempt on the same
-- reservation in the 24h before this one started.
-- A payment spans 2-3 stg rows. The source back-fills payment_id onto all of them once the
-- provider assigns it, so grouping on payment_id collapses them. A payment that dies at
-- initiation never gets an id, so it keeps its own "unresolved" key. (This assumes the source
-- back-fills — noted rather than trying to link the initiation row by reservation_id + timing.)

with payments as (
    select * from {{ ref('stg_payments') }}
),

reservations as (
    select *
    from {{ ref('stg_reservations') }}
),

keyed as (
    select
        *,
        -- resolved payment id, with a stable fallback so an unresolved payment isn't merged or dropped
        coalesce(payment_id, concat('unassigned_', payment_event_id)) as payment_key,
        (payment_id is null) as is_unresolved
    from payments
),

-- final status = the last row per payment. the id tiebreak matters: callback and resolution can
-- share updated_at, and without it the sort could land on 'processing' instead of 'succeeded'.
final_row as (
    select
        payment_key,
        is_unresolved,
        reservation_id,
        status     as final_status,
        action     as final_action,
        amount_usd,
        payment_method,
        payment_policy,
        updated_at as resolved_at        -- when the payment settled; other payments' 24h check compares to this
    from keyed
    qualify row_number() over (
        partition by payment_key
        order by updated_at desc, payment_event_id desc
    ) = 1
),

initiation as (
    -- when the payment started — the anchor for its own 24h window
    select
        payment_key,
        min(created_at) as initiated_at
    from keyed
    group by payment_key
),

reservation_company as (
    -- company_id for company-level metrics. stable per reservation, so any_value is fine.
    -- reservations we never saw in a snapshot come back null (e.g. res_104 / res_107).
    select
        reservation_id,
        any_value(company_id) as company_id
    from reservations
    group by reservation_id
),

payment_level as (
    select
        f.payment_key,
        f.reservation_id,
        rc.company_id,
        f.final_status,
        f.final_action,
        f.amount_usd,
        f.payment_method,
        f.payment_policy,
        i.initiated_at,
        f.resolved_at,
        f.is_unresolved
    from final_row f
    inner join initiation i using (payment_key)
    left  join reservation_company rc using (reservation_id)
),

-- true if another payment on the same reservation failed and settled in the 24h before this one
-- started: prior.resolved_at in [initiated_at - 24h, initiated_at). the strict upper bound keeps it
-- from counting itself or peeking at a failure that resolves after this payment begins.
-- self-join is fine at this size; at scale I'd use a range window or a pre-filtered failed CTE.
final as (
    select
        cur.payment_key,
        cur.reservation_id,
        cur.company_id,
        cur.final_status,
        cur.final_action,
        cur.amount_usd,
        cur.payment_method,
        cur.payment_policy,
        cur.initiated_at,
        cur.resolved_at,
        cur.is_unresolved,
        coalesce(
            logical_or(
                prior.final_status = 'failed'
                and prior.resolved_at >= timestamp_sub(cur.initiated_at, interval 24 hour)
                and prior.resolved_at <  cur.initiated_at
            ),
            false
        ) as had_failed_attempt_prior_24h
    from payment_level cur
    left join payment_level prior
        on  prior.reservation_id = cur.reservation_id
        and prior.payment_key   != cur.payment_key
    group by
        cur.payment_key, cur.reservation_id, cur.company_id, cur.final_status,
        cur.final_action, cur.amount_usd, cur.payment_method, cur.payment_policy,
        cur.initiated_at, cur.resolved_at, cur.is_unresolved
)

select * from final

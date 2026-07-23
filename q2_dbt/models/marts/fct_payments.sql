{{ config(materialized='table') }}

-- fct_payments — ONE ROW PER PAYMENT (not per provider interaction), with its final resolved status
-- and a flag for a prior failed attempt on the same reservation within 24h.
-- ================================================================================================
-- PAYMENT-ENTITY RESOLUTION
-- A payment spans 2-3 stg rows. The source back-fills payment_id onto ALL rows of a payment once the
-- provider assigns it (rows mutate in place), so grouping on payment_id resolves any payment that ever
-- reached callback. A payment that died at initiation never received a payment_id -> it stays its own
-- "unresolved" payment (flagged is_unresolved). We deliberately do NOT link the initiation row by
-- reservation_id + timing: that is over-engineering here, and back-fill already solves it. (This rests
-- on an assumption about source write-behaviour, documented here as an explicit assumption.)
-- ================================================================================================

with payments as (
    select * from {{ ref('stg_payments') }}
),

keyed as (
    select
        *,
        -- payment_key = resolved payment identity. The COALESCE fallback gives a never-resolved payment
        -- its own stable key from the row id, so it is neither merged with others nor silently dropped.
        coalesce(payment_id, concat('unassigned_', payment_event_id)) as payment_key,
        (payment_id is null) as is_unresolved
    from payments
),

-- FINAL STATUS = last row per payment. The payment_event_id tiebreak is REQUIRED: same-timestamp rows
-- exist (callback and resolution can share updated_at), and ORDER BY updated_at alone is non-deterministic
-- there — it could pick 'processing' over 'succeeded'. The id tiebreak makes the choice deterministic.
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
        updated_at as resolved_at        -- resolution time of the final row = the reference other payments' lookback uses
    from keyed
    qualify row_number() over (
        partition by payment_key
        order by updated_at desc, payment_event_id desc
    ) = 1
),

initiation as (
    -- initiated_at = when the payment STARTED (earliest interaction). Anchor for its OWN 24h window.
    select
        payment_key,
        min(created_at) as initiated_at
    from keyed
    group by payment_key
),

reservation_company as (
    -- Enrich with company_id for company-level metrics (see semantic_layer.md). company_id is stable
    -- per reservation, so ANY_VALUE is safe. Payments whose reservation never appeared in a snapshot
    -- get NULL via the LEFT JOIN below (e.g. res_104 / res_107 in the seed).
    select
        reservation_id,
        any_value(company_id) as company_id
    from {{ ref('stg_reservations') }}
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

-- 24h PRIOR-FAILED-ATTEMPT flag.
-- TRUE iff another payment on the SAME reservation reached final_status='failed' and RESOLVED within
-- [ this payment's initiated_at - 24h , this payment's initiated_at ).
--   - strict `<` upper bound: prevents self-counting and future leakage — never peek at a failure that
--     resolves at or after this payment starts.
--   - the reference point is the FAILED attempt's OWN resolved_at, not its initiation.
--   - prior.payment_key != cur.payment_key: a payment can never flag itself.
--   - LEFT JOIN + LOGICAL_OR: a payment with no qualifying prior resolves to FALSE (COALESCE of the
--     all-NULL / no-match case). 10x note: this is O(payments-per-reservation^2); fine here, but at
--     scale I'd bound it with a window range or a pre-filtered failed-payments CTE.
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

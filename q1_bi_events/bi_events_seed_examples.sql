-- bi_events — runnable example data + verification queries.
-- Supporting material, not a required deliverable — the point is to make the Q1.3 claims executable
-- rather than just asserted. Run bi_events_schema.sql first, then this file, then the queries at the bottom.
--
-- Section A: the 5 documented events from example_events.md
-- Section B: a few edge-case rows (a replayed duplicate, a missing transition) so the verification
--            queries have something real to catch
-- Section C: the verification queries
--
-- Dialect: BigQuery (GoogleSQL)


-- Section A — the five documented events.
-- All one traveler journey (usr_204 / corr_A1) except the BNPL event, which belongs to a separate
-- flow to show payment and booking decoupling in time.

INSERT INTO analytics.bi_events (
  event_id, event_domain, event_name, entity_type, entity_id,
  subject_user_id, correlation_id, actor_type, actor_id,
  previous_status, new_status,
  occurred_at, received_at, loaded_at, sequence_number,
  source_service, environment, schema_version, payload
)
VALUES

-- 1. search_performed — non-lifecycle, so both status columns are NULL.
(
  'evt_001', 'search', 'search_performed', 'search', 'srch_881',
  'usr_204', 'corr_A1', 'traveler', 'usr_204',
  NULL, NULL,
  TIMESTAMP '2026-07-23 09:14:02.114 UTC', TIMESTAMP '2026-07-23 09:14:02.400 UTC', TIMESTAMP '2026-07-23 09:20:00 UTC', 4471,
  'search-svc', 'prod', 1,
  JSON '{"destination":"London","check_in":"2026-09-10","check_out":"2026-09-13","results_count":142,"filters":{"stars":4}}'
),

-- 2. search_result_clicked — why event_domain and entity_type are separate: a search-domain event
--    on a hotel entity.
(
  'evt_002', 'search', 'search_result_clicked', 'hotel', 'htl_9912',
  'usr_204', 'corr_A1', 'traveler', 'usr_204',
  NULL, NULL,
  TIMESTAMP '2026-07-23 09:15:40.002 UTC', TIMESTAMP '2026-07-23 09:15:40.230 UTC', TIMESTAMP '2026-07-23 09:20:00 UTC', 4472,
  'search-svc', 'prod', 1,
  JSON '{"search_id":"srch_881","position_in_results":3,"price_shown_usd":290.00}'
),

-- 3. booking_approved — actor (approver usr_31) differs from subject (traveler usr_204).
--    A funnel built on actor alone loses this step.
(
  'evt_005', 'booking', 'booking_approved', 'booking', 'bkg_555',
  'usr_204', 'corr_A1', 'approver', 'usr_31',
  'requested', 'approved',
  TIMESTAMP '2026-07-23 09:40:12.007 UTC', TIMESTAMP '2026-07-23 09:40:12.190 UTC', TIMESTAMP '2026-07-23 10:00:00 UTC', 8104,
  'approval-svc', 'prod', 1,
  JSON '{"approval_policy":"manager_manual","decision_latency_sec":1105}'
),

-- 4. payment_charged (standard CC) — immediate charge, seconds after approval. Booking linked via
--    payload.reservation_id; the envelope stays domain-agnostic.
(
  'evt_006', 'payment', 'payment_charged', 'payment', 'pay_610',
  'usr_204', 'corr_A1', 'system', 'stripe_webhook',
  'processing', 'succeeded',
  TIMESTAMP '2026-07-23 09:40:15.310 UTC', TIMESTAMP '2026-07-23 09:40:15.502 UTC', TIMESTAMP '2026-07-23 10:00:00 UTC', 2201,
  'payment-svc', 'prod', 1,
  JSON '{"reservation_id":"bkg_555","amount_usd":870.00,"payment_method":"credit_card","payment_policy":"pay_now","provider":"stripe"}'
),

-- 5. payment_charged (BNPL) — same event_name and shape as #4, fired two days later by a scheduler.
--    The policy difference is data, not structure: no schema change was needed for the deferred case.
(
  'evt_007', 'payment', 'payment_charged', 'payment', 'pay_733',
  'usr_209', 'corr_B7', 'system', 'scheduler',
  'processing', 'succeeded',
  TIMESTAMP '2026-07-25 03:00:01.020 UTC', TIMESTAMP '2026-07-25 03:00:01.310 UTC', TIMESTAMP '2026-07-25 03:30:00 UTC', 2377,
  'payment-svc', 'prod', 1,
  JSON '{"reservation_id":"bkg_601","amount_usd":1240.00,"payment_method":"credit_card","payment_policy":"pay_later","provider":"stripe","booking_created_at":"2026-07-23T11:40:09Z","charge_scheduled_by":"bnpl_scheduler"}'
);


-- Section B — edge cases.
-- Test fixtures, not part of the five definitions. They exist so the Section C queries catch
-- something real instead of returning empty on clean data.

INSERT INTO analytics.bi_events (
  event_id, event_domain, event_name, entity_type, entity_id,
  subject_user_id, correlation_id, actor_type, actor_id,
  previous_status, new_status,
  occurred_at, received_at, loaded_at, sequence_number,
  source_service, environment, schema_version, payload
)
VALUES

-- B1. Replayed webhook: the same delivery of evt_006 arriving 4 minutes later. Because event_id is
--     producer-generated, the duplicate carries the same id, so dedup is a QUALIFY. Note the later
--     received_at/loaded_at — the duplicate is real and visible in raw.
(
  'evt_006', 'payment', 'payment_charged', 'payment', 'pay_610',
  'usr_204', 'corr_A1', 'system', 'stripe_webhook',
  'processing', 'succeeded',
  TIMESTAMP '2026-07-23 09:40:15.310 UTC', TIMESTAMP '2026-07-23 09:44:02.118 UTC', TIMESTAMP '2026-07-23 10:00:00 UTC', 2201,
  'payment-svc', 'prod', 1,
  JSON '{"reservation_id":"bkg_555","amount_usd":870.00,"payment_method":"credit_card","payment_policy":"pay_now","provider":"stripe"}'
),

-- B2/B3. Same-timestamp transitions on bkg_601: initialized and requested fire in the same
--     millisecond when the traveler submits. occurred_at can't order these; sequence_number
--     (9001 < 9002) does, and both come from the same service so the counters are comparable.
(
  'evt_010', 'booking', 'booking_initialized', 'booking', 'bkg_601',
  'usr_209', 'corr_B7', 'traveler', 'usr_209',
  NULL, 'initialized',
  TIMESTAMP '2026-07-23 11:40:09.100 UTC', TIMESTAMP '2026-07-23 11:40:09.280 UTC', TIMESTAMP '2026-07-23 12:00:00 UTC', 9001,
  'booking-svc', 'prod', 1,
  JSON '{"hotel_id":"htl_4410","total_usd":1240.00,"payment_policy":"pay_later"}'
),
(
  'evt_011', 'booking', 'booking_requested', 'booking', 'bkg_601',
  'usr_209', 'corr_B7', 'traveler', 'usr_209',
  'initialized', 'requested',
  TIMESTAMP '2026-07-23 11:40:09.100 UTC', TIMESTAMP '2026-07-23 11:40:09.290 UTC', TIMESTAMP '2026-07-23 12:00:00 UTC', 9002,
  'booking-svc', 'prod', 1,
  JSON '{"approval_required":true,"approver_group":"finance_il"}'
),

-- B4. Missing transition: booking_approved for bkg_601 was never emitted (dropped by the approval
--     service). This event claims previous_status 'approved', but the last recorded state for bkg_601
--     is 'requested'. Nothing errors — take only the latest event and the booking reads as 'requested',
--     with the chain now broken. Query C3 catches exactly this. It also arrives late (received_at ~9 min
--     after occurred_at), which is why the two timestamps are separate columns.
(
  'evt_013', 'booking', 'booking_completed', 'booking', 'bkg_601',
  'usr_209', 'corr_B7', 'system', 'booking_scheduler',
  'approved', 'completed',
  TIMESTAMP '2026-07-23 12:15:00.000 UTC', TIMESTAMP '2026-07-23 12:24:11.700 UTC', TIMESTAMP '2026-07-23 13:00:00 UTC', 9014,
  'booking-svc', 'prod', 1,
  JSON '{"checkout_completed":true}'
);


-- Section C — verification queries.
-- Every query filters on DATE(occurred_at): the table sets require_partition_filter = TRUE, so an
-- unbounded scan is rejected. That's the cost guardrail, and it shapes how every downstream model
-- has to be written.

-- C1. Idempotent dedup.
-- Proves the producer-generated event_id claim: the replayed webhook (B1) collapses to one row.
-- Keeping the earliest received_at preserves the original delivery and treats the replay as the dup.
SELECT *
FROM analytics.bi_events
WHERE DATE(occurred_at) BETWEEN '2026-07-23' AND '2026-07-25'
QUALIFY ROW_NUMBER() OVER (PARTITION BY event_id ORDER BY received_at ASC) = 1;
-- Expect 8 rows from 9 inserted — evt_006 deduped.


-- C2. Derived current state, with the full tiebreak chain.
-- State is never stored; it's an interpretation of the events. For bkg_601, occurred_at ties between
-- evt_010 and evt_011, so sequence_number decides.
WITH deduped AS (
  SELECT *
  FROM analytics.bi_events
  WHERE DATE(occurred_at) BETWEEN '2026-07-23' AND '2026-07-25'
    AND environment = 'prod'        -- bot/test traffic excluded, not deleted
    AND new_status IS NOT NULL      -- lifecycle events only
  QUALIFY ROW_NUMBER() OVER (PARTITION BY event_id ORDER BY received_at ASC) = 1
)
SELECT
  entity_type,
  entity_id,
  new_status AS current_status,
  occurred_at AS status_since
FROM deduped
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY entity_type, entity_id
  ORDER BY occurred_at DESC, sequence_number DESC, event_id DESC
) = 1;
-- Expect: bkg_555 approved, bkg_601 completed, pay_610 succeeded, pay_733 succeeded.


-- C3. Chain-gap detection — the Q1.3 claim, executable.
-- Each lifecycle event carries previous_status, so a gap is detectable: flag any event whose
-- previous_status doesn't match the prior event's new_status for the same entity. Without this the
-- loss is silent.
WITH deduped AS (
  SELECT *
  FROM analytics.bi_events
  WHERE DATE(occurred_at) BETWEEN '2026-07-23' AND '2026-07-25'
    AND environment = 'prod'
    AND new_status IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (PARTITION BY event_id ORDER BY received_at ASC) = 1
),
chained AS (
  SELECT
    entity_type, entity_id, event_id, event_name, occurred_at,
    previous_status, new_status,
    LAG(new_status) OVER (
      PARTITION BY entity_type, entity_id
      ORDER BY occurred_at, sequence_number, event_id
    ) AS prior_event_new_status
  FROM deduped
)
SELECT
  entity_type, entity_id, event_id, event_name, occurred_at,
  prior_event_new_status AS expected_previous_status,
  previous_status        AS claimed_previous_status
FROM chained
-- First event of a chain has no predecessor: not a gap.
WHERE prior_event_new_status IS NOT NULL
  AND previous_status IS DISTINCT FROM prior_event_new_status;
-- Expect exactly 1 row: bkg_601 / evt_013, claiming 'approved' after 'requested' — pinpointing where
-- booking_approved went missing. This is the query behind the dbt test described in rationale.md.


-- C4. Cross-domain journey reconstruction.
-- The payoff of correlation_id: one traveler's search -> book -> approve -> pay across three services
-- is a filter and a sort, not a multi-way join.
SELECT
  occurred_at, event_domain, event_name, entity_type, entity_id,
  source_service, actor_type,
  -- hot payload fields get promoted to typed columns in staging; at the raw layer, extracting on
  -- demand is the right trade-off
  JSON_VALUE(payload, '$.amount_usd') AS amount_usd
FROM analytics.bi_events
WHERE DATE(occurred_at) BETWEEN '2026-07-23' AND '2026-07-25'
  AND correlation_id = 'corr_A1'
QUALIFY ROW_NUMBER() OVER (PARTITION BY event_id ORDER BY received_at ASC) = 1
ORDER BY occurred_at, sequence_number;
-- Expect the full funnel: search -> click -> approval -> charge, with the approval step attributed to
-- the traveler (subject) though an approver acted.

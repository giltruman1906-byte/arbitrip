# bi_events — Example Event Definitions (Q1.2)

Five events spanning three domains (search, booking, payment), including one full booking-lifecycle event and the two required payment events — a standard credit-card charge and a buy-now-pay-later charge that fires after booking creation.

All examples share one traveler journey (`usr_204`, correlation `corr_A1`) so the cross-domain linking is visible — except event 5, which deliberately belongs to a different flow to demonstrate the BNPL time-decoupling.

---

## 1. `search_performed`  (domain: search)

**Trigger:** traveler submits a hotel search from the app; emitted by `search-svc` at query execution.

| Envelope field | Value |
|---|---|
| event_id | `evt_001` |
| event_domain / event_name | `search` / `search_performed` |
| entity_type / entity_id | `search` / `srch_881` |
| subject_user_id / correlation_id | `usr_204` / `corr_A1` |
| actor_type / actor_id | `traveler` / `usr_204` |
| previous_status / new_status | NULL / NULL *(non-lifecycle event)* |
| occurred_at / sequence_number | `2026-07-23 09:14:02.114 UTC` / `4471` |
| source_service / environment / schema_version | `search-svc` / `prod` / `1` |

**Payload:** `{"destination": "London", "check_in": "2026-09-10", "check_out": "2026-09-13", "results_count": 142, "filters": {"stars": 4}}`

---

## 2. `search_result_clicked`  (domain: search — entity: hotel)

**Trigger:** traveler clicks a hotel in the results list; emitted by `search-svc`.

Demonstrates why `event_domain` ≠ `entity_type`: the event belongs to the **search** process, but the thing it happened to is a **hotel**.

| Envelope field | Value |
|---|---|
| event_id | `evt_002` |
| event_domain / event_name | `search` / `search_result_clicked` |
| entity_type / entity_id | **`hotel`** / `htl_9912` |
| subject_user_id / correlation_id | `usr_204` / `corr_A1` |
| actor_type / actor_id | `traveler` / `usr_204` |
| previous_status / new_status | NULL / NULL |
| occurred_at / sequence_number | `2026-07-23 09:15:40.002 UTC` / `4472` |
| source_service / environment / schema_version | `search-svc` / `prod` / `1` |

**Payload:** `{"search_id": "srch_881", "position_in_results": 3, "price_shown_usd": 290.00}`

---

## 3. `booking_approved`  (domain: booking — lifecycle event)

**Trigger:** a company approver approves the pending booking request in the approval flow; emitted by `approval-svc` on decision commit.

Demonstrates actor ≠ subject: the **approver** acts, but the event remains part of the **traveler's** journey via `subject_user_id` and `correlation_id`.

| Envelope field | Value |
|---|---|
| event_id | `evt_005` |
| event_domain / event_name | `booking` / `booking_approved` |
| entity_type / entity_id | `booking` / `bkg_555` |
| subject_user_id / correlation_id | `usr_204` / `corr_A1` |
| actor_type / actor_id | **`approver`** / **`usr_31`** |
| previous_status / new_status | **`requested`** / **`approved`** |
| occurred_at / sequence_number | `2026-07-23 09:40:12.007 UTC` / `8104` |
| source_service / environment / schema_version | `approval-svc` / `prod` / `1` |

**Payload:** `{"approval_policy": "manager_manual", "decision_latency_sec": 1105}`

---

## 4. `payment_charged` — standard credit card  (domain: payment)

**Trigger:** payment provider (Stripe) webhook confirms a successful immediate charge, seconds after booking approval; emitted by `payment-svc` on webhook receipt.

| Envelope field | Value |
|---|---|
| event_id | `evt_006` |
| event_domain / event_name | `payment` / `payment_charged` |
| entity_type / entity_id | `payment` / `pay_610` |
| subject_user_id / correlation_id | `usr_204` / `corr_A1` |
| actor_type / actor_id | `system` / `stripe_webhook` |
| previous_status / new_status | `processing` / `succeeded` |
| occurred_at / sequence_number | `2026-07-23 09:40:15.310 UTC` / `2201` |
| source_service / environment / schema_version | `payment-svc` / `prod` / `1` |

**Payload:** `{"reservation_id": "bkg_555", "amount_usd": 870.00, "payment_method": "credit_card", "payment_policy": "pay_now", "provider": "stripe"}`

Note the cross-domain link: the booking is referenced via `payload.reservation_id`, while the event's own entity is the payment. The envelope stays domain-agnostic; the relationship lives in the payload and in `correlation_id`.

---

## 5. `payment_charged` — buy now pay later  (domain: payment, time-decoupled)

**Trigger:** the BNPL scheduler executes a deferred charge **two days after** the booking was created (per `pay_later` policy) — no user action involved.

Demonstrates the required BNPL case: **same event_name, same structure** as event 4 — the policy difference is data (`payment_policy`), the trigger difference is the actor (`scheduler` vs `stripe_webhook`), and the time gap between booking creation and payment is naturally handled because the payment event simply references a booking created earlier. No schema accommodation needed.

| Envelope field | Value |
|---|---|
| event_id | `evt_007` |
| event_domain / event_name | `payment` / `payment_charged` |
| entity_type / entity_id | `payment` / `pay_733` |
| subject_user_id / correlation_id | `usr_209` / `corr_B7` |
| actor_type / actor_id | `system` / **`scheduler`** |
| previous_status / new_status | `processing` / `succeeded` |
| occurred_at / sequence_number | **`2026-07-25 03:00:01.020 UTC`** / `2377` |
| source_service / environment / schema_version | `payment-svc` / `prod` / `1` |

**Payload:** `{"reservation_id": "bkg_601", "amount_usd": 1240.00, "payment_method": "credit_card", "payment_policy": "pay_later", "provider": "stripe", "booking_created_at": "2026-07-23T11:40:09Z", "charge_scheduled_by": "bnpl_scheduler"}`

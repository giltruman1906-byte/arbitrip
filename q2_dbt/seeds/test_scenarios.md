# Seed Test Scenarios

Every seed row exists to exercise a specific downstream behaviour. This maps each
scenario to the rows that carry it and the result the models should produce, so the
seed doubles as a readable set of test cases.

The seed is deliberately compact (27 payment rows / 16 reservation rows): every row
is purposeful, which makes the expected outputs easy to verify by hand. Padding with
random rows would only dilute that.

---

## `raw_payments` — payment entity resolution, final status, tiebreak, 24h lookback

| Case | payment_id | Rows (`id`) | What it proves | Expected in `fct_payments` |
|---|---|---|---|---|
| **3-row payment** | `pay_A` | pe_001, pe_002, pe_003 | Entity resolution: 3 provider interactions collapse to ONE payment. Note pe_001 (initiation) carries `pay_A` — back-filled once assigned (see 2.3 rationale), so grouping on payment_id is enough. | 1 row, `final_status = succeeded` |
| **Same-timestamp tiebreak** | `pay_B` | pe_009, pe_010, pe_011 | pe_010 (callback) and pe_011 (resolution) share `updated_at = 09:00:10`. ORDER BY updated_at alone is ambiguous and could pick `processing`. The `payment_event_id DESC` tiebreak deterministically picks pe_011. | 1 row, `final_status = succeeded` (NOT processing) |
| **Lookback TRUE** | `pay_C` (fails), `pay_D` (succeeds) | pe_020-021, pe_022-023 | Same `res_102`. C resolves failed at `07-03 08:00:05`; D initiates `07-04 04:00:05` — exactly 20h later, inside the 24h window measured from the FAILED attempt's own resolution time. | pay_D row: `had_failed_attempt_prior_24h = TRUE` |
| **Lookback FALSE (boundary)** | `pay_E` (fails), `pay_F` (succeeds) | pe_030-031, pe_032-033 | Same `res_103`. E resolves failed `07-05 06:00:05`; F initiates `07-06 12:00:05` — 30h later, just outside 24h. Proves the boundary, not just the happy path. | pay_F row: `had_failed_attempt_prior_24h = FALSE` |
| **Lookback FALSE (prior was NOT failed)** | `pay_K` (succeeds), `pay_L` (succeeds) | pe_080-081, pe_082-083 | Same `res_108`, only 10h apart (well inside 24h) — but the prior payment SUCCEEDED. Proves the filter is on `final_status = 'failed'`, not "any prior payment on the reservation". | pay_L row: `had_failed_attempt_prior_24h = FALSE` |
| **Unresolved / NULL payment_id** | *(NULL)* | pe_040 | Payment that died at initiation — provider never assigned an id, so it stays NULL. NULL here is a meaningful state ("never resolved"), not a row to link. | 1 row, `is_unresolved = TRUE`, `final_status = pending` |
| **Refund** | `pay_H` | pe_050-053 | Two resolution rows: succeeded then refunded a day later. Final status must follow the latest `updated_at`. Feeds the "revenue excludes refunds" semantic-layer point. | 1 row, `final_status = refunded` |
| **Clean BNPL success** | `pay_I` | pe_060, pe_061 | A `pay_later` payment that succeeds — gives the semantic layer real BNPL revenue to aggregate by `payment_policy`. | 1 row, `final_status = succeeded`, `payment_policy = pay_later` |
| **Standalone failure** | `pay_J` | pe_070, pe_071 | A failed payment with no follow-up — a payment can end `failed` with no successful retry. | 1 row, `final_status = failed` |

**Referential-integrity cases (feed the `relationships` WARN test in 2.4):**
`res_104` (pay_G) and `res_107` (pay_J) deliberately have **no** row in `raw_reservations`.
A payment can land before the reservation snapshot exists (or after it dropped), so the
relationship test is `warn`, not `error` — these two rows are why.

**Status/action domains** (must match the `accepted_values` tests):
`action` ∈ {initiation, callback, resolution}; `status` ∈ {pending, processing, succeeded, failed, refunded}.

---

## `raw_reservations` — snapshot-derived transitions

| Case | reservation_id | Snapshot dates | What it proves | Expected in `stg_reservations` |
|---|---|---|---|---|
| **Clean 3-status path** | `res_100` | 07-01 pending → 07-02 approved → 07-03 completed | The happy path: LAG detects each change. | 3 transition rows: (NULL→pending), (pending→approved), (approved→completed) |
| **Repeated same status** | `res_101` | 07-02 approved, 07-03 approved, 07-04 completed | `IS DISTINCT FROM` suppresses the no-change day (07-03). | 2 transition rows: (NULL→approved on 07-02), (approved→completed on 07-04) — nothing for 07-03 |
| **Disappearance** | `res_102` | 07-03 approved, 07-04 approved, then GONE | Snapshot holds active reservations only; a reservation present then absent is an implicit transition the model CANNOT see. This is limitation #4 made concrete. | Only (NULL→approved). The exit (completed? cancelled? deleted?) is invisible — documented, not derived |
| **Single appearance** | `res_103` | 07-05 pending only | A reservation seen once = first-observed only, no further transitions. | 1 row: (NULL→pending) as "first observed" |
| **Cancellation lifecycle** | `res_200` | 07-06 approved → 07-07 pending_cancellation → 07-08 cancelled | The cancellation path (ties to Q1's allowed-transitions matrix). | 3 rows: (NULL→approved), (approved→pending_cancellation), (pending_cancellation→cancelled) |

**Intra-day invisibility (limitation #1)** is inherent to ALL rows: any status the
snapshot never caught (e.g. a same-day pending→approved→pending revert) leaves no trace.
The seed cannot "show" an invisible transition — that's the point, and it's documented
in `snapshot_limitations.md` rather than faked into the data.

# bi_events — Design Rationale (Q1.1 & Q1.3)

## The core decision: envelope + payload

The requirement that drove everything: *"accommodate new event types and new domains over time without requiring structural changes."* Two naive designs fail it — one wide table with typed columns per event type (hundreds of mostly-NULL columns, an ALTER TABLE per product feature) and one table per event type (no unified log at all).

The design splits every event into a **typed envelope** — the fields that are true of *any* event that will ever exist ("something happened, to some entity, at some time, caused by someone, emitted by some service") — and a **JSON payload** carrying event-type-specific attributes. New event types and new domains are new *values and new payload shapes*: zero DDL. The rule for what goes where: **if a field is needed to route, order, join, or dedup ANY event → envelope; if it only makes sense once you know the event type → payload.**

The trade-off is stated honestly: payloads are schemaless, so write-time safety is traded for flexibility. Mitigations: (1) `schema_version` plus a per-event-type payload contract (an event registry, validated at the producer and by dbt tests downstream); (2) **promotion** — when a payload field becomes analytically hot (e.g. `amount_usd`), dbt staging models extract it into a typed column, so the raw layer stays stable and the curated layer stays fast.

## Key field decisions

- **`event_id` is producer-generated**, not assigned at load. Services and webhooks retry; the same logical event can arrive twice. A producer-side ID makes duplicates share an ID, turning dedup into a trivial `QUALIFY ROW_NUMBER() ... = 1`. Load-time IDs would make duplicates indistinguishable from distinct events.
- **`event_domain` and `entity_type` are both kept, deliberately.** They correlate for ~90% of events but answer different questions: which business *process* does this event belong to, versus which table does its target *join to*. They diverge exactly where a unified log earns its keep — e.g. `search_result_clicked` is a search-domain event on a **hotel** entity. Deriving one from the other would break that case.
- **The fine-grained taxonomy lives in the `event_name` convention (`object_action`), not in a sub_domain column.** Sub-domains multiply and shift as the product evolves; freezing today's taxonomy into a column invites exactly the structural churn the design forbids. A naming convention can deepen without touching the table; `event_domain` stays coarse (4–8 values) for clustering and access control.
- **`subject_user_id` is separate from `actor_id`.** An approver acts on a traveler's booking: the actor is the approver, but the event belongs to the traveler's journey. Funnels built on actor alone silently lose approval steps.
- **`correlation_id`** threads one end-to-end flow (search → book → approve → pay) across services, making journey reconstruction a GROUP BY instead of cross-service join archaeology.
- **Three timestamps, three jobs:** `occurred_at` (real-world time, from the source), `received_at` (pipeline receipt — the gap exposes late arrivals), `loaded_at` (table landing — ingestion debugging). BigQuery time travel (`FOR SYSTEM_TIME AS OF`, 7 days) complements these for table-state investigation.
- **`previous_status` / `new_status` are promoted to the envelope** (nullable) rather than left in the payload. Status transitions are the analytical backbone of both booking and payment lifecycles; typed columns make transition queries plain SQL (no JSON extraction), and non-lifecycle events simply carry NULLs. This is a conscious exception to the envelope rule, justified by how central lifecycle analysis is to this business.
- **`environment`** exists because Arbitrip's own landscape lists *external/automated traffic* as a real feed — bot and test events must be excludable from business metrics without being deleted.
- **PII stays out of payloads** (or arrives hashed/tokenized). The event log is long-retention and append-only; raw PII in it turns GDPR right-to-be-forgotten into a rewrite of an immutable log.

## Physical design (BigQuery)

Partitioned by `DATE(occurred_at)` — time is the universal access pattern for an event log — and clustered by `event_domain, event_name`, so domain-scoped queries scan slivers of a table that will reach hundreds of millions of rows. `require_partition_filter = TRUE` forces every query to bound its scan: a deliberate cost guardrail under BigQuery's scan-based pricing.

## Q1.3 — Lifecycle handling, rapid transitions, and missed transitions

**How transitions are represented.** Each transition is one immutable event row carrying `previous_status → new_status`. The table is append-only: state is never updated in place; "current status" is *derived* downstream (latest event per entity — `ROW_NUMBER() OVER (PARTITION BY entity_id ORDER BY occurred_at DESC, sequence_number DESC) = 1`). Events are facts; state is an interpretation of facts.

**Transitions minutes — or milliseconds — apart.** `initialized → requested` can fire within one millisecond when a traveler submits. Timestamp precision alone cannot order same-instant events, so ordering falls back through a chain:

1. **`occurred_at`** (millisecond precision) — resolves the overwhelming majority.
2. **`sequence_number`** — scoped to `(source_service, entity_id)`. This resolves ties *within one service*, which covers the common rapid-fire case (`initialized → requested`, both emitted by `booking-svc`).
3. **The `previous_status` chain** — for ties *across* services. This is the case a counter cannot solve: a booking's lifecycle spans `booking-svc` and `approval-svc`, whose counters are independent and not comparable. Because every lifecycle event carries `previous_status`, the true order is recoverable *topologically* — link each event to the one whose `new_status` matches its `previous_status`. This orders by causality rather than by clock, so it is immune to both clock skew between services and same-millisecond collisions.
4. **`event_id`** — final tiebreak. Deterministic but arbitrary: it guarantees *stable* results across query runs, not *correct* ones. If two events for one entity are genuinely indistinguishable at steps 1–3, that is a producer-side instrumentation gap, and the honest response is to fix the emitter rather than pretend the sort resolved it.

**Limitation, stated plainly:** step 3 works only for lifecycle events (those carrying statuses) and only when the chain is intact — a missed transition breaks the very links used to order. Ordering and gap-detection therefore share a failure mode, which is precisely why the reconciliation control below is not optional.

**What breaks if a transition is missed.** Because state is derived from events, a missing event makes downstream state *silently wrong* — the worst failure mode, because nothing errors:
1. **Wrong current state:** if `approved` is lost, the booking reads as `requested` forever — approval-latency SLAs, pending-approval dashboards, and revenue-recognition timing all mis-report.
2. **Broken transition chains:** a lost `pending_cancellation` makes a booking jump `completed → cancelled`, an illegal transition that corrupts funnel and cancellation-rate analysis.
3. **Compounding trust damage:** one silent gap discovered late (e.g. by finance) undermines confidence in the entire log.

**Mitigations designed in:**
- **Chain validation:** each lifecycle event carries `previous_status`, so gaps are *detectable* — a dbt test asserts that every event's `previous_status` equals the prior event's `new_status` per entity, and that every observed transition appears in the allowed-transitions matrix, which is defined per `entity_type`:
  - **booking:** `initialized→requested`, `requested→approved`, `approved→completed`, `requested/approved→pending_cancellation`, `pending_cancellation→cancelled`
  - **payment:** `initiated→processing`, `processing→succeeded`, `processing→failed`, `failed→processing` (retry), `succeeded→refunded`

  A violation pinpoints exactly where an event went missing. Note that `failed→processing` makes retries first-class in the log — the same retry behaviour that Q2's "failed attempt within the prior 24h" column has to reconstruct from mutable snapshot rows. A proper event log makes that column a simple filter rather than a window-function reconstruction.
- **Reconciliation:** periodic comparison of event-derived current state against the operational source of truth (the services' own DBs / daily snapshot); mismatches are alerted, and a `state_corrected` event can be emitted to repair the log *forward* — never by mutating history.
- **Idempotent replay:** producer-generated `event_id` means a service that detects a gap can safely re-emit; duplicates dedup cleanly.

**Consciously not done (time budget):** no per-domain sub-tables or materialized per-domain views (a dbt-layer concern, not a log-schema concern), no exactly-once delivery design at the transport layer (the schema assumes at-least-once + idempotent dedup, which is the practical standard).

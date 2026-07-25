# Arbitrip Data Engineering Take-Home

Three exercises: a unified event schema, a dbt project on BigQuery, and an infrastructure
recommendation. BigQuery is the target warehouse throughout, so all SQL and dbt config use
GoogleSQL and BigQuery-native features.

The reasoning matters as much as the output, so each deliverable carries its own rationale —
inline where it's short, in a dedicated note where it isn't.

## Q1 — Unified `bi_events` schema

An append-only event log using an envelope + JSON payload pattern, so new event types and
domains are new rows, never schema changes.

- [`q1_bi_events/bi_events_schema.sql`](q1_bi_events/bi_events_schema.sql) — table definition with field descriptions
- [`q1_bi_events/example_events.md`](q1_bi_events/example_events.md) — five example events across search, booking and payment (incl. a BNPL charge that fires after booking)
- [`q1_bi_events/rationale.md`](q1_bi_events/rationale.md) — design decisions, plus the lifecycle-ordering and missed-transition essay
- [`q1_bi_events/bi_events_seed_examples.sql`](q1_bi_events/bi_events_seed_examples.sql) — runnable sample data and verification queries

## Q2 — dbt models on BigQuery

Staging over mutable `raw_payments` (nullable `payment_id`) and snapshot-only `raw_reservations`,
plus an `fct_payments` mart. Seeds make the whole thing runnable end to end.

- [`q2_dbt/`](q2_dbt) — the dbt project ([its README](q2_dbt/README.md) covers how to run it)
- Staging: [`stg_payments.sql`](q2_dbt/models/staging/stg_payments.sql) (merge-incremental), [`stg_reservations.sql`](q2_dbt/models/staging/stg_reservations.sql) (snapshot → SCD-2 transitions)
- Mart: [`fct_payments.sql`](q2_dbt/models/marts/fct_payments.sql) — one row per payment, final status, 24h prior-failed-attempt flag
- Tests: [`_stg_models.yml`](q2_dbt/models/staging/_stg_models.yml), [`_marts_models.yml`](q2_dbt/models/marts/_marts_models.yml), [`tests/`](q2_dbt/tests)
- Notes: [`snapshot_limitations.md`](q2_dbt/snapshot_limitations.md), [`semantic_layer.md`](q2_dbt/semantic_layer.md)

## Q3 — Infrastructure recommendation

Current stack (Rivery → BigQuery → dbt → Looker) vs. an end-to-end Databricks move: comparison,
cost, risk, architecture maps, a 100-day plan, and the tripwires that would change the call.

- [`q3_infra_recommendation.md`](q3_infra_recommendation.md)

## Conventions

- **BigQuery dialect** everywhere (partitioning, clustering, `merge`, native `JSON`, no Snowflake-only functions).
- dbt naming: `stg_` / `fct_` prefixes, snake_case, one model per file, tests in yml.

# Q2 — dbt on BigQuery

dbt project answering Q2: staging models over `raw_payments` (mutable, nullable `payment_id`) and
`raw_reservations` (daily snapshot, no history), and a `fct_payments` mart with final-status
resolution and a 24h prior-failed-attempt flag.

## Required deliverables (per the assignment's "What to submit")

| Deliverable | File |
|---|---|
| `stg_payments.sql` (incremental + comments) | `models/staging/stg_payments.sql` |
| `stg_reservations.sql` (transition window logic) | `models/staging/stg_reservations.sql` |
| `fct_payments.sql` (final status + 24h lookback) | `models/marts/fct_payments.sql` |
| `stg_payments.yml` (5+ tests + why-comments) | `models/staging/_stg_models.yml` * |
| Snapshot-transition limitations note | `snapshot_limitations.md` |
| Semantic layer sketch | `semantic_layer.md` |

\* Naming: tests are consolidated one-file-per-layer (`_stg_models.yml`, `_marts_models.yml`) per dbt
style-guide convention — dbt keys tests by the `name:` inside the file, not the filename, so the
required `stg_payments` tests are all present.

## Supporting files (for runnability + readability)

- `seeds/raw_payments.csv`, `seeds/raw_reservations.csv` — simulate the two raw tables.
- `seeds/_seeds.yml` — pinned column types.
- `seeds/test_scenarios.md` — maps every seed row to the behaviour it exercises and its expected output.
- `models/staging/_sources.yml`, `dbt_project.yml`, `packages.yml`, `macros/`, `profiles.yml.example`.

## Run

```bash
cp profiles.yml.example ~/.dbt/profiles.yml   # then edit with your GCP project + keyfile
dbt deps        # installs dbt_utils
dbt seed        # loads the two CSVs into the `raw` dataset
dbt run         # builds staging (analytics) then fct_payments (analytics)
dbt test        # runs the tests in _stg_models.yml / _marts_models.yml
```

Run order matters: `dbt seed` before `dbt run` (the sources point at the seeded tables).

## Verification status — read this

**Not executed against BigQuery** — no warehouse connection was available while building. The SQL is
written to BigQuery (GoogleSQL) dialect and hand-verified against `seeds/test_scenarios.md` (final-status
picks, tiebreak, and the lookback TRUE/FALSE/status-boundary rows all traced by hand). If connected,
the one thing to eyeball first is `fct_payments.had_failed_attempt_prior_24h` on `pay_D` (TRUE),
`pay_F` (FALSE, 30h), and `pay_L` (FALSE, prior succeeded).

## Data model in one line

`raw_payments` → `stg_payments` (one row per interaction, merge-incremental) → `fct_payments`
(one row per payment). `raw_reservations` → `stg_reservations` (one row per status transition),
which also supplies `company_id` to the mart.

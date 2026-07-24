# Semantic Layer Sketch on `fct_payments` (Q2.5)

A semantic layer defines each metric **once**, in one governed place, so every downstream consumer —
Tableau, Looker, a Python notebook, a Slack bot — inherits the *same* definition instead of each
re-deriving it in its own SQL. Below are the metrics on top of `fct_payments`, expressed as a
MetricFlow-style spec (the exact syntax matters less than the discipline: aggregation + grain + a
single filter set, version-controlled). The same metrics are also expressed as runnable dbt/MetricFlow
objects in `models/marts/_semantic_models.yml` — this doc is the reasoning, that file is the code form.

**Base table:** `fct_payments` — grain: **one row per payment**.
**Shared dimensions:** `initiated_at` (→ day/week/month), `company_id`, `payment_policy`, `payment_method`.

| Metric | Aggregation | Definition | Grain | Notes |
|---|---|---|---|---|
| `total_revenue` | `SUM(amount_usd)` | `WHERE final_status = 'succeeded'` | payment | Excludes failed, pending, **and refunded** by construction — the single point where "what counts as revenue" is decided. |
| `payment_count` | `COUNT(payment_key)` | filter optional (all payments, or scoped to `succeeded`) | payment | Distinct payments, not interactions — the mart grain guarantees this. |
| `avg_payment_value` | **derived ratio** | `total_revenue / payment_count` | payment | Defined as a ratio of the two metrics above, **never** as a standalone `AVG(amount_usd)`. |
| `failed_payment_rate` *(optional)* | **derived ratio** | `count(final_status='failed') / payment_count` | payment | Reuses the same denominator, so it can't drift from `payment_count`. |

**Why `avg_payment_value` is a ratio, not an `AVG()`.** If an analyst writes `AVG(amount_usd)` directly,
its numerator and denominator can silently diverge from the governed revenue metric — a different status
filter, refunds left in, failed attempts counted. Defining it as `total_revenue / payment_count` forces
both halves to inherit the *identical* filter set from the metrics above. Consistency is guaranteed by
construction, not by everyone remembering to apply the same `WHERE` clause.

## How this prevents metric-definition drift

Ask five analysts for "revenue" today and you get five numbers, because each answers unstated questions
differently: *Include refunds? Count BNPL that hasn't charged yet? Count failed retries? Gross or net?*
Each writes their own `WHERE`, the dashboards disagree, and trust in the numbers erodes — the failure
mode is silent, because every query "works."

A semantic layer collapses those five definitions into **one**. "Revenue excludes refunds and failed
attempts" lives in exactly one place; Tableau, Looker, a notebook, and a Slack query all compile against
it and return the same figure. Changing the definition — say, finance rules that partial refunds should
net down revenue — becomes **one reviewed pull request**, not five people editing five dashboards and
hoping they matched. The definition is code: versioned, reviewed, and diffable.

This is the exact role a dbt semantic/metrics layer has played for me before — one governed set of
metric definitions feeding every BI surface, so "the number" means one thing across the company. It
matters most when it is set up early: the convention lands *before* five different "revenue" queries
proliferate and have to be reconciled after the fact.

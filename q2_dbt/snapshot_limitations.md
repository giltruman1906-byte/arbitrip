# Limitations of Snapshot-Derived Status Transitions (Q2.2)

`stg_reservations` reconstructs *when a reservation changed status* from `raw_reservations` — a table
that is **overwritten every night** with the current state of active reservations and keeps no history.
The model orders each reservation's daily snapshots with `LAG(status)` and emits a row wherever the
status differs from the day before. This works, but it is **forensic reconstruction from daily photos,
not ground truth.** The reliable failure modes:

1. **Intra-day transitions are invisible.** The snapshot captures state once per day. If a reservation
   moves `pending → approved → completed` within a single day, we see only the last value — the model
   reports `pending → completed`, or if it was created and completed the same day, only `completed`.
   A quick revert (`approved → pending → approved` in one day) looks like *no change at all*.

2. **Precision is a date, never a time.** `valid_from` / `valid_to` tell us the *day* a change was first
   observed, not the moment. Any analysis needing hour-level timing (approval latency, SLA breaches,
   time-to-pay) cannot be answered from this model — only "on which day." Likewise `date_diff(valid_to,
   valid_from)` measures *observed* days in a status, not true elapsed time.

3. **A missed or failed snapshot day fabricates adjacency.** `LAG` orders by whatever snapshots exist,
   not by the calendar. If the Tuesday snapshot fails to run, Monday and Wednesday become "consecutive"
   and a transition is attributed to the wrong day, or two days' worth of change collapse into one.

4. **Disappearance is an unlabelled transition.** The snapshot holds *active* reservations only. A
   reservation present yesterday and absent today has clearly moved to a terminal state — but the model
   cannot tell **completed** from **cancelled** from **hard-deleted**, because the last thing it ever
   saw was the pre-exit status. (Seed `res_102` shows exactly this: last seen `approved`, then gone.)
   The exit is real information the snapshot structurally cannot carry.

5. **Same-day create-and-close is never observed.** A reservation that appears and reaches a terminal
   state between two nightly snapshots leaves no trace in any snapshot — it is invisible end to end.

**A modelling choice worth noting:** the first time a reservation appears, `previous_status` is `NULL`,
and `IS DISTINCT FROM` emits it as a *"first observed"* transition rather than dropping it. That is
deliberate — first observation is itself analytically useful — but it is an *observation event*, not a
true status change, and should be read as such.

## A note on retention (how the history is kept in production)

The real source is **overwritten every night** — it only ever holds *one* day. So the accumulated
multi-day history this model reads does not exist in the source; it has to be **captured**. In
production that capture is a separate upstream layer: a nightly job (dbt's built-in `dbt snapshot`)
copies each night's snapshot into a history table that only ever grows. `stg_reservations` then derives
transitions on top of that retained history. Here the **seed simulates that already-captured history**
(it keeps multiple `snapshot_date`s side by side) so this model can focus on the derivation, not the
ingestion. Note the pipeline is two distinct jobs: **capture/retention** (accumulate snapshots) →
**derivation** (this model). Importantly, even perfect nightly capture only yields *daily* granularity —
it fixes *retention*, not the five gaps above, which are inherent to snapshotting once per day.

## The real fix (cross-reference to Q1)

Every limitation above traces to one root cause: **we are inferring events from state.** The snapshot
records *what is*, and we reverse-engineer *what happened*. The correct fix is to stop inferring —
**emit a status-change event at the source the moment a transition occurs.** That is precisely the Q1
`bi_events` design: each transition is an immutable fact carrying `previous_status → new_status` and a
true `occurred_at` timestamp. With that log, transitions are read directly (intra-day changes, exact
timing, and terminal exits all captured) instead of guessed from daily photos. Until that exists, this
model is the honest best-effort — and its output should be consumed with these five caveats attached.

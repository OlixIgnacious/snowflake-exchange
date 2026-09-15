# CoCo task: full persona-workflow demo (propose -> approve -> log -> render -> sign off -> ask)

## Context

`ui/streamlit_app.py` (2026-09-16 redesign) added a demo-only persona switcher: real Snowflake
`USE ROLE` switching (not a widened grant) lets one viewer walk the full governance lifecycle --
Surveillance Operator (`AUDIT_INSERT`), Market Data Ops (`MARKET_DATA_INGEST`), Governance
Reviewer (`GOVERNANCE_WRITE`), Compliance Officer (`OFFICER_SIGNOFF`) -- each acting through a
narrow, already-existing procedure, then back to `ANALYST_READ`. Every procedure below was already
granted to exactly the role that calls it before this task; no new `GRANT` is needed anywhere.

This task reproduces the same workflow from CoCo, outside the Streamlit app, as a live
CLI-driven proof rather than a UI screenshot. **Unlike
`cortex_project/coco_task_verify_agent_routing.md`, this task is NOT read-only** -- steps 2-5
genuinely write rows (a new `AUDIT_LOG` snapshot, a rendered report payload, a new obligation, a
sign-off record). That's the point: verify the actual effect landed, don't just report that a
`CALL` returned without error.

**Read this before step 2:** this account defaults every session to secondary roles = `ALL`,
discovered live while building a negative-check test for this exact workflow -- a session's
*primary* active role (`CURRENT_ROLE()`) restricts nothing by itself unless you also run
`USE SECONDARY ROLES NONE` first. Without it, `USE ROLE ANALYST_READ` would still let every
`CALL` below succeed regardless of which role is "current," making the whole persona switcher a
label, not real enforcement. Run this once per session, before step 2:

```sql
USE SECONDARY ROLES NONE;
USE ROLE ANALYST_READ;
```

## Steps

### 1. Orient
Connect to `VIGIL.CORE`, confirm 18 tables with real row counts. Show current role, and confirm
(via `SHOW GRANTS TO ROLE ANALYST_READ` or a live attempt) that `ANALYST_READ` alone cannot call
any of the procedures in steps 2-5 -- a real rejection, not an assumption.

### 2. Surveillance Operator -- log a run
Switch to `AUDIT_INSERT`, call `SP_LOG_SURVEILLANCE_RUN('JP')`. Switch back to `ANALYST_READ`,
query `SURVEILLANCE_RUN_LOG` for the `RUN_ID`s just written -- show the 5 new rows (one per
detector) with their `FLAGGED_COUNT`. Show the actual rows, not just "succeeded."

### 3. Market Data Ops -- render a report payload
As `ANALYST_READ`, find a JP report in `TRANSACTION_REPORTS_CURRENT` where
`REPORT_PAYLOAD_REF IS NULL`. Switch to `MARKET_DATA_INGEST`, call `SP_RENDER_REPORT_PAYLOAD` for
that `REPORT_ID` and `'JP'`. Switch back, confirm `REPORT_PAYLOAD_REF` is now populated -- show
the stage path.

### 4. Governance Reviewer -- propose then approve
Switch to `GOVERNANCE_WRITE`. Call `SP_PROPOSE_OBLIGATION` for a new JP obligation (id like
`JP-DEMO-<timestamp>`, source table `TRADES`, source columns `PRICE,VOLUME`, detector
`wash_trading`). Call `SP_APPROVE_OBLIGATION` for the same obligation. Confirm it appears in
`APPROVED_OBLIGATIONS` with `STATUS='approved'` -- query and show the row. (Note: `OBLIGATION_MAP`
is milestoned -- a `proposed` row is never deleted, only superseded by a later `approved` row with
the same key and a later `LOADED_AT`. Query "is this still pending" with
`QUALIFY ROW_NUMBER() OVER (PARTITION BY OBLIGATION_ID, JURISDICTION_ID ORDER BY LOADED_AT DESC) =
1 AND STATUS = 'proposed'` -- not a bare `WHERE STATUS = 'proposed'`, which found all 5 of JP's
already-approved obligations as "pending" when this exact bug was caught in `ui/streamlit_app.py`
on 2026-09-16.)

### 5. Compliance Officer -- record a sign-off
As `ANALYST_READ`, get the most recent `RUN_ID` from `SURVEILLANCE_RUN_LOG` for JP (the one from
step 2 works). Switch to `OFFICER_SIGNOFF`, call `SP_RECORD_SIGNOFF` for that `RUN_ID` with
decision `'approved'`. Switch back, query `AUDIT_LOG WHERE STAGE='signoff'` for that
`SIGNOFF_FOR_RUN_ID` -- confirm `SIGNOFF_BY` is your own `CURRENT_USER()`, not anything passed in
(the procedure binds it server-side on purpose -- a caller cannot assert a fabricated identity).

### 6. Close the loop -- ask the real agent, not your own reasoning
Call `SNOWFLAKE.CORTEX.DATA_AGENT_RUN` on `VIGIL.CORE.VIGIL_SURVEILLANCE_AGENT`:
first "How many wash-trading candidates are flagged for JP?", then in the same conversation "And
what rule covers that?". Confirm the second answer cites Japan's own FIEA Article 159, not a US
statute -- a real jurisdiction-mixing bug fixed earlier in this project (`rule_search`'s
`JURISDICTION_ID` filter), worth re-proving still holds rather than assuming it does forever.

### 7. Log it
Write a `NOTES.md` entry (this file, gitignored, is the durable run log for this project) covering
everything above: what ran, the actual verified results at each step (not "succeeded"), and
confirm via `SHOW GRANTS TO ROLE ANALYST_READ` that it still shows zero write grants after all of
this -- the whole point of the role-switching design is that it never needed one.

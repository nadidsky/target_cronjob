# Scenarios & edge cases

Every scenario below is a **test case**. The Go tests in [src/go/target_job_test.go](src/go/target_job_test.go) and the bats tests in [tests/](tests/) assert the behaviour described here. Treat this file as the spec; the code is an attempt at implementing it.

## Reference calendar — 2025

| Date | Weekday | TARGET status |
|---|---|---|
| 2025-01-01 | Wed | Closing — New Year's Day |
| 2025-04-18 | Fri | Closing — Good Friday |
| 2025-04-19 | Sat | Closing — weekend |
| 2025-04-20 | Sun | Closing — Easter Sunday (weekend) |
| 2025-04-21 | Mon | Closing — Easter Monday |
| 2025-04-22 | Tue | **Open** |
| 2025-05-01 | Thu | Closing — Labour Day |
| 2025-12-24 | Wed | **Open** |
| 2025-12-25 | Thu | Closing — Christmas Day |
| 2025-12-26 | Fri | Closing — Boxing Day |
| 2025-12-27 | Sat | Closing — weekend |
| 2025-12-28 | Sun | Closing — weekend |
| 2025-12-29 | Mon | **Open** |
| 2025-12-31 | Wed | **Open** |
| 2026-01-01 | Thu | Closing — New Year's Day |
| 2026-01-02 | Fri | **Open** |

Easter Sundays used in tests: 2024-03-31 · 2025-04-20 · 2026-04-05 · 2027-03-28 · 2028-04-16.

---

## How to read each scenario

Each scenario specifies:

- **Inputs**: today's date, time, contents of the state file, and the anchor date.
- **Behaviour**: which of the four gates fires, or whether the job runs.
- **Job invocation**: exact argv passed to `JOB_COMMAND` when the job runs.
- **Log output**: representative lines written to `target_job.log`. A scenario that ends with a silent gate writes nothing.

The date range passed to `JOB_COMMAND` always contains **every calendar date** from `last_success + 1` through today, **inclusive of closing days** — the cron driver does the calendar catch-up, the downstream job decides what to do with each date.

---

## Easter week

### S1 — Tuesday after Easter Monday (backfill of 5 days)

**Inputs**
- `today = 2025-04-22` (Tuesday, open), `time = 19:35`
- Last success on file: `2025-04-17` (the Thursday before Good Friday)
- Anchor: `2025-01-01`

**Behaviour**: all four gates pass. Job runs.

**Job invocation**
```
my_report_job 2025-04-18 2025-04-19 2025-04-20 2025-04-21 2025-04-22
```
Five dates: Good Friday, Saturday, Easter Sunday, Easter Monday, today.

**Log**
```
[2025-04-22 19:35:00] [INFO] ========== target_job started (PID 12345) ==========
[2025-04-22 19:35:00] [INFO] Today  : 2025-04-22 | Trigger reached: 19:35
[2025-04-22 19:35:00] [INFO] Last success: 2025-04-17 | Anchor: 2025-01-01
[2025-04-22 19:35:00] [INFO] Date range to process (5 day(s)):
[2025-04-22 19:35:00] [INFO]   -> 2025-04-18
[2025-04-22 19:35:00] [INFO]   -> 2025-04-19
[2025-04-22 19:35:00] [INFO]   -> 2025-04-20
[2025-04-22 19:35:00] [INFO]   -> 2025-04-21
[2025-04-22 19:35:00] [INFO]   -> 2025-04-22
[2025-04-22 19:35:00] [INFO] Running: my_report_job 2025-04-18 2025-04-19 2025-04-20 2025-04-21 2025-04-22
[2025-04-22 19:35:00] [INFO] Job completed successfully (exit code 0).
[2025-04-22 19:35:00] [INFO] Recorded success for 2025-04-22 → /var/lib/target_job/target_job_success.log
```

### S2 — Wednesday of Easter week (normal one-day run)

**Inputs**: `today = 2025-04-23`, last success `2025-04-22`.

**Behaviour**: job runs with a single date.

**Job invocation**
```
my_report_job 2025-04-23
```

### S3 — Clock ticks to 19:30 *on* Good Friday

**Inputs**: `today = 2025-04-18`, `time = 19:35`.

**Behaviour**: Gate 1 passes (time). **Gate 2 fires** — today is a TARGET closing day. Silent exit. No log, no lock file, no change to state.

### S4 — Clock ticks *on* Easter Monday

**Inputs**: `today = 2025-04-21`, any time past 19:30.

**Behaviour**: Same as S3 — Gate 2 fires.

---

## Christmas & the Dec 26–28 weekend cluster

### S5 — Running on Dec 24, 2025 (Wed, open)

**Inputs**: `today = 2025-12-24`, last success `2025-12-23`.

**Behaviour**: one-day run.

**Job invocation**
```
my_report_job 2025-12-24
```

### S6 — Running on Dec 25 (Christmas)

`Gate 2` fires — closing. Silent exit.

### S7 — Running on Dec 26 (Boxing Day)

`Gate 2` fires — closing. Silent exit.

### S8 — Running on Dec 27 (Saturday)

`Gate 2` fires — weekend. Silent exit.

### S9 — Running on Dec 28 (Sunday)

`Gate 2` fires — weekend. Silent exit.

### S10 — Monday Dec 29, 2025 — first open day after the Christmas weekend

**Inputs**: `today = 2025-12-29`, last success `2025-12-24`.

**Behaviour**: Gates 1–4 pass. Job runs with 5 dates.

**Job invocation**
```
my_report_job 2025-12-25 2025-12-26 2025-12-27 2025-12-28 2025-12-29
```
Christmas, Boxing Day, Saturday, Sunday, today.

---

## Year-end / New Year

### S11 — Running on Dec 31, 2025 (Wed, open)

**Inputs**: `today = 2025-12-31`, last success `2025-12-30`.

**Job invocation**
```
my_report_job 2025-12-31
```

### S12 — Running on Jan 1, 2026 (New Year's Day)

`Gate 2` fires. Silent exit. Note that Dec 31's success is recorded, so even a successful 19:30 run the previous day does not conflict.

### S13 — Running on Jan 2, 2026 (Fri, open — first open day of the year)

**Inputs**: `today = 2026-01-02`, last success `2025-12-31`.

**Job invocation**
```
my_report_job 2026-01-01 2026-01-02
```
The closed New Year's Day is included in the range.

---

## First-ever run and anchor semantics

### S14 — First run, today = anchor

**Inputs**: empty state file, anchor `2025-01-02`, today `2025-01-02` (Thursday, open).

**Behaviour**: last_success defaults to `anchor − 1` = `2025-01-01`. Range starts at `2025-01-02`.

**Job invocation**
```
my_report_job 2025-01-02
```

### S15 — First run, today > anchor (backfill since anchor)

**Inputs**: empty state file, anchor `2025-01-02`, today `2025-01-07` (Tuesday).

**Job invocation**
```
my_report_job 2025-01-02 2025-01-03 2025-01-04 2025-01-05 2025-01-06 2025-01-07
```
Anchor itself is included (because `last_success = anchor − 1`).

---

## Gate 1 — time check

### S16 — Clock at 19:29 on an open day

**Behaviour**: Gate 1 fires. Silent exit. The script enters, reads config, compares `HHMM = 1929 < 1930`, returns `0` without creating a log file. This is the vast majority of cron invocations.

### S17 — Clock at exactly 19:30

**Behaviour**: Gate 1 passes (comparison is `<`, not `≤`). Gates 2–4 then evaluated.

### S18 — Clock at 23:59, still haven't succeeded

**Behaviour**: Gate 1 passes. If Gates 2–4 also pass, the job runs — there is no upper bound. If the job is still running at 00:00 the next day, the lock prevents the new-day tick from interfering, and "today" on the next tick will roll to the new calendar date (so the just-finished run will have recorded yesterday's success, not today's — acceptable behaviour).

---

## Gate 3 — already succeeded today

### S19 — Second invocation on the same day

**Inputs**: state file contains `2025-04-22  executed_at=...`. `today = 2025-04-22`, time `20:15`.

**Behaviour**: Gate 3 fires. Silent exit. Idempotent under repeated cron ticks.

---

## Gate 4 — lock

### S20 — Concurrent invocation

**Inputs**: first invocation is mid-run, holding the lock. Second invocation arrives one minute later, same conditions.

**Behaviour**: second invocation's `acquire_lock` fails. Silent exit. No log, no error.

### S21 — Stale lock after crash (POSIX sh / Go)

**Known limitation**: in the POSIX sh and Go implementations the lock is a directory. If the process is killed with `SIGKILL` the lock directory is not removed, and every subsequent tick silent-exits on Gate 4 until an operator removes it manually. (`bash` is unaffected: `flock` releases on fd close, even via `SIGKILL`.)

**Expected operator action**: `rm -rf /var/lib/target_job/target_job.lock`.

---

## Job failure and retry

### S22 — Job exits non-zero

**Inputs**: all four gates pass; `JOB_COMMAND` exits with status `7`.

**Behaviour**: success is **not** recorded. Lock is released on exit. Script exits with status `7`.

**Log**
```
[2025-04-22 19:35:00] [INFO] Running: my_report_job 2025-04-22
[2025-04-22 19:35:00] [ERROR] Job FAILED with exit code 7.
[2025-04-22 19:35:00] [ERROR] Will retry on next cron trigger (every minute after 19:30).
```

### S23 — Automatic retry one minute later

**Inputs**: following S22, the next cron tick fires at `19:36`.

**Behaviour**: Gate 1 passes. Gate 2 passes (same day). Gate 3 passes (no success recorded). Gate 4 passes. Job runs with the **same** date range — the retry is automatic and does not need operator action. Continues every minute until success is recorded or midnight flips the calendar.

---

## Leap year & rare calendar quirks

### S24 — Feb 29 in a leap year

`2024-02-29` is a Thursday, open. No special handling.

### S25 — Easter at its earliest (March 22)

Easter 2285 = March 22. The date arithmetic handles a Good Friday of March 20.

### S26 — Easter at its latest (April 25)

Easter 2038 = April 25. Good Friday April 23, Easter Monday April 26.

### S27 — DST transitions

TARGET calendar is defined on calendar dates, not wall-clock times. DST changes in Europe happen on Sundays (always closing days), so they cannot affect the gating logic. The script uses `date +%Y-%m-%d` / `time.Now()` which always returns the local calendar date; the trigger time is compared as `HHMM` local, not UTC. A DST skip at 02:00 does not affect a 19:30 trigger.

---

## Config errors

### S28 — Missing config file

`FATAL: config file not found: /etc/target_job/target_job.conf` → stderr → exit 1.

### S29 — `TRIGGER_HOUR=25`

`ERROR: TRIGGER_HOUR must be 0-23, got: '25'` → stderr → exit 1.

### S30 — `ANCHOR_DATE=2025/01/01`

`ERROR: ANCHOR_DATE must be YYYY-MM-DD, got: '2025/01/01'` → stderr → exit 1.

---

## Cross-implementation consistency

All three implementations must produce **identical** results for every scenario above. The test suites run the same table of cases against each implementation; any divergence is a bug.

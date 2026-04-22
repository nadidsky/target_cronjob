# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository status

Per [README.md](README.md), **the code here is AI-generated and not yet tested**. Treat behavior as specification, not verified fact. Do not assume prior runs have validated any path.

## What this project is

A single cron job — "run a report for every calendar date since the last successful run, after 19:30 on TARGET-open days" — implemented three times in three languages, each standalone and feature-equivalent. There is no shared library, no build system covering multiple languages, and no cross-implementation test suite. The three copies diverge in mechanism but must stay equivalent in behavior.

## Three parallel implementations

| Directory | Language | Config format | Dependencies |
|---|---|---|---|
| [src/posix_sh/](src/posix_sh/) | POSIX `/bin/sh` (1992+) — dash, ash, ksh, busybox, old Solaris/HP-UX/AIX | `target.conf` (sourced `KEY="VALUE"`) | `expr`, `cut`, `awk`, `tail`, `mkdir`, `rm` only |
| [src/bash/](src/bash/) | bash 3.2+ | `target.conf` (sourced `KEY="VALUE"`) | GNU `date -d`, `flock` |
| [src/go/](src/go/) | Go (stdlib only) | `config.json` | none — compiled binary |

When editing one implementation, check whether the same change needs to be mirrored in the other two. The `target.conf` files under `src/posix_sh/` and `src/bash/` are byte-identical today; the Go version uses JSON with snake_case keys for the same settings.

## The 4-gate architecture

All three implementations run cron-style every minute and use the same short-circuit sequence. Ticks that fail an early gate must produce **zero output** (no stdout, no log writes) — this is deliberate, to keep logs clean under 1440 ticks/day:

1. **Time gate** — exit if now < `TRIGGER_HOUR:TRIGGER_MINUTE` (default 19:30).
2. **Calendar gate** — exit if today is a TARGET closing day.
3. **State gate** — exit if today's date already appears in the success state file.
4. **Lock gate** — exit if another instance holds the lock.

Only after all four pass does the script initialize logging, build the date range, and invoke `JOB_COMMAND`. If any gate logic changes, the silence-before-logging invariant must be preserved.

## TARGET calendar rules (identical across all three)

Closing days: Saturday, Sunday, Jan 1, May 1, Dec 25, Dec 26, Good Friday, Easter Monday. Easter is computed via the Meeus/Jones/Butcher algorithm (valid Gregorian 1583+). If any of these rules change, update all three implementations and re-verify the Easter algorithm still matches the intended target year.

## Date arithmetic — the main cross-implementation divergence

- **POSIX sh**: no `date -d` available, so it implements date arithmetic via **Julian Day Numbers** (`date_to_jdn` / `jdn_to_date` in [target_job.sh](src/posix_sh/target_job.sh)). Weekday is derived from `JDN % 7`. Leading zeros in month/day are stripped with `expr` to avoid octal interpretation inside `$(( ))`.
- **bash**: delegates to GNU `date -d "$x + 1 day"`.
- **Go**: uses `time.Time.AddDate` in UTC.

When fixing a date bug, the fix almost always needs to land in all three places but will look different in each.

## Locking — also divergent

- **bash**: `flock` on fd 9 — released automatically on exit, no stale-lock risk.
- **POSIX sh** and **Go**: atomic `mkdir` of a lock directory, released by trap/`defer`. A crash before cleanup would leave a stale lock dir; current code does not detect or recover stale locks.

## State file format

`$RUN_DIR/target_job_success.log` — append-only text, one line per successful day:
```
YYYY-MM-DD  executed_at=YYYY-MM-DD HH:MM:SS
```
`get_last_success_date` / `getLastSuccessDate` reads the **last line** (`tail -1`). The date range builder starts at `last_success + 1` and ends at today (inclusive), so every calendar day — including TARGET closing days that were skipped — is passed to `JOB_COMMAND`. This is intentional: the cronjob handles scheduling, the downstream job handles per-date processing.

If the state file is empty or missing, `last_success` defaults to `ANCHOR_DATE − 1` so `ANCHOR_DATE` itself is included on first run.

## Running and testing

There is no build system, no test suite, no CI. Manual steps:

- **POSIX sh / bash**: `sh src/posix_sh/target_job.sh -c /path/to/target.conf` (same for bash variant with `-c`). Install paths and cron line are in the header comment of each script.
- **Go**: `go build -o target_job src/go/target_job.go`, then run with `-config /path/to/config.json`.

To exercise an implementation without waiting for 19:30 or a real TARGET-open day, edit the config to point `TRIGGER_HOUR`/`TRIGGER_MINUTE` at the current time and pick a `JOB_COMMAND` that just `echo`s its arguments. There is no mock of "today" — you can only test against the real system clock.

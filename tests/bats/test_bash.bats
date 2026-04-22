#!/usr/bin/env bats
# =============================================================================
# test_bash.bats — unit tests for src/bash/target_job.sh
# =============================================================================
# Run:  bats tests/bats/test_bash.bats
#
# Requires:  bash 3.2+, bats-core >= 1.7
#
# Edge cases covered:
#   - Easter dates and the boundary days around Easter week
#   - Christmas / Boxing Day cluster
#   - New Year's Day, May Day
#   - Cron field matching (all syntax variants)
#   - Cron window evaluation (exact, within tolerance, outside, DOW/month gates)
#   - Date range builder (normal, Easter backfill, Christmas backfill)
#   - State gate (already ran / not yet ran)
# =============================================================================

SCRIPT="${BATS_TEST_DIRNAME}/../../src/bash/target_job.sh"

# Source the script once — _SOURCED_FOR_TESTING suppresses main().
setup_file() {
    export _SOURCED_FOR_TESTING=1
    # shellcheck source=../../src/bash/target_job.sh
    source "$SCRIPT"
}

setup() {
    # Each test gets a fresh temp directory for state/log files.
    TEST_DIR="$(mktemp -d)"
    export ANCHOR_DATE="2025-01-01"
    export RUN_DIR="$TEST_DIR"
    export STATE_FILE="${TEST_DIR}/target_job_success.log"
    export LOG_FILE="${TEST_DIR}/target_job.log"
    export LOCK_FILE="${TEST_DIR}/target_job.lock"
    export JOB_COMMAND="echo"
    export MAX_LOG_SIZE=10485760
    export CRON_SCHEDULE="30 19 * * 1-5"
    export CRON_TOLERANCE=15
    # Clear cron/time test overrides
    unset _TEST_NOW_HOUR _TEST_NOW_MIN _TEST_NOW_DOM _TEST_NOW_MON _TEST_NOW_DOW
}

teardown() {
    rm -rf "$TEST_DIR"
}

# ===========================================================================
# easter_sunday
# ===========================================================================

@test "bash: easter_sunday 2025 = 2025-04-20" {
    result=$(easter_sunday 2025)
    [ "$result" = "2025-04-20" ]
}

@test "bash: easter_sunday 2026 = 2026-04-05" {
    result=$(easter_sunday 2026)
    [ "$result" = "2026-04-05" ]
}

@test "bash: easter_sunday 2024 = 2024-03-31" {
    result=$(easter_sunday 2024)
    [ "$result" = "2024-03-31" ]
}

@test "bash: easter_sunday 2019 = 2019-04-21" {
    result=$(easter_sunday 2019)
    [ "$result" = "2019-04-21" ]
}

# ===========================================================================
# is_target_closing_day — weekends
# ===========================================================================

@test "bash: Saturday is a closing day" {
    run is_target_closing_day "2025-04-19"
    [ "$status" -eq 0 ]
}

@test "bash: Sunday is a closing day" {
    run is_target_closing_day "2025-04-13"
    [ "$status" -eq 0 ]
}

@test "bash: Monday is open" {
    run is_target_closing_day "2025-04-14"
    [ "$status" -eq 1 ]
}

# ===========================================================================
# is_target_closing_day — fixed holidays
# ===========================================================================

@test "bash: New Year's Day 2025 (Wednesday) is closed" {
    run is_target_closing_day "2025-01-01"
    [ "$status" -eq 0 ]
}

@test "bash: Jan 2 2025 (Thursday) is open" {
    run is_target_closing_day "2025-01-02"
    [ "$status" -eq 1 ]
}

@test "bash: May Day 2025 (Thursday) is closed" {
    run is_target_closing_day "2025-05-01"
    [ "$status" -eq 0 ]
}

@test "bash: May 2 2025 (Friday) is open" {
    run is_target_closing_day "2025-05-02"
    [ "$status" -eq 1 ]
}

@test "bash: Christmas 2025 (Thursday) is closed" {
    run is_target_closing_day "2025-12-25"
    [ "$status" -eq 0 ]
}

@test "bash: Boxing Day 2025 (Friday) is closed" {
    run is_target_closing_day "2025-12-26"
    [ "$status" -eq 0 ]
}

@test "bash: Dec 27 2025 (Saturday) is closed — weekend" {
    run is_target_closing_day "2025-12-27"
    [ "$status" -eq 0 ]
}

@test "bash: Dec 28 2025 (Sunday) is closed — weekend" {
    run is_target_closing_day "2025-12-28"
    [ "$status" -eq 0 ]
}

@test "bash: Dec 29 2025 (Monday) is open — first day after Christmas cluster" {
    run is_target_closing_day "2025-12-29"
    [ "$status" -eq 1 ]
}

# ===========================================================================
# is_target_closing_day — Easter 2025 boundary (KEY EDGE CASES)
# Easter Sunday 2025 = April 20
# Good Friday = April 18, Easter Monday = April 21
# ===========================================================================

@test "bash: Maundy Thursday 2025 (Apr 17) is open" {
    run is_target_closing_day "2025-04-17"
    [ "$status" -eq 1 ]
}

@test "bash: Good Friday 2025 (Apr 18) is closed" {
    run is_target_closing_day "2025-04-18"
    [ "$status" -eq 0 ]
}

@test "bash: Holy Saturday 2025 (Apr 19) is closed — weekend" {
    run is_target_closing_day "2025-04-19"
    [ "$status" -eq 0 ]
}

@test "bash: Easter Sunday 2025 (Apr 20) is closed — Sunday" {
    run is_target_closing_day "2025-04-20"
    [ "$status" -eq 0 ]
}

@test "bash: Easter Monday 2025 (Apr 21) is closed" {
    run is_target_closing_day "2025-04-21"
    [ "$status" -eq 0 ]
}

@test "bash: Tuesday after Easter Monday 2025 (Apr 22) is OPEN" {
    run is_target_closing_day "2025-04-22"
    [ "$status" -eq 1 ]
}

@test "bash: Wednesday of Easter week 2025 (Apr 23) is OPEN" {
    run is_target_closing_day "2025-04-23"
    [ "$status" -eq 1 ]
}

# ===========================================================================
# is_target_closing_day — Easter 2026 (Good Friday Apr 3, Easter Mon Apr 6)
# ===========================================================================

@test "bash: Good Friday 2026 (Apr 3) is closed" {
    run is_target_closing_day "2026-04-03"
    [ "$status" -eq 0 ]
}

@test "bash: Easter Monday 2026 (Apr 6) is closed" {
    run is_target_closing_day "2026-04-06"
    [ "$status" -eq 0 ]
}

@test "bash: Tuesday after Easter Monday 2026 (Apr 7) is OPEN" {
    run is_target_closing_day "2026-04-07"
    [ "$status" -eq 1 ]
}

# ===========================================================================
# cron_field_matches
# ===========================================================================

@test "bash: cron_field_matches wildcard * matches anything" {
    run cron_field_matches "*" 42
    [ "$status" -eq 0 ]
}

@test "bash: cron_field_matches exact — hit" {
    run cron_field_matches "19" 19
    [ "$status" -eq 0 ]
}

@test "bash: cron_field_matches exact — miss" {
    run cron_field_matches "19" 20
    [ "$status" -eq 1 ]
}

@test "bash: cron_field_matches range 1-5 includes boundaries" {
    run cron_field_matches "1-5" 1
    [ "$status" -eq 0 ]
    run cron_field_matches "1-5" 5
    [ "$status" -eq 0 ]
}

@test "bash: cron_field_matches range 1-5 excludes outside" {
    run cron_field_matches "1-5" 0
    [ "$status" -eq 1 ]
    run cron_field_matches "1-5" 6
    [ "$status" -eq 1 ]
}

@test "bash: cron_field_matches step */15 matches 0,15,30,45" {
    run cron_field_matches "*/15" 0
    [ "$status" -eq 0 ]
    run cron_field_matches "*/15" 15
    [ "$status" -eq 0 ]
    run cron_field_matches "*/15" 30
    [ "$status" -eq 0 ]
    run cron_field_matches "*/15" 45
    [ "$status" -eq 0 ]
}

@test "bash: cron_field_matches step */15 misses 1,14,16" {
    run cron_field_matches "*/15" 1
    [ "$status" -eq 1 ]
    run cron_field_matches "*/15" 14
    [ "$status" -eq 1 ]
    run cron_field_matches "*/15" 16
    [ "$status" -eq 1 ]
}

@test "bash: cron_field_matches comma list 0,30" {
    run cron_field_matches "0,30" 0
    [ "$status" -eq 0 ]
    run cron_field_matches "0,30" 30
    [ "$status" -eq 0 ]
    run cron_field_matches "0,30" 15
    [ "$status" -eq 1 ]
}

@test "bash: cron_field_matches mixed list 1-5,10,15" {
    run cron_field_matches "1-5,10,15" 3
    [ "$status" -eq 0 ]
    run cron_field_matches "1-5,10,15" 10
    [ "$status" -eq 0 ]
    run cron_field_matches "1-5,10,15" 6
    [ "$status" -eq 1 ]
}

# ===========================================================================
# is_in_cron_window — time gate
# All tests use April 22 2025 (Tuesday: ISO dow=2, cron dow=2)
# ===========================================================================

@test "bash: cron window — exact hit at 19:30 with schedule '30 19 * * *'" {
    export _TEST_NOW_HOUR=19 _TEST_NOW_MIN=30
    export _TEST_NOW_DOM=22 _TEST_NOW_MON=4 _TEST_NOW_DOW=2
    CRON_SCHEDULE="30 19 * * *"; CRON_TOLERANCE=15
    run is_in_cron_window
    [ "$status" -eq 0 ]
}

@test "bash: cron window — within tolerance (19:44, schedule 19:30, tol 15)" {
    export _TEST_NOW_HOUR=19 _TEST_NOW_MIN=44
    export _TEST_NOW_DOM=22 _TEST_NOW_MON=4 _TEST_NOW_DOW=2
    CRON_SCHEDULE="30 19 * * *"; CRON_TOLERANCE=15
    run is_in_cron_window
    [ "$status" -eq 0 ]
}

@test "bash: cron window — at tolerance boundary (19:45, schedule 19:30, tol 15)" {
    export _TEST_NOW_HOUR=19 _TEST_NOW_MIN=45
    export _TEST_NOW_DOM=22 _TEST_NOW_MON=4 _TEST_NOW_DOW=2
    CRON_SCHEDULE="30 19 * * *"; CRON_TOLERANCE=15
    run is_in_cron_window
    [ "$status" -eq 0 ]
}

@test "bash: cron window — outside tolerance (19:46, schedule 19:30, tol 15)" {
    export _TEST_NOW_HOUR=19 _TEST_NOW_MIN=46
    export _TEST_NOW_DOM=22 _TEST_NOW_MON=4 _TEST_NOW_DOW=2
    CRON_SCHEDULE="30 19 * * *"; CRON_TOLERANCE=15
    run is_in_cron_window
    [ "$status" -eq 1 ]
}

@test "bash: cron window — before schedule (19:29, schedule 19:30, tol 15)" {
    export _TEST_NOW_HOUR=19 _TEST_NOW_MIN=29
    export _TEST_NOW_DOM=22 _TEST_NOW_MON=4 _TEST_NOW_DOW=2
    CRON_SCHEDULE="30 19 * * *"; CRON_TOLERANCE=15
    run is_in_cron_window
    [ "$status" -eq 1 ]
}

@test "bash: cron window — zero tolerance, exact minute fires" {
    export _TEST_NOW_HOUR=19 _TEST_NOW_MIN=30
    export _TEST_NOW_DOM=22 _TEST_NOW_MON=4 _TEST_NOW_DOW=2
    CRON_SCHEDULE="30 19 * * *"; CRON_TOLERANCE=0
    run is_in_cron_window
    [ "$status" -eq 0 ]
}

@test "bash: cron window — zero tolerance, next minute does NOT fire" {
    export _TEST_NOW_HOUR=19 _TEST_NOW_MIN=31
    export _TEST_NOW_DOM=22 _TEST_NOW_MON=4 _TEST_NOW_DOW=2
    CRON_SCHEDULE="30 19 * * *"; CRON_TOLERANCE=0
    run is_in_cron_window
    [ "$status" -eq 1 ]
}

@test "bash: cron window — */15 schedule, 00:16 with tol 5 fires (00:15 in window)" {
    export _TEST_NOW_HOUR=0 _TEST_NOW_MIN=16
    export _TEST_NOW_DOM=22 _TEST_NOW_MON=4 _TEST_NOW_DOW=2
    CRON_SCHEDULE="*/15 * * * *"; CRON_TOLERANCE=5
    run is_in_cron_window
    [ "$status" -eq 0 ]
}

@test "bash: cron window — DOW filter: Saturday blocked with '30 19 * * 1-5'" {
    # Saturday: ISO dow=6, cron dow=6
    export _TEST_NOW_HOUR=19 _TEST_NOW_MIN=30
    export _TEST_NOW_DOM=19 _TEST_NOW_MON=4 _TEST_NOW_DOW=6
    CRON_SCHEDULE="30 19 * * 1-5"; CRON_TOLERANCE=15
    run is_in_cron_window
    [ "$status" -eq 1 ]
}

@test "bash: cron window — DOW filter: Tuesday passes with '30 19 * * 1-5'" {
    export _TEST_NOW_HOUR=19 _TEST_NOW_MIN=30
    export _TEST_NOW_DOM=22 _TEST_NOW_MON=4 _TEST_NOW_DOW=2
    CRON_SCHEDULE="30 19 * * 1-5"; CRON_TOLERANCE=15
    run is_in_cron_window
    [ "$status" -eq 0 ]
}

# ===========================================================================
# get_report_dates — date range builder
# ===========================================================================

@test "bash: date range — first run from anchor date" {
    # No state file → should produce just the anchor date
    ANCHOR_DATE="2025-04-22"
    result=$(get_report_dates "2025-04-22")
    [ "$result" = "2025-04-22" ]
}

@test "bash: date range — Easter week backfill (Thu Apr 17 → Tue Apr 22 = 5 dates)" {
    # Last success Apr 17; today Apr 22 → dates: Apr 18,19,20,21,22
    echo "2025-04-17  executed_at=2025-04-17 19:30:00" > "$STATE_FILE"
    result=$(get_report_dates "2025-04-22")
    expected="2025-04-18
2025-04-19
2025-04-20
2025-04-21
2025-04-22"
    [ "$result" = "$expected" ]
}

@test "bash: date range — Christmas cluster backfill (Wed Dec 24 → Mon Dec 29 = 5 dates)" {
    # Last success Dec 24; today Dec 29 → dates: Dec 25,26,27,28,29
    echo "2025-12-24  executed_at=2025-12-24 19:30:00" > "$STATE_FILE"
    result=$(get_report_dates "2025-12-29")
    expected="2025-12-25
2025-12-26
2025-12-27
2025-12-28
2025-12-29"
    [ "$result" = "$expected" ]
}

@test "bash: date range — same day (already ran yesterday, running today = 1 date)" {
    echo "2025-04-21  executed_at=2025-04-21 19:30:00" > "$STATE_FILE"
    result=$(get_report_dates "2025-04-22")
    [ "$result" = "2025-04-22" ]
}

# ===========================================================================
# has_run_successfully_today
# ===========================================================================

@test "bash: has_run_successfully_today — false when no state file" {
    run has_run_successfully_today "2025-04-22"
    [ "$status" -eq 1 ]
}

@test "bash: has_run_successfully_today — true after writing today" {
    echo "2025-04-22  executed_at=2025-04-22 19:30:05" > "$STATE_FILE"
    run has_run_successfully_today "2025-04-22"
    [ "$status" -eq 0 ]
}

@test "bash: has_run_successfully_today — false for different date" {
    echo "2025-04-21  executed_at=2025-04-21 19:30:05" > "$STATE_FILE"
    run has_run_successfully_today "2025-04-22"
    [ "$status" -eq 1 ]
}

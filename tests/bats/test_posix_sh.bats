#!/usr/bin/env bats
# =============================================================================
# test_posix_sh.bats — unit tests for src/posix_sh/target_job.sh
# =============================================================================
# Run:  bats tests/bats/test_posix_sh.bats
#
# Requires:  bats-core >= 1.7 (runs with dash/sh on CI)
#
# Tests the POSIX sh implementation independently — it uses JDN arithmetic
# instead of date -d, so we verify both the calendar logic AND the arithmetic.
# =============================================================================

SCRIPT="${BATS_TEST_DIRNAME}/../../src/posix_sh/target_job.sh"

setup_file() {
    export _SOURCED_FOR_TESTING=1
    # shellcheck source=../../src/posix_sh/target_job.sh
    . "$SCRIPT"
}

setup() {
    TEST_DIR="$(mktemp -d)"
    export ANCHOR_DATE="2025-01-01"
    export RUN_DIR="$TEST_DIR"
    export STATE_FILE="${TEST_DIR}/target_job_success.log"
    export LOG_FILE="${TEST_DIR}/target_job.log"
    export LOCK_DIR="${TEST_DIR}/target_job.lock"
    export DATES_FILE="/tmp/target_job_dates_bats_$$"
    export JOB_COMMAND="echo"
    export MAX_LOG_SIZE=10485760
    export CRON_SCHEDULE="30 19 * * 1-5"
    export CRON_TOLERANCE=15
    unset _TEST_NOW_HOUR _TEST_NOW_MIN _TEST_NOW_DOM _TEST_NOW_MON _TEST_NOW_DOW
}

teardown() {
    rm -rf "$TEST_DIR"
    rm -f "$DATES_FILE"
}

# ===========================================================================
# JDN arithmetic — verify date_to_jdn / jdn_to_date roundtrip
# ===========================================================================

@test "posix_sh: JDN roundtrip — 2025-01-01" {
    jdn=$(date_to_jdn 2025 1 1)
    result=$(jdn_to_date "$jdn")
    [ "$result" = "2025-01-01" ]
}

@test "posix_sh: JDN roundtrip — 2025-12-31" {
    jdn=$(date_to_jdn 2025 12 31)
    result=$(jdn_to_date "$jdn")
    [ "$result" = "2025-12-31" ]
}

@test "posix_sh: JDN roundtrip — 2000-02-29 (leap year)" {
    jdn=$(date_to_jdn 2000 2 29)
    result=$(jdn_to_date "$jdn")
    [ "$result" = "2000-02-29" ]
}

@test "posix_sh: JDN weekday — 2025-04-21 is Monday (JDN%7==0)" {
    jdn=$(date_to_jdn 2025 4 21)
    weekday=$(( jdn % 7 ))
    # 0=Mon, 1=Tue, ..., 4=Fri, 5=Sat, 6=Sun in the JDN%7 system
    [ "$weekday" -eq 0 ]
}

@test "posix_sh: JDN weekday — 2025-04-19 is Saturday (JDN%7==5)" {
    jdn=$(date_to_jdn 2025 4 19)
    weekday=$(( jdn % 7 ))
    [ "$weekday" -eq 5 ]
}

@test "posix_sh: JDN weekday — 2025-04-20 is Sunday (JDN%7==6)" {
    jdn=$(date_to_jdn 2025 4 20)
    weekday=$(( jdn % 7 ))
    [ "$weekday" -eq 6 ]
}

# ===========================================================================
# easter_sunday
# ===========================================================================

@test "posix_sh: easter_sunday 2025 = 2025-04-20" {
    result=$(easter_sunday 2025)
    [ "$result" = "2025-04-20" ]
}

@test "posix_sh: easter_sunday 2026 = 2026-04-05" {
    result=$(easter_sunday 2026)
    [ "$result" = "2026-04-05" ]
}

@test "posix_sh: easter_sunday 2024 = 2024-03-31" {
    result=$(easter_sunday 2024)
    [ "$result" = "2024-03-31" ]
}

@test "posix_sh: easter_sunday 2019 = 2019-04-21" {
    result=$(easter_sunday 2019)
    [ "$result" = "2019-04-21" ]
}

# ===========================================================================
# is_target_closing_day — weekends
# ===========================================================================

@test "posix_sh: Saturday is a closing day" {
    run is_target_closing_day "2025-04-19"
    [ "$status" -eq 0 ]
}

@test "posix_sh: Sunday is a closing day" {
    run is_target_closing_day "2025-04-20"
    [ "$status" -eq 0 ]
}

@test "posix_sh: Monday is open" {
    run is_target_closing_day "2025-04-14"
    [ "$status" -eq 1 ]
}

@test "posix_sh: Friday is open" {
    run is_target_closing_day "2025-04-25"
    [ "$status" -eq 1 ]
}

# ===========================================================================
# is_target_closing_day — fixed holidays
# ===========================================================================

@test "posix_sh: New Year's Day 2025 is closed" {
    run is_target_closing_day "2025-01-01"
    [ "$status" -eq 0 ]
}

@test "posix_sh: Jan 2 2025 is open" {
    run is_target_closing_day "2025-01-02"
    [ "$status" -eq 1 ]
}

@test "posix_sh: May Day 2025 (Thursday) is closed" {
    run is_target_closing_day "2025-05-01"
    [ "$status" -eq 0 ]
}

@test "posix_sh: May 2 2025 is open" {
    run is_target_closing_day "2025-05-02"
    [ "$status" -eq 1 ]
}

@test "posix_sh: Christmas 2025 (Thursday) is closed" {
    run is_target_closing_day "2025-12-25"
    [ "$status" -eq 0 ]
}

@test "posix_sh: Boxing Day 2025 (Friday) is closed" {
    run is_target_closing_day "2025-12-26"
    [ "$status" -eq 0 ]
}

@test "posix_sh: Dec 27 2025 (Saturday) is closed — weekend" {
    run is_target_closing_day "2025-12-27"
    [ "$status" -eq 0 ]
}

@test "posix_sh: Dec 29 2025 (Monday) is open — first after Christmas cluster" {
    run is_target_closing_day "2025-12-29"
    [ "$status" -eq 1 ]
}

# ===========================================================================
# is_target_closing_day — Easter 2025 (KEY EDGE CASES)
# Easter Sunday = Apr 20, Good Friday = Apr 18, Easter Monday = Apr 21
# ===========================================================================

@test "posix_sh: Maundy Thursday 2025 (Apr 17) is open" {
    run is_target_closing_day "2025-04-17"
    [ "$status" -eq 1 ]
}

@test "posix_sh: Good Friday 2025 (Apr 18) is closed" {
    run is_target_closing_day "2025-04-18"
    [ "$status" -eq 0 ]
}

@test "posix_sh: Holy Saturday 2025 (Apr 19) is closed — weekend" {
    run is_target_closing_day "2025-04-19"
    [ "$status" -eq 0 ]
}

@test "posix_sh: Easter Sunday 2025 (Apr 20) is closed — Sunday" {
    run is_target_closing_day "2025-04-20"
    [ "$status" -eq 0 ]
}

@test "posix_sh: Easter Monday 2025 (Apr 21) is closed" {
    run is_target_closing_day "2025-04-21"
    [ "$status" -eq 0 ]
}

@test "posix_sh: Tuesday after Easter Monday 2025 (Apr 22) is OPEN" {
    run is_target_closing_day "2025-04-22"
    [ "$status" -eq 1 ]
}

@test "posix_sh: Wednesday of Easter week 2025 (Apr 23) is OPEN" {
    run is_target_closing_day "2025-04-23"
    [ "$status" -eq 1 ]
}

# ===========================================================================
# is_target_closing_day — Easter 2026
# Easter Sunday = Apr 5, Good Friday = Apr 3, Easter Monday = Apr 6
# ===========================================================================

@test "posix_sh: Good Friday 2026 (Apr 3) is closed" {
    run is_target_closing_day "2026-04-03"
    [ "$status" -eq 0 ]
}

@test "posix_sh: Easter Monday 2026 (Apr 6) is closed" {
    run is_target_closing_day "2026-04-06"
    [ "$status" -eq 0 ]
}

@test "posix_sh: Tuesday after Easter Monday 2026 (Apr 7) is OPEN" {
    run is_target_closing_day "2026-04-07"
    [ "$status" -eq 1 ]
}

# ===========================================================================
# cron_field_matches
# ===========================================================================

@test "posix_sh: cron_field_matches * matches any value" {
    run cron_field_matches "*" 59
    [ "$status" -eq 0 ]
    run cron_field_matches "*" 0
    [ "$status" -eq 0 ]
}

@test "posix_sh: cron_field_matches exact value" {
    run cron_field_matches "30" 30
    [ "$status" -eq 0 ]
    run cron_field_matches "30" 31
    [ "$status" -eq 1 ]
}

@test "posix_sh: cron_field_matches range 1-5" {
    run cron_field_matches "1-5" 1; [ "$status" -eq 0 ]
    run cron_field_matches "1-5" 5; [ "$status" -eq 0 ]
    run cron_field_matches "1-5" 3; [ "$status" -eq 0 ]
    run cron_field_matches "1-5" 0; [ "$status" -eq 1 ]
    run cron_field_matches "1-5" 6; [ "$status" -eq 1 ]
}

@test "posix_sh: cron_field_matches step */15" {
    run cron_field_matches "*/15" 0;  [ "$status" -eq 0 ]
    run cron_field_matches "*/15" 15; [ "$status" -eq 0 ]
    run cron_field_matches "*/15" 30; [ "$status" -eq 0 ]
    run cron_field_matches "*/15" 45; [ "$status" -eq 0 ]
    run cron_field_matches "*/15" 1;  [ "$status" -eq 1 ]
    run cron_field_matches "*/15" 16; [ "$status" -eq 1 ]
}

@test "posix_sh: cron_field_matches comma list 0,30" {
    run cron_field_matches "0,30" 0;  [ "$status" -eq 0 ]
    run cron_field_matches "0,30" 30; [ "$status" -eq 0 ]
    run cron_field_matches "0,30" 15; [ "$status" -eq 1 ]
}

@test "posix_sh: cron_field_matches mixed list 1-5,10,15" {
    run cron_field_matches "1-5,10,15" 3;  [ "$status" -eq 0 ]
    run cron_field_matches "1-5,10,15" 10; [ "$status" -eq 0 ]
    run cron_field_matches "1-5,10,15" 6;  [ "$status" -eq 1 ]
    run cron_field_matches "1-5,10,15" 11; [ "$status" -eq 1 ]
}

# ===========================================================================
# is_in_cron_window — time gate
# Apr 22 2025 = Tuesday; cron DOW = 2 (1=Mon, 2=Tue)
# ===========================================================================

@test "posix_sh: cron window — exact hit at 19:30 with '30 19 * * *' tol=15" {
    export _TEST_NOW_HOUR=19 _TEST_NOW_MIN=30
    export _TEST_NOW_DOM=22 _TEST_NOW_MON=4 _TEST_NOW_DOW=2
    CRON_SCHEDULE="30 19 * * *"; CRON_TOLERANCE=15
    run is_in_cron_window
    [ "$status" -eq 0 ]
}

@test "posix_sh: cron window — within tolerance (19:44, tol=15)" {
    export _TEST_NOW_HOUR=19 _TEST_NOW_MIN=44
    export _TEST_NOW_DOM=22 _TEST_NOW_MON=4 _TEST_NOW_DOW=2
    CRON_SCHEDULE="30 19 * * *"; CRON_TOLERANCE=15
    run is_in_cron_window
    [ "$status" -eq 0 ]
}

@test "posix_sh: cron window — at boundary (19:45, tol=15)" {
    export _TEST_NOW_HOUR=19 _TEST_NOW_MIN=45
    export _TEST_NOW_DOM=22 _TEST_NOW_MON=4 _TEST_NOW_DOW=2
    CRON_SCHEDULE="30 19 * * *"; CRON_TOLERANCE=15
    run is_in_cron_window
    [ "$status" -eq 0 ]
}

@test "posix_sh: cron window — outside tolerance (19:46, tol=15)" {
    export _TEST_NOW_HOUR=19 _TEST_NOW_MIN=46
    export _TEST_NOW_DOM=22 _TEST_NOW_MON=4 _TEST_NOW_DOW=2
    CRON_SCHEDULE="30 19 * * *"; CRON_TOLERANCE=15
    run is_in_cron_window
    [ "$status" -eq 1 ]
}

@test "posix_sh: cron window — before schedule (19:29, tol=15)" {
    export _TEST_NOW_HOUR=19 _TEST_NOW_MIN=29
    export _TEST_NOW_DOM=22 _TEST_NOW_MON=4 _TEST_NOW_DOW=2
    CRON_SCHEDULE="30 19 * * *"; CRON_TOLERANCE=15
    run is_in_cron_window
    [ "$status" -eq 1 ]
}

@test "posix_sh: cron window — zero tolerance, exact minute fires" {
    export _TEST_NOW_HOUR=19 _TEST_NOW_MIN=30
    export _TEST_NOW_DOM=22 _TEST_NOW_MON=4 _TEST_NOW_DOW=2
    CRON_SCHEDULE="30 19 * * *"; CRON_TOLERANCE=0
    run is_in_cron_window
    [ "$status" -eq 0 ]
}

@test "posix_sh: cron window — zero tolerance, next minute does NOT fire" {
    export _TEST_NOW_HOUR=19 _TEST_NOW_MIN=31
    export _TEST_NOW_DOM=22 _TEST_NOW_MON=4 _TEST_NOW_DOW=2
    CRON_SCHEDULE="30 19 * * *"; CRON_TOLERANCE=0
    run is_in_cron_window
    [ "$status" -eq 1 ]
}

@test "posix_sh: cron window — */15 step, 00:16 with tol=5 fires (00:15 in window)" {
    export _TEST_NOW_HOUR=0 _TEST_NOW_MIN=16
    export _TEST_NOW_DOM=22 _TEST_NOW_MON=4 _TEST_NOW_DOW=2
    CRON_SCHEDULE="*/15 * * * *"; CRON_TOLERANCE=5
    run is_in_cron_window
    [ "$status" -eq 0 ]
}

@test "posix_sh: cron window — DOW filter: Saturday blocked with '30 19 * * 1-5'" {
    # Saturday: cron DOW = 6
    export _TEST_NOW_HOUR=19 _TEST_NOW_MIN=30
    export _TEST_NOW_DOM=19 _TEST_NOW_MON=4 _TEST_NOW_DOW=6
    CRON_SCHEDULE="30 19 * * 1-5"; CRON_TOLERANCE=15
    run is_in_cron_window
    [ "$status" -eq 1 ]
}

@test "posix_sh: cron window — DOW filter: Sunday (DOW=0) blocked with '30 19 * * 1-5'" {
    export _TEST_NOW_HOUR=19 _TEST_NOW_MIN=30
    export _TEST_NOW_DOM=20 _TEST_NOW_MON=4 _TEST_NOW_DOW=0
    CRON_SCHEDULE="30 19 * * 1-5"; CRON_TOLERANCE=15
    run is_in_cron_window
    [ "$status" -eq 1 ]
}

@test "posix_sh: cron window — DOW filter: Tuesday passes with '30 19 * * 1-5'" {
    export _TEST_NOW_HOUR=19 _TEST_NOW_MIN=30
    export _TEST_NOW_DOM=22 _TEST_NOW_MON=4 _TEST_NOW_DOW=2
    CRON_SCHEDULE="30 19 * * 1-5"; CRON_TOLERANCE=15
    run is_in_cron_window
    [ "$status" -eq 0 ]
}

# ===========================================================================
# get_report_dates — date range builder
# ===========================================================================

@test "posix_sh: date range — first run from anchor date" {
    ANCHOR_DATE="2025-04-22"
    get_report_dates "2025-04-22"
    result=$(cat "$DATES_FILE")
    [ "$result" = "2025-04-22" ]
}

@test "posix_sh: date range — Easter week backfill (Apr 17 last → Apr 22 today)" {
    # Dates: Apr 18, 19, 20, 21, 22
    echo "2025-04-17  executed_at=2025-04-17 19:30:00" > "$STATE_FILE"
    get_report_dates "2025-04-22"
    result=$(cat "$DATES_FILE")
    expected="2025-04-18
2025-04-19
2025-04-20
2025-04-21
2025-04-22"
    [ "$result" = "$expected" ]
}

@test "posix_sh: date range — Christmas backfill (Dec 24 last → Dec 29 today)" {
    echo "2025-12-24  executed_at=2025-12-24 19:30:00" > "$STATE_FILE"
    get_report_dates "2025-12-29"
    result=$(cat "$DATES_FILE")
    expected="2025-12-25
2025-12-26
2025-12-27
2025-12-28
2025-12-29"
    [ "$result" = "$expected" ]
}

@test "posix_sh: date range — single day (yesterday last → today)" {
    echo "2025-04-21  executed_at=2025-04-21 19:30:00" > "$STATE_FILE"
    get_report_dates "2025-04-22"
    result=$(cat "$DATES_FILE")
    [ "$result" = "2025-04-22" ]
}

# ===========================================================================
# has_run_successfully_today
# ===========================================================================

@test "posix_sh: has_run_successfully_today — false with no state file" {
    run has_run_successfully_today "2025-04-22"
    [ "$status" -eq 1 ]
}

@test "posix_sh: has_run_successfully_today — true after writing today" {
    echo "2025-04-22  executed_at=2025-04-22 19:30:05" > "$STATE_FILE"
    run has_run_successfully_today "2025-04-22"
    [ "$status" -eq 0 ]
}

@test "posix_sh: has_run_successfully_today — false for different date" {
    echo "2025-04-21  executed_at=2025-04-21 19:30:05" > "$STATE_FILE"
    run has_run_successfully_today "2025-04-22"
    [ "$status" -eq 1 ]
}

#!/bin/bash
# =============================================================================
# target_job_bash.sh — TARGET Closing Days Report Runner  (bash version)
# =============================================================================
#
# A cron job (every minute) that, after a configurable time on TARGET open days,
# runs a report job covering all calendar dates since the last successful run —
# automatically backfilling weekends, holidays, and failed days.
# Silent on most ticks; single-instance locked; retries until success is recorded.
#
# REQUIRES: bash 3.2+, GNU coreutils (date -d), util-linux (flock)
# For old Unix without these, use target_job_sh.sh instead.
#
# USAGE:
#   target_job_bash.sh [-c /path/to/config]
#
# CONFIG FILE (default: /etc/target_job/target_job.conf):
#   Standard KEY="VALUE" shell file, sourced at startup.
#   Edit the config file and wait for the next cron tick — no restart needed.
#
# INSTALL:
#   sudo cp target_job_bash.sh /usr/local/bin/target_job_bash.sh
#   sudo chmod +x /usr/local/bin/target_job_bash.sh
#   sudo mkdir -p /etc/target_job /var/lib/target_job
#   sudo cp target_job.conf /etc/target_job/target_job.conf   # then edit it
#   crontab -e  →  add:  * * * * * /usr/local/bin/target_job_bash.sh
#
# =============================================================================


# =============================================================================
# CONFIG FILE LOADING
# =============================================================================

DEFAULT_CONFIG="/etc/target_job/target_job.conf"

# parse_args
# Reads -c <config_path> from command-line arguments.
# Sets CONFIG_FILE to the provided path or the default.
parse_args() {
    CONFIG_FILE="$DEFAULT_CONFIG"
    while getopts "c:" opt; do
        case "$opt" in
            c) CONFIG_FILE="$OPTARG" ;;
            *) echo "Usage: $0 [-c config_file]" >&2; exit 1 ;;
        esac
    done
}

# load_config
# Sources CONFIG_FILE into the current shell, making all KEY=VALUE pairs
# available as variables. Exits with a clear error if the file is missing.
load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "FATAL: config file not found: $CONFIG_FILE" >&2
        exit 1
    fi
    # shellcheck source=/dev/null
    . "$CONFIG_FILE" || {
        echo "FATAL: failed to source config file: $CONFIG_FILE" >&2
        exit 1
    }
}

# validate_config
# Checks that all required variables are present and sensible after sourcing.
validate_config() {
    local errors=0

    if [ -z "$JOB_COMMAND" ]; then
        echo "ERROR: JOB_COMMAND must not be empty" >&2;   errors=1
    fi
    local cron_nf
    cron_nf=$(awk '{print NF}' <<< "$CRON_SCHEDULE")
    if [[ ! "$cron_nf" =~ ^[0-9]+$ ]] || [ "$cron_nf" -ne 5 ]; then
        echo "ERROR: CRON_SCHEDULE must have 5 fields (min hr dom mon dow), got ${cron_nf}: '${CRON_SCHEDULE}'" >&2
        errors=1
    fi
    if ! [[ "$CRON_TOLERANCE" =~ ^[0-9]+$ ]]; then
        echo "ERROR: CRON_TOLERANCE must be a non-negative integer (minutes), got: '${CRON_TOLERANCE}'" >&2
        errors=1
    fi
    if ! date -d "$ANCHOR_DATE" +%Y-%m-%d > /dev/null 2>&1; then
        echo "ERROR: ANCHOR_DATE must be YYYY-MM-DD, got: '${ANCHOR_DATE}'" >&2; errors=1
    fi
    if [ -z "$RUN_DIR" ]; then
        echo "ERROR: RUN_DIR must not be empty" >&2;       errors=1
    fi
    if ! [[ "$MAX_LOG_SIZE" =~ ^[0-9]+$ ]] || [ "$MAX_LOG_SIZE" -le 0 ]; then
        echo "ERROR: MAX_LOG_SIZE must be a positive integer, got: '${MAX_LOG_SIZE}'" >&2
        errors=1
    fi

    if [ "$errors" -ne 0 ]; then
        echo "FATAL: fix the above errors in $CONFIG_FILE" >&2
        exit 1
    fi
}


# =============================================================================
# RUNTIME PATHS — derived from RUN_DIR (set after config is loaded)
# =============================================================================

# init_paths sets path variables that depend on RUN_DIR.
# Called after load_config so RUN_DIR is guaranteed to be set.
init_paths() {
    LOCK_FILE="${RUN_DIR}/target_job.lock"
    STATE_FILE="${RUN_DIR}/target_job_success.log"
    LOG_FILE="${RUN_DIR}/target_job.log"
}


# =============================================================================
# LOGGING
# =============================================================================

# log LEVEL MESSAGE
# Appends a timestamped line to LOG_FILE and echoes it to stdout.
# Only called when the job is actually going to run — silent exits produce
# no log output, avoiding noise from the every-minute cron.
log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    local line="[$timestamp] [$level] $message"
    echo "$line"
    echo "$line" >> "$LOG_FILE"
}

# rotate_log_if_needed
# Rotates LOG_FILE to LOG_FILE.1 if it exceeds MAX_LOG_SIZE bytes.
rotate_log_if_needed() {
    if [ -f "$LOG_FILE" ]; then
        local size
        size=$(wc -c < "$LOG_FILE")
        if [ "$size" -gt "$MAX_LOG_SIZE" ]; then
            mv "$LOG_FILE" "${LOG_FILE}.1"
            log "INFO" "Log rotated (exceeded ${MAX_LOG_SIZE} bytes)"
        fi
    fi
}


# =============================================================================
# LOCK — ensures only one instance runs at a time
# =============================================================================
# Uses flock on a file descriptor — lock is released automatically on exit,
# even on crashes. No stale lock cleanup needed.

# acquire_lock
# Opens fd 9 on LOCK_FILE and applies an exclusive non-blocking flock.
# Exits silently if the lock is already held by another instance.
acquire_lock() {
    exec 9>"$LOCK_FILE"
    if ! flock --nonblock 9; then
        exit 0  # another instance is running — silent exit
    fi
    log "INFO" "Lock acquired (PID $$)"
}


# =============================================================================
# EASTER / TARGET CALENDAR LOGIC
# =============================================================================

# easter_sunday YEAR
# Prints Easter Sunday as YYYY-MM-DD using the Meeus/Jones/Butcher algorithm.
# Valid for all Gregorian calendar years (1583+).
easter_sunday() {
    local Y=$1
    local a=$((Y % 19))
    local b=$((Y / 100))
    local c=$((Y % 100))
    local d=$((b / 4))
    local e=$((b % 4))
    local f=$(((b + 8) / 25))
    local g=$(((b - f + 1) / 3))
    local h=$(((19*a + b - d - g + 15) % 30))
    local i=$((c / 4))
    local k=$((c % 4))
    local l=$(((32 + 2*e + 2*i - h - k) % 7))
    local m=$(((a + 11*h + 22*l) / 451))
    local month=$(((h + l - 7*m + 114) / 31))
    local day=$(((h + l - 7*m + 114) % 31 + 1))
    printf "%04d-%02d-%02d" "$Y" "$month" "$day"
}

# is_target_closing_day DATE (YYYY-MM-DD)
# Returns 0 (true) if the date is a TARGET closing day, 1 (false) if open.
# Closing days: Sat, Sun, Jan 1, May 1, Dec 25, Dec 26, Good Friday, Easter Monday.
is_target_closing_day() {
    local input_date="$1"
    local year="${input_date:0:4}"
    local month=$((10#${input_date:5:2}))
    local day=$((10#${input_date:8:2}))

    # Weekend (5=Saturday, 6=Sunday)
    local weekday
    weekday=$(date -d "$input_date" +%u)
    if [ "$weekday" -ge 6 ]; then
        return 0
    fi

    # Fixed public holidays
    if { [ "$month" -eq 1  ] && [ "$day" -eq 1  ]; } ||
       { [ "$month" -eq 5  ] && [ "$day" -eq 1  ]; } ||
       { [ "$month" -eq 12 ] && [ "$day" -eq 25 ]; } ||
       { [ "$month" -eq 12 ] && [ "$day" -eq 26 ]; }; then
        return 0
    fi

    # Moving holidays
    local easter
    easter=$(easter_sunday "$year")
    local good_friday
    good_friday=$(date -d "$easter - 2 days" +%Y-%m-%d)
    local easter_monday
    easter_monday=$(date -d "$easter + 1 day" +%Y-%m-%d)

    if [ "$input_date" = "$good_friday" ] || [ "$input_date" = "$easter_monday" ]; then
        return 0
    fi

    return 1
}


# =============================================================================
# STATE — track which TARGET open days have been successfully processed
# =============================================================================

# get_last_success_date
# Prints the most recently recorded success date from STATE_FILE.
# If STATE_FILE is empty or missing, prints (ANCHOR_DATE - 1 day) so that
# ANCHOR_DATE itself is included on the first ever run.
get_last_success_date() {
    if [ -f "$STATE_FILE" ] && [ -s "$STATE_FILE" ]; then
        tail -1 "$STATE_FILE" | cut -d' ' -f1
    else
        date -d "$ANCHOR_DATE - 1 day" +%Y-%m-%d
    fi
}

# has_run_successfully_today DATE
# Returns 0 if DATE appears in STATE_FILE, 1 otherwise.
has_run_successfully_today() {
    if [ -f "$STATE_FILE" ] && grep -qF "$1" "$STATE_FILE"; then
        return 0
    fi
    return 1
}

# record_success DATE
# Appends DATE with an execution timestamp to STATE_FILE.
record_success() {
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "$1  executed_at=$timestamp" >> "$STATE_FILE"
}


# =============================================================================
# DATE RANGE BUILDER
# =============================================================================

# get_report_dates TODAY_DATE
# Prints every calendar date from (last_success + 1 day) up to and including
# TODAY_DATE, in chronological order (one date per line).
get_report_dates() {
    local today="$1"
    local last_success
    last_success=$(get_last_success_date)

    local current
    current=$(date -d "$last_success + 1 day" +%Y-%m-%d)

    while [[ ! "$current" > "$today" ]]; do
        echo "$current"
        current=$(date -d "$current + 1 day" +%Y-%m-%d)
    done
}


# =============================================================================
# CLEANUP — registered via trap, always runs on exit
# =============================================================================

cleanup() {
    # flock releases automatically when fd 9 is closed on exit.
    # Nothing extra needed — included for future extensibility.
    :
}


# =============================================================================
# CRON SCHEDULE EVALUATION
# =============================================================================
# Implements a 5-field cron expression evaluator used by the time gate.
# Format:  MINUTE  HOUR  DOM  MONTH  DOW
#   *        any value
#   n        exact integer
#   n-m      inclusive range
#   */n      every n-th step starting from 0  (e.g. */15 → 0,15,30,45)
#   a,b,...  comma-separated list of the above
# DOW: 0=Sun, 1=Mon, …, 6=Sat (7=Sun is also accepted as an alias).

# cron_field_matches FIELD VALUE
# Returns 0 if VALUE matches the cron FIELD expression, 1 otherwise.
cron_field_matches() {
    local field="$1" value="$2"
    [[ "$field" == "*" ]] && return 0
    local part
    while IFS= read -r -d ',' part; do
        [[ -z "$part" ]] && continue
        if [[ "$part" == */* ]]; then
            # Step: */n
            local n="${part#*/}"
            (( value % n == 0 )) && return 0
        elif [[ "$part" == *-* ]]; then
            # Range: lo-hi
            local lo="${part%-*}" hi="${part#*-}"
            (( value >= lo && value <= hi )) && return 0
        else
            # Exact
            (( value == part )) 2>/dev/null && return 0
        fi
    done <<< "${field},"
    return 1
}

# is_in_cron_window
# Returns 0 if "now" falls within a CRON_SCHEDULE trigger window.
# A trigger window covers [T, T + CRON_TOLERANCE] for every scheduled time T
# that also matches today's dom/month/dow fields.
#
# Test-time overrides (optional env vars):
#   _TEST_NOW_HOUR  _TEST_NOW_MIN  _TEST_NOW_DOM  _TEST_NOW_MON  _TEST_NOW_DOW
# DOW is cron-style: 0=Sun, 1=Mon, …, 6=Sat.
is_in_cron_window() {
    local min_f hr_f dom_f mon_f dow_f
    read -r min_f hr_f dom_f mon_f dow_f <<< "$CRON_SCHEDULE"

    # Current time/date — accept test overrides
    local cur_min cur_hr cur_dom cur_mon cur_dow cur_dow_alt
    cur_min=${_TEST_NOW_MIN:-$(date +%-M)}
    cur_hr=${_TEST_NOW_HOUR:-$(date +%-H)}
    cur_dom=${_TEST_NOW_DOM:-$(date +%-d)}
    cur_mon=${_TEST_NOW_MON:-$(date +%-m)}

    if [[ -n "${_TEST_NOW_DOW+set}" ]]; then
        cur_dow="$_TEST_NOW_DOW"                           # already cron-style
        cur_dow_alt=$(( cur_dow == 0 ? 7 : cur_dow ))      # ISO alt (7=Sun)
    else
        local iso_dow
        iso_dow=$(date +%u)   # 1=Mon..7=Sun
        cur_dow=$(( iso_dow == 7 ? 0 : iso_dow ))
        cur_dow_alt="$iso_dow"
    fi

    # Month gate
    cron_field_matches "$mon_f" "$cur_mon" || return 1

    # DOM / DOW gate (OR when both are restricted, vixie-cron semantics)
    if [[ "$dom_f" == "*" && "$dow_f" == "*" ]]; then
        :  # both wildcards — always passes
    elif [[ "$dom_f" == "*" ]]; then
        cron_field_matches "$dow_f" "$cur_dow" || \
        cron_field_matches "$dow_f" "$cur_dow_alt" || return 1
    elif [[ "$dow_f" == "*" ]]; then
        cron_field_matches "$dom_f" "$cur_dom" || return 1
    else
        local dom_ok=1 dow_ok=1
        cron_field_matches "$dom_f" "$cur_dom"     && dom_ok=0
        cron_field_matches "$dow_f" "$cur_dow"     && dow_ok=0
        cron_field_matches "$dow_f" "$cur_dow_alt" && dow_ok=0
        (( dom_ok && dow_ok )) && return 1
    fi

    # Time-window gate: walk backward from now by CRON_TOLERANCE minutes;
    # if any minute in [now-tolerance, now] matches the schedule, we are in window.
    local cur_total=$(( cur_hr * 60 + cur_min ))
    local win_start=$(( cur_total - CRON_TOLERANCE ))
    (( win_start < 0 )) && win_start=0

    local t t_hr t_min
    for (( t = win_start; t <= cur_total; t++ )); do
        t_hr=$(( t / 60 ))
        t_min=$(( t % 60 ))
        if cron_field_matches "$hr_f"  "$t_hr" && \
           cron_field_matches "$min_f" "$t_min"; then
            return 0
        fi
    done
    return 1
}


# =============================================================================
# MAIN
# =============================================================================

main() {
    # ------------------------------------------------------------------
    # Load and validate configuration
    # ------------------------------------------------------------------
    parse_args "$@"
    load_config
    validate_config
    init_paths

    local today
    today=$(date +%Y-%m-%d)

    # ------------------------------------------------------------------
    # GATE 1 — Cron window check (silent exit outside schedule window)
    # Passes when now is within CRON_TOLERANCE minutes of any scheduled
    # time matching CRON_SCHEDULE (including dom/month/dow fields).
    # ------------------------------------------------------------------
    if ! is_in_cron_window; then
        exit 0
    fi

    # ------------------------------------------------------------------
    # GATE 2 — TARGET closing day (silent exit — nothing to process)
    # ------------------------------------------------------------------
    if is_target_closing_day "$today"; then
        exit 0
    fi

    # ------------------------------------------------------------------
    # GATE 3 — Already succeeded today (silent exit)
    # ------------------------------------------------------------------
    if has_run_successfully_today "$today"; then
        exit 0
    fi

    # ------------------------------------------------------------------
    # GATE 4 — Acquire lock (silent exit if another instance is running)
    # ------------------------------------------------------------------
    trap cleanup EXIT INT TERM HUP
    mkdir -p "$RUN_DIR"
    acquire_lock

    rotate_log_if_needed
    log "INFO" "========== target_job_bash.sh started (PID $$) =========="
    log "INFO" "Config : $CONFIG_FILE"
    log "INFO" "Today  : $today | Schedule: ${CRON_SCHEDULE} | Tol: ${CRON_TOLERANCE}m | At: $(date +%H:%M)"

    # ------------------------------------------------------------------
    # BUILD DATE RANGE
    # ------------------------------------------------------------------
    local last_success
    last_success=$(get_last_success_date)
    log "INFO" "Last success: $last_success | Anchor: $ANCHOR_DATE"

    # Load dates into an array then into positional params for the job call
    local dates=()
    while IFS= read -r d; do
        dates+=("$d")
        log "INFO" "  -> $d"
    done < <(get_report_dates "$today")

    log "INFO" "Date range: ${#dates[@]} day(s)"

    # ------------------------------------------------------------------
    # EXECUTE JOB
    # ------------------------------------------------------------------
    log "INFO" "Running: $JOB_COMMAND ${dates[*]}"
    if "$JOB_COMMAND" "${dates[@]}"; then
        log "INFO" "Job completed successfully (exit code 0)."
        record_success "$today"
        log "INFO" "Recorded success for $today → $STATE_FILE"
    else
        local exit_code=$?
        log "ERROR" "Job FAILED with exit code $exit_code."
        log "ERROR" "Will retry on next cron tick matching: ${CRON_SCHEDULE} (tolerance: ${CRON_TOLERANCE}m)."
        exit "$exit_code"
    fi

    log "INFO" "========== target_job_bash.sh finished =========="
}

# Run main only when executed directly; skip when sourced for unit testing.
if [[ -z "${_SOURCED_FOR_TESTING:-}" ]]; then
    main "$@"
fi
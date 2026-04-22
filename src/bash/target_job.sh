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
    if ! [[ "$TRIGGER_HOUR" =~ ^[0-9]+$ ]] || \
       [ "$TRIGGER_HOUR" -lt 0 ] || [ "$TRIGGER_HOUR" -gt 23 ]; then
        echo "ERROR: TRIGGER_HOUR must be 0-23, got: '${TRIGGER_HOUR}'" >&2; errors=1
    fi
    if ! [[ "$TRIGGER_MINUTE" =~ ^[0-9]+$ ]] || \
       [ "$TRIGGER_MINUTE" -lt 0 ] || [ "$TRIGGER_MINUTE" -gt 59 ]; then
        echo "ERROR: TRIGGER_MINUTE must be 0-59, got: '${TRIGGER_MINUTE}'" >&2; errors=1
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

    local now
    now=$(date +%H%M)
    local trigger
    trigger=$(printf "%02d%02d" "$TRIGGER_HOUR" "$TRIGGER_MINUTE")
    local today
    today=$(date +%Y-%m-%d)

    # ------------------------------------------------------------------
    # GATE 1 — Time check (silent exit before trigger time)
    # ------------------------------------------------------------------
    if [ "$now" -lt "$trigger" ]; then
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
    log "INFO" "Today  : $today | Trigger reached: $(date +%H:%M)"

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
        log "ERROR" "Will retry on next cron trigger (every minute after ${TRIGGER_HOUR}:${TRIGGER_MINUTE})."
        exit "$exit_code"
    fi

    log "INFO" "========== target_job_bash.sh finished =========="
}

main "$@"
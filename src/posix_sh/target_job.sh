#!/bin/sh
# =============================================================================
# target_job_sh.sh — TARGET Closing Days Report Runner  (POSIX sh version)
# =============================================================================
#
# A cron job (every minute) that, after a configurable time on TARGET open days,
# runs a report job covering all calendar dates since the last successful run —
# automatically backfilling weekends, holidays, and failed days.
# Silent on most ticks; single-instance locked; retries until success is recorded.
#
# COMPATIBILITY: POSIX sh (1992+) — dash, ash, ksh88/93, busybox sh,
#   Bourne shell on Solaris 8+, HP-UX 10+, AIX 4+
# Requires: expr, cut, awk, tail, mkdir, rm  (all POSIX standard utilities)
# Does NOT require: bash, flock, date -d, mktemp, perl, python
#
# USAGE:
#   target_job_sh.sh [-c /path/to/config]
#
# CONFIG FILE (default: /etc/target_job/target_job.conf):
#   Standard KEY="VALUE" shell file, sourced at startup.
#   Edit the config file and wait for the next cron tick — no restart needed.
#
# INSTALL:
#   sudo cp target_job_sh.sh /usr/local/bin/target_job_sh.sh
#   sudo chmod +x /usr/local/bin/target_job_sh.sh
#   sudo mkdir -p /etc/target_job /var/lib/target_job
#   sudo cp target_job.conf /etc/target_job/target_job.conf   # then edit it
#   crontab -e  →  add:  * * * * * /usr/local/bin/target_job_sh.sh
#
# On old Solaris where /bin/sh is pre-POSIX:
#   * * * * * /usr/xpg4/bin/sh /usr/local/bin/target_job_sh.sh
#
# =============================================================================


# =============================================================================
# CONFIG FILE LOADING
# =============================================================================

DEFAULT_CONFIG="/etc/target_job/target_job.conf"

# parse_args
# Reads -c <config_path> from command-line arguments using POSIX getopts.
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
# Uses only expr and POSIX [ ] — no bash-specific features.
validate_config() {
    errors=0

    if [ -z "$JOB_COMMAND" ]; then
        echo "ERROR: JOB_COMMAND must not be empty" >&2;                  errors=1
    fi

    # Check CRON_SCHEDULE has exactly 5 space-separated fields (min hr dom mon dow)
    _v_nf=$(echo "$CRON_SCHEDULE" | awk '{print NF}')
    if [ "$_v_nf" -ne 5 ]; then
        echo "ERROR: CRON_SCHEDULE must have 5 fields (min hr dom mon dow), got ${_v_nf}: '${CRON_SCHEDULE}'" >&2
        errors=1
    fi

    # Check CRON_TOLERANCE is a non-negative integer
    if ! expr "$CRON_TOLERANCE" : '^[0-9][0-9]*$' > /dev/null 2>&1; then
        echo "ERROR: CRON_TOLERANCE must be a non-negative integer (minutes), got: '${CRON_TOLERANCE}'" >&2
        errors=1
    fi

    # Check ANCHOR_DATE matches YYYY-MM-DD pattern
    if ! expr "$ANCHOR_DATE" : '^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$' \
         > /dev/null 2>&1; then
        echo "ERROR: ANCHOR_DATE must be YYYY-MM-DD, got: '${ANCHOR_DATE}'" >&2; errors=1
    fi

    if [ -z "$RUN_DIR" ]; then
        echo "ERROR: RUN_DIR must not be empty" >&2;                       errors=1
    fi

    # Check MAX_LOG_SIZE is a positive integer
    if ! expr "$MAX_LOG_SIZE" : '^[0-9][0-9]*$' > /dev/null 2>&1 || \
       [ "$MAX_LOG_SIZE" -le 0 ]; then
        echo "ERROR: MAX_LOG_SIZE must be a positive integer, got: '${MAX_LOG_SIZE}'" >&2
        errors=1
    fi

    if [ "$errors" -ne 0 ]; then
        echo "FATAL: fix the above errors in $CONFIG_FILE" >&2
        exit 1
    fi
}

# init_paths
# Sets path variables that depend on RUN_DIR.
# Called after load_config so RUN_DIR is guaranteed to be set.
init_paths() {
    LOCK_DIR="${RUN_DIR}/target_job.lock"
    STATE_FILE="${RUN_DIR}/target_job_success.log"
    LOG_FILE="${RUN_DIR}/target_job.log"
    DATES_FILE="/tmp/target_job_dates_$$"
}


# =============================================================================
# LOGGING
# =============================================================================

# log LEVEL MESSAGE
# Appends a timestamped line to LOG_FILE and echoes it to stdout.
# Only called when the job is actually going to run — silent exits produce
# no log output, avoiding noise from the every-minute cron.
log() {
    level="$1"
    message="$2"
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    line="[$timestamp] [$level] $message"
    echo "$line"
    echo "$line" >> "$LOG_FILE"
}

# rotate_log_if_needed
# Rotates LOG_FILE to LOG_FILE.1 if it exceeds MAX_LOG_SIZE bytes.
rotate_log_if_needed() {
    if [ -f "$LOG_FILE" ]; then
        size=$(wc -c < "$LOG_FILE" | awk '{print $1}')
        if [ "$size" -gt "$MAX_LOG_SIZE" ]; then
            mv "$LOG_FILE" "${LOG_FILE}.1"
            log "INFO" "Log rotated (exceeded ${MAX_LOG_SIZE} bytes)"
        fi
    fi
}


# =============================================================================
# LOCK — ensures only one instance runs at a time
# =============================================================================
# mkdir is atomic on all POSIX-compliant filesystems. The EXIT trap releases it.

# acquire_lock
# Creates LOCK_DIR atomically. Returns 0 if acquired, 1 if already locked.
acquire_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo $$ > "${LOCK_DIR}/pid"
        return 0
    fi
    return 1
}

# release_lock
# Removes the lock directory. Called via the EXIT trap.
release_lock() {
    rm -rf "$LOCK_DIR"
}


# =============================================================================
# DATE ARITHMETIC — pure sh, no date -d required
# =============================================================================
# Uses Julian Day Numbers (JDN) for portable date arithmetic.
# Valid for all Gregorian calendar dates (1583+).

# date_to_jdn YEAR MONTH DAY → prints the Julian Day Number
date_to_jdn() {
    year="$1" month="$2" day="$3"
    a=$(( (14 - month) / 12 ))
    y=$(( year + 4800 - a ))
    m=$(( month + 12 * a - 3 ))
    echo $(( day + (153*m + 2)/5 + 365*y + y/4 - y/100 + y/400 - 32045 ))
}

# jdn_to_date JDN → prints YYYY-MM-DD
jdn_to_date() {
    jdn="$1"
    a=$(( jdn + 32044 ))
    b=$(( (4*a + 3) / 146097 ))
    c=$(( a - (146097*b)/4 ))
    d=$(( (4*c + 3) / 1461 ))
    e=$(( c - (1461*d)/4 ))
    m=$(( (5*e + 2) / 153 ))
    day=$(( e - (153*m+2)/5 + 1 ))
    month=$(( m + 3 - 12*(m/10) ))
    year=$(( 100*b + d - 4800 + m/10 ))
    printf "%04d-%02d-%02d\n" "$year" "$month" "$day"
}

# parse_date DATE_STR
# Sets PARSED_YEAR, PARSED_MONTH, PARSED_DAY from a YYYY-MM-DD string.
# Uses expr to strip leading zeros (avoids octal misinterpretation in $(())).
parse_date() {
    PARSED_YEAR=$(echo  "$1" | cut -d'-' -f1)
    PARSED_MONTH=$(expr "$(echo "$1" | cut -d'-' -f2)" + 0)
    PARSED_DAY=$(expr   "$(echo "$1" | cut -d'-' -f3)" + 0)
}

# date_to_jdn_str DATE_STR → convenience wrapper: parse then convert to JDN
date_to_jdn_str() {
    parse_date "$1"
    date_to_jdn "$PARSED_YEAR" "$PARSED_MONTH" "$PARSED_DAY"
}

# subtract_days DATE_STR N → prints date N days before DATE_STR
subtract_days() {
    parse_date "$1"
    jdn=$(date_to_jdn "$PARSED_YEAR" "$PARSED_MONTH" "$PARSED_DAY")
    jdn_to_date $(( jdn - $2 ))
}


# =============================================================================
# EASTER / TARGET CALENDAR LOGIC
# =============================================================================

# easter_sunday YEAR → prints YYYY-MM-DD
# Uses the Meeus/Jones/Butcher algorithm. Valid for Gregorian years (1583+).
easter_sunday() {
    Y="$1"
    a=$(( Y % 19 ))
    b=$(( Y / 100 ))
    c=$(( Y % 100 ))
    d=$(( b / 4 ))
    e=$(( b % 4 ))
    f=$(( (b + 8) / 25 ))
    g=$(( (b - f + 1) / 3 ))
    h=$(( (19*a + b - d - g + 15) % 30 ))
    i=$(( c / 4 ))
    k=$(( c % 4 ))
    l=$(( (32 + 2*e + 2*i - h - k) % 7 ))
    m=$(( (a + 11*h + 22*l) / 451 ))
    month=$(( (h + l - 7*m + 114) / 31 ))
    day=$(( (h + l - 7*m + 114) % 31 + 1 ))
    printf "%04d-%02d-%02d\n" "$Y" "$month" "$day"
}

# is_target_closing_day DATE_STR
# Returns 0 (true) if closing, 1 (false) if open.
# Closing days: Sat, Sun, Jan 1, May 1, Dec 25, Dec 26, Good Friday, Easter Monday.
is_target_closing_day() {
    parse_date "$1"
    year="$PARSED_YEAR"
    month="$PARSED_MONTH"
    day="$PARSED_DAY"

    # Weekend: JDN % 7 gives 0=Mon ... 4=Fri, 5=Sat, 6=Sun
    jdn=$(date_to_jdn "$year" "$month" "$day")
    if [ $(( jdn % 7 )) -ge 5 ]; then
        return 0
    fi

    # Fixed public holidays
    if   { [ "$month" -eq 1  ] && [ "$day" -eq 1  ]; } \
      || { [ "$month" -eq 5  ] && [ "$day" -eq 1  ]; } \
      || { [ "$month" -eq 12 ] && [ "$day" -eq 25 ]; } \
      || { [ "$month" -eq 12 ] && [ "$day" -eq 26 ]; }; then
        return 0
    fi

    # Moving holidays
    easter=$(easter_sunday "$year")
    easter_jdn=$(date_to_jdn_str "$easter")
    good_friday=$(jdn_to_date  $(( easter_jdn - 2 )))
    easter_monday=$(jdn_to_date $(( easter_jdn + 1 )))

    if [ "$1" = "$good_friday" ] || [ "$1" = "$easter_monday" ]; then
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
        subtract_days "$ANCHOR_DATE" 1
    fi
}

# has_run_successfully_today DATE
# Returns 0 if DATE appears in STATE_FILE, 1 otherwise.
has_run_successfully_today() {
    if [ -f "$STATE_FILE" ] && grep -F "$1" "$STATE_FILE" > /dev/null 2>&1; then
        return 0
    fi
    return 1
}

# record_success DATE
# Appends DATE with an execution timestamp to STATE_FILE.
record_success() {
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "$1  executed_at=$timestamp" >> "$STATE_FILE"
}


# =============================================================================
# DATE RANGE BUILDER
# =============================================================================

# get_report_dates TODAY_DATE
# Writes to DATES_FILE every calendar date from (last_success + 1 day)
# up to and including TODAY_DATE, in chronological order (one date per line).
get_report_dates() {
    today="$1"
    last_success=$(get_last_success_date)

    start_jdn=$(( $(date_to_jdn_str "$last_success") + 1 ))
    end_jdn=$(date_to_jdn_str "$today")

    rm -f "$DATES_FILE"
    current_jdn="$start_jdn"
    while [ "$current_jdn" -le "$end_jdn" ]; do
        jdn_to_date "$current_jdn" >> "$DATES_FILE"
        current_jdn=$(( current_jdn + 1 ))
    done
}


# =============================================================================
# CLEANUP — registered via trap, always runs on exit
# =============================================================================

cleanup() {
    release_lock
    rm -f "$DATES_FILE"
}


# =============================================================================
# CRON SCHEDULE EVALUATION
# =============================================================================
# Implements a 5-field cron expression evaluator used by the time gate.
# Format (identical to vixie-cron):  MINUTE  HOUR  DOM  MONTH  DOW
#   *        any value
#   n        exact integer
#   n-m      inclusive range
#   */n      every n-th step starting from 0  (e.g. */15 → 0,15,30,45)
#   a,b,...  comma-separated list of the above (no spaces)
# NOTE: range-step combinations like 5-30/5 are not supported; use comma lists.
# DOW convention follows standard cron: 0=Sun, 1=Mon, …, 6=Sat (7=Sun alias).

# cron_field_matches FIELD VALUE
# Returns 0 if the integer VALUE matches the cron FIELD expression, 1 otherwise.
# VALUE must be a non-negative decimal integer (no leading zeros).
cron_field_matches() {
    _cf_field="$1"
    _cf_value="$2"

    [ "$_cf_field" = "*" ] && return 0        # wildcard always matches

    # Iterate comma-separated parts (pure POSIX, no subshell)
    _cf_remain="${_cf_field},"
    while [ -n "$_cf_remain" ]; do
        _cf_part="${_cf_remain%%,*}"
        _cf_remain="${_cf_remain#*,}"

        case "$_cf_part" in
            \*/*)
                # Step: */n — matches when value % n == 0
                _cf_n="${_cf_part#*/}"
                [ $(( _cf_value % _cf_n )) -eq 0 ] && return 0
                ;;
            *-*)
                # Range: lo-hi inclusive
                _cf_lo="${_cf_part%-*}"
                _cf_hi="${_cf_part#*-}"
                if [ "$_cf_value" -ge "$_cf_lo" ] && \
                   [ "$_cf_value" -le "$_cf_hi" ]; then return 0; fi
                ;;
            *)
                # Exact value
                [ "$_cf_value" -eq "$_cf_part" ] 2>/dev/null && return 0
                ;;
        esac
    done
    return 1
}

# is_in_cron_window
# Returns 0 if "now" falls within a CRON_SCHEDULE trigger window.
# A trigger window is the interval [T, T + CRON_TOLERANCE] where T is any
# past scheduled time that matches today's date fields (dom/month/dow).
#
# Supports test-time overrides via environment variables (all optional):
#   _TEST_NOW_HOUR   _TEST_NOW_MIN   — current hour (0-23) and minute (0-59)
#   _TEST_NOW_DOM    _TEST_NOW_MON   — day-of-month (1-31) and month (1-12)
#   _TEST_NOW_DOW                   — day-of-week cron-style (0=Sun..6=Sat)
is_in_cron_window() {
    # --- Parse the 5 cron fields ---
    _cw_min_f=$(echo "$CRON_SCHEDULE" | awk '{print $1}')
    _cw_hr_f=$( echo "$CRON_SCHEDULE" | awk '{print $2}')
    _cw_dom_f=$(echo "$CRON_SCHEDULE" | awk '{print $3}')
    _cw_mon_f=$(echo "$CRON_SCHEDULE" | awk '{print $4}')
    _cw_dow_f=$(echo "$CRON_SCHEDULE" | awk '{print $5}')

    # --- Current time/date (test-override-aware; strip leading zeros) ---
    if [ -n "$_TEST_NOW_MIN" ];  then _cw_cur_min="$_TEST_NOW_MIN"
    else _cw_cur_min=$(expr "$(date +%M)" + 0); fi

    if [ -n "$_TEST_NOW_HOUR" ]; then _cw_cur_hr="$_TEST_NOW_HOUR"
    else _cw_cur_hr=$(expr "$(date +%H)" + 0); fi

    if [ -n "$_TEST_NOW_DOM" ];  then _cw_cur_dom="$_TEST_NOW_DOM"
    else _cw_cur_dom=$(expr "$(date +%d)" + 0); fi

    if [ -n "$_TEST_NOW_MON" ];  then _cw_cur_mon="$_TEST_NOW_MON"
    else _cw_cur_mon=$(expr "$(date +%m)" + 0); fi

    # Convert ISO weekday (%u: 1=Mon..7=Sun) to cron (0=Sun..6=Sat)
    if [ -n "$_TEST_NOW_DOW" ]; then
        _cw_cur_dow="$_TEST_NOW_DOW"          # already cron-style
        _cw_cur_dow_alt=$(( (_cw_cur_dow == 0) ? 7 : _cw_cur_dow ))
    else
        _cw_iso=$(date +%u)
        if [ "$_cw_iso" -eq 7 ]; then _cw_cur_dow=0; else _cw_cur_dow="$_cw_iso"; fi
        _cw_cur_dow_alt="$_cw_iso"            # ISO form (7=Sun) for aliases
    fi

    # --- Month gate ---
    cron_field_matches "$_cw_mon_f" "$_cw_cur_mon" || return 1

    # --- DOM / DOW gate (cron OR-when-both-restricted semantics) ---
    if [ "$_cw_dom_f" = "*" ] && [ "$_cw_dow_f" = "*" ]; then
        :  # both wildcards — always passes
    elif [ "$_cw_dom_f" = "*" ]; then
        cron_field_matches "$_cw_dow_f" "$_cw_cur_dow" || \
        cron_field_matches "$_cw_dow_f" "$_cw_cur_dow_alt" || return 1
    elif [ "$_cw_dow_f" = "*" ]; then
        cron_field_matches "$_cw_dom_f" "$_cw_cur_dom" || return 1
    else
        # Both restricted: OR logic
        _cw_dom_ok=1; _cw_dow_ok=1
        cron_field_matches "$_cw_dom_f" "$_cw_cur_dom"     && _cw_dom_ok=0
        cron_field_matches "$_cw_dow_f" "$_cw_cur_dow"     && _cw_dow_ok=0
        cron_field_matches "$_cw_dow_f" "$_cw_cur_dow_alt" && _cw_dow_ok=0
        if [ "$_cw_dom_ok" -ne 0 ] && [ "$_cw_dow_ok" -ne 0 ]; then return 1; fi
    fi

    # --- Time-window gate ---
    # Walk back from "now" up to CRON_TOLERANCE minutes; if any past minute
    # matched the hour+minute fields we are inside a valid trigger window.
    _cw_cur_total=$(( _cw_cur_hr * 60 + _cw_cur_min ))
    _cw_win_start=$(( _cw_cur_total - CRON_TOLERANCE ))
    [ "$_cw_win_start" -lt 0 ] && _cw_win_start=0

    _cw_t="$_cw_win_start"
    while [ "$_cw_t" -le "$_cw_cur_total" ]; do
        _cw_t_hr=$(( _cw_t / 60 ))
        _cw_t_min=$(( _cw_t % 60 ))
        if cron_field_matches "$_cw_hr_f"  "$_cw_t_hr" && \
           cron_field_matches "$_cw_min_f" "$_cw_t_min"; then
            return 0
        fi
        _cw_t=$(( _cw_t + 1 ))
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

    today=$(date +%Y-%m-%d)

    # ------------------------------------------------------------------
    # GATE 1 — Cron window check (silent exit outside schedule window)
    # Passes when now is within CRON_TOLERANCE minutes of a matching
    # CRON_SCHEDULE time and today satisfies the dom/month/dow fields.
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
    if ! acquire_lock; then
        exit 0
    fi
    trap cleanup EXIT INT TERM HUP

    # ------------------------------------------------------------------
    # Initialise logging — only reached when we are actually going to run
    # ------------------------------------------------------------------
    mkdir -p "$RUN_DIR"
    rotate_log_if_needed

    log "INFO" "========== target_job_sh.sh started (PID $$) =========="
    log "INFO" "Config : $CONFIG_FILE"
    log "INFO" "Today  : $today | Schedule: ${CRON_SCHEDULE} | Tol: ${CRON_TOLERANCE}m | At: $(date +%H:%M)"

    # ------------------------------------------------------------------
    # BUILD DATE RANGE
    # ------------------------------------------------------------------
    last_success=$(get_last_success_date)
    log "INFO" "Last success: $last_success | Anchor: $ANCHOR_DATE"

    get_report_dates "$today"

    count=$(wc -l < "$DATES_FILE" | awk '{print $1}')
    log "INFO" "Date range to process ($count day(s)):"
    while IFS= read -r d; do
        log "INFO" "  -> $d"
    done < "$DATES_FILE"

    # ------------------------------------------------------------------
    # LOAD DATES INTO POSITIONAL PARAMETERS ($@)
    # POSIX substitute for arrays: set -- clears $@, then we append
    # each date one by one. After the loop "$@" holds all dates.
    # ------------------------------------------------------------------
    set --
    while IFS= read -r d; do
        set -- "$@" "$d"
    done < "$DATES_FILE"

    # ------------------------------------------------------------------
    # EXECUTE JOB
    # ------------------------------------------------------------------
    log "INFO" "Running: $JOB_COMMAND $*"
    if "$JOB_COMMAND" "$@"; then
        log "INFO" "Job completed successfully (exit code 0)."
        record_success "$today"
        log "INFO" "Recorded success for $today → $STATE_FILE"
    else
        exit_code=$?
        log "ERROR" "Job FAILED with exit code $exit_code."
        log "ERROR" "Will retry on next cron tick matching: ${CRON_SCHEDULE} (tolerance: ${CRON_TOLERANCE}m)."
        exit "$exit_code"
    fi

    log "INFO" "========== target_job_sh.sh finished =========="
}

# Run main only when executed directly; skip when sourced for unit testing.
if [ -z "$_SOURCED_FOR_TESTING" ]; then
    main "$@"
fi
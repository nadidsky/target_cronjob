#!/bin/sh
# =============================================================================
# target_job.sh — TARGET Closing Days Report Runner  (every-minute cron)
# =============================================================================
#
# PURPOSE:
#   Runs every minute via cron. After TRIGGER_TIME each day, executes
#   JOB_COMMAND with all dates from the day after the last successful run
#   up to and including today — covering any TARGET closing days, failed
#   runs, or skipped days in between.
#
# TRIGGER LOGIC (evaluated every minute):
#   1. Silent exit  — current time is before TRIGGER_TIME
#   2. Silent exit  — today is a TARGET closing day (nothing to process)
#   3. Silent exit  — today already completed successfully
#   4. Silent exit  — another instance is already running (lock held)
#   5. RUN          — compute date range from (last success + 1 day) to
#                     today, pass all dates to JOB_COMMAND
#
# DATE RANGE LOGIC:
#   Last success date is read from STATE_FILE (last line).
#   On first ever run (empty STATE_FILE), ANCHOR_DATE - 1 day is used,
#   so ANCHOR_DATE itself is the earliest date ever included.
#
#   Example A — normal day (no gaps):
#     last success = 2025-04-17 (Thu), today = 2025-04-22 (Tue after Easter)
#     range = 2025-04-18, 19, 20, 21, 22
#
#   Example B — failed run yesterday:
#     last success = 2025-04-15 (Tue), today = 2025-04-17 (Thu)
#     range = 2025-04-16, 17
#
#   Example C — first ever run, ANCHOR_DATE = 2025-01-01:
#     range = 2025-01-01 ... today
#
# COMPATIBILITY:
#   Requires: POSIX sh (1992+) — dash, ash, ksh88/93, busybox sh,
#             Bourne shell on Solaris 8+, HP-UX 10+, AIX 4+
#   Requires: expr, cut, awk, tail, mkdir, rm  (all POSIX utilities)
#   Does NOT require: bash, flock, date -d, mktemp, perl, python
#
# CRON ENTRY (add via: crontab -e):
#   * * * * * /usr/local/bin/target_job.sh
#
# INSTALLATION:
#   1. cp target_job.sh /usr/local/bin/target_job.sh
#   2. chmod +x /usr/local/bin/target_job.sh
#   3. mkdir -p /var/lib/target_job
#   4. Edit CONFIGURATION below
#   5. crontab -e  →  add:  * * * * * /usr/local/bin/target_job.sh
#
# =============================================================================


# =============================================================================
# CONFIGURATION — edit these values before deploying
# =============================================================================

# Job to execute. Receives dates as arguments (oldest first):
#   JOB_COMMAND 2025-04-18 2025-04-19 2025-04-20 2025-04-21 2025-04-22
JOB_COMMAND="/usr/local/bin/my_report_job"

# Time gate: job will not trigger before this time each day (24h format)
TRIGGER_HOUR=19
TRIGGER_MINUTE=30

# Anchor date (YYYY-MM-DD): the earliest date ever included in a run.
# Used as the floor on the first ever execution (empty STATE_FILE).
# Set this to the first business day you want covered.
ANCHOR_DATE="2025-01-01"

# Directory for all runtime files
RUN_DIR="/var/lib/target_job"

# Lock directory — atomic mkdir prevents parallel executions
LOCK_DIR="${RUN_DIR}/target_job.lock"

# State file — one line per successfully processed TARGET open day
# Format: YYYY-MM-DD  executed_at=YYYY-MM-DD HH:MM:SS
STATE_FILE="${RUN_DIR}/target_job_success.log"

# Log file — execution log (only written when the job actually runs)
LOG_FILE="${RUN_DIR}/target_job.log"

# Temp file for the date list (PID-based, no mktemp needed)
DATES_FILE="/tmp/target_job_dates_$$"

# Max log size in bytes before rotation (default: 10 MB)
MAX_LOG_SIZE=10485760


# =============================================================================
# LOGGING
# =============================================================================

# log LEVEL MESSAGE
# Appends a timestamped line to LOG_FILE and echoes it to stdout.
# Only called when the job is actually going to run — silent exits
# (time gate, already ran, closing day) produce no log output, which
# avoids flooding the log from the every-minute cron.
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
# mkdir is atomic on all POSIX filesystems. The EXIT trap always releases it.

# acquire_lock
# Returns 0 if lock acquired, 1 if already locked (caller should exit).
acquire_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo $$ > "${LOCK_DIR}/pid"
        return 0
    fi
    return 1
}

# release_lock
# Called by the EXIT trap — removes the lock directory.
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

# subtract_days DATE_STR N → prints date N days before DATE_STR
subtract_days() {
    parse_date "$1"
    jdn=$(date_to_jdn "$PARSED_YEAR" "$PARSED_MONTH" "$PARSED_DAY")
    jdn_to_date $(( jdn - $2 ))
}

# date_to_jdn_str DATE_STR → convenience wrapper that parses then converts
date_to_jdn_str() {
    parse_date "$1"
    date_to_jdn "$PARSED_YEAR" "$PARSED_MONTH" "$PARSED_DAY"
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
# ANCHOR_DATE itself will be included in the first ever run.
get_last_success_date() {
    if [ -f "$STATE_FILE" ] && [ -s "$STATE_FILE" ]; then
        # Each line: "YYYY-MM-DD  executed_at=..."  — grab first field of last line
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
# up to and including TODAY_DATE, in chronological order.
#
# This covers:
#   - TARGET closing days (weekends, holidays) in the gap
#   - TARGET open days that previously failed in the gap
#   - Today itself
#
# The range floor is always ANCHOR_DATE (first ever run uses it).
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
# MAIN
# =============================================================================

main() {
    # ------------------------------------------------------------------
    # GATE 1 — Time check (silent exit before TRIGGER_TIME)
    # Running every minute means most invocations exit here instantly.
    # No logging at this stage to avoid flooding the log.
    # ------------------------------------------------------------------
    current_hhmm=$(date +%H%M)
    trigger_hhmm=$(printf "%02d%02d" "$TRIGGER_HOUR" "$TRIGGER_MINUTE")
    if [ "$current_hhmm" -lt "$trigger_hhmm" ]; then
        exit 0
    fi

    today=$(date +%Y-%m-%d)

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

    # Register cleanup now that we hold the lock
    trap cleanup EXIT INT TERM HUP

    # From here we know we need to run — start logging
    mkdir -p "$RUN_DIR" || { echo "FATAL: Cannot create RUN_DIR=$RUN_DIR" >&2; exit 1; }
    rotate_log_if_needed

    log "INFO" "========== target_job.sh started (PID $$) =========="
    log "INFO" "Today: $today | Trigger time reached: $(date +%H:%M)"

    # ------------------------------------------------------------------
    # BUILD DATE RANGE
    # From (last success + 1 day) to today, inclusive.
    # ------------------------------------------------------------------
    last_success=$(get_last_success_date)
    log "INFO" "Last successful run: $last_success"
    log "INFO" "Anchor date (floor): $ANCHOR_DATE"

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
        log "ERROR" "Will retry on next cron trigger (every minute after $trigger_hhmm)."
        exit "$exit_code"
    fi

    log "INFO" "========== target_job.sh finished =========="
}

main "$@"


# =============================================================================
# INSTALLATION GUIDE
# =============================================================================
#
# --- Step 1: Install ---
#
#   sudo cp target_job.sh /usr/local/bin/target_job.sh
#   sudo chmod +x /usr/local/bin/target_job.sh
#   sudo mkdir -p /var/lib/target_job
#
# --- Step 2: Add the cron entry ---
#
#   sudo crontab -e
#
#   Add:
#     * * * * * /usr/local/bin/target_job.sh
#
#   The script is safe to run every minute:
#     - Before TRIGGER_TIME  → exits in milliseconds (time check only)
#     - After TRIGGER_TIME   → exits in milliseconds if already ran today
#     - On TARGET closing day → exits in milliseconds (no log noise)
#     - If already running   → exits immediately (lock check)
#
# --- Step 3: Behaviour summary ---
#
#   Scenario                          What happens
#   ────────────────────────────────  ──────────────────────────────────────
#   Before 19:30 any day              Silent exit every minute
#   19:30 on a TARGET closing day     Silent exit (nothing to process)
#   19:30 on a TARGET open day        Runs once successfully → records it
#   19:31-23:59 after success         Silent exit (already ran today)
#   19:30 after a failed yesterday    Covers yesterday + today in one run
#   19:30 after Easter long weekend   Covers Fri+Sat+Sun+Mon+Tue in one run
#   First ever run (no state file)    Covers ANCHOR_DATE through today
#   Machine was off all day           Runs as soon as it boots (if >= 19:30)
#
# --- Step 4: Verify ---
#
#   tail -f /var/lib/target_job/target_job.log
#   cat     /var/lib/target_job/target_job_success.log
#
# --- On old Solaris/HP-UX where /bin/sh is pre-POSIX ---
#
#   Use ksh or the POSIX shell explicitly:
#     * * * * * /usr/xpg4/bin/sh /usr/local/bin/target_job.sh   # Solaris
#     * * * * * /usr/bin/ksh     /usr/local/bin/target_job.sh   # HP-UX / AIX
#
# =============================================================================

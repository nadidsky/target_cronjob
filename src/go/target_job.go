// target_job.go — TARGET Closing Days Report Runner
//
// A POSIX sh cron script (every minute) that, after 19:30 on TARGET open days,
// runs a report job covering all calendar dates since the last successful run —
// automatically backfilling weekends, holidays, and failed days.
// Silent on most ticks; single-instance locked; retries until success is recorded.
//
// Build:
//   go build -o target_job target_job.go
//
// Install:
//   sudo cp target_job /usr/local/bin/target_job
//   sudo mkdir -p /var/lib/target_job
//   crontab -e  →  add:  * * * * * /usr/local/bin/target_job
//
// No external dependencies — standard library only.

package main

import (
	"bufio"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

// =============================================================================
// CONFIGURATION — edit these values before building
// =============================================================================

const (
	// jobCommand is the executable to run. It receives dates as arguments,
	// oldest first: jobCommand 2025-04-18 2025-04-19 ... 2025-04-22
	jobCommand = "/usr/local/bin/my_report_job"

	// triggerHour and triggerMinute define the earliest time the job may run
	// each day (24h format). Before this time every cron tick is a silent exit.
	triggerHour   = 19
	triggerMinute = 30

	// anchorDate (YYYY-MM-DD) is the earliest date ever included in a run.
	// On the first ever execution (empty state file) the date range starts here.
	anchorDate = "2025-01-01"

	// runDir holds the lock directory, state file, and log file.
	runDir = "/var/lib/target_job"

	// maxLogBytes is the log file size threshold for rotation (default: 10 MB).
	maxLogBytes = 10 * 1024 * 1024
)

// =============================================================================
// RUNTIME PATHS — derived from runDir
// =============================================================================

var (
	lockDir   = filepath.Join(runDir, "target_job.lock")
	stateFile = filepath.Join(runDir, "target_job_success.log")
	logFile   = filepath.Join(runDir, "target_job.log")
)

// =============================================================================
// LOGGING
// =============================================================================

// appLog is initialised only when the job is actually going to run.
// Silent exits (time gate, closing day, already ran, lock held) produce
// zero log output, keeping the log clean despite the every-minute cron.
var appLog *log.Logger

// initLogging opens the log file (rotating if over maxLogBytes), then
// creates a logger that writes to both the file and stdout.
func initLogging() error {
	if err := os.MkdirAll(runDir, 0755); err != nil {
		return fmt.Errorf("cannot create runDir %s: %w", runDir, err)
	}

	// Rotate if the log file has grown too large
	if info, err := os.Stat(logFile); err == nil && info.Size() > maxLogBytes {
		_ = os.Rename(logFile, logFile+".1")
	}

	f, err := os.OpenFile(logFile, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return fmt.Errorf("cannot open log file %s: %w", logFile, err)
	}

	mw := io.MultiWriter(os.Stdout, f)
	appLog = log.New(mw, "", log.LstdFlags)
	return nil
}

func logf(level, format string, args ...interface{}) {
	if appLog != nil {
		appLog.Printf("["+level+"] "+format, args...)
	}
}

// =============================================================================
// LOCK — single-instance guarantee via atomic directory creation
// =============================================================================

// acquireLock creates lockDir atomically. Returns true if the lock was
// acquired, false if another instance already holds it.
// os.Mkdir is atomic on all POSIX-compliant filesystems.
func acquireLock() bool {
	if err := os.Mkdir(lockDir, 0700); err != nil {
		return false
	}
	pidFile := filepath.Join(lockDir, "pid")
	_ = os.WriteFile(pidFile, []byte(fmt.Sprintf("%d\n", os.Getpid())), 0644)
	return true
}

// releaseLock removes the lock directory. Called via defer and signal handler.
func releaseLock() {
	_ = os.RemoveAll(lockDir)
}

// =============================================================================
// TARGET CALENDAR LOGIC
// =============================================================================

// easterSunday returns Easter Sunday for the given year using the
// Meeus/Jones/Butcher algorithm. Valid for all Gregorian years (1583+).
func easterSunday(year int) time.Time {
	a := year % 19
	b := year / 100
	c := year % 100
	d := b / 4
	e := b % 4
	f := (b + 8) / 25
	g := (b - f + 1) / 3
	h := (19*a + b - d - g + 15) % 30
	i := c / 4
	k := c % 4
	l := (32 + 2*e + 2*i - h - k) % 7
	m := (a + 11*h + 22*l) / 451
	month := (h + l - 7*m + 114) / 31
	day := (h+l-7*m+114)%31 + 1
	return time.Date(year, time.Month(month), day, 0, 0, 0, 0, time.UTC)
}

// isTargetClosingDay returns true if d is a TARGET closing day:
//   - Saturday or Sunday
//   - New Year's Day  (January 1)
//   - Labour Day      (May 1)
//   - Christmas Day   (December 25)
//   - Boxing Day      (December 26)
//   - Good Friday     (Easter Sunday − 2 days)
//   - Easter Monday   (Easter Sunday + 1 day)
func isTargetClosingDay(d time.Time) bool {
	// Normalise to midnight UTC so date comparisons are clean
	d = time.Date(d.Year(), d.Month(), d.Day(), 0, 0, 0, 0, time.UTC)

	// Weekend
	if d.Weekday() == time.Saturday || d.Weekday() == time.Sunday {
		return true
	}

	// Fixed public holidays
	switch {
	case d.Month() == time.January  && d.Day() == 1,
		 d.Month() == time.May       && d.Day() == 1,
		 d.Month() == time.December  && d.Day() == 25,
		 d.Month() == time.December  && d.Day() == 26:
		return true
	}

	// Moving holidays
	easter := easterSunday(d.Year())
	goodFriday  := easter.AddDate(0, 0, -2)
	easterMonday := easter.AddDate(0, 0, 1)

	return d.Equal(goodFriday) || d.Equal(easterMonday)
}

// =============================================================================
// STATE — track successfully processed TARGET open days
// =============================================================================

// parseAnchor parses ANCHOR_DATE and returns it as a time.Time.
// Panics on misconfiguration (invalid constant).
func parseAnchor() time.Time {
	t, err := time.Parse("2006-01-02", anchorDate)
	if err != nil {
		panic(fmt.Sprintf("invalid anchorDate constant %q: %v", anchorDate, err))
	}
	return t
}

// getLastSuccessDate reads the most recent success date from the state file.
// Returns (anchorDate − 1 day) if the state file is absent or empty,
// so that anchorDate itself is included on the first ever run.
func getLastSuccessDate() time.Time {
	floor := parseAnchor().AddDate(0, 0, -1)

	f, err := os.Open(stateFile)
	if err != nil {
		return floor // file absent
	}
	defer f.Close()

	// Scan to the last non-empty line
	var lastLine string
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		if line := strings.TrimSpace(scanner.Text()); line != "" {
			lastLine = line
		}
	}
	if lastLine == "" {
		return floor
	}

	// Line format: "YYYY-MM-DD  executed_at=YYYY-MM-DD HH:MM:SS"
	parts := strings.Fields(lastLine)
	if len(parts) == 0 {
		return floor
	}
	d, err := time.Parse("2006-01-02", parts[0])
	if err != nil {
		return floor
	}
	return d
}

// hasRunSuccessfullyToday returns true if today's date appears in the state file.
func hasRunSuccessfullyToday(today time.Time) bool {
	dateStr := today.Format("2006-01-02")
	f, err := os.Open(stateFile)
	if err != nil {
		return false
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		if strings.HasPrefix(scanner.Text(), dateStr) {
			return true
		}
	}
	return false
}

// recordSuccess appends today's date with a timestamp to the state file.
func recordSuccess(today time.Time) error {
	f, err := os.OpenFile(stateFile, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return fmt.Errorf("cannot open state file: %w", err)
	}
	defer f.Close()

	line := fmt.Sprintf("%s  executed_at=%s\n",
		today.Format("2006-01-02"),
		time.Now().Format("2006-01-02 15:04:05"))
	_, err = f.WriteString(line)
	return err
}

// =============================================================================
// DATE RANGE BUILDER
// =============================================================================

// getReportDates returns every calendar date from (lastSuccess + 1 day) up to
// and including today, in chronological order.
//
// This covers:
//   - TARGET closing days (weekends, holidays) in the gap
//   - TARGET open days that previously failed
//   - Today itself
func getReportDates(today time.Time) []time.Time {
	lastSuccess := getLastSuccessDate()
	start := lastSuccess.AddDate(0, 0, 1)
	end   := time.Date(today.Year(), today.Month(), today.Day(), 0, 0, 0, 0, time.UTC)

	var dates []time.Time
	for d := start; !d.After(end); d = d.AddDate(0, 0, 1) {
		dates = append(dates, d)
	}
	return dates
}

// =============================================================================
// JOB EXECUTION
// =============================================================================

// runJob executes jobCommand with the given dates as arguments.
// Stdout and stderr of the child process are forwarded to our own stdout/stderr.
func runJob(dates []time.Time) error {
	args := make([]string, len(dates))
	for i, d := range dates {
		args[i] = d.Format("2006-01-02")
	}

	cmd := exec.Command(jobCommand, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

// =============================================================================
// MAIN
// =============================================================================

func main() {
	now   := time.Now()
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)

	// ------------------------------------------------------------------
	// GATE 1 — Time check (silent exit before TRIGGER_TIME)
	// Most cron ticks exit here in microseconds.
	// ------------------------------------------------------------------
	triggerReached := now.Hour() > triggerHour ||
		(now.Hour() == triggerHour && now.Minute() >= triggerMinute)
	if !triggerReached {
		os.Exit(0)
	}

	// ------------------------------------------------------------------
	// GATE 2 — TARGET closing day (silent exit — nothing to process)
	// ------------------------------------------------------------------
	if isTargetClosingDay(today) {
		os.Exit(0)
	}

	// ------------------------------------------------------------------
	// GATE 3 — Already succeeded today (silent exit)
	// ------------------------------------------------------------------
	if hasRunSuccessfullyToday(today) {
		os.Exit(0)
	}

	// ------------------------------------------------------------------
	// GATE 4 — Acquire lock (silent exit if another instance is running)
	// ------------------------------------------------------------------
	if !acquireLock() {
		os.Exit(0)
	}
	defer releaseLock()

	// Release lock cleanly on SIGINT / SIGTERM / SIGHUP
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)
	go func() {
		<-sigCh
		releaseLock()
		os.Exit(1)
	}()

	// ------------------------------------------------------------------
	// Initialise logging — only reached when we are actually going to run
	// ------------------------------------------------------------------
	if err := initLogging(); err != nil {
		fmt.Fprintf(os.Stderr, "FATAL: %v\n", err)
		os.Exit(1)
	}

	logf("INFO", "========== target_job started (PID %d) ==========", os.Getpid())
	logf("INFO", "Today: %s | Trigger time reached: %s",
		today.Format("2006-01-02"), now.Format("15:04"))

	// ------------------------------------------------------------------
	// BUILD DATE RANGE
	// ------------------------------------------------------------------
	lastSuccess := getLastSuccessDate()
	logf("INFO", "Last successful run : %s", lastSuccess.Format("2006-01-02"))
	logf("INFO", "Anchor date (floor) : %s", anchorDate)

	dates := getReportDates(today)
	logf("INFO", "Date range to process (%d day(s)):", len(dates))
	for _, d := range dates {
		logf("INFO", "  -> %s", d.Format("2006-01-02"))
	}

	// ------------------------------------------------------------------
	// EXECUTE JOB
	// ------------------------------------------------------------------
	args := make([]string, len(dates))
	for i, d := range dates {
		args[i] = d.Format("2006-01-02")
	}
	logf("INFO", "Running: %s %s", jobCommand, strings.Join(args, " "))

	if err := runJob(dates); err != nil {
		logf("ERROR", "Job FAILED: %v", err)
		logf("ERROR", "Will retry on next cron trigger (every minute after %02d:%02d).",
			triggerHour, triggerMinute)
		os.Exit(1)
	}

	logf("INFO", "Job completed successfully.")
	if err := recordSuccess(today); err != nil {
		logf("ERROR", "Could not record success: %v", err)
		os.Exit(1)
	}
	logf("INFO", "Recorded success for %s → %s", today.Format("2006-01-02"), stateFile)
	logf("INFO", "========== target_job finished ==========")
}

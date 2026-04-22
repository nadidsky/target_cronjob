// target_job.go — TARGET Closing Days Report Runner
//
// A cron job (every minute) that, after a configurable time on TARGET open days,
// runs a report job covering all calendar dates since the last successful run —
// automatically backfilling weekends, holidays, and failed days.
// Silent on most ticks; single-instance locked; retries until success is recorded.
//
// Build:
//   go build -o target_job target_job.go
//
// Install:
//   sudo cp target_job /usr/local/bin/target_job
//   sudo mkdir -p /etc/target_job /var/lib/target_job
//   sudo cp config.json /etc/target_job/config.json   # edit before copying
//   crontab -e  →  add:  * * * * * /usr/local/bin/target_job
//
// Override config path:
//   /usr/local/bin/target_job -config /path/to/my_config.json
//
// No external dependencies — standard library only.

package main

import (
	"bufio"
	"encoding/json"
	"flag"
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
// CONFIGURATION
// =============================================================================

const defaultConfigPath = "/etc/target_job/config.json"

// Config holds all runtime settings loaded from the JSON config file.
// Edit the config file and restart — no recompilation needed.
type Config struct {
	// JobCommand is the executable to run. It receives dates as arguments
	// (oldest first): e.g. my_report_job 2025-04-18 2025-04-19 2025-04-22
	JobCommand string `json:"job_command"`

	// TriggerHour and TriggerMinute define the earliest time the job may
	// run each day (24h format). Every cron tick before this is a silent exit.
	TriggerHour   int `json:"trigger_hour"`
	TriggerMinute int `json:"trigger_minute"`

	// AnchorDate (YYYY-MM-DD) is the earliest date ever included in a run.
	// On the first ever execution (empty state file) the date range starts here.
	AnchorDate string `json:"anchor_date"`

	// RunDir holds all runtime files: lock directory, state file, log file.
	RunDir string `json:"run_dir"`

	// MaxLogBytes is the log file size threshold for rotation. Default: 10 MB.
	MaxLogBytes int64 `json:"max_log_bytes"`
}

// defaults returns a Config with safe fallback values.
// Any field present in the JSON file overrides the corresponding default.
func defaults() Config {
	return Config{
		JobCommand:    "/usr/local/bin/my_report_job",
		TriggerHour:   19,
		TriggerMinute: 30,
		AnchorDate:    "2025-01-01",
		RunDir:        "/var/lib/target_job",
		MaxLogBytes:   10 * 1024 * 1024,
	}
}

// loadConfig reads and parses the JSON config file at path.
// Missing fields keep their default values.
func loadConfig(path string) (Config, error) {
	cfg := defaults()

	f, err := os.Open(path)
	if err != nil {
		return cfg, fmt.Errorf("cannot open config file %s: %w", path, err)
	}
	defer f.Close()

	dec := json.NewDecoder(f)
	dec.DisallowUnknownFields() // catch typos in the config file
	if err := dec.Decode(&cfg); err != nil {
		return cfg, fmt.Errorf("cannot parse config file %s: %w", path, err)
	}

	if err := validateConfig(cfg); err != nil {
		return cfg, fmt.Errorf("invalid config: %w", err)
	}
	return cfg, nil
}

// validateConfig checks that all required fields are sensible.
func validateConfig(cfg Config) error {
	if cfg.JobCommand == "" {
		return fmt.Errorf("job_command must not be empty")
	}
	if cfg.TriggerHour < 0 || cfg.TriggerHour > 23 {
		return fmt.Errorf("trigger_hour must be 0–23, got %d", cfg.TriggerHour)
	}
	if cfg.TriggerMinute < 0 || cfg.TriggerMinute > 59 {
		return fmt.Errorf("trigger_minute must be 0–59, got %d", cfg.TriggerMinute)
	}
	if _, err := time.Parse("2006-01-02", cfg.AnchorDate); err != nil {
		return fmt.Errorf("anchor_date must be YYYY-MM-DD, got %q", cfg.AnchorDate)
	}
	if cfg.RunDir == "" {
		return fmt.Errorf("run_dir must not be empty")
	}
	if cfg.MaxLogBytes <= 0 {
		return fmt.Errorf("max_log_bytes must be positive, got %d", cfg.MaxLogBytes)
	}
	return nil
}

// =============================================================================
// RUNTIME PATHS — derived from cfg.RunDir
// =============================================================================

func lockDir(cfg Config) string   { return filepath.Join(cfg.RunDir, "target_job.lock") }
func stateFile(cfg Config) string { return filepath.Join(cfg.RunDir, "target_job_success.log") }
func logFile(cfg Config) string   { return filepath.Join(cfg.RunDir, "target_job.log") }

// =============================================================================
// LOGGING
// =============================================================================

// appLog is initialised only when the job is actually going to run.
// Silent exits (time gate, closing day, already ran, lock held) produce
// zero log output, keeping the log clean despite the every-minute cron.
var appLog *log.Logger

// initLogging opens the log file (rotating if over MaxLogBytes) and creates
// a logger that writes to both the file and stdout.
func initLogging(cfg Config) error {
	if err := os.MkdirAll(cfg.RunDir, 0755); err != nil {
		return fmt.Errorf("cannot create run_dir %s: %w", cfg.RunDir, err)
	}

	lf := logFile(cfg)
	if info, err := os.Stat(lf); err == nil && info.Size() > cfg.MaxLogBytes {
		_ = os.Rename(lf, lf+".1")
	}

	f, err := os.OpenFile(lf, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return fmt.Errorf("cannot open log file %s: %w", lf, err)
	}

	appLog = log.New(io.MultiWriter(os.Stdout, f), "", log.LstdFlags)
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

// acquireLock creates the lock directory atomically.
// Returns true if the lock was acquired, false if another instance holds it.
func acquireLock(cfg Config) bool {
	if err := os.Mkdir(lockDir(cfg), 0700); err != nil {
		return false
	}
	_ = os.WriteFile(
		filepath.Join(lockDir(cfg), "pid"),
		[]byte(fmt.Sprintf("%d\n", os.Getpid())),
		0644,
	)
	return true
}

// releaseLock removes the lock directory. Called via defer and signal handler.
func releaseLock(cfg Config) {
	_ = os.RemoveAll(lockDir(cfg))
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

// isTargetClosingDay reports whether d is a TARGET closing day:
//   - Saturday or Sunday
//   - New Year's Day  (January 1)
//   - Labour Day      (May 1)
//   - Christmas Day   (December 25)
//   - Boxing Day      (December 26)
//   - Good Friday     (Easter Sunday − 2 days)
//   - Easter Monday   (Easter Sunday + 1 day)
func isTargetClosingDay(d time.Time) bool {
	d = time.Date(d.Year(), d.Month(), d.Day(), 0, 0, 0, 0, time.UTC)

	if d.Weekday() == time.Saturday || d.Weekday() == time.Sunday {
		return true
	}

	switch {
	case d.Month() == time.January  && d.Day() == 1,
		 d.Month() == time.May       && d.Day() == 1,
		 d.Month() == time.December  && d.Day() == 25,
		 d.Month() == time.December  && d.Day() == 26:
		return true
	}

	easter := easterSunday(d.Year())
	return d.Equal(easter.AddDate(0, 0, -2)) || d.Equal(easter.AddDate(0, 0, 1))
}

// =============================================================================
// STATE — track successfully processed TARGET open days
// =============================================================================

// getLastSuccessDate reads the most recent success date from the state file.
// Returns (anchorDate − 1 day) if absent or empty, so anchorDate is included
// on the first ever run.
func getLastSuccessDate(cfg Config) time.Time {
	anchor, _ := time.Parse("2006-01-02", cfg.AnchorDate)
	floor := anchor.AddDate(0, 0, -1)

	f, err := os.Open(stateFile(cfg))
	if err != nil {
		return floor
	}
	defer f.Close()

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
	d, err := time.Parse("2006-01-02", parts[0])
	if err != nil {
		return floor
	}
	return d
}

// hasRunSuccessfullyToday reports whether today's date appears in the state file.
func hasRunSuccessfullyToday(cfg Config, today time.Time) bool {
	dateStr := today.Format("2006-01-02")
	f, err := os.Open(stateFile(cfg))
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
func recordSuccess(cfg Config, today time.Time) error {
	f, err := os.OpenFile(stateFile(cfg), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return fmt.Errorf("cannot open state file: %w", err)
	}
	defer f.Close()

	_, err = fmt.Fprintf(f, "%s  executed_at=%s\n",
		today.Format("2006-01-02"),
		time.Now().Format("2006-01-02 15:04:05"))
	return err
}

// =============================================================================
// DATE RANGE BUILDER
// =============================================================================

// getReportDates returns every calendar date from (lastSuccess + 1 day) up to
// and including today, in chronological order.
func getReportDates(cfg Config, today time.Time) []time.Time {
	lastSuccess := getLastSuccessDate(cfg)
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

// runJob executes cfg.JobCommand with the given dates as string arguments.
// The child process inherits our stdout and stderr.
func runJob(cfg Config, dates []time.Time) error {
	args := make([]string, len(dates))
	for i, d := range dates {
		args[i] = d.Format("2006-01-02")
	}
	cmd := exec.Command(cfg.JobCommand, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

// =============================================================================
// MAIN
// =============================================================================

func main() {
	// ------------------------------------------------------------------
	// Parse flags — only -config is supported
	// ------------------------------------------------------------------
	configPath := flag.String("config", defaultConfigPath, "path to JSON config file")
	flag.Parse()

	// ------------------------------------------------------------------
	// Load configuration
	// ------------------------------------------------------------------
	cfg, err := loadConfig(*configPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "FATAL: %v\n", err)
		os.Exit(1)
	}

	now   := time.Now()
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)

	// ------------------------------------------------------------------
	// GATE 1 — Time check (silent exit before trigger time)
	// Most cron ticks exit here in microseconds.
	// ------------------------------------------------------------------
	triggerReached := now.Hour() > cfg.TriggerHour ||
		(now.Hour() == cfg.TriggerHour && now.Minute() >= cfg.TriggerMinute)
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
	if hasRunSuccessfullyToday(cfg, today) {
		os.Exit(0)
	}

	// ------------------------------------------------------------------
	// GATE 4 — Acquire lock (silent exit if another instance is running)
	// ------------------------------------------------------------------
	if !acquireLock(cfg) {
		os.Exit(0)
	}
	defer releaseLock(cfg)

	// Release lock cleanly on SIGINT / SIGTERM / SIGHUP
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)
	go func() {
		<-sigCh
		releaseLock(cfg)
		os.Exit(1)
	}()

	// ------------------------------------------------------------------
	// Initialise logging — only reached when we are actually going to run
	// ------------------------------------------------------------------
	if err := initLogging(cfg); err != nil {
		fmt.Fprintf(os.Stderr, "FATAL: %v\n", err)
		os.Exit(1)
	}

	logf("INFO", "========== target_job started (PID %d) ==========", os.Getpid())
	logf("INFO", "Config     : %s", *configPath)
	logf("INFO", "Today      : %s | Trigger time reached: %s", today.Format("2006-01-02"), now.Format("15:04"))
	logf("INFO", "Job command: %s", cfg.JobCommand)

	// ------------------------------------------------------------------
	// BUILD DATE RANGE
	// ------------------------------------------------------------------
	lastSuccess := getLastSuccessDate(cfg)
	logf("INFO", "Last success: %s | Anchor: %s", lastSuccess.Format("2006-01-02"), cfg.AnchorDate)

	dates := getReportDates(cfg, today)
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
	logf("INFO", "Running: %s %s", cfg.JobCommand, strings.Join(args, " "))

	if err := runJob(cfg, dates); err != nil {
		logf("ERROR", "Job FAILED: %v", err)
		logf("ERROR", "Will retry on next cron trigger (every minute after %02d:%02d).",
			cfg.TriggerHour, cfg.TriggerMinute)
		os.Exit(1)
	}

	logf("INFO", "Job completed successfully.")
	if err := recordSuccess(cfg, today); err != nil {
		logf("ERROR", "Could not record success: %v", err)
		os.Exit(1)
	}
	logf("INFO", "Recorded success for %s → %s", today.Format("2006-01-02"), stateFile(cfg))
	logf("INFO", "========== target_job finished ==========")
}
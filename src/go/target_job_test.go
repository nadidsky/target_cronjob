package main

// =============================================================================
// target_job_test.go — unit tests for target_job.go
// =============================================================================
// Run with:   cd src/go && go mod init target_job && go test -v ./...
//
// Edge-case coverage includes:
//  - Easter dates for several years (Meeus/Jones/Butcher algorithm)
//  - Every category of TARGET closing day
//  - Boundary dates around Easter week (Good Friday, Easter Monday,
//    the Tuesday after Easter Monday, Wednesday of Easter week)
//  - Christmas cluster (Dec 24 open, Dec 25–28 closed, Dec 29 open)
//  - May Day on different weekdays
//  - Cron field matching (*, n, n-m, */n, comma lists)
//  - Cron window evaluation (exact hit, within tolerance, outside tolerance,
//    DOW/DOM/month filtering)
//  - Date-range builder (normal, backfill over long weekend, first run)
// =============================================================================

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

func mustDate(s string) time.Time {
	t, err := time.Parse("2006-01-02", s)
	if err != nil {
		panic(fmt.Sprintf("bad date literal %q: %v", s, err))
	}
	return t
}

func nowAt(hour, minute, year int, month time.Month, day int) time.Time {
	return time.Date(year, month, day, hour, minute, 0, 0, time.UTC)
}

// ---------------------------------------------------------------------------
// easterSunday
// ---------------------------------------------------------------------------

func TestEasterSunday(t *testing.T) {
	cases := []struct {
		year        int
		wantDate    string
		description string
	}{
		{2024, "2024-03-31", "Easter 2024 — March 31"},
		{2025, "2025-04-20", "Easter 2025 — April 20"},
		{2026, "2026-04-05", "Easter 2026 — April 5"},
		{2027, "2027-03-28", "Easter 2027 — March 28"},
		{2028, "2028-04-16", "Easter 2028 — April 16"},
		{2030, "2030-04-21", "Easter 2030 — April 21"},
		{1818, "1818-03-22", "Easter 1818 — earliest possible (Mar 22)"},
		{2019, "2019-04-21", "Easter 2019 — April 21"},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.description, func(t *testing.T) {
			got := easterSunday(tc.year).Format("2006-01-02")
			if got != tc.wantDate {
				t.Errorf("easterSunday(%d) = %s, want %s", tc.year, got, tc.wantDate)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// isTargetClosingDay
// ---------------------------------------------------------------------------

func TestIsTargetClosingDay_Weekend(t *testing.T) {
	cases := []struct{ date, desc string }{
		{"2025-04-19", "Saturday (Easter weekend)"},
		{"2025-04-13", "Regular Sunday"},
		{"2025-09-06", "Regular Saturday"},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.desc, func(t *testing.T) {
			if !isTargetClosingDay(mustDate(tc.date)) {
				t.Errorf("%s (%s) should be a closing day (weekend)", tc.desc, tc.date)
			}
		})
	}
}

func TestIsTargetClosingDay_FixedHolidays(t *testing.T) {
	cases := []struct{ date, desc string }{
		// New Year's Day
		{"2025-01-01", "New Year's Day 2025 (Wednesday)"},
		{"2026-01-01", "New Year's Day 2026 (Thursday)"},
		// May Day
		{"2025-05-01", "May Day 2025 (Thursday)"},
		{"2026-05-01", "May Day 2026 (Friday)"},
		// Christmas / Boxing Day
		{"2025-12-25", "Christmas 2025 (Thursday)"},
		{"2025-12-26", "Boxing Day 2025 (Friday)"},
		{"2026-12-25", "Christmas 2026 (Friday)"},
		{"2026-12-26", "Boxing Day 2026 (Saturday) — double-closed"},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.desc, func(t *testing.T) {
			if !isTargetClosingDay(mustDate(tc.date)) {
				t.Errorf("%s (%s) should be a closing day", tc.desc, tc.date)
			}
		})
	}
}

func TestIsTargetClosingDay_Easter2025(t *testing.T) {
	// Easter Sunday 2025 = April 20
	// Good Friday = April 18, Easter Monday = April 21
	cases := []struct {
		date   string
		closed bool
		desc   string
	}{
		{"2025-04-17", false, "Maundy Thursday — open"},
		{"2025-04-18", true, "Good Friday 2025 — closed"},
		{"2025-04-19", true, "Holy Saturday 2025 — closed (weekend)"},
		{"2025-04-20", true, "Easter Sunday 2025 — closed (weekend)"},
		{"2025-04-21", true, "Easter Monday 2025 — closed"},
		// KEY EDGE CASES: first open days after Easter
		{"2025-04-22", false, "Tuesday after Easter Monday 2025 — open"},
		{"2025-04-23", false, "Wednesday of Easter week 2025 — open"},
		{"2025-04-24", false, "Thursday of Easter week 2025 — open"},
		{"2025-04-25", false, "Friday of Easter week 2025 — open"},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.desc, func(t *testing.T) {
			got := isTargetClosingDay(mustDate(tc.date))
			if got != tc.closed {
				if tc.closed {
					t.Errorf("%s should be CLOSED", tc.desc)
				} else {
					t.Errorf("%s should be OPEN", tc.desc)
				}
			}
		})
	}
}

func TestIsTargetClosingDay_Easter2026(t *testing.T) {
	// Easter Sunday 2026 = April 5
	// Good Friday = April 3, Easter Monday = April 6
	cases := []struct {
		date   string
		closed bool
		desc   string
	}{
		{"2026-04-02", false, "Maundy Thursday 2026 — open"},
		{"2026-04-03", true, "Good Friday 2026 — closed"},
		{"2026-04-04", true, "Holy Saturday 2026 — closed (weekend)"},
		{"2026-04-05", true, "Easter Sunday 2026 — closed (weekend)"},
		{"2026-04-06", true, "Easter Monday 2026 — closed"},
		{"2026-04-07", false, "Tuesday after Easter Monday 2026 — open"},
		{"2026-04-08", false, "Wednesday of Easter week 2026 — open"},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.desc, func(t *testing.T) {
			got := isTargetClosingDay(mustDate(tc.date))
			if got != tc.closed {
				if tc.closed {
					t.Errorf("%s should be CLOSED", tc.desc)
				} else {
					t.Errorf("%s should be OPEN", tc.desc)
				}
			}
		})
	}
}

func TestIsTargetClosingDay_ChristmasCluster2025(t *testing.T) {
	// Christmas 2025: Thu Dec 25 (Christmas), Fri Dec 26 (Boxing Day)
	// Then Sat Dec 27, Sun Dec 28 — weekend
	// Mon Dec 29 is the first open day
	cases := []struct {
		date   string
		closed bool
		desc   string
	}{
		{"2025-12-24", false, "Christmas Eve 2025 (Wed) — open"},
		{"2025-12-25", true, "Christmas Day 2025 (Thu) — closed"},
		{"2025-12-26", true, "Boxing Day 2025 (Fri) — closed"},
		{"2025-12-27", true, "Sat Dec 27 2025 — closed (weekend)"},
		{"2025-12-28", true, "Sun Dec 28 2025 — closed (weekend)"},
		{"2025-12-29", false, "Mon Dec 29 2025 — open (first after Xmas)"},
		{"2025-12-30", false, "Tue Dec 30 2025 — open"},
		{"2025-12-31", false, "Wed Dec 31 2025 — open"},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.desc, func(t *testing.T) {
			got := isTargetClosingDay(mustDate(tc.date))
			if got != tc.closed {
				if tc.closed {
					t.Errorf("%s should be CLOSED", tc.desc)
				} else {
					t.Errorf("%s should be OPEN", tc.desc)
				}
			}
		})
	}
}

func TestIsTargetClosingDay_NewYear2026(t *testing.T) {
	// Jan 1 2026 = Thursday
	cases := []struct {
		date   string
		closed bool
		desc   string
	}{
		{"2025-12-31", false, "Wed Dec 31 2025 — open (last day of year)"},
		{"2026-01-01", true, "New Year's Day 2026 (Thu) — closed"},
		{"2026-01-02", false, "Fri Jan 2 2026 — open"},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.desc, func(t *testing.T) {
			got := isTargetClosingDay(mustDate(tc.date))
			if got != tc.closed {
				if tc.closed {
					t.Errorf("%s should be CLOSED", tc.desc)
				} else {
					t.Errorf("%s should be OPEN", tc.desc)
				}
			}
		})
	}
}

func TestIsTargetClosingDay_MayDay(t *testing.T) {
	// May 1 2025 = Thursday; May 1 2026 = Friday
	cases := []struct {
		date   string
		closed bool
		desc   string
	}{
		{"2025-04-30", false, "Day before May Day 2025 (Wed) — open"},
		{"2025-05-01", true, "May Day 2025 (Thu) — closed"},
		{"2025-05-02", false, "Day after May Day 2025 (Fri) — open"},
		{"2026-04-30", false, "Day before May Day 2026 (Thu) — open"},
		{"2026-05-01", true, "May Day 2026 (Fri) — closed"},
		{"2026-05-02", true, "Sat May 2 2026 — closed (weekend)"},
		{"2026-05-04", false, "Mon May 4 2026 — open"},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.desc, func(t *testing.T) {
			got := isTargetClosingDay(mustDate(tc.date))
			if got != tc.closed {
				if tc.closed {
					t.Errorf("%s should be CLOSED", tc.desc)
				} else {
					t.Errorf("%s should be OPEN", tc.desc)
				}
			}
		})
	}
}

func TestIsTargetClosingDay_OpenDays(t *testing.T) {
	open := []struct{ date, desc string }{
		{"2025-01-02", "First trading day of 2025 (Thu)"},
		{"2025-06-16", "Regular Monday"},
		{"2025-09-22", "Regular Monday"},
		{"2025-11-14", "Regular Friday"},
	}
	for _, tc := range open {
		tc := tc
		t.Run(tc.desc, func(t *testing.T) {
			if isTargetClosingDay(mustDate(tc.date)) {
				t.Errorf("%s (%s) should be OPEN", tc.desc, tc.date)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// matchesCronField
// ---------------------------------------------------------------------------

func TestMatchesCronField_Wildcard(t *testing.T) {
	for _, v := range []int{0, 5, 30, 59} {
		if !matchesCronField("*", v) {
			t.Errorf("* should match %d", v)
		}
	}
}

func TestMatchesCronField_Exact(t *testing.T) {
	if !matchesCronField("19", 19) {
		t.Error("19 should match 19")
	}
	if matchesCronField("19", 20) {
		t.Error("19 should not match 20")
	}
	if !matchesCronField("0", 0) {
		t.Error("0 should match 0")
	}
}

func TestMatchesCronField_Range(t *testing.T) {
	cases := []struct {
		field string
		value int
		want  bool
	}{
		{"1-5", 1, true},
		{"1-5", 5, true},
		{"1-5", 3, true},
		{"1-5", 0, false},
		{"1-5", 6, false},
		{"9-17", 9, true},
		{"9-17", 17, true},
		{"9-17", 18, false},
	}
	for _, tc := range cases {
		got := matchesCronField(tc.field, tc.value)
		if got != tc.want {
			t.Errorf("matchesCronField(%q, %d) = %v, want %v", tc.field, tc.value, got, tc.want)
		}
	}
}

func TestMatchesCronField_Step(t *testing.T) {
	cases := []struct {
		field string
		value int
		want  bool
	}{
		{"*/15", 0, true},
		{"*/15", 15, true},
		{"*/15", 30, true},
		{"*/15", 45, true},
		{"*/15", 1, false},
		{"*/15", 14, false},
		{"*/15", 16, false},
		{"*/2", 0, true},
		{"*/2", 2, true},
		{"*/2", 4, true},
		{"*/2", 1, false},
		{"*/2", 3, false},
	}
	for _, tc := range cases {
		got := matchesCronField(tc.field, tc.value)
		if got != tc.want {
			t.Errorf("matchesCronField(%q, %d) = %v, want %v", tc.field, tc.value, got, tc.want)
		}
	}
}

func TestMatchesCronField_List(t *testing.T) {
	cases := []struct {
		field string
		value int
		want  bool
	}{
		{"0,30", 0, true},
		{"0,30", 30, true},
		{"0,30", 15, false},
		{"1,3,5", 3, true},
		{"1,3,5", 2, false},
		// List mixing range and exact
		{"1-5,10,15", 3, true},
		{"1-5,10,15", 10, true},
		{"1-5,10,15", 15, true},
		{"1-5,10,15", 6, false},
		{"1-5,10,15", 11, false},
	}
	for _, tc := range cases {
		got := matchesCronField(tc.field, tc.value)
		if got != tc.want {
			t.Errorf("matchesCronField(%q, %d) = %v, want %v", tc.field, tc.value, got, tc.want)
		}
	}
}

// ---------------------------------------------------------------------------
// isInCronWindow
// ---------------------------------------------------------------------------

// 2025-04-22 is a Tuesday — so Go weekday = 2 (Tuesday), cron DOW = 2
// 2025-12-25 is a Thursday — weekday = 4, cron DOW = 4

func TestIsInCronWindow_ExactHit(t *testing.T) {
	// Schedule "30 19 * * *", tolerance 15; hit at exactly 19:30
	now := nowAt(19, 30, 2025, time.April, 22) // Tuesday
	if !isInCronWindow(now, "30 19 * * *", 15) {
		t.Error("expected window open at exactly 19:30 with schedule '30 19 * * *'")
	}
}

func TestIsInCronWindow_WithinTolerance(t *testing.T) {
	// 19:44 — 14 minutes after 19:30, tolerance 15 → should fire
	now := nowAt(19, 44, 2025, time.April, 22)
	if !isInCronWindow(now, "30 19 * * *", 15) {
		t.Error("expected window open at 19:44 (14 min after 19:30, tol=15)")
	}
}

func TestIsInCronWindow_AtToleranceBoundary(t *testing.T) {
	// 19:45 — exactly 15 minutes after 19:30, tolerance 15 → should fire
	now := nowAt(19, 45, 2025, time.April, 22)
	if !isInCronWindow(now, "30 19 * * *", 15) {
		t.Error("expected window open at 19:45 (15 min after 19:30, tol=15)")
	}
}

func TestIsInCronWindow_OutsideTolerance(t *testing.T) {
	// 19:46 — 16 minutes after 19:30, tolerance 15 → should NOT fire
	now := nowAt(19, 46, 2025, time.April, 22)
	if isInCronWindow(now, "30 19 * * *", 15) {
		t.Error("expected window CLOSED at 19:46 (16 min after 19:30, tol=15)")
	}
}

func TestIsInCronWindow_BeforeSchedule(t *testing.T) {
	// 19:29 — 1 minute before 19:30, tolerance 15 → should NOT fire
	now := nowAt(19, 29, 2025, time.April, 22)
	if isInCronWindow(now, "30 19 * * *", 15) {
		t.Error("expected window CLOSED at 19:29 (before 19:30)")
	}
}

func TestIsInCronWindow_ZeroTolerance(t *testing.T) {
	// Zero tolerance — only the exact minute fires
	now1 := nowAt(19, 30, 2025, time.April, 22)
	now2 := nowAt(19, 31, 2025, time.April, 22)
	if !isInCronWindow(now1, "30 19 * * *", 0) {
		t.Error("zero tolerance: 19:30 should fire")
	}
	if isInCronWindow(now2, "30 19 * * *", 0) {
		t.Error("zero tolerance: 19:31 should NOT fire")
	}
}

func TestIsInCronWindow_StepSchedule(t *testing.T) {
	// "*/15 * * * *" fires at :00, :15, :30, :45 every hour
	// At 00:16 with tolerance 5: window [00:11, 00:16]; 00:15 matches → fire
	now := nowAt(0, 16, 2025, time.April, 22)
	if !isInCronWindow(now, "*/15 * * * *", 5) {
		t.Error("*/15 schedule: 00:16 with tol=5 should fire (00:15 is in window)")
	}
}

func TestIsInCronWindow_MultipleHours(t *testing.T) {
	// "0 8,12,17 * * *" — fires at 08:00, 12:00, 17:00
	// At 12:03 with tolerance 5 → fire (12:00 in window)
	now := nowAt(12, 3, 2025, time.April, 22)
	if !isInCronWindow(now, "0 8,12,17 * * *", 5) {
		t.Error("multi-hour schedule: 12:03 tol=5 should fire")
	}
	// At 09:00 → fire (08:00 + 60 tol? No — 09:00 is 60 min after 08:00, > tol=5)
	now2 := nowAt(9, 0, 2025, time.April, 22)
	if isInCronWindow(now2, "0 8,12,17 * * *", 5) {
		t.Error("multi-hour schedule: 09:00 tol=5 should NOT fire")
	}
}

func TestIsInCronWindow_DOWFilter_Weekday(t *testing.T) {
	// "30 19 * * 1-5" — weekdays only (Mon=1 to Fri=5)
	// April 22 2025 = Tuesday (Go weekday 2 = cron DOW 2) → fire
	tue := nowAt(19, 30, 2025, time.April, 22)
	if !isInCronWindow(tue, "30 19 * * 1-5", 15) {
		t.Error("Tuesday 19:30 should fire with '30 19 * * 1-5'")
	}
	// April 19 2025 = Saturday (Go weekday 6 = cron DOW 6) → no fire
	sat := nowAt(19, 30, 2025, time.April, 19)
	if isInCronWindow(sat, "30 19 * * 1-5", 15) {
		t.Error("Saturday 19:30 should NOT fire with '30 19 * * 1-5'")
	}
	// April 20 2025 = Sunday (Go weekday 0 = cron DOW 0) → no fire
	sun := nowAt(19, 30, 2025, time.April, 20)
	if isInCronWindow(sun, "30 19 * * 1-5", 15) {
		t.Error("Sunday 19:30 should NOT fire with '30 19 * * 1-5'")
	}
}

func TestIsInCronWindow_MonthFilter(t *testing.T) {
	// "30 19 * 4 *" — only in April
	apr := nowAt(19, 30, 2025, time.April, 22)
	if !isInCronWindow(apr, "30 19 * 4 *", 15) {
		t.Error("April date should fire with month=4")
	}
	may := nowAt(19, 30, 2025, time.May, 22)
	if isInCronWindow(may, "30 19 * 4 *", 15) {
		t.Error("May date should NOT fire with month=4")
	}
}

func TestIsInCronWindow_SundayAlias7(t *testing.T) {
	// cron "30 19 * * 7" — Sunday using 7 alias
	// April 20 2025 = Sunday
	sun := nowAt(19, 30, 2025, time.April, 20)
	if !isInCronWindow(sun, "30 19 * * 7", 15) {
		t.Error("Sunday should match DOW=7 (Sun alias)")
	}
	// Monday should not match
	mon := nowAt(19, 30, 2025, time.April, 21)
	if isInCronWindow(mon, "30 19 * * 7", 15) {
		t.Error("Monday should NOT match DOW=7")
	}
}

// ---------------------------------------------------------------------------
// getReportDates
// ---------------------------------------------------------------------------

func makeTestConfig(t *testing.T, anchorDate string) (Config, string) {
	t.Helper()
	dir := t.TempDir()
	cfg := Config{
		JobCommand:           "echo",
		CronSchedule:         "30 19 * * 1-5",
		CronToleranceMinutes: 15,
		AnchorDate:           anchorDate,
		RunDir:               dir,
		MaxLogBytes:          10 * 1024 * 1024,
	}
	return cfg, dir
}

func writeStateFile(t *testing.T, dir string, lines ...string) {
	t.Helper()
	f, err := os.OpenFile(filepath.Join(dir, "target_job_success.log"),
		os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0644)
	if err != nil {
		t.Fatalf("writeStateFile: %v", err)
	}
	defer f.Close()
	for _, l := range lines {
		fmt.Fprintln(f, l)
	}
}

func fmtDates(dates []time.Time) []string {
	s := make([]string, len(dates))
	for i, d := range dates {
		s[i] = d.Format("2006-01-02")
	}
	return s
}

func TestGetReportDates_FirstRun(t *testing.T) {
	// No state file → should start from anchor date
	cfg, _ := makeTestConfig(t, "2025-04-22")
	today := mustDate("2025-04-22")
	dates := getReportDates(cfg, today)
	got := fmtDates(dates)
	want := []string{"2025-04-22"}
	if len(got) != len(want) || got[0] != want[0] {
		t.Errorf("first run: got %v, want %v", got, want)
	}
}

func TestGetReportDates_SingleDayBackfill(t *testing.T) {
	cfg, dir := makeTestConfig(t, "2025-01-01")
	writeStateFile(t, dir, "2025-04-21  executed_at=2025-04-21 19:30:05")
	today := mustDate("2025-04-22")
	dates := getReportDates(cfg, today)
	got := fmtDates(dates)
	want := []string{"2025-04-22"}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Errorf("single-day backfill: got %v, want %v", got, want)
	}
}

func TestGetReportDates_EasterWeekBackfill(t *testing.T) {
	// Last success: Thursday April 17 (Maundy Thursday, open)
	// Today: Tuesday April 22 (day after Easter Monday)
	// Expected: Apr 18, 19, 20, 21, 22 — ALL dates including closing days
	// (the script passes them all to JOB_COMMAND; the downstream job filters)
	cfg, dir := makeTestConfig(t, "2025-01-01")
	writeStateFile(t, dir, "2025-04-17  executed_at=2025-04-17 19:30:01")
	today := mustDate("2025-04-22")
	dates := getReportDates(cfg, today)
	got := fmtDates(dates)
	want := []string{"2025-04-18", "2025-04-19", "2025-04-20", "2025-04-21", "2025-04-22"}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Errorf("Easter week backfill:\n got  %v\n want %v", got, want)
	}
}

func TestGetReportDates_ChristmasBackfill(t *testing.T) {
	// Last success: Wednesday Dec 24 2025
	// Today: Monday Dec 29 2025 (first open day after Christmas + Boxing Day + weekend)
	// Expected: Dec 25, 26, 27, 28, 29 (all 5 dates)
	cfg, dir := makeTestConfig(t, "2025-01-01")
	writeStateFile(t, dir, "2025-12-24  executed_at=2025-12-24 19:30:00")
	today := mustDate("2025-12-29")
	dates := getReportDates(cfg, today)
	got := fmtDates(dates)
	want := []string{"2025-12-25", "2025-12-26", "2025-12-27", "2025-12-28", "2025-12-29"}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Errorf("Christmas backfill:\n got  %v\n want %v", got, want)
	}
}

func TestGetReportDates_MayDayLongWeekend2026(t *testing.T) {
	// May Day 2026 = Friday May 1
	// Last success: Thursday April 30, today: Monday May 4
	// Expected: May 1, 2, 3, 4
	cfg, dir := makeTestConfig(t, "2026-01-01")
	writeStateFile(t, dir, "2026-04-30  executed_at=2026-04-30 19:30:00")
	today := mustDate("2026-05-04")
	dates := getReportDates(cfg, today)
	got := fmtDates(dates)
	want := []string{"2026-05-01", "2026-05-02", "2026-05-03", "2026-05-04"}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Errorf("May Day backfill:\n got  %v\n want %v", got, want)
	}
}

func TestGetReportDates_AnchorEdge(t *testing.T) {
	// Anchor = 2025-04-22, no state file, today = 2025-04-22
	// Should produce exactly [2025-04-22]
	cfg, _ := makeTestConfig(t, "2025-04-22")
	dates := getReportDates(cfg, mustDate("2025-04-22"))
	if len(dates) != 1 || dates[0].Format("2006-01-02") != "2025-04-22" {
		t.Errorf("anchor edge: got %v, want [2025-04-22]", fmtDates(dates))
	}
}

// ---------------------------------------------------------------------------
// hasRunSuccessfullyToday
// ---------------------------------------------------------------------------

func TestHasRunSuccessfullyToday(t *testing.T) {
	cfg, dir := makeTestConfig(t, "2025-01-01")
	today := mustDate("2025-04-22")

	// No state file yet
	if hasRunSuccessfullyToday(cfg, today) {
		t.Error("should return false with no state file")
	}

	// Write a success entry
	writeStateFile(t, dir, "2025-04-22  executed_at=2025-04-22 19:30:05")
	if !hasRunSuccessfullyToday(cfg, today) {
		t.Error("should return true after writing today's success")
	}

	// Different date in state file
	cfg2, dir2 := makeTestConfig(t, "2025-01-01")
	cfg2.RunDir = dir2
	writeStateFile(t, dir2, "2025-04-21  executed_at=2025-04-21 19:30:05")
	if hasRunSuccessfullyToday(cfg2, today) {
		t.Error("should return false when state has different date")
	}
}

// ---------------------------------------------------------------------------
// validateCronSchedule
// ---------------------------------------------------------------------------

func TestValidateCronSchedule(t *testing.T) {
	good := []string{
		"30 19 * * *",
		"30 19 * * 1-5",
		"*/15 * * * *",
		"0 8,12,17 * * 1-5",
		"0 0 1 1 0",
	}
	for _, s := range good {
		if err := validateCronSchedule(s); err != nil {
			t.Errorf("validateCronSchedule(%q) unexpected error: %v", s, err)
		}
	}
	bad := []string{
		"",
		"30 19",
		"30 19 *",
		"30 19 * *",
		"30 19 * * * extra",
	}
	for _, s := range bad {
		if err := validateCronSchedule(s); err == nil {
			t.Errorf("validateCronSchedule(%q) expected error, got nil", s)
		}
	}
}

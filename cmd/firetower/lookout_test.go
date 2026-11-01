package main

import (
	"strings"
	"testing"
	"time"
)

func TestCleanText(t *testing.T) {
	for in, want := range map[string]string{
		"plain":                                 "plain",
		"  two\n\nlines\r\n ":                   "two lines",
		"\x1b[31mred\x1b[0m":                    "red",
		"\x1b]8;;https://x\x07link\x1b]8;;\x07": "link",
		"\x1b]0;title\x1b\\after":               "after",
		"a\u202eb\u2066c":                       "abc",
		"bell\x07 and \x00null":                 "bell and null",
		"emoji 🔥 stays":                         "emoji 🔥 stays",
		"bad \xff utf8":                         "bad ? utf8",
	} {
		if got := cleanText(in, 200); got != want {
			t.Errorf("cleanText(%q) = %q, want %q", in, got, want)
		}
	}
	if got := cleanText(strings.Repeat("é", 300), 200); len([]rune(got)) != 200 || !strings.HasSuffix(got, "…") {
		t.Errorf("not cut to 200 runes: %d", len([]rune(got)))
	}
}

func TestSpans(t *testing.T) {
	for in, want := range map[string]time.Duration{
		"30m": 30 * time.Minute, "4h": 4 * time.Hour, "1d": 24 * time.Hour, "1d12h": 36 * time.Hour, "90s": 90 * time.Second,
	} {
		if got, err := parseSpan(in); err != nil || got != want {
			t.Errorf("parseSpan(%q) = %v, %v; want %v", in, got, err, want)
		}
	}
	for _, bad := range []string{"soon", "-5m", "d", "1x"} {
		if _, err := parseSpan(bad); err == nil {
			t.Errorf("parseSpan(%q) should fail", bad)
		}
	}
}

func TestWhen(t *testing.T) {
	at := time.Date(2026, 10, 31, 14, 0, 0, 0, time.Local)
	for in, want := range map[string]time.Time{
		"30m":                  at.Add(30 * time.Minute),
		"1d":                   at.Add(24 * time.Hour),
		"23:59":                time.Date(2026, 10, 31, 23, 59, 0, 0, time.Local),
		"09:00":                time.Date(2026, 11, 1, 9, 0, 0, 0, time.Local), // past today: tomorrow's
		"today 18:00":          time.Date(2026, 10, 31, 18, 0, 0, 0, time.Local),
		"tomorrow 07:00":       time.Date(2026, 11, 1, 7, 0, 0, 0, time.Local),
		"2026-11-01T06:00:00Z": time.Date(2026, 11, 1, 6, 0, 0, 0, time.UTC),
	} {
		u, _, err := parseWhen("next", in, at)
		if err != nil || !u.Equal(want) {
			t.Errorf("parseWhen(%q) = %v, %v; want %v", in, u, err, want)
		}
	}
	for _, bad := range []string{"soon", "25:00", "12:60", "yesterday 10:00"} {
		if _, _, err := parseWhen("next", bad, at); err == nil {
			t.Errorf("parseWhen(%q) should fail", bad)
		}
	}
	if u, _, err := parseWhen("until", "none", at); u != nil || err != nil {
		t.Error("none should clear it")
	}
}

func TestNames(t *testing.T) {
	for _, ok := range []string{"deploy", "deploy-landed", "a.b_c", "0x"} {
		if checkName("n", ok) != nil {
			t.Errorf("%q should be a name", ok)
		}
	}
	for _, bad := range []string{"", ".", "..", ".x", "-x", "A", "a/b", "a b", "a\\b", strings.Repeat("x", 65)} {
		if checkName("n", bad) == nil {
			t.Errorf("%q should not be a name", bad)
		}
	}
}

func TestCompareVersions(t *testing.T) {
	for _, c := range []struct {
		a, b string
		want int
	}{
		{"v1.0.0", "v1.0.0", 0}, {"v1.0.1", "v1.0.0", 1}, {"v1.10.0", "v1.9.9", 1},
		{"v1.0.0", "v1.0.0-rc1", 1}, {"v1.0.0-rc2", "v1.0.0-rc1", 1}, {"v0.9.0", "v1.0.0", -1},
	} {
		got := compareVersions(c.a, c.b)
		if (got > 0) != (c.want > 0) || (got < 0) != (c.want < 0) {
			t.Errorf("compareVersions(%s, %s) = %d, want sign of %d", c.a, c.b, got, c.want)
		}
	}
	for _, bad := range []string{"1.0.0", "v1.0", "dev", "vx.y.z", ""} {
		if _, _, ok := parseSemver(bad); ok {
			t.Errorf("%q should not be a version", bad)
		}
	}
}

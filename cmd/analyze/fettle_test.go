//go:build darwin

package main

import (
	"fmt"
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
)

func fettleListModel(width, height, entries int) model {
	m := model{path: "/fixture", width: width, height: height}
	for i := range entries {
		m.entriesAll = append(m.entriesAll, dirEntry{
			Name: fmt.Sprintf("entry-%03d", i),
			Path: fmt.Sprintf("/fixture/entry-%03d", i),
			Size: int64(entries - i),
		})
	}
	m.entries = m.entriesAll
	m.totalSize = int64(entries * entries)
	return m
}

func TestAnalyzeKeepsMolesWidthsOutsideAFrame(t *testing.T) {
	if analyzeTermWidth != 0 {
		t.Fatalf("analyzeTermWidth = %d before any frame, want 0", analyzeTermWidth)
	}
	if got := analyzeBarWidth(); got != barWidth {
		t.Errorf("bar = %d, want Mole's %d", got, barWidth)
	}
	if got := calculateNameWidth(200); got != classicNameWidth {
		t.Errorf("name at 200 columns outside a frame = %d, want Mole's %d", got, classicNameWidth)
	}
}

func TestAnalyzeRowsStretchToTheWindowAndNoFurther(t *testing.T) {
	for _, width := range []int{80, 121, 130, 200, 400} {
		analyzeTermWidth = width
		name, bar := calculateNameWidth(width), analyzeBarWidth()
		analyzeTermWidth = 0
		if width <= nameFixedWidth+classicNameWidth {
			if bar != barWidth {
				t.Errorf("width %d: bar = %d, want Mole's %d", width, bar, barWidth)
			}
			continue
		}
		if used := nameFixedWidth + (bar - barWidth) + name; used != width {
			t.Errorf("width %d: row uses %d columns (bar %d, name %d), want all of them", width, used, bar, name)
		}
		if bar > maxAnalyzeBarWidth {
			t.Errorf("width %d: bar = %d, want at most %d", width, bar, maxAnalyzeBarWidth)
		}
	}
}

func TestAnalyzeFrameFillsTheWindowWithTheKeysOnTheLastRow(t *testing.T) {
	for _, tc := range []struct{ width, height, entries int }{
		{200, 60, 5},   // a short list: blank rows push the keys down
		{200, 60, 300}, // a long list: more than Mole's 30 rows show
		{80, 24, 5},
	} {
		view := fettleListModel(tc.width, tc.height, tc.entries).View()
		if analyzeTermWidth != 0 {
			t.Fatalf("View left analyzeTermWidth = %d, want 0", analyzeTermWidth)
		}
		lines := strings.Split(view, "\n")
		if len(lines) != tc.height {
			t.Errorf("%dx%d, %d entries: %d rows, want %d", tc.width, tc.height, tc.entries, len(lines), tc.height)
		}
		if last := lines[len(lines)-1]; !strings.Contains(last, "Quit") {
			t.Errorf("%dx%d: last row = %q, want the keys line", tc.width, tc.height, last)
		}
		// At 80 columns Mole's own rows run past the window (its name column
		// keeps 24 columns), which Fettle leaves alone; it only widens rows
		// past Mole's widest layout.
		for i, line := range lines {
			if w := lipgloss.Width(line); tc.width > nameFixedWidth+classicNameWidth && w > tc.width {
				t.Errorf("%dx%d: row %d is %d columns wide", tc.width, tc.height, i, w)
			}
		}
		if tc.entries > 30 && !strings.Contains(view, "entry-040") {
			t.Errorf("%dx%d: a long list stops before row 41", tc.width, tc.height)
		}
	}
}

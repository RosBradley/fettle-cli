//go:build darwin

package main

import "strings"

// glimwell: Analyze fills the window, as Status does. Mole stops at 30 rows,
// a 60-column name and a 24-cell bar, so a big window kept a small list with
// its keys line floating under it. Here the list runs to the bottom of the
// window, the keys line sits on the last row, and the columns past Mole's
// widest layout are shared between a longer bar and a longer name.

// analyzeTermWidth is the width of the window the frame being drawn fills.
// View sets it and clears it when the frame is done, so a bar drawn outside
// a frame (tests, say) keeps Mole's widths.
var analyzeTermWidth int

const (
	classicNameWidth   = 60 // Mole's widest name column
	nameFixedWidth     = 61 // every column of a row but the name, at Mole's bar width
	maxAnalyzeBarWidth = 64
)

// analyzeExtraWidth is how many columns the window has past Mole's widest row.
func analyzeExtraWidth() int {
	if analyzeTermWidth <= 0 {
		return 0
	}
	return max(analyzeTermWidth-nameFixedWidth-classicNameWidth, 0)
}

// analyzeBarWidth is the bar's width: Mole's, plus half the extra columns.
func analyzeBarWidth() int {
	return min(barWidth+analyzeExtraWidth()/2, maxAnalyzeBarWidth)
}

// analyzeNameWidth is the widest name column: Mole's, plus the extra columns
// the bar didn't take.
func analyzeNameWidth() int {
	return classicNameWidth + analyzeExtraWidth() - (analyzeBarWidth() - barWidth)
}

// fillWindowHeight puts blank lines between the list and the keys below it,
// so the last line of the keys is the window's last row. A frame of height
// rows holds height-1 newlines, so the footer's own final newline goes: it
// would leave an empty row under the keys. A frame already as tall as the
// window gets no blank lines.
func fillWindowHeight(body, footer string, height int) string {
	if height <= 0 {
		return body + footer
	}
	footer = strings.TrimSuffix(footer, "\n")
	lines := strings.Count(body, "\n") + strings.Count(footer, "\n")
	if lines >= height-1 {
		return body + footer
	}
	return body + strings.Repeat("\n", height-1-lines) + footer
}

// glimwellBadge is the Glimwell mark in front of the Analyze title: a white G and
// a copper dot on verdigris, as on the Status title. Four columns, then two
// spaces.
const glimwellBadge = "\033[1;97;48;5;30m G\033[0;38;5;166;48;5;30m▪\033[0;48;5;30m \033[0m  "

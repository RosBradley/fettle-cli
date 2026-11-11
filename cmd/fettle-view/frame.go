package main

import (
	"slices"
	"strings"

	"github.com/charmbracelet/x/ansi"
)

// The command screen keeps what does not scroll at the edges: the title and
// the command's summary at the top, and at the bottom a bar that says what
// is happening and which keys work, where the eyes are while output streams
// in. The output scrolls between them.

// spinnerFrames match Mole's own spinner (lib/core/ui.sh, cmd/analyze).
var spinnerFrames = []string{"⠖", "⠲", "⠴", "⠦"}

// barSeparator joins the parts of the bar.
const barSeparator = "  |  "

// topRows returns the rows above the output: the title with a note on the
// right, the summary rows and a divider.
func topRows(title, note string, summary []string, width int) []string {
	rows := []string{header(title, note, width)}
	for _, s := range summary {
		rows = append(rows, ansi.Truncate(s, width, "…"))
	}
	return append(rows, divider(width))
}

// bottomRows returns the rows below the output: a divider and the bar.
func bottomRows(bar string, width int) []string {
	return []string{divider(width), ansi.Truncate(bar, width, "…")}
}

func divider(width int) string {
	return grayStyle + strings.Repeat("─", width) + resetStyle
}

// fitBar joins the status and the keys, dropping the optional keys, in
// order, until the bar fits the width; then it shortens the status, so the
// keys that are left stay whole. The keys show in gray.
func fitBar(status string, keys, optional []string, width int) string {
	for {
		parts := make([]string, 0, len(keys))
		for _, k := range keys {
			parts = append(parts, grayStyle+k+resetStyle)
		}
		keyText := strings.Join(parts, barSeparator)
		if status == "" {
			if ansi.StringWidth(keyText) <= width || len(optional) == 0 {
				return keyText
			}
		} else {
			bar := status + barSeparator + keyText
			if keyText == "" {
				bar = status
			}
			if ansi.StringWidth(bar) <= width {
				return bar
			}
			if len(optional) == 0 {
				room := width - ansi.StringWidth(keyText) - len(barSeparator)
				if keyText == "" || room < 4 {
					return bar
				}
				return ansi.Truncate(status, room, "…") + resetStyle + barSeparator + keyText
			}
		}
		keys = slices.DeleteFunc(slices.Clone(keys), func(k string) bool { return k == optional[0] })
		optional = optional[1:]
	}
}

// waitingBar is the bar while the command waits for a key: no spinner.
func waitingBar(width int) string {
	return fitBar("· Waiting for you", []string{"Keys go to the command", "Ctrl-C Stop"}, []string{"Keys go to the command"}, width)
}

// liveBar is the bar while the command runs.
func liveBar(spin string, width int) string {
	return fitBar(spin+" Running", []string{"Keys go to the command", "Ctrl-C Stop"}, []string{"Keys go to the command"}, width)
}

// header is the title row: the Fettle badge and the title, and a gray note
// on the right. A window too narrow for the badge drops it.
func header(title, note string, width int) string {
	mark := badge
	if width < 20 {
		mark = ""
	}
	room := width - ansi.StringWidth(mark) - ansi.StringWidth(note) - 1
	title = ansi.Truncate(title, max(1, room), "…")
	row := mark + titleStyle + title + resetStyle
	if note != "" {
		gap := max(1, width-ansi.StringWidth(mark)-ansi.StringWidth(title)-ansi.StringWidth(note))
		row += strings.Repeat(" ", gap) + grayStyle + note + resetStyle
	}
	return row
}

// placeholder is the summary while the command runs: its labels, with the
// spinner where the numbers will go.
func placeholder(labels []string, spin string) []string {
	if len(labels) == 0 {
		return nil
	}
	parts := make([]string, len(labels))
	for i, label := range labels {
		parts[i] = label + ": " + grayStyle + spin + resetStyle
	}
	return []string{strings.Join(parts, " | ")}
}

// splitSummary takes the command's closing summary out of its output. Mole
// prints every summary as a block between two rows of "=" (print_summary_block
// in lib/core/log.sh); the last such block is the summary.
func splitSummary(lines []string) (rest, summary []string) {
	end := -1
	for i, line := range slices.Backward(lines) {
		if isRule(line) {
			end = i
			break
		}
	}
	start := -1
	for i := end - 1; i >= 0; i-- {
		if isRule(lines[i]) {
			start = i
			break
		}
	}
	if start < 0 {
		return lines, nil
	}
	for _, l := range lines[start+1 : end] {
		if strings.TrimSpace(ansi.Strip(l)) != "" {
			summary = append(summary, l)
		}
	}
	rest = trimBlankEnd(append([]string(nil), lines[:start]...))
	rest = append(rest, lines[end+1:]...)
	return trimBlankEnd(rest), summary
}

func isRule(line string) bool {
	s := strings.TrimSpace(ansi.Strip(line))
	return len(s) >= 10 && strings.Trim(s, "=") == ""
}

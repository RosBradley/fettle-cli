package main

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
)

func numbered(n int) []string {
	out := make([]string, n)
	for i := range out {
		out[i] = fmt.Sprintf("line %d", i+1)
	}
	return out
}

func press(m model, keys ...string) model {
	for _, k := range keys {
		var msg tea.KeyMsg
		switch k {
		case "up", "down", "pgup", "pgdown", "home", "end", "enter", "esc", "ctrl+c", "backspace":
			msg = tea.KeyMsg{Type: map[string]tea.KeyType{
				"up": tea.KeyUp, "down": tea.KeyDown, "pgup": tea.KeyPgUp, "pgdown": tea.KeyPgDown,
				"home": tea.KeyHome, "end": tea.KeyEnd, "enter": tea.KeyEnter, "esc": tea.KeyEsc, "ctrl+c": tea.KeyCtrlC,
				"backspace": tea.KeyBackspace,
			}[k]}
		case " ":
			msg = tea.KeyMsg{Type: tea.KeySpace, Runes: []rune{' '}}
		default:
			msg = tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(k)}
		}
		next, _ := m.Update(msg)
		m = next.(model)
	}
	return m
}

func quits(m model, key string) bool {
	msg := tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(key)}
	if key == "enter" {
		msg = tea.KeyMsg{Type: tea.KeyEnter}
	}
	_, cmd := m.Update(msg)
	if cmd == nil {
		return false
	}
	_, ok := cmd().(tea.QuitMsg)
	return ok
}

func TestViewOpensAtTheEndAndScrolls(t *testing.T) {
	m := newModel("Clean · Preview", numbered(100), 0, "", nil, 40, 12)
	// 12 rows: the title and a divider at the top, 8 lines, then a divider
	// and the bar at the bottom.
	if m.offset[outputPage] != 92 {
		t.Fatalf("starts at %d, want the last page (92)", m.offset[outputPage])
	}
	view := ansi.Strip(m.View())
	rows := strings.Split(view, "\n")
	if len(rows) != 12 || !strings.HasPrefix(rows[0], " F▪   Clean · Preview") || !strings.HasSuffix(rows[0], "93-100 of 100") {
		t.Fatalf("view rows %d, title %q", len(rows), rows[0])
	}
	if rows[1] != strings.Repeat("─", 40) || rows[10] != strings.Repeat("─", 40) {
		t.Errorf("dividers %q, %q", rows[1], rows[10])
	}
	if !strings.HasPrefix(rows[11], "✓ Done") || !strings.HasSuffix(rows[11], "Q Back to menu") {
		t.Errorf("bar %q", rows[11])
	}
	if rows[2] != "line 93" || rows[9] != "line 100" {
		t.Errorf("body %q .. %q", rows[2], rows[9])
	}
	m = press(m, "up", "up", "pgup")
	if m.offset[outputPage] != 82 {
		t.Errorf("after up, up, pgup: %d", m.offset[outputPage])
	}
	m = press(m, "home", "up")
	if m.offset[outputPage] != 0 {
		t.Errorf("home then up: %d", m.offset[outputPage])
	}
	m = press(m, "end", "down", "pgdown")
	if m.offset[outputPage] != 92 {
		t.Errorf("end, down, pgdown: %d", m.offset[outputPage])
	}
}

func TestViewShortOutputHasNoPosition(t *testing.T) {
	m := newModel("Touch ID", []string{"Touch ID is not configured"}, 0, "", nil, 40, 12)
	view := ansi.Strip(m.View())
	if strings.Contains(view, " of ") || !strings.Contains(view, "Touch ID is not configured") {
		t.Errorf("view %q", view)
	}
	if strings.Contains(view, "File list") {
		t.Error("F offered without a file")
	}
}

func TestViewFileListOnF(t *testing.T) {
	long := "/Users/me/Library/Caches/" + strings.Repeat("a", 50) + "/file.cache"
	m := newModel("Clean · Preview", numbered(5), 0, "/tmp/clean-list.txt", []string{"# Clean list", long}, 40, 12)
	if !strings.Contains(ansi.Strip(m.View()), "F File list") {
		t.Fatal("F not offered")
	}
	m = press(m, "F")
	if m.page != filePage {
		t.Fatal("F did not open the file list")
	}
	view := ansi.Strip(m.View())
	if !strings.HasPrefix(view, " F▪   File list: /tmp/clean-list.txt") || !strings.Contains(view, "Q Back to results") {
		t.Errorf("file view %q", view)
	}
	// The long path wraps instead of being cut.
	if !strings.Contains(strings.ReplaceAll(view, "\n", ""), long) {
		t.Errorf("path not shown whole: %q", view)
	}
	if quits(m, "q") {
		t.Fatal("Q on the file list left the screen")
	}
	m = press(m, "q")
	if m.page != outputPage {
		t.Fatal("Q on the file list did not go back to the results")
	}
	if !quits(m, "q") || !quits(m, "enter") {
		t.Error("Q or Enter on the results does not go back to the menu")
	}
}

func TestBarDropsHintsBeforeTheStatusAndTheBackKey(t *testing.T) {
	m := newModel("Clean", numbered(3), 0, "/tmp/x", []string{"x"}, 120, 12)
	if k := ansi.Strip(m.bar(120)); !strings.Contains(k, "Home End") || !strings.Contains(k, "PgUp PgDn") || !strings.Contains(k, "/ Search") {
		t.Errorf("wide bar %q", k)
	}
	k := ansi.Strip(m.bar(50))
	if k != "✓ Done  |  F File list  |  Q Back to menu" {
		t.Errorf("narrow bar %q", k)
	}
}

func cleanPreviewOutput() []string {
	out := numbered(20)
	return append(out, "",
		strings.Repeat("=", 70),
		"\x1b[1;34mDry run complete - no changes made\x1b[0m",
		"Potential space: \x1b[0;33m611.0MB\x1b[0m | Items: 84 | Categories: 6",
		"Detailed file list: \x1b[0;38;5;244m/tmp/clean-list.txt\x1b[0m",
		"Use mo clean --whitelist to add protection rules",
		strings.Repeat("=", 70))
}

func TestSummaryIsPinnedAtTheTop(t *testing.T) {
	m := newModel("Clean · Preview", cleanPreviewOutput(), 0, "/tmp/clean-list.txt", []string{"x"}, 80, 16)
	rows := strings.Split(ansi.Strip(m.View()), "\n")
	if len(rows) != 16 {
		t.Fatalf("%d rows", len(rows))
	}
	want := []string{
		"Dry run complete - no changes made",
		"Potential space: 611.0MB | Items: 84 | Categories: 6",
		"Detailed file list: /tmp/clean-list.txt  (F to view)",
		"Use mo clean --whitelist to add protection rules",
	}
	for i, w := range want {
		if rows[1+i] != w {
			t.Errorf("summary row %d = %q, want %q", i, rows[1+i], w)
		}
	}
	if !strings.HasPrefix(rows[5], "───") {
		t.Errorf("divider %q", rows[5])
	}
	// The bar at the bottom repeats the summary's heading, where the eyes are.
	if !strings.HasPrefix(rows[15], "✓ Dry run complete - no changes made") {
		t.Errorf("bar %q", rows[15])
	}
	// The summary is not repeated at the end of the output.
	body := strings.Join(rows[6:14], "\n")
	if strings.Contains(body, "Potential space") || strings.Contains(body, "=====") || !strings.HasSuffix(body, "line 20") {
		t.Errorf("body %q", body)
	}
	// The file list shows no summary.
	m = press(m, "F")
	if strings.Contains(ansi.Strip(m.View()), "Potential space") {
		t.Error("the summary stayed on the file list")
	}
}

func TestSplitSummaryNeedsAWholeBlock(t *testing.T) {
	lines := []string{"a", strings.Repeat("=", 70), "b"}
	if rest, summary := splitSummary(lines); summary != nil || len(rest) != 3 {
		t.Errorf("one rule: %q %q", rest, summary)
	}
	lines = []string{"a", strings.Repeat("=", 70), "Done", strings.Repeat("=", 70), "after"}
	if rest, summary := splitSummary(lines); strings.Join(summary, ",") != "Done" || strings.Join(rest, ",") != "a,after" {
		t.Errorf("block: %q %q", rest, summary)
	}
	if rest, summary := splitSummary([]string{"=== a heading ==="}); summary != nil || len(rest) != 1 {
		t.Errorf("text with = signs: %q %q", rest, summary)
	}
}

func TestRunNeedsACommandAndATerminal(t *testing.T) {
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = r.Close(); _ = w.Close() }()
	var stderr strings.Builder
	if code := run([]string{"--title", "x"}, r, w, &stderr); code != 2 || !strings.Contains(stderr.String(), "Usage") {
		t.Errorf("no command: %d %q", code, stderr.String())
	}
	// Without a terminal the menu runs the command the plain way, told so by
	// the --unstarted file.
	unstarted := filepath.Join(t.TempDir(), "unstarted")
	if code := run([]string{"--unstarted", unstarted, "--", "true"}, r, w, &stderr); code != exitCannotRun {
		t.Errorf("no terminal: %d", code)
	}
	if _, err := os.Stat(unstarted); err != nil {
		t.Errorf("no --unstarted file: %v", err)
	}
	if _, ok := readFileLines(filepath.Join(t.TempDir(), "missing")); ok {
		t.Error("a missing file was read")
	}
}

func TestFileWrittenSinceTheRunStarted(t *testing.T) {
	path := filepath.Join(t.TempDir(), "clean-list.txt")
	if err := os.WriteFile(path, []byte("x\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-time.Hour)
	if err := os.Chtimes(path, old, old); err != nil {
		t.Fatal(err)
	}
	if fileWrittenSince(path, time.Now()) {
		t.Error("an hour-old list counts as this run's")
	}
	start := time.Now()
	if err := os.WriteFile(path, []byte("y\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if !fileWrittenSince(path, start) {
		t.Error("a list written during the run is not offered")
	}
}

// keystrokes hands the program one key per read, as a terminal does.
type keystrokes struct{ keys []string }

func (r *keystrokes) Read(p []byte) (int, error) {
	if len(r.keys) == 0 {
		return 0, io.EOF
	}
	n := copy(p, r.keys[0])
	r.keys = r.keys[1:]
	return n, nil
}

func TestShowRunsTheScreenUntilQ(t *testing.T) {
	m := newModel("Clean · Preview", numbered(100), 0, "/tmp/clean-list.txt", []string{"# list"}, 40, 12)
	var out bytes.Buffer
	// Up twice, then F, Q (back to the results) and Q (back to the menu).
	keys := &keystrokes{keys: []string{"\x1b[A", "\x1b[A", "F", "q", "q"}}
	final, err := show(m, tea.WithInput(keys), tea.WithOutput(&out))
	if err != nil {
		t.Fatal(err)
	}
	if final.page != outputPage || final.offset[outputPage] != 90 {
		t.Errorf("ended on page %d at %d", final.page, final.offset[outputPage])
	}
	if !strings.Contains(ansi.Strip(out.String()), "Clean · Preview") {
		t.Error("the screen was never drawn")
	}

	// Ctrl-C leaves from the file list too.
	keys = &keystrokes{keys: []string{"F", "\x03"}}
	if final, err = show(m, tea.WithInput(keys), tea.WithOutput(&out)); err != nil || final.page != filePage {
		t.Errorf("Ctrl-C on the file list: page %d, %v", final.page, err)
	}
}

func TestKeysThatArriveTogetherEachCount(t *testing.T) {
	m := newModel("Clean", numbered(100), 0, "", nil, 40, 12)
	next, _ := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("kkk")})
	if got := next.(model).offset[outputPage]; got != 89 {
		t.Errorf("kkk scrolled to %d, want 89", got)
	}
	if _, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("kq")}); cmd == nil {
		t.Error("a q among other keys did not leave")
	}
}

func TestFinishStatusSaysHowTheCommandEnded(t *testing.T) {
	heading := []string{"\x1b[1;34mUpdates installed\x1b[0m", "Updated 1"}
	for _, c := range []struct {
		summary []string
		code    int
		want    string
	}{
		{heading, 0, "✓ Updates installed"},
		{nil, 0, "✓ Done"},
		{nil, 130, "■ Stopped"},
		{heading, -1, "■ Stopped"},
		{[]string{"Some updates did not install"}, 1, "! Some updates did not install"},
		{nil, 2, "! Ended with an error (exit status 2)"},
	} {
		if got := ansi.Strip(finishStatus(c.summary, c.code)); got != c.want {
			t.Errorf("finishStatus(%q, %d) = %q, want %q", c.summary, c.code, got, c.want)
		}
	}
}

func TestBarAtTheBottomSaysTheCommandFinished(t *testing.T) {
	out := append(numbered(30), strings.Repeat("=", 70), "\x1b[1;34mUpdates installed\x1b[0m", "Updated 1", strings.Repeat("=", 70))
	m := newModel("Software updates", out, 0, "", nil, 80, 14)
	rows := strings.Split(ansi.Strip(m.View()), "\n")
	last := rows[len(rows)-1]
	if !strings.HasPrefix(last, "✓ Updates installed  |  ") || !strings.HasSuffix(last, "Q Back to menu") {
		t.Errorf("bar %q", last)
	}
	if rows[len(rows)-2] != strings.Repeat("─", 80) || rows[len(rows)-3] != "line 30" {
		t.Errorf("rows above the bar %q, %q", rows[len(rows)-3], rows[len(rows)-2])
	}
	// A narrow window shortens the heading but keeps Q whole.
	if got := ansi.Strip(m.bar(30)); !strings.HasSuffix(got, "Q Back to menu") || !strings.HasPrefix(got, "✓ Upd") {
		t.Errorf("narrow bar %q", got)
	}
}

func TestSearchNarrowsTheResultsAsYouType(t *testing.T) {
	m := newModel("History", numbered(100), 0, "", nil, 60, 12)
	m = press(m, "/")
	if !m.typing || !strings.Contains(ansi.Strip(m.View()), "/ Search: _") {
		t.Fatalf("/ did not open the search line: %q", ansi.Strip(m.View()))
	}
	m = press(m, "l", "i", "n", "e", " ", "4")
	// line 4 and line 40 to 49 match.
	view := ansi.Strip(m.View())
	rows := strings.Split(view, "\n")
	if rows[2] != "line 4" || rows[3] != "line 40" || !strings.Contains(rows[11], "/ Search: line 4_") || !strings.Contains(rows[11], "11 matching lines") {
		t.Fatalf("filtered view %q", view)
	}
	if !strings.Contains(m.View(), markStyle+"line 4"+resetStyle) {
		t.Error("the match is not marked")
	}
	// q is typed while the search line has the keys; backspace takes it off.
	m = press(m, "q")
	if !m.typing || m.query != "line 4q" || !strings.Contains(ansi.Strip(m.View()), "No matches") {
		t.Fatalf("q while typing: typing=%v query=%q", m.typing, m.query)
	}
	m = press(m, "backspace", "enter")
	if m.typing || m.query != "line 4" {
		t.Fatalf("Enter did not finish the search: typing=%v query=%q", m.typing, m.query)
	}
	// Q clears the search and goes back to where the page was; Q again leaves.
	if quits(m, "q") {
		t.Fatal("Q left with a search applied")
	}
	m = press(m, "q")
	if m.query != "" || m.offset[outputPage] != 92 {
		t.Fatalf("after Q: query %q, offset %d", m.query, m.offset[outputPage])
	}
	if !quits(m, "q") {
		t.Error("Q without a search did not go back to the menu")
	}
}

func TestArrowsLeaveTheSearchLineAndEscClearsIt(t *testing.T) {
	m := newModel("History", numbered(100), 0, "", nil, 40, 12)
	m = press(m, "/", "1", "down")
	if m.typing || m.query != "1" || m.offset[outputPage] != 1 {
		t.Fatalf("down: typing=%v query=%q offset=%d", m.typing, m.query, m.offset[outputPage])
	}
	// j scrolls now instead of typing.
	m = press(m, "j")
	if m.query != "1" || m.offset[outputPage] != 2 {
		t.Fatalf("j: query=%q offset=%d", m.query, m.offset[outputPage])
	}
	m = press(m, "/", "0", "esc")
	if m.typing || m.query != "" || m.offset[outputPage] != 92 {
		t.Fatalf("esc: typing=%v query=%q offset=%d", m.typing, m.query, m.offset[outputPage])
	}
	// / then Esc without typing leaves the page where it was.
	m = press(m, "up", "/", "esc")
	if m.offset[outputPage] != 91 {
		t.Errorf("/ then Esc moved the page to %d", m.offset[outputPage])
	}
}

func TestSearchTheFileList(t *testing.T) {
	m := newModel("Clean · Preview", numbered(5), 0, "/tmp/clean-list.txt",
		[]string{"# Clean list", "/Users/me/Library/Caches/com.example.app", "/Users/me/Library/Logs/old.log"}, 60, 12)
	m = press(m, "/", "x")
	m = press(m, "esc", "F", "/", "C", "A", "C", "H", "E", "enter")
	view := ansi.Strip(m.View())
	if m.page != filePage || !strings.Contains(view, "com.example.app") || strings.Contains(view, "old.log") || !strings.Contains(view, "1 matching line") {
		t.Fatalf("file list search %q", view)
	}
	// Q clears the search first, then goes back to the results.
	m = press(m, "q")
	if m.page != filePage || m.query != "" {
		t.Fatalf("first Q: page %d query %q", m.page, m.query)
	}
	m = press(m, "q")
	if m.page != outputPage {
		t.Error("second Q did not go back to the results")
	}
}

func TestBackToMenuScreenOnlyWhenTheMenuHasOne(t *testing.T) {
	var out bytes.Buffer
	t.Setenv("FETTLE_MENU_SCREEN", "")
	backToMenuScreen(&out)
	if out.Len() != 0 {
		t.Errorf("wrote %q without the menu's screen", out.String())
	}
	t.Setenv("FETTLE_MENU_SCREEN", "true")
	backToMenuScreen(&out)
	if out.String() != "\x1b[?1049h\x1b[H\x1b[2J" {
		t.Errorf("wrote %q", out.String())
	}
}

func TestTitleRowCarriesTheFettleBadgeAndFitsTheWidth(t *testing.T) {
	for _, width := range []int{12, 19, 20, 40} {
		row := header("Clean · Preview", "1 of 9", width)
		if got := ansi.StringWidth(row); got > width {
			t.Fatalf("width %d: title row is %d columns: %q", width, got, ansi.Strip(row))
		}
		plain := ansi.Strip(row)
		if width >= 20 && !strings.HasPrefix(plain, " F▪   ") {
			t.Fatalf("width %d: title row should start with the badge, got %q", width, plain)
		}
		if width < 20 && strings.Contains(plain, "F▪") {
			t.Fatalf("width %d: a narrow title row should drop the badge, got %q", width, plain)
		}
	}
	if !strings.Contains(badge, "48;5;30") {
		t.Fatalf("badge should sit on verdigris (color 30), got %q", badge)
	}
}

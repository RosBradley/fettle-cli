// Command fettle-view-go runs a command from the menu on a screen of its
// own: fixed rows at the top hold the title and the command's summary (its
// labels with a spinner until it finishes), a bar at the bottom says it is
// running, and the command's output scrolls between them; keys go to the
// command. When it finishes, its summary is pinned at the top, the bar says
// how it ended and which keys work, and the rest of what it printed scrolls
// between them, with / to search it and Clean's file list on F when the run
// wrote it.
//
//	fettle-view-go [--title TITLE] [--note TEXT] [--summary LABELS] [--file PATH] [--unstarted PATH] -- COMMAND [ARGS...]
//
// It exits with the command's status. When it could not start the command
// (no terminal, for one) it exits with 125 and creates the --unstarted file,
// so the menu can run the command another way without running it twice.
package main

import (
	"bufio"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

// exitCannotRun tells the menu that nothing was started.
const exitCannotRun = 125

var errCannotRun = errors.New("cannot run the command in a pane")

// readFileLines reads the file offered on F.
func readFileLines(path string) ([]string, bool) {
	f, err := os.Open(path)
	if err != nil {
		return nil, false
	}
	defer func() { _ = f.Close() }()
	var lines []string
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		lines = append(lines, scanner.Text())
	}
	return lines, scanner.Err() == nil
}

// fileWrittenSince reports whether path changed after the run started; an
// older list belongs to an earlier run.
func fileWrittenSince(path string, start time.Time) bool {
	info, err := os.Stat(path)
	return err == nil && !info.ModTime().Before(start.Truncate(time.Second))
}

// cancelled reports whether the command said the user cancelled it, through
// the marker the menu named (lib/fettle/cancel.sh).
func cancelled() bool {
	marker := os.Getenv("FETTLE_CANCEL_FILE")
	if marker == "" {
		return false
	}
	_, err := os.Stat(marker)
	return err == nil
}

func run(args []string, stdin, stdout *os.File, stderr io.Writer) int {
	flags := flag.NewFlagSet("fettle-view-go", flag.ContinueOnError)
	flags.SetOutput(stderr)
	title := flags.String("title", "Results", "title shown at the top")
	note := flags.String("note", "", "a line shown above the command's output")
	file := flags.String("file", "", "a file to offer on F when the command writes it")
	summary := flags.String("summary", "", "the summary's labels, |-separated, shown with a spinner while the command runs")
	unstarted := flags.String("unstarted", "", "a file to create when the command could not start")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	argv := flags.Args()
	if len(argv) == 0 {
		_, _ = fmt.Fprintln(stderr, "Usage: fettle-view-go [--title TITLE] [--note TEXT] [--summary LABELS] [--file PATH] [--unstarted PATH] -- COMMAND [ARGS...]")
		return 2
	}
	notStarted := func() int {
		if *unstarted != "" {
			_ = os.WriteFile(*unstarted, nil, 0o600)
		}
		return exitCannotRun
	}
	if !isTerminal(stdin) || !isTerminal(stdout) {
		return notStarted()
	}

	start := time.Now()
	var labels []string
	for label := range strings.SplitSeq(*summary, "|") {
		if label = strings.TrimSpace(label); label != "" {
			labels = append(labels, label)
		}
	}
	p := &pane{
		title:  strings.TrimSpace(*title),
		note:   *note,
		labels: labels,
		in:     stdin,
		out:    stdout,
		size:   func() (int, int, bool) { return terminalSize(stdout) },
	}
	output, code, err := p.run(argv)
	if errors.Is(err, errCannotRun) {
		_, _ = fmt.Fprintln(stderr, err)
		return notStarted()
	}
	if err != nil || cancelled() {
		leaveScreen(stdout)
		backToMenuScreen(stdout)
		return code
	}

	filePath := ""
	var fileLines []string
	if *file != "" && fileWrittenSince(*file, start) {
		if lines, ok := readFileLines(*file); ok {
			filePath, fileLines = *file, lines
		}
	}
	cols, rows, _ := terminalSize(stdout)
	m := newModel(p.title, output, code, filePath, fileLines, cols, rows)
	if _, err := show(m); err != nil {
		leaveScreen(stdout)
		_, _ = fmt.Fprintln(stderr, err)
	}
	backToMenuScreen(stdout)
	return code
}

// backToMenuScreen returns to the menu's alternate screen (lib/fettle/menu.sh)
// right after this one leaves it, so the normal screen never shows between
// the command and the menu.
func backToMenuScreen(out io.Writer) {
	if os.Getenv("FETTLE_MENU_SCREEN") == "true" {
		_, _ = io.WriteString(out, "\x1b[?1049h\x1b[H\x1b[2J")
	}
}

// show runs the results screen until the user leaves it; tests pass their
// own input and output.
func show(m model, opts ...tea.ProgramOption) (model, error) {
	final, err := tea.NewProgram(m, append([]tea.ProgramOption{tea.WithAltScreen()}, opts...)...).Run()
	if done, ok := final.(model); ok {
		m = done
	}
	return m, err
}

func main() {
	os.Exit(run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr))
}

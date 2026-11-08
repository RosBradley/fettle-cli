//go:build !darwin && !linux

package main

import (
	"fmt"
	"io"
	"os"
)

type pane struct {
	title  string
	note   string
	labels []string
	in     *os.File
	out    io.Writer
	size   func() (cols, rows int, ok bool)
}

func terminalSize(*os.File) (int, int, bool) { return 0, 0, false }

func isTerminal(*os.File) bool { return false }

func (p *pane) run([]string) ([]string, int, error) {
	return nil, 0, fmt.Errorf("%w: the pane needs macOS or Linux", errCannotRun)
}

func leaveScreen(io.Writer) {}

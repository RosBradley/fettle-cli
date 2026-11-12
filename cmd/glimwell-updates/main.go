// Command glimwell-updates-go finds software updates for glimwell's Software
// updates screen. bin/glimwell-updates.sh runs one subcommand per source and
// handles selection and installing; this program only looks.
//
// Each subcommand prints one row per update, fields separated by the ASCII
// unit separator (0x1f) so empty fields survive a shell read:
//
//	kind  id  name  installed  available  note  bundle
//
// kind is app (Homebrew cask), tool (Homebrew formula), store (App Store app),
// macos (installable from Terminal), macos-settings (needs System Settings),
// takeover (an app Homebrew can replace with a newer version), feed (an app
// whose own updater has a newer version; id is the app's path) or notice (a
// message for the user, with its key in id and its text in note). bundle is
// the bundle identifier of the app a row updates, when known. Nothing starts
// selected: the user picks.
//
// The host subcommand prints instead the bundle identifiers of the apps it
// runs inside, one per line (host.go).
package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const fieldSeparator = "\x1f"

// Row is one update, or a notice, as printed for the shell script.
type Row struct {
	Kind      string
	ID        string
	Name      string
	Installed string
	Available string
	Note      string
	Bundle    string // the app's bundle identifier, when known
}

func (r Row) String() string {
	fields := []string{r.Kind, r.ID, r.Name, r.Installed, r.Available, r.Note, r.Bundle}
	for i, f := range fields {
		fields[i] = strings.Map(func(c rune) rune {
			if c == '\t' || c == '\n' || c == '\r' || c == 0x1f {
				return ' '
			}
			return c
		}, f)
	}
	return strings.Join(fields, fieldSeparator)
}

func notice(key, text string) Row {
	return Row{Kind: "notice", ID: key, Note: text}
}

// runCommand runs a program and returns its standard output, or its combined
// output when combined is set. Tests replace it.
var runCommand = func(ctx context.Context, combined bool, name string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Env = append(os.Environ(),
		"HOMEBREW_NO_AUTO_UPDATE=1",
		"HOMEBREW_NO_ENV_HINTS=1",
		"HOMEBREW_NO_COLOR=1",
	)
	var out []byte
	var err error
	if combined {
		out, err = cmd.CombinedOutput()
	} else {
		out, err = cmd.Output()
	}
	return string(out), err
}

func run(timeout time.Duration, name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	return runCommand(ctx, false, name, args...)
}

// findProgram looks a program up on PATH, then in the given folders, which
// cover Homebrew's two install locations when PATH lacks them.
var findProgram = func(name string, extraDirs ...string) string {
	if path, err := exec.LookPath(name); err == nil {
		return path
	}
	for _, dir := range extraDirs {
		path := filepath.Join(dir, name)
		if info, err := os.Stat(path); err == nil && !info.IsDir() && info.Mode()&0o111 != 0 {
			return path
		}
	}
	return ""
}

var homebrewDirs = []string{"/opt/homebrew/bin", "/usr/local/bin"}

func findBrew() string { return findProgram("brew", homebrewDirs...) }

func usage(w io.Writer) {
	_, _ = fmt.Fprintln(w, "Usage: glimwell-updates-go brew|store|macos|apps|host")
}

func main() {
	if len(os.Args) != 2 {
		usage(os.Stderr)
		os.Exit(2)
	}
	var rows []Row
	switch os.Args[1] {
	case "brew":
		rows = scanHomebrew()
	case "store":
		rows = scanAppStore()
	case "macos":
		rows = scanMacOS()
	case "apps":
		rows = scanApps()
	case "host":
		for _, id := range scanHost() {
			fmt.Println(id)
		}
		return
	case "-h", "--help":
		usage(os.Stdout)
		return
	default:
		usage(os.Stderr)
		os.Exit(2)
	}
	for _, r := range rows {
		fmt.Println(r.String())
	}
}

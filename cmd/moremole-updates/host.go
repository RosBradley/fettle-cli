package main

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// The app MoreMole runs inside, such as iTerm2, must not be updated from
// inside itself: Homebrew may quit it in the middle of the run, which ends
// MoreMole and the update with it, and the app's own updater restarts it.
// hostApps finds that app three ways, since each one can miss it: the app
// that started the shell (macOS sets __CFBundleIdentifier for it), the app
// TERM_PROGRAM names when it names one ("iTerm.app"), and any app among the
// parents of this process. A terminal that runs shells through a helper of
// its own, as iTerm2 can, is not among the parents. Terminals that name
// themselves without ".app" (Ghostty, WezTerm, Warp, Hyper, Tabby) or only
// set a variable of their own (kitty, Alacritty) are found by their app's
// file name, and the bundle identifier is read from the app itself.

// knownTerminals are those terminals, by TERM_PROGRAM (lowercased) or by a
// variable each sets, with the file name of their app.
var knownTerminals = []struct{ program, variable, app string }{
	{program: "ghostty", app: "Ghostty.app"},
	{program: "wezterm", app: "WezTerm.app"},
	{program: "warpterminal", app: "Warp.app"},
	{program: "hyper", app: "Hyper.app"},
	{program: "tabby", app: "Tabby.app"},
	{variable: "KITTY_WINDOW_ID", app: "kitty.app"},
	{variable: "ALACRITTY_WINDOW_ID", app: "Alacritty.app"},
}

// appDirs are the folders apps are installed in. Tests replace it.
var appDirs = func() []string {
	dirs := []string{"/Applications"}
	if home, err := os.UserHomeDir(); err == nil && home != "" {
		dirs = append(dirs, filepath.Join(home, "Applications"))
	}
	return dirs
}

// bundleOfApp reads an app's bundle identifier. Tests replace it.
var bundleOfApp = func(appPath string) string {
	values, err := readInfoPlist(filepath.Join(appPath, "Contents", "Info.plist"))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(values["CFBundleIdentifier"])
}

// installedBundle finds an app by its file name ("iTerm.app") in the
// Applications folders and returns its bundle identifier, or "".
func installedBundle(fileName string) string {
	if fileName == "" || strings.Contains(fileName, "/") {
		return ""
	}
	for _, dir := range appDirs() {
		path := filepath.Join(dir, fileName)
		if info, err := os.Stat(path); err == nil && info.IsDir() {
			return bundleOfApp(path)
		}
	}
	return ""
}

// appPathOf returns the outermost app bundle an executable lives in, or "".
func appPathOf(executable string) string {
	if !strings.HasPrefix(executable, "/") {
		return ""
	}
	i := strings.Index(executable, ".app/")
	if i < 0 {
		return ""
	}
	return executable[:i+len(".app")]
}

// hostApps returns the bundle identifiers of the apps this process runs
// inside, each once, given the environment and the executables of its
// parent processes, nearest first.
func hostApps(getenv func(string) string, parents []string) []string {
	var ids []string
	add := func(id string) {
		if id = strings.TrimSpace(id); id == "" {
			return
		}
		for _, seen := range ids {
			if strings.EqualFold(seen, id) {
				return
			}
		}
		ids = append(ids, id)
	}
	add(getenv("__CFBundleIdentifier"))
	program := getenv("TERM_PROGRAM")
	if strings.HasSuffix(program, ".app") {
		add(installedBundle(program))
	}
	for _, t := range knownTerminals {
		if (t.program != "" && strings.EqualFold(program, t.program)) || (t.variable != "" && getenv(t.variable) != "") {
			add(installedBundle(t.app))
		}
	}
	for _, exe := range parents {
		if app := appPathOf(exe); app != "" {
			add(bundleOfApp(app))
		}
	}
	return ids
}

// processTable lists every process as "pid ppid command". Tests replace it.
var processTable = func() (string, error) {
	return run(10*time.Second, "/bin/ps", "-axo", "pid=,ppid=,comm=")
}

// parentExecutables returns the executables of the parents of process pid,
// nearest first, from a process table.
func parentExecutables(table string, pid int) []string {
	type proc struct {
		ppid int
		exe  string
	}
	procs := map[int]proc{}
	for line := range strings.Lines(table) {
		fields := strings.Fields(line)
		if len(fields) < 3 {
			continue
		}
		id, err1 := strconv.Atoi(fields[0])
		parent, err2 := strconv.Atoi(fields[1])
		if err1 != nil || err2 != nil {
			continue
		}
		// The command may hold spaces ("/Applications/Visual Studio Code.app/...").
		exe := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(line), fields[0]))
		exe = strings.TrimSpace(strings.TrimPrefix(exe, fields[1]))
		procs[id] = proc{ppid: parent, exe: exe}
	}
	var exes []string
	seen := map[int]bool{pid: true}
	for p, ok := procs[pid]; ok && p.ppid > 1 && !seen[p.ppid]; p, ok = procs[p.ppid] {
		seen[p.ppid] = true
		if parent, found := procs[p.ppid]; found {
			exes = append(exes, parent.exe)
		}
	}
	return exes
}

// scanHost prints the host apps' bundle identifiers, one per line.
func scanHost() []string {
	table, err := processTable()
	var parents []string
	if err == nil {
		parents = parentExecutables(table, os.Getpid())
	}
	return hostApps(os.Getenv, parents)
}

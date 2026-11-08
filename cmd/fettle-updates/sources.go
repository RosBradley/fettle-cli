package main

import (
	"context"
	"encoding/json"
	"regexp"
	"sort"
	"strings"
	"time"
)

const (
	brewUpdateTimeout = 3 * time.Minute
	brewQueryTimeout  = 2 * time.Minute
	masTimeout        = 2 * time.Minute
	// softwareupdate asks Apple's servers and can take a minute.
	softwareUpdateTimeout = 3 * time.Minute
	softwareUpdatePath    = "/usr/sbin/softwareupdate"
)

// brewOutdated is `brew outdated --json=v2`. installed_versions is a list in
// current Homebrew and was a string in older releases.
type brewOutdated struct {
	Formulae []struct {
		Name              string          `json:"name"`
		InstalledVersions json.RawMessage `json:"installed_versions"`
		CurrentVersion    string          `json:"current_version"`
		Pinned            bool            `json:"pinned"`
	} `json:"formulae"`
	Casks []struct {
		Name              string          `json:"name"`
		InstalledVersions json.RawMessage `json:"installed_versions"`
		CurrentVersion    string          `json:"current_version"`
	} `json:"casks"`
}

// caskInfo is one cask from `brew info --cask --json=v2` or Homebrew's cask
// index; only the fields fettle reads.
type caskInfo struct {
	Token       string            `json:"token"`
	Name        []string          `json:"name"`
	Version     string            `json:"version"`
	AutoUpdates bool              `json:"auto_updates"`
	Deprecated  bool              `json:"deprecated"`
	Disabled    bool              `json:"disabled"`
	Artifacts   []json.RawMessage `json:"artifacts"`
}

func (c caskInfo) displayName() string {
	if len(c.Name) > 0 && strings.TrimSpace(c.Name[0]) != "" {
		return c.Name[0]
	}
	return c.Token
}

// lastVersion reads installed_versions, a list or a single string, and
// returns the newest (last) entry.
func lastVersion(raw json.RawMessage) string {
	var list []string
	if json.Unmarshal(raw, &list) == nil && len(list) > 0 {
		return list[len(list)-1]
	}
	var single string
	if json.Unmarshal(raw, &single) == nil {
		return single
	}
	return ""
}

func parseCaskInfos(out string) map[string]caskInfo {
	var parsed struct {
		Casks []caskInfo `json:"casks"`
	}
	infos := map[string]caskInfo{}
	if json.Unmarshal([]byte(out), &parsed) != nil {
		return infos
	}
	for _, c := range parsed.Casks {
		infos[c.Token] = c
	}
	return infos
}

func scanHomebrew() []Row {
	brew := findBrew()
	if brew == "" {
		return []Row{notice("homebrew-missing", "Homebrew is not installed, so Homebrew apps and tools can't be checked. Get it at https://brew.sh")}
	}
	var rows []Row
	if _, err := run(brewUpdateTimeout, brew, "update", "--quiet"); err != nil {
		rows = append(rows, notice("homebrew-stale", "Couldn't refresh Homebrew's version list, so recent updates may be missing."))
	}
	// brew outdated can exit nonzero while still printing a usable list.
	out, err := run(brewQueryTimeout, brew, "outdated", "--json=v2", "--greedy")
	var outdated brewOutdated
	if jsonErr := json.Unmarshal([]byte(out), &outdated); jsonErr != nil {
		reason := "its answer was unreadable"
		if err != nil {
			reason = err.Error()
		}
		return append(rows, notice("homebrew-failed", "Homebrew couldn't list outdated software ("+reason+")."))
	}
	infos := map[string]caskInfo{}
	if len(outdated.Casks) > 0 {
		args := []string{"info", "--cask", "--json=v2"}
		for _, c := range outdated.Casks {
			args = append(args, c.Name)
		}
		if infoOut, err := run(brewQueryTimeout, brew, args...); err == nil {
			infos = parseCaskInfos(infoOut)
		}
	}
	return append(rows, homebrewRows(outdated, infos)...)
}

// homebrewRows turns Homebrew's outdated list into rows, noting apps that
// update themselves or have no version to compare, and versions older than
// the installed one, which Homebrew sometimes moves back to on purpose.
// Pinned tools are left out, as Homebrew will not upgrade them.
func homebrewRows(outdated brewOutdated, infos map[string]caskInfo) []Row {
	var apps, tools []Row
	for _, c := range outdated.Casks {
		info, known := infos[c.Name]
		row := Row{Kind: "app", ID: c.Name, Name: c.Name, Installed: lastVersion(c.InstalledVersions), Available: c.CurrentVersion}
		if known {
			row.Name = info.displayName()
			if names, _ := info.appNames(); len(names) > 0 {
				row.Bundle = installedBundle(names[0])
			}
		}
		switch {
		case c.CurrentVersion == "latest" || (known && info.Version == "latest"):
			row.Note = "always reinstalls"
		case olderVersion(row):
			row.Note = olderNote
		case known && info.AutoUpdates:
			row.Note = "updates itself"
		}
		apps = append(apps, row)
	}
	for _, f := range outdated.Formulae {
		if f.Pinned {
			continue
		}
		row := Row{Kind: "tool", ID: f.Name, Name: f.Name, Installed: lastVersion(f.InstalledVersions), Available: f.CurrentVersion}
		if olderVersion(row) {
			row.Note = olderNote
		}
		tools = append(tools, row)
	}
	sortRows(apps)
	sortRows(tools)
	return append(apps, tools...)
}

const olderNote = "older version, Homebrew's choice"

// olderVersion reports an update to an older version than the one installed,
// as when Homebrew moved openssl@3 back to its long-term 3.5 line.
func olderVersion(r Row) bool {
	return r.Installed != "" && r.Available != "" && compareVersions(r.Available, r.Installed) < 0
}

func sortRows(rows []Row) {
	sort.SliceStable(rows, func(i, j int) bool {
		return strings.ToLower(rows[i].Name) < strings.ToLower(rows[j].Name)
	})
}

func scanAppStore() []Row {
	mas := findProgram("mas", homebrewDirs...)
	if mas == "" {
		return []Row{notice("mas-missing", "App Store apps can't be checked until the free mas tool is installed.")}
	}
	out, err := run(masTimeout, mas, "outdated")
	rows := parseMasOutdated(out)
	if err != nil && len(rows) == 0 {
		return []Row{notice("mas-failed", "mas couldn't check the App Store. Open the App Store app and make sure you're signed in.")}
	}
	for i := range rows {
		rows[i].Bundle = installedBundle(rows[i].Name + ".app") // App Store apps keep their name
	}
	return rows
}

var (
	masWithVersions = regexp.MustCompile(`^\s*(\d+)\s+(.+?)\s+\((.+?)\s+->\s+(.+?)\)\s*$`)
	masIDAndName    = regexp.MustCompile(`^\s*(\d+)\s+(.+?)\s*$`)
)

// parseMasOutdated reads `mas outdated`: "<id> <name> (<installed> -> <new>)",
// or just "<id> <name>" from older versions of mas.
func parseMasOutdated(out string) []Row {
	var rows []Row
	for line := range strings.Lines(out) {
		line = strings.TrimRight(line, "\r\n")
		if m := masWithVersions.FindStringSubmatch(line); m != nil {
			rows = append(rows, Row{Kind: "store", ID: m[1], Name: m[2], Installed: m[3], Available: m[4]})
		} else if m := masIDAndName.FindStringSubmatch(line); m != nil {
			rows = append(rows, Row{Kind: "store", ID: m[1], Name: m[2]})
		}
	}
	sortRows(rows)
	return rows
}

func scanMacOS() []Row {
	ctx, cancel := context.WithTimeout(context.Background(), softwareUpdateTimeout)
	defer cancel()
	// softwareupdate prints "No new software available." on standard error.
	out, err := runCommand(ctx, true, softwareUpdatePath, "--list")
	rows := parseSoftwareUpdate(out)
	if err != nil && len(rows) == 0 && !strings.Contains(out, "No new software available") {
		return []Row{notice("macos-failed", "Couldn't check for macOS updates. Software Update in System Settings can check instead.")}
	}
	return rows
}

var (
	suLabel   = regexp.MustCompile(`^\s*\*\s*Label:\s*(.+?)\s*$`)
	suTitle   = regexp.MustCompile(`Title:\s*(.+?),\s*Version:`)
	suVersion = regexp.MustCompile(`Version:\s*(.+?),`)
	suRestart = regexp.MustCompile(`Action:\s*restart`)
)

// parseSoftwareUpdate reads `softwareupdate --list`. Each update is a
// "* Label:" line followed by a details line with its title, version and,
// when it needs one, "Action: restart". Updates that restart the Mac, and any
// macOS update itself, go through System Settings; the rest can be installed
// from Terminal. None starts selected.
func parseSoftwareUpdate(out string) []Row {
	var rows []Row
	var current *Row
	for line := range strings.Lines(out) {
		line = strings.TrimRight(line, "\r\n")
		if m := suLabel.FindStringSubmatch(line); m != nil {
			rows = append(rows, Row{Kind: "macos", ID: m[1], Name: m[1]})
			current = &rows[len(rows)-1]
			continue
		}
		if current == nil || !strings.Contains(line, "Title:") {
			continue
		}
		if m := suTitle.FindStringSubmatch(line); m != nil {
			current.Name = m[1]
		}
		if m := suVersion.FindStringSubmatch(line); m != nil {
			current.Available = m[1]
		}
		if suRestart.MatchString(line) || strings.HasPrefix(current.Name, "macOS") {
			current.Kind = "macos-settings"
			current.Note = "needs a restart, opens Settings"
		}
		current = nil
	}
	return rows
}

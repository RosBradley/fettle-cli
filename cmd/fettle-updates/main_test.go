package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// fakeCommands replaces runCommand and findProgram. Each response is keyed by
// the program's base name and its arguments joined by spaces.
type fakeResponse struct {
	out string
	err error
}

func useFakeCommands(t *testing.T, programs map[string]string, responses map[string]fakeResponse) *[]string {
	t.Helper()
	var calls []string
	savedRun, savedFind := runCommand, findProgram
	runCommand = func(_ context.Context, _ bool, name string, args ...string) (string, error) {
		key := strings.TrimSpace(filepath.Base(name) + " " + strings.Join(args, " "))
		calls = append(calls, key)
		r, ok := responses[key]
		if !ok {
			return "", errors.New("unexpected command: " + key)
		}
		return r.out, r.err
	}
	findProgram = func(name string, _ ...string) string { return programs[name] }
	t.Cleanup(func() { runCommand, findProgram = savedRun, savedFind })
	return &calls
}

const outdatedJSON = `{
  "formulae": [
    {"name": "git", "installed_versions": ["2.44.0"], "current_version": "2.45.0", "pinned": false},
    {"name": "openssl@3", "installed_versions": ["3.6.5"], "current_version": "3.5.9", "pinned": false},
    {"name": "node", "installed_versions": ["20.1.0"], "current_version": "22.0.0", "pinned": true, "pinned_version": "20.1.0"}
  ],
  "casks": [
    {"name": "visual-studio-code", "installed_versions": ["1.88.0"], "current_version": "1.89.0"},
    {"name": "google-chrome", "installed_versions": "124.0", "current_version": "125.0"},
    {"name": "some-latest", "installed_versions": ["latest"], "current_version": "latest"},
    {"name": "no-info", "installed_versions": ["1.0"], "current_version": "1.1"}
  ]
}`

const caskInfoJSON = `{"formulae": [], "casks": [
  {"token": "visual-studio-code", "name": ["Microsoft Visual Studio Code"], "version": "1.89.0", "auto_updates": false,
   "artifacts": [{"app": ["Visual Studio Code.app"]}]},
  {"token": "google-chrome", "name": ["Google Chrome"], "version": "125.0", "auto_updates": true},
  {"token": "some-latest", "name": ["Some Latest"], "version": "latest"}
]}`

// useApps puts fake apps, by file name and bundle identifier, in an
// Applications folder of the test's own.
func useApps(t *testing.T, apps map[string]string) {
	t.Helper()
	dir := t.TempDir()
	byPath := map[string]string{}
	for name, id := range apps {
		path := filepath.Join(dir, name)
		if err := os.MkdirAll(path, 0o755); err != nil {
			t.Fatal(err)
		}
		byPath[path] = id
	}
	savedDirs, savedBundle := appDirs, bundleOfApp
	appDirs = func() []string { return []string{dir} }
	bundleOfApp = func(path string) string { return byPath[path] }
	t.Cleanup(func() { appDirs, bundleOfApp = savedDirs, savedBundle })
}

func TestScanHomebrewListsAppsAndToolsWithTheirDefaults(t *testing.T) {
	useApps(t, map[string]string{"Visual Studio Code.app": "com.microsoft.VSCode"})
	calls := useFakeCommands(t, map[string]string{"brew": "/opt/homebrew/bin/brew"}, map[string]fakeResponse{
		"brew update --quiet":              {err: errors.New("offline")},
		"brew outdated --json=v2 --greedy": {out: outdatedJSON, err: errors.New("exit status 1")},
		"brew info --cask --json=v2 visual-studio-code google-chrome some-latest no-info": {out: caskInfoJSON},
	})
	got := scanHomebrew()
	want := []Row{
		notice("homebrew-stale", "Couldn't refresh Homebrew's version list, so recent updates may be missing."),
		{Kind: "app", ID: "google-chrome", Name: "Google Chrome", Installed: "124.0", Available: "125.0", Note: "updates itself"},
		{Kind: "app", ID: "visual-studio-code", Name: "Microsoft Visual Studio Code", Installed: "1.88.0", Available: "1.89.0", Bundle: "com.microsoft.VSCode"},
		{Kind: "app", ID: "no-info", Name: "no-info", Installed: "1.0", Available: "1.1"},
		{Kind: "app", ID: "some-latest", Name: "Some Latest", Installed: "latest", Available: "latest", Note: "always reinstalls"},
		{Kind: "tool", ID: "git", Name: "git", Installed: "2.44.0", Available: "2.45.0"},
		{Kind: "tool", ID: "openssl@3", Name: "openssl@3", Installed: "3.6.5", Available: "3.5.9", Note: "older version, Homebrew's choice"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("rows:\n got %#v\nwant %#v\ncalls %v", got, want, *calls)
	}
}

func TestScanHomebrewWithoutHomebrewOrWithAnUnreadableAnswer(t *testing.T) {
	useFakeCommands(t, map[string]string{}, nil)
	if got := scanHomebrew(); len(got) != 1 || got[0].ID != "homebrew-missing" {
		t.Errorf("no Homebrew: %#v", got)
	}
	useFakeCommands(t, map[string]string{"brew": "/usr/local/bin/brew"}, map[string]fakeResponse{
		"brew update --quiet":              {},
		"brew outdated --json=v2 --greedy": {out: "Error: something", err: errors.New("exit status 1")},
	})
	if got := scanHomebrew(); len(got) != 1 || got[0].ID != "homebrew-failed" || !strings.Contains(got[0].Note, "exit status 1") {
		t.Errorf("unreadable answer: %#v", got)
	}
}

func TestParseMasOutdated(t *testing.T) {
	out := "497799835 Xcode (15.0 -> 15.1)\n1295203466   Microsoft Remote Desktop  (10.9.5 -> 10.9.6)\n409183694 Keynote\nWarning: something\n"
	want := []Row{
		{Kind: "store", ID: "409183694", Name: "Keynote"},
		{Kind: "store", ID: "1295203466", Name: "Microsoft Remote Desktop", Installed: "10.9.5", Available: "10.9.6"},
		{Kind: "store", ID: "497799835", Name: "Xcode", Installed: "15.0", Available: "15.1"},
	}
	if got := parseMasOutdated(out); !reflect.DeepEqual(got, want) {
		t.Errorf("got %#v\nwant %#v", got, want)
	}
}

func TestScanAppStoreFindsTheAppsBundle(t *testing.T) {
	useApps(t, map[string]string{"Xcode.app": "com.apple.dt.Xcode"})
	useFakeCommands(t, map[string]string{"mas": "/opt/homebrew/bin/mas"}, map[string]fakeResponse{
		"mas outdated": {out: "497799835 Xcode (15.0 -> 15.1)\n409183694 Keynote\n"},
	})
	got := scanAppStore()
	if len(got) != 2 || got[0].Bundle != "" || got[1].Bundle != "com.apple.dt.Xcode" {
		t.Errorf("rows %#v", got)
	}
}

func TestScanAppStoreNotices(t *testing.T) {
	useFakeCommands(t, map[string]string{}, nil)
	if got := scanAppStore(); len(got) != 1 || got[0].ID != "mas-missing" {
		t.Errorf("no mas: %#v", got)
	}
	useFakeCommands(t, map[string]string{"mas": "/opt/homebrew/bin/mas"}, map[string]fakeResponse{
		"mas outdated": {out: "Error: not signed in\n", err: errors.New("exit status 1")},
	})
	if got := scanAppStore(); len(got) != 1 || got[0].ID != "mas-failed" {
		t.Errorf("mas failed: %#v", got)
	}
}

const softwareUpdateList = `Software Update Tool

Finding available software
Software Update found the following new or updated software:
* Label: Command Line Tools for Xcode-16.1
	Title: Command Line Tools for Xcode, Version: 16.1, Size: 1595618KiB, Recommended: YES,
* Label: Safari18.1VenturaAuto-18.1
	Title: Safari, Version: 18.1, Size: 197632K, Recommended: YES,
* Label: macOS Sequoia 15.1-24B83
	Title: macOS Sequoia 15.1, Version: 15.1, Size: 3355432K, Recommended: YES, Action: restart,
* Label: Some Firmware-1.0
	Title: Some Firmware, Version: 1.0, Size: 100K, Recommended: YES, Action: restart,
`

func TestParseSoftwareUpdate(t *testing.T) {
	want := []Row{
		{Kind: "macos", ID: "Command Line Tools for Xcode-16.1", Name: "Command Line Tools for Xcode", Available: "16.1"},
		{Kind: "macos", ID: "Safari18.1VenturaAuto-18.1", Name: "Safari", Available: "18.1"},
		{Kind: "macos-settings", ID: "macOS Sequoia 15.1-24B83", Name: "macOS Sequoia 15.1", Available: "15.1", Note: "needs a restart, opens Settings"},
		{Kind: "macos-settings", ID: "Some Firmware-1.0", Name: "Some Firmware", Available: "1.0", Note: "needs a restart, opens Settings"},
	}
	if got := parseSoftwareUpdate(softwareUpdateList); !reflect.DeepEqual(got, want) {
		t.Errorf("got %#v\nwant %#v", got, want)
	}
}

func TestScanMacOSWithNothingNewOrAFailure(t *testing.T) {
	useFakeCommands(t, nil, map[string]fakeResponse{
		"softwareupdate --list": {out: "Software Update Tool\n\nFinding available software\nNo new software available.\n"},
	})
	if got := scanMacOS(); len(got) != 0 {
		t.Errorf("nothing new: %#v", got)
	}
	useFakeCommands(t, nil, map[string]fakeResponse{
		"softwareupdate --list": {out: "Can't connect", err: errors.New("exit status 1")},
	})
	if got := scanMacOS(); len(got) != 1 || got[0].ID != "macos-failed" {
		t.Errorf("failure: %#v", got)
	}
}

func TestRowStringKeepsFieldsApart(t *testing.T) {
	row := Row{Kind: "app", ID: "x", Name: "A\tB\x1fC\nD", Installed: "", Available: "2", Bundle: "com.x"}
	fields := strings.Split(row.String(), fieldSeparator)
	want := []string{"app", "x", "A B C D", "", "2", "", "com.x"}
	if !reflect.DeepEqual(fields, want) {
		t.Errorf("fields %q, want %q", fields, want)
	}
}

func TestFindProgramChecksHomebrewFolders(t *testing.T) {
	dir := t.TempDir()
	tool := filepath.Join(dir, "fettle-test-tool")
	if err := os.WriteFile(tool, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", "/nonexistent")
	if got := findProgram("fettle-test-tool", dir); got != tool {
		t.Errorf("got %q, want %q", got, tool)
	}
	if got := findProgram("fettle-test-tool"); got != "" {
		t.Errorf("without the folder: got %q", got)
	}
}

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"encoding/xml"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"
)

// Apps installed without Homebrew that Homebrew offers a newer version of.
// Updating one runs `brew install --cask --force`, which replaces the app with
// Homebrew's copy; from then on Homebrew manages it and it shows up with the
// other Homebrew apps. Settings and documents live outside the app and stay.

const (
	caskIndexURL     = "https://formulae.brew.sh/api/cask.json"
	caskIndexMaxAge  = 24 * time.Hour
	caskIndexTimeout = time.Minute
	plutilPath       = "/usr/bin/plutil"
	plistTimeout     = 10 * time.Second
	plistWorkers     = 8
)

// takeoverArtifacts are the cask parts a plain app install may have. A cask
// with anything else, such as a pkg installer, changes more than the app, so
// it is never offered.
var takeoverArtifacts = map[string]bool{
	"app": true, "binary": true, "zap": true, "uninstall": true, "manpage": true,
	"bash_completion": true, "zsh_completion": true, "fish_completion": true,
}

// appNames returns the file names the cask installs into the Applications
// folder, and whether it installs nothing beyond what an app install needs.
func (c caskInfo) appNames() (names []string, plain bool) {
	plain = true
	for _, raw := range c.Artifacts {
		var artifact map[string]json.RawMessage
		if json.Unmarshal(raw, &artifact) != nil {
			plain = false
			continue
		}
		for key, value := range artifact {
			if !takeoverArtifacts[key] {
				plain = false
			}
			if key != "app" {
				continue
			}
			var parts []json.RawMessage
			if json.Unmarshal(value, &parts) != nil || len(parts) == 0 {
				continue
			}
			var source string
			if json.Unmarshal(parts[0], &source) != nil {
				continue
			}
			name := filepath.Base(source)
			if len(parts) > 1 {
				var options struct {
					Target string `json:"target"`
				}
				if json.Unmarshal(parts[1], &options) == nil && options.Target != "" {
					name = filepath.Base(options.Target)
				}
			}
			names = append(names, name)
		}
	}
	return names, plain
}

// localApp is an app found in an Applications folder.
type localApp struct {
	Path     string
	FileName string // "Visual Studio Code.app"
	Name     string // the name the app shows
	BundleID string
	Short    string // CFBundleShortVersionString
	Build    string // CFBundleVersion
	FeedURL  string // SUFeedURL: where the app's own updater looks
}

// installedCasks lists what Homebrew already manages: the cask tokens and the
// app file names they installed.
func installedCasks(brew string) (tokens, apps map[string]bool, err error) {
	out, err := run(brewQueryTimeout, brew, "info", "--cask", "--json=v2", "--installed")
	if err != nil {
		return nil, nil, err
	}
	tokens, apps = map[string]bool{}, map[string]bool{}
	for token, info := range parseCaskInfos(out) {
		tokens[token] = true
		names, _ := info.appNames()
		for _, name := range names {
			apps[name] = true
		}
	}
	return tokens, apps, nil
}

// takeoverRows matches apps to casks by the app's file name and offers each
// one Homebrew has a newer version of. A match must be unambiguous, the cask
// must install only the app, and casks for apps that update themselves are
// left out: those apps keep themselves current. None starts selected.
func takeoverRows(apps []localApp, index []caskInfo, managedTokens, managedApps map[string]bool) []Row {
	byApp := map[string][]caskInfo{}
	for _, c := range index {
		if c.Deprecated || c.Disabled || c.AutoUpdates || c.Version == "latest" || c.Version == "" {
			continue
		}
		names, plain := c.appNames()
		if !plain || len(names) != 1 {
			continue
		}
		byApp[names[0]] = append(byApp[names[0]], c)
	}

	var rows []Row
	for _, app := range apps {
		if managedApps[app.FileName] || strings.HasPrefix(app.BundleID, "com.apple.") {
			continue
		}
		cask, ok := pickCask(byApp[app.FileName])
		if !ok || managedTokens[cask.Token] {
			continue
		}
		available, _, _ := strings.Cut(cask.Version, ",")
		if !newerThanApp(available, app.Short, app.Build) {
			continue
		}
		rows = append(rows, Row{
			Kind:      "takeover",
			ID:        cask.Token,
			Name:      strings.TrimSuffix(app.FileName, ".app"),
			Installed: app.Short,
			Available: available,
			Note:      "replaces your copy",
			Bundle:    app.BundleID,
		})
	}
	sortRows(rows)
	return rows
}

// pickCask chooses the cask for an app. Variants such as "firefox@beta"
// install the same app name, so the plain token wins; anything still
// ambiguous is skipped rather than guessed.
func pickCask(candidates []caskInfo) (caskInfo, bool) {
	var plain []caskInfo
	for _, c := range candidates {
		if !strings.Contains(c.Token, "@") {
			plain = append(plain, c)
		}
	}
	if len(plain) == 1 {
		return plain[0], true
	}
	if len(plain) == 0 && len(candidates) == 1 {
		return candidates[0], true
	}
	return caskInfo{}, false
}

// newerThanApp says whether Homebrew's version is newer than the app's. Some
// apps report a short version ("3") and keep the detail in their build
// number ("3.0.12"), so a dotted build number must be older too.
func newerThanApp(available, short, build string) bool {
	if short == "" || compareVersions(available, short) <= 0 {
		return false
	}
	if strings.Contains(build, ".") && compareVersions(available, build) <= 0 {
		return false
	}
	return true
}

// versionParts splits "1.10.0b2" into ["1" "10" "0" "b" "2"].
func versionParts(v string) []string {
	var parts []string
	var current []rune
	kind := 0 // 1 digit, 2 letter
	flush := func() {
		if len(current) > 0 {
			parts = append(parts, string(current))
			current = current[:0]
		}
	}
	for _, r := range v {
		k := 0
		switch {
		case unicode.IsDigit(r):
			k = 1
		case unicode.IsLetter(r):
			k = 2
		}
		if k == 0 || k != kind {
			flush()
		}
		kind = k
		if k != 0 {
			current = append(current, unicode.ToLower(r))
		}
	}
	flush()
	return parts
}

// compareVersions compares two version strings part by part: numbers by
// value, words alphabetically, a number above a word (so 1.0 is newer than
// 1.0b2), and a missing part as 0.
func compareVersions(a, b string) int {
	pa, pb := versionParts(a), versionParts(b)
	for i := 0; i < max(len(pa), len(pb)); i++ {
		x, y := "0", "0"
		if i < len(pa) {
			x = pa[i]
		}
		if i < len(pb) {
			y = pb[i]
		}
		xn, xErr := strconv.Atoi(x)
		yn, yErr := strconv.Atoi(y)
		switch {
		case xErr == nil && yErr == nil:
			if xn != yn {
				if xn < yn {
					return -1
				}
				return 1
			}
		case xErr == nil:
			return 1
		case yErr == nil:
			return -1
		case x != y:
			if x < y {
				return -1
			}
			return 1
		}
	}
	return 0
}

// scanApplications lists the apps in each folder and in its plain subfolders
// (such as Utilities), skipping App Store apps and symlinks.
func scanApplications(dirs []string) []localApp {
	var paths []string
	for _, dir := range dirs {
		entries, err := os.ReadDir(dir)
		if err != nil {
			continue
		}
		for _, entry := range entries {
			path := filepath.Join(dir, entry.Name())
			if entry.Type()&os.ModeSymlink != 0 || !entry.IsDir() {
				continue
			}
			if strings.HasSuffix(entry.Name(), ".app") {
				paths = append(paths, path)
				continue
			}
			sub, err := os.ReadDir(path)
			if err != nil {
				continue
			}
			for _, s := range sub {
				if s.IsDir() && s.Type()&os.ModeSymlink == 0 && strings.HasSuffix(s.Name(), ".app") {
					paths = append(paths, filepath.Join(path, s.Name()))
				}
			}
		}
	}

	apps := make([]localApp, len(paths))
	found := make([]bool, len(paths))
	var wg sync.WaitGroup
	jobs := make(chan int)
	for range plistWorkers {
		wg.Go(func() {
			for i := range jobs {
				apps[i], found[i] = readApp(paths[i])
			}
		})
	}
	for i := range paths {
		jobs <- i
	}
	close(jobs)
	wg.Wait()

	var result []localApp
	for i, ok := range found {
		if ok {
			result = append(result, apps[i])
		}
	}
	return result
}

func readApp(path string) (localApp, bool) {
	if _, err := os.Stat(filepath.Join(path, "Contents", "_MASReceipt")); err == nil {
		return localApp{}, false // App Store apps update through the App Store
	}
	values, err := readInfoPlist(filepath.Join(path, "Contents", "Info.plist"))
	if err != nil {
		return localApp{}, false
	}
	name := strings.TrimSpace(values["CFBundleDisplayName"])
	if name == "" {
		name = strings.TrimSpace(values["CFBundleName"])
	}
	if name == "" {
		name = strings.TrimSuffix(filepath.Base(path), ".app")
	}
	return localApp{
		Path:     path,
		FileName: filepath.Base(path),
		Name:     name,
		BundleID: values["CFBundleIdentifier"],
		Short:    strings.TrimSpace(values["CFBundleShortVersionString"]),
		Build:    strings.TrimSpace(values["CFBundleVersion"]),
		FeedURL:  strings.TrimSpace(values["SUFeedURL"]),
	}, true
}

// readInfoPlist reads the top-level text values of a property list, which
// may be stored as XML or binary; plutil prints either as XML. Tests replace it.
var readInfoPlist = func(path string) (map[string]string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), plistTimeout)
	defer cancel()
	out, err := runCommand(ctx, false, plutilPath, "-convert", "xml1", "-o", "-", path)
	if err != nil {
		return nil, err
	}
	return parsePlistStrings([]byte(out)), nil
}

// parsePlistStrings returns the <string> values of an XML property list's
// top-level dictionary, by key.
func parsePlistStrings(data []byte) map[string]string {
	values := map[string]string{}
	decoder := xml.NewDecoder(bytes.NewReader(data))
	depth := 0
	key := ""
	for {
		token, err := decoder.Token()
		if err != nil {
			return values
		}
		switch t := token.(type) {
		case xml.StartElement:
			depth++
			// plist (1) > dict (2) > key and value (3)
			if depth != 3 {
				continue
			}
			if t.Name.Local != "key" && t.Name.Local != "string" {
				key = ""
				continue
			}
			var text string
			if decoder.DecodeElement(&text, &t) != nil {
				return values
			}
			depth--
			if t.Name.Local == "key" {
				key = text
			} else if key != "" {
				values[key] = text
				key = ""
			}
		case xml.EndElement:
			depth--
		}
	}
}

// loadCaskIndex reads Homebrew's catalog of casks: Homebrew's own copy, which
// `brew update` keeps current, else moremole's copy of the public one,
// downloaded at most once a day.
func loadCaskIndex(brew string) ([]caskInfo, error) {
	if out, err := run(brewQueryTimeout, brew, "--cache"); err == nil {
		path := filepath.Join(strings.TrimSpace(out), "api", "cask.jws.json")
		if data, err := os.ReadFile(path); err == nil {
			if index, err := parseCaskIndex(data); err == nil && len(index) > 0 {
				return index, nil
			}
		}
	}

	home, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}
	cached := filepath.Join(home, "Library", "Caches", "moremole", "cask.json")
	if info, err := os.Stat(cached); err == nil && time.Since(info.ModTime()) < caskIndexMaxAge {
		if data, err := os.ReadFile(cached); err == nil {
			if index, err := parseCaskIndex(data); err == nil && len(index) > 0 {
				return index, nil
			}
		}
	}
	data, err := downloadCaskIndex()
	if err != nil {
		return nil, err
	}
	index, err := parseCaskIndex(data)
	if err != nil {
		return nil, err
	}
	if os.MkdirAll(filepath.Dir(cached), 0o755) == nil {
		_ = os.WriteFile(cached, data, 0o644)
	}
	return index, nil
}

func downloadCaskIndex() ([]byte, error) {
	client := http.Client{Timeout: caskIndexTimeout}
	resp, err := client.Get(caskIndexURL)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, errors.New(resp.Status)
	}
	return io.ReadAll(resp.Body)
}

// parseCaskIndex reads a list of casks, either plain JSON or wrapped the way
// Homebrew stores its copy: a signed object whose "payload" holds the list as
// a JSON string.
func parseCaskIndex(data []byte) ([]caskInfo, error) {
	var index []caskInfo
	if err := json.Unmarshal(data, &index); err == nil {
		return index, nil
	}
	var signed struct {
		Payload string `json:"payload"`
	}
	if err := json.Unmarshal(data, &signed); err != nil {
		return nil, err
	}
	if signed.Payload == "" {
		return nil, errors.New("no payload")
	}
	err := json.Unmarshal([]byte(signed.Payload), &index)
	return index, err
}

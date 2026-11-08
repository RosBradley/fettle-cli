package main

import (
	"os"
	"path/filepath"
	"strings"
)

// scanApps checks the apps installed without Homebrew or the App Store. An
// app Homebrew has a newer version of can move to Homebrew (takeover.go);
// any other app whose own updater lists a newer version is offered to open,
// so that updater installs it (feeds.go).
func scanApps() []Row {
	home, _ := os.UserHomeDir()
	apps := scanApplications([]string{"/Applications", filepath.Join(home, "Applications")})

	var rows []Row
	managed := map[string]bool{}
	if brew := findBrew(); brew != "" {
		tokens, managedApps, err := installedCasks(brew)
		var index []caskInfo
		if err == nil {
			managed = managedApps
			index, err = loadCaskIndex(brew)
		}
		if err != nil {
			rows = append(rows, notice("takeover-failed", "Couldn't check whether Homebrew has newer versions of apps installed without it."))
		} else {
			rows = append(rows, takeoverRows(apps, index, tokens, managedApps)...)
		}
	}

	offered := map[string]bool{}
	for _, r := range rows {
		offered[r.Name+".app"] = true
	}
	var candidates []localApp
	for _, app := range apps {
		if managed[app.FileName] || offered[app.FileName] || strings.HasPrefix(app.BundleID, "com.apple.") {
			continue
		}
		if app.FeedURL != "" {
			candidates = append(candidates, app)
		}
	}
	return append(rows, feedRows(candidates, fetchFeed, macOSVersion())...)
}

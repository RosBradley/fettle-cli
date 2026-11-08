package main

import (
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"
)

// Apps downloaded from their makers' websites mostly update themselves with
// Sparkle, which reads an "appcast": a feed listing each version, named in
// the app's Info.plist as SUFeedURL. Reading that feed shows whether a newer
// version exists. Installing stays with the app's own updater, which checks
// the download's signature, so updating such an app opens it.

const (
	feedTimeout  = 15 * time.Second
	feedWorkers  = 8
	feedMaxBytes = 4 << 20
	feedNote     = "opens the app"
)

type appcastItem struct {
	Version       string `xml:"version"`
	ShortVersion  string `xml:"shortVersionString"`
	MinimumSystem string `xml:"minimumSystemVersion"`
	Channel       string `xml:"channel"` // beta and other test channels
	Enclosure     struct {
		Version      string `xml:"version,attr"`
		ShortVersion string `xml:"shortVersionString,attr"`
	} `xml:"enclosure"`
}

type appcast struct {
	Items []appcastItem `xml:"channel>item"`
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if v = strings.TrimSpace(v); v != "" {
			return v
		}
	}
	return ""
}

// latestRelease returns the newest version in a feed that a Mac running
// macOS system can install, leaving out test channels such as beta, as the
// app's updater does unless the user opted in. build is what the updater
// compares with the app's CFBundleVersion; short is the version people see.
func latestRelease(data []byte, system string) (build, short string, ok bool) {
	var feed appcast
	if err := xml.Unmarshal(data, &feed); err != nil {
		return "", "", false
	}
	for _, item := range feed.Items {
		if strings.TrimSpace(item.Channel) != "" {
			continue
		}
		b := firstNonEmpty(item.Version, item.Enclosure.Version)
		if b == "" {
			continue
		}
		if minimum := strings.TrimSpace(item.MinimumSystem); minimum != "" && system != "" && compareVersions(minimum, system) > 0 {
			continue
		}
		if !ok || compareVersions(b, build) > 0 {
			build, short, ok = b, firstNonEmpty(item.ShortVersion, item.Enclosure.ShortVersion, b), true
		}
	}
	return build, short, ok
}

// newerInFeed compares the way the app's updater does: the feed's build
// against the app's CFBundleVersion, or the shown versions when the app has
// no build number.
func newerInFeed(app localApp, build, short string) bool {
	if app.Build != "" {
		return compareVersions(build, app.Build) > 0
	}
	return app.Short != "" && compareVersions(short, app.Short) > 0
}

// fetchFeed downloads a feed. Tests replace it.
var fetchFeed = func(url string) ([]byte, error) {
	if !strings.HasPrefix(url, "https://") && !strings.HasPrefix(url, "http://") {
		return nil, errors.New("not a web address")
	}
	client := &http.Client{Timeout: feedTimeout}
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "Fettle (Sparkle feed check)")
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	return io.ReadAll(io.LimitReader(resp.Body, feedMaxBytes))
}

// macOSVersion is this Mac's macOS version, or "" when unknown, which skips
// the minimum-version check. Tests replace it.
var macOSVersion = func() string {
	out, err := run(10*time.Second, "/usr/bin/sw_vers", "-productVersion")
	if err != nil {
		return ""
	}
	return strings.TrimSpace(out)
}

// feedRows checks each app's feed, several at a time, and lists the apps
// with a newer version. A feed that cannot be read is skipped quietly: the
// app's own updater still works.
func feedRows(apps []localApp, fetch func(string) ([]byte, error), system string) []Row {
	found := make([]*Row, len(apps))
	jobs := make(chan int)
	var wg sync.WaitGroup
	for range feedWorkers {
		wg.Go(func() {
			for i := range jobs {
				app := apps[i]
				data, err := fetch(app.FeedURL)
				if err != nil {
					continue
				}
				build, short, ok := latestRelease(data, system)
				if !ok || !newerInFeed(app, build, short) {
					continue
				}
				found[i] = &Row{
					Kind:      "feed",
					ID:        app.Path,
					Name:      app.Name,
					Installed: firstNonEmpty(app.Short, app.Build),
					Available: short,
					Note:      feedNote,
					Bundle:    app.BundleID,
				}
			}
		})
	}
	for i := range apps {
		jobs <- i
	}
	close(jobs)
	wg.Wait()

	var rows []Row
	for _, r := range found {
		if r != nil {
			rows = append(rows, *r)
		}
	}
	sortRows(rows)
	return rows
}

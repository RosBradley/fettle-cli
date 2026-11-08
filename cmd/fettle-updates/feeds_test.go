package main

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

const postico = `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Postico</title>
    <item>
      <title>Postico 2.2</title>
      <sparkle:version>9000</sparkle:version>
      <sparkle:shortVersionString>2.2</sparkle:shortVersionString>
      <enclosure url="https://example.com/2.2.zip" length="1" type="application/octet-stream"/>
    </item>
    <item>
      <title>Postico 2.3</title>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <enclosure url="https://example.com/2.3.zip" sparkle:version="9100" sparkle:shortVersionString="2.3" length="1" type="application/octet-stream"/>
    </item>
    <item>
      <title>Postico 2.4 beta</title>
      <sparkle:channel>beta</sparkle:channel>
      <sparkle:version>9200</sparkle:version>
      <sparkle:shortVersionString>2.4b1</sparkle:shortVersionString>
    </item>
    <item>
      <title>Postico 3.0</title>
      <sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion>
      <sparkle:version>9900</sparkle:version>
      <sparkle:shortVersionString>3.0</sparkle:shortVersionString>
    </item>
  </channel>
</rss>`

func TestLatestReleaseSkipsTestChannelsAndNewerMacOS(t *testing.T) {
	build, short, ok := latestRelease([]byte(postico), "15.1")
	if !ok || build != "9100" || short != "2.3" {
		t.Errorf("got %q %q %v, want 9100 2.3 (enclosure attributes, no beta, no macOS 99)", build, short, ok)
	}
	// An unknown macOS version keeps every release.
	if build, _, _ := latestRelease([]byte(postico), ""); build != "9900" {
		t.Errorf("unknown macOS: %q", build)
	}
	if _, _, ok := latestRelease([]byte("<html>not a feed</html>"), "15.1"); ok {
		t.Error("a web page read as a feed")
	}
}

func TestNewerInFeedComparesBuildNumbersFirst(t *testing.T) {
	for _, tc := range []struct {
		app          localApp
		build, short string
		want         bool
	}{
		{localApp{Short: "2.2", Build: "9000"}, "9100", "2.3", true},
		{localApp{Short: "2.2", Build: "9100"}, "9100", "2.3", false},
		{localApp{Short: "2.2"}, "9100", "2.3", true},
		{localApp{Short: "2.3"}, "9100", "2.3", false},
		{localApp{}, "9100", "2.3", false},
	} {
		if got := newerInFeed(tc.app, tc.build, tc.short); got != tc.want {
			t.Errorf("newerInFeed(%+v, %q, %q) = %v", tc.app, tc.build, tc.short, got)
		}
	}
}

func TestFeedRowsListAppsWithANewerVersion(t *testing.T) {
	apps := []localApp{
		{Path: "/Applications/Postico 2.app", Name: "Postico 2", BundleID: "at.eggerapps.Postico2", Short: "2.2", Build: "9000", FeedURL: "https://postico/feed"},
		{Path: "/Applications/Current.app", Name: "Current", Short: "2.3", Build: "9100", FeedURL: "https://postico/feed"},
		{Path: "/Applications/Offline.app", Name: "Offline", Short: "1.0", Build: "1", FeedURL: "https://offline/feed"},
	}
	fetch := func(url string) ([]byte, error) {
		if url == "https://offline/feed" {
			return nil, errors.New("no network")
		}
		return []byte(postico), nil
	}
	got := feedRows(apps, fetch, "15.1")
	want := []Row{{Kind: "feed", ID: "/Applications/Postico 2.app", Name: "Postico 2", Installed: "2.2", Available: "2.3", Note: feedNote, Bundle: "at.eggerapps.Postico2"}}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %#v\nwant %#v", got, want)
	}
}

func TestReadAppReadsItsFeedAndShownName(t *testing.T) {
	app := filepath.Join(t.TempDir(), "Postico 2.app")
	if err := os.MkdirAll(filepath.Join(app, "Contents"), 0o755); err != nil {
		t.Fatal(err)
	}
	plist := `<plist><dict>
<key>CFBundleName</key><string>Postico</string>
<key>CFBundleDisplayName</key><string>Postico 2</string>
<key>CFBundleShortVersionString</key><string>2.2</string>
<key>CFBundleVersion</key><string>9000</string>
<key>SUFeedURL</key><string>https://eggerapps.at/postico2/appcast.xml</string>
</dict></plist>`
	if err := os.WriteFile(filepath.Join(app, "Contents", "Info.plist"), []byte(plist), 0o644); err != nil {
		t.Fatal(err)
	}
	saved := readInfoPlist
	readInfoPlist = func(path string) (map[string]string, error) {
		data, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		return parsePlistStrings(data), nil
	}
	t.Cleanup(func() { readInfoPlist = saved })

	got, ok := readApp(app)
	if !ok || got.Name != "Postico 2" || got.FeedURL != "https://eggerapps.at/postico2/appcast.xml" || got.Path != app || got.Build != "9000" {
		t.Errorf("readApp: %+v %v", got, ok)
	}
}

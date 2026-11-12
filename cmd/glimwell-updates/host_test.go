package main

import (
	"reflect"
	"testing"
)

func TestAppPathOfFindsTheOutermostApp(t *testing.T) {
	for exe, want := range map[string]string{
		"/Applications/iTerm.app/Contents/MacOS/iTerm2":                                                  "/Applications/iTerm.app",
		"/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code H": "/Applications/Visual Studio Code.app",
		"/bin/zsh": "",
		"-zsh":     "",
		"login":    "",
	} {
		if got := appPathOf(exe); got != want {
			t.Errorf("appPathOf(%q) = %q, want %q", exe, got, want)
		}
	}
}

func TestParentExecutablesWalksUpToLaunchd(t *testing.T) {
	table := `    1     0 /sbin/launchd
  500     1 /Applications/Visual Studio Code.app/Contents/MacOS/Electron
  610   500 /Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper
  700   610 /bin/zsh
  800   700 /bin/bash
  900   800 /opt/glimwell/bin/glimwell-updates-go
  950   999 unrelated
`
	want := []string{
		"/bin/bash",
		"/bin/zsh",
		"/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper",
		"/Applications/Visual Studio Code.app/Contents/MacOS/Electron",
	}
	if got := parentExecutables(table, 900); !reflect.DeepEqual(got, want) {
		t.Errorf("got %q\nwant %q", got, want)
	}
	// A loop in the table ends the walk.
	if got := parentExecutables("10 11 a\n11 10 b\n", 10); !reflect.DeepEqual(got, []string{"b"}) {
		t.Errorf("loop: %q", got)
	}
}

func TestHostAppsFindsTheTerminalEachWay(t *testing.T) {
	useApps(t, map[string]string{"iTerm.app": "com.googlecode.iterm2"})
	saved := bundleOfApp
	bundleOfApp = func(path string) string {
		if path == "/Applications/Visual Studio Code.app" {
			return "com.microsoft.VSCode"
		}
		return saved(path)
	}
	env := map[string]string{"__CFBundleIdentifier": "com.googlecode.iterm2", "TERM_PROGRAM": "iTerm.app"}
	parents := []string{"/bin/zsh", "/Applications/Visual Studio Code.app/Contents/MacOS/Electron"}
	got := hostApps(func(k string) string { return env[k] }, parents)
	// iTerm2 found twice counts once.
	if want := []string{"com.googlecode.iterm2", "com.microsoft.VSCode"}; !reflect.DeepEqual(got, want) {
		t.Errorf("got %q, want %q", got, want)
	}
	// TERM_PROGRAM alone, as when the shell runs under iTerm2's own helper.
	env = map[string]string{"TERM_PROGRAM": "iTerm.app"}
	if got := hostApps(func(k string) string { return env[k] }, nil); !reflect.DeepEqual(got, []string{"com.googlecode.iterm2"}) {
		t.Errorf("TERM_PROGRAM only: %q", got)
	}
	// Terminal.app names itself without ".app"; nothing to find there.
	env = map[string]string{"TERM_PROGRAM": "Apple_Terminal"}
	if got := hostApps(func(k string) string { return env[k] }, []string{"/bin/zsh"}); len(got) != 0 {
		t.Errorf("Apple_Terminal: %q", got)
	}
}

func TestHostAppsFindsTerminalsThatNameThemselvesWithoutDotApp(t *testing.T) {
	useApps(t, map[string]string{
		"Ghostty.app":   "com.mitchellh.ghostty",
		"WezTerm.app":   "com.github.wez.wezterm",
		"Warp.app":      "dev.warp.Warp-Stable",
		"Hyper.app":     "co.zeit.hyper",
		"Tabby.app":     "org.tabby",
		"kitty.app":     "net.kovidgoyal.kitty",
		"Alacritty.app": "org.alacritty",
	})
	for _, tc := range []struct {
		env  map[string]string
		want string
	}{
		{map[string]string{"TERM_PROGRAM": "ghostty"}, "com.mitchellh.ghostty"},
		{map[string]string{"TERM_PROGRAM": "WezTerm"}, "com.github.wez.wezterm"},
		{map[string]string{"TERM_PROGRAM": "WarpTerminal"}, "dev.warp.Warp-Stable"},
		{map[string]string{"TERM_PROGRAM": "Hyper"}, "co.zeit.hyper"},
		{map[string]string{"TERM_PROGRAM": "Tabby"}, "org.tabby"},
		{map[string]string{"KITTY_WINDOW_ID": "1"}, "net.kovidgoyal.kitty"},
		{map[string]string{"ALACRITTY_WINDOW_ID": "4294967297"}, "org.alacritty"},
	} {
		got := hostApps(func(k string) string { return tc.env[k] }, nil)
		if !reflect.DeepEqual(got, []string{tc.want}) {
			t.Errorf("%v: got %q, want %q", tc.env, got, tc.want)
		}
	}
	// A terminal that isn't installed in an Applications folder adds nothing.
	useApps(t, map[string]string{})
	if got := hostApps(func(k string) string { return map[string]string{"TERM_PROGRAM": "ghostty"}[k] }, nil); len(got) != 0 {
		t.Errorf("Ghostty not installed: %q", got)
	}
}

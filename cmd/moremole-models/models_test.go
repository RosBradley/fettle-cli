package main

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func fields(line string) []string { return strings.Split(line, fieldSeparator) }

func TestParseModelNameFollowsOllama(t *testing.T) {
	for name, want := range map[string]modelRef{
		"llama3.2":                  {defaultRegistry, "library", "llama3.2", "latest"},
		"llama3.2:3b":               {defaultRegistry, "library", "llama3.2", "3b"},
		"jmorgan/test:v1":           {defaultRegistry, "jmorgan", "test", "v1"},
		"hf.co/bartowski/Qwen-GGUF": {"hf.co", "bartowski", "Qwen-GGUF", "latest"},
		"localhost:5000/me/m:q4":    {"localhost:5000", "me", "m", "q4"},
	} {
		got, ok := parseModelName(name)
		if !ok || got != want {
			t.Errorf("parseModelName(%q) = %+v, %v; want %+v", name, got, ok, want)
		}
	}
	for _, bad := range []string{"", "a/b/c/d", "x@sha256:00", "../x", "a b"} {
		if _, ok := parseModelName(bad); ok {
			t.Errorf("parseModelName(%q) accepted", bad)
		}
	}
	ref, _ := parseModelName("hf.co/bartowski/Qwen-GGUF:Q4_K_M")
	if got := ref.manifestURL(); got != "https://hf.co/v2/bartowski/Qwen-GGUF/manifests/Q4_K_M" {
		t.Errorf("url %q", got)
	}
}

// registry serves manifests by URL and Accept header for the check.
type registry map[string]string

func (r registry) fetch(url, accept string) ([]byte, int, error) {
	if body, ok := r[url+" "+accept]; ok {
		return []byte(body), http.StatusOK, nil
	}
	if body, ok := r[url]; ok {
		return []byte(body), http.StatusOK, nil
	}
	return []byte(`{"errors":[{"code":"MANIFEST_UNKNOWN"}]}`), http.StatusNotFound, nil
}

func TestCheckModelComparesTheSavedManifest(t *testing.T) {
	const plain = `{"schemaVersion":2,"mediaType":"application/vnd.docker.distribution.manifest.v2+json","layers":[{"size":10}]}`
	const newer = `{"schemaVersion":2,"mediaType":"application/vnd.docker.distribution.manifest.v2+json","layers":[{"size":11}]}`
	list := `{"schemaVersion":2,"mediaType":"application/vnd.ollama.manifest.list.v2+json","manifests":[{"digest":"sha256:` + sha256Hex([]byte(plain)) + `"}]}`
	url := "https://registry.ollama.ai/v2/library/m/manifests/latest"
	both := mediaManifestList + ", " + mediaManifest
	for _, c := range []struct {
		name   string
		digest string
		reg    registry
		want   string
	}{
		{"same bytes", sha256Hex([]byte(plain)), registry{url: plain}, "current"},
		{"changed", sha256Hex([]byte(plain)), registry{url: newer}, "update"},
		{"saved list still served", sha256Hex([]byte(list)), registry{url + " " + both: list, url: plain}, "current"},
		{"list holds the saved entry", sha256Hex([]byte(plain)), registry{url + " " + both: list}, "current"},
		{"older Ollama saved the plain one", sha256Hex([]byte(newer)), registry{url + " " + both: list, url + " " + mediaManifest: newer}, "current"},
		{"made here", sha256Hex([]byte(plain)), registry{}, "local"},
		{"no digest", "", registry{url: plain}, "unknown"},
	} {
		got := checkModel(localModel{Name: "m:latest", Digest: c.digest}, c.reg.fetch)
		if got != c.want {
			t.Errorf("%s: %q, want %q", c.name, got, c.want)
		}
	}
	offline := func(string, string) ([]byte, int, error) { return nil, 0, os.ErrDeadlineExceeded }
	if got := checkModel(localModel{Name: "m", Digest: "ab"}, offline); got != "unknown" {
		t.Errorf("offline: %q", got)
	}
}

func TestDownloadSizeAddsUpTheFiles(t *testing.T) {
	url := "https://registry.ollama.ai/v2/library/m/manifests/4b"
	reg := registry{url + " " + mediaManifest: `{"config":{"size":5},"layers":[{"size":100},{"size":20}]}`}
	lines := sizeLines([]string{"m:4b", "gone:1b"}, reg.fetch)
	want := []string{row("size", "m:4b", "125"), notice("not-found", "gone:1b")}
	if !reflect.DeepEqual(lines, want) {
		t.Errorf("got %q, want %q", lines, want)
	}
}

// fakeService serves Ollama's local API.
func fakeService(t *testing.T, tags, ps string) service {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/version":
			_, _ = w.Write([]byte(`{"version":"0.12.0"}`))
		case "/api/tags":
			_, _ = w.Write([]byte(tags))
		case "/api/ps":
			_, _ = w.Write([]byte(ps))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)
	return service{base: srv.URL, client: srv.Client()}
}

func TestListLinesShowSizesStatusAndWhatIsLoaded(t *testing.T) {
	const plain = `{"layers":[{"size":1}]}`
	tags, _ := json.Marshal(map[string]any{"models": []map[string]any{
		{"name": "qwen3:4b", "size": 2500, "digest": sha256Hex([]byte(plain)), "modified_at": "2026-10-01T10:00:00Z"},
		{"name": "Llama3.2:latest", "size": 2000, "digest": "00", "modified_at": "2026-09-01T10:00:00Z"},
		{"name": "my-assistant:latest", "size": 2000, "digest": "11", "modified_at": "2026-09-02T10:00:00Z"},
	}})
	s := fakeService(t, string(tags), `{"models":[{"name":"qwen3:4b"}]}`)
	if !s.running() {
		t.Fatal("service not running")
	}
	var calls atomic.Int32
	reg := registry{
		"https://registry.ollama.ai/v2/library/qwen3/manifests/4b":        plain,
		"https://registry.ollama.ai/v2/library/Llama3.2/manifests/latest": `{"layers":[{"size":2}]}`,
	}
	fetch := func(url, accept string) ([]byte, int, error) {
		calls.Add(1)
		return reg.fetch(url, accept)
	}
	// Without --check nothing is fetched and the status is empty; A-Z.
	lines := listLines(s, false, fetch, nil, nil)
	if calls.Load() != 0 || len(lines) != 3 || fields(lines[0])[1] != "Llama3.2:latest" || fields(lines[0])[4] != "" {
		t.Fatalf("plain list %q, %d fetches", lines, calls.Load())
	}
	lines = listLines(s, true, fetch, nil, nil)
	want := []string{
		row("model", "Llama3.2:latest", "2000", "1788256800", "update", "0", ""),
		row("model", "my-assistant:latest", "2000", "1788343200", "local", "0", ""),
		row("model", "qwen3:4b", "2500", "1790848800", "current", "1", ""),
	}
	if !reflect.DeepEqual(lines, want) {
		t.Errorf("got %q\nwant %q", lines, want)
	}
	// No service: one notice.
	off := service{base: "http://127.0.0.1:1", client: &http.Client{Timeout: time.Second}}
	if got := listLines(off, true, fetch, nil, nil); len(got) != 1 || !strings.HasPrefix(got[0], "notice"+fieldSeparator+"service-failed") {
		t.Errorf("no service: %q", got)
	}
}

func TestLibraryListsDownloadableModelsAndMarksInstalled(t *testing.T) {
	page, err := os.ReadFile(filepath.Join("testdata", "library.html"))
	if err != nil {
		t.Fatal(err)
	}
	models := parseLibrary(string(page))
	if len(models) != 4 {
		t.Fatalf("%d models", len(models))
	}
	llama := models[0]
	if llama.Name != "llama3.1" || !reflect.DeepEqual(llama.Sizes, []string{"8b", "70b", "405b"}) ||
		!reflect.DeepEqual(llama.Capabilities, []string{"tools"}) || llama.Pulls != "120.6M" ||
		llama.Updated.Unix() != 1733006040 || !strings.HasPrefix(llama.Description, "Llama 3.1 is a new") || llama.Cloud {
		t.Errorf("llama3.1: %+v", llama)
	}

	s := fakeService(t, `{"models":[{"name":"llama3.1:8b"},{"name":"nomic-embed-text:latest"}]}`, `{"models":[]}`)
	lines := libraryLines(func() (string, error) { return string(page), nil }, s, nil)
	var names []string
	installed, sizes := map[string]string{}, map[string]string{}
	for _, l := range lines {
		f := fields(l)
		names = append(names, f[1])
		installed[f[1]] = f[5]
		sizes[f[1]] = f[6]
	}
	// One row per model. minimax-m2.7 runs only on Ollama's servers; gemma4
	// is on both.
	if want := []string{"llama3.1", "nomic-embed-text", "gemma4"}; !reflect.DeepEqual(names, want) {
		t.Errorf("rows %q\nwant %q", names, want)
	}
	if sizes["llama3.1"] != "8b,70b,405b" || sizes["nomic-embed-text"] != "" || sizes["gemma4"] != "e2b,e4b,12b,26b,31b" {
		t.Errorf("sizes %v", sizes)
	}
	if installed["llama3.1"] != "1" || installed["nomic-embed-text"] != "1" || installed["gemma4"] != "0" {
		t.Errorf("installed marks %v", installed)
	}
	// Without an MLX index (an Intel Mac) the MLX count is empty.
	if f := fields(lines[0]); f[7] != "" || !strings.HasPrefix(f[8], "Llama 3.1 is a new") {
		t.Errorf("mlx %q, description %q", f[7], f[8])
	}

	failed := libraryLines(func() (string, error) { return "<html>redesigned</html>", nil }, s, nil)
	if len(failed) != 1 || !strings.Contains(failed[0], "library-failed") {
		t.Errorf("unreadable page: %q", failed)
	}
}

func TestServiceURLFollowsOllamaHost(t *testing.T) {
	for host, want := range map[string]string{
		"":                       "http://127.0.0.1:11434",
		"0.0.0.0":                "http://127.0.0.1:11434",
		"0.0.0.0:8080":           "http://127.0.0.1:8080",
		"https://ollama.lan:443": "https://ollama.lan:443",
		"[::1]:11434":            "http://[::1]:11434",
	} {
		if got := serviceURL(host); got != want {
			t.Errorf("serviceURL(%q) = %q, want %q", host, got, want)
		}
	}
}

func TestFindOllamaUsesTheAppsOwnCommand(t *testing.T) {
	dir := t.TempDir()
	app := filepath.Join(dir, "Ollama.app")
	cli := filepath.Join(app, "Contents", "Resources", "ollama")
	if err := os.MkdirAll(filepath.Dir(cli), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(cli, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	savedApps, savedCLI := appDirs, cliDirs
	appDirs = func() []string { return []string{dir} }
	cliDirs = nil
	t.Setenv("PATH", t.TempDir())
	t.Cleanup(func() { appDirs, cliDirs = savedApps, savedCLI })
	in := findOllama()
	if in.App != app || in.CLI != cli {
		t.Errorf("found %+v", in)
	}
	if got := statusLines(in, true, 16<<30); !reflect.DeepEqual(got, []string{"app=" + app, "cli=" + cli, "running=1", "memory=17179869184"}) {
		t.Errorf("status %q", got)
	}
}

func tagsFixture(t *testing.T) string {
	t.Helper()
	page, err := os.ReadFile(filepath.Join("testdata", "tags.html"))
	if err != nil {
		t.Fatal(err)
	}
	return string(page)
}

func TestTagsPageGivesEachVersionsSizeContextInputAndMLX(t *testing.T) {
	tags := parseTags("qwen3.5", tagsFixture(t))
	var names []string
	for _, tag := range tags {
		names = append(names, tag.Name)
	}
	// latest repeats 9b, the default; the cloud version has no size.
	if want := []string{"qwen3.5:9b", "qwen3.5:9b-mlx", "qwen3.5:9b-q4_K_M", "qwen3.5:122b"}; !reflect.DeepEqual(names, want) {
		t.Fatalf("versions %q\nwant %q", names, want)
	}
	nine, mlx, big := tags[0], tags[1], tags[3]
	if nine.SizeText != "6.6GB-7.6GB" || nine.Bytes != 6_600_000_000 || nine.Context != "256K" || nine.Input != "Text, Image" || !nine.Default || nine.MLX {
		t.Errorf("9b: %+v", nine)
	}
	if !mlx.MLX || mlx.Default || mlx.Bytes != 8_900_000_000 {
		t.Errorf("9b-mlx: %+v", mlx)
	}
	if big.Bytes != 81_000_000_000 || big.MLX {
		t.Errorf("122b: %+v", big)
	}
	if got := parseTags("gemma4", tagsFixture(t)); len(got) != 0 {
		t.Errorf("another model's page gave versions: %+v", got)
	}
}

func TestTagsLinesMarkInstalledAndLeaveOutMLXOnIntel(t *testing.T) {
	page := tagsFixture(t)
	fetch := func(model string) (string, error) {
		if model == "qwen3.5" {
			return page, nil
		}
		return "", errors.New("HTTP 404")
	}
	s := fakeService(t, `{"models":[{"name":"qwen3.5:latest"}]}`, `{"models":[]}`)
	rows := map[string][]string{}
	var order []string
	for _, l := range tagsLines([]string{"qwen3.5", "gone", "../x"}, fetch, s, true) {
		f := fields(l)
		rows[f[1]] = f
		order = append(order, f[0]+":"+f[1])
	}
	want := []string{"tag:qwen3.5:9b", "tag:qwen3.5:9b-mlx", "tag:qwen3.5:9b-q4_K_M", "tag:qwen3.5:122b", "notice:tags-failed", "notice:tags-failed"}
	if !reflect.DeepEqual(order, want) {
		t.Fatalf("rows %q\nwant %q", order, want)
	}
	// qwen3.5:latest is installed, which is the default 9b.
	if f := rows["qwen3.5:9b"]; f[2] != "6600000000" || f[3] != "6.6GB-7.6GB" || f[4] != "256K" || f[5] != "Text, Image" || f[6] != "0" || f[7] != "1" || f[8] != "1" {
		t.Errorf("9b row %q", f)
	}
	if f := rows["qwen3.5:9b-mlx"]; f[6] != "1" || f[8] != "0" {
		t.Errorf("9b-mlx row %q", f)
	}
	for _, l := range tagsLines([]string{"qwen3.5"}, fetch, s, false) {
		if f := fields(l); f[6] == "1" {
			t.Errorf("an Intel Mac was offered an MLX version: %q", f)
		}
	}
}

package main

import (
	"bytes"
	"crypto/sha1" //nolint:gosec // G505: git's blob IDs are SHA-1
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// tagsPageFor turns the qwen3.5 tags page in testdata into another model's,
// with its one MLX version.
func tagsPageFor(t *testing.T, model string) string {
	t.Helper()
	page, err := os.ReadFile(filepath.Join("testdata", "tags.html"))
	if err != nil {
		t.Fatal(err)
	}
	return strings.ReplaceAll(string(page), "/library/qwen3.5:", "/library/"+model+":")
}

func useCacheDir(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	saved := cacheDir
	cacheDir = func() string { return dir }
	t.Cleanup(func() { cacheDir = saved })
	return dir
}

func TestLibraryCountsMLXVersionsAndReadsAPageAgainOnlyWhenTheModelChanged(t *testing.T) {
	useCacheDir(t)
	page, err := os.ReadFile(filepath.Join("testdata", "library.html"))
	if err != nil {
		t.Fatal(err)
	}
	library := func() (string, error) { return string(page), nil }
	s := fakeService(t, `{"models":[]}`, `{"models":[]}`)
	var mu sync.Mutex
	asked := map[string]int{}
	fetch := func(model string) (string, error) {
		mu.Lock()
		asked[model]++
		mu.Unlock()
		if model == "nomic-embed-text" {
			return "", errors.New("offline")
		}
		return tagsPageFor(t, model), nil
	}
	index := func() *mlxIndex {
		x := newMLXIndex()
		x.fetch = fetch
		return x
	}
	mlxOf := func(lines []string) map[string]string {
		got := map[string]string{}
		for _, l := range lines {
			got[fields(l)[1]] = fields(l)[7]
		}
		return got
	}

	got := mlxOf(libraryLines(library, s, index()))
	// A page that couldn't be read leaves the count unknown.
	if want := map[string]string{"llama3.1": "1", "nomic-embed-text": "", "gemma4": "1"}; !reflect.DeepEqual(got, want) {
		t.Errorf("first look: %v, want %v", got, want)
	}
	// The cloud-only model is never read.
	if asked["minimax-m2.7"] != 0 || asked["llama3.1"] != 1 {
		t.Errorf("asked %v", asked)
	}

	// Nothing changed: only the unread page is asked for again.
	got = mlxOf(libraryLines(library, s, index()))
	if got["llama3.1"] != "1" || asked["llama3.1"] != 1 || asked["nomic-embed-text"] != 2 {
		t.Errorf("second look: %v, asked %v", got, asked)
	}

	// A model whose date on the page changed is read again, and so is
	// everything after a week.
	changed := strings.Replace(string(page), "Nov 30, 2024 10:34 PM", "Dec 1, 2024 10:34 PM", 1)
	libraryLines(func() (string, error) { return changed, nil }, s, index())
	if asked["llama3.1"] != 2 || asked["gemma4"] != 1 {
		t.Errorf("after llama3.1 changed: asked %v", asked)
	}
	saved := now
	now = func() time.Time { return saved().Add(8 * 24 * time.Hour) }
	t.Cleanup(func() { now = saved })
	libraryLines(func() (string, error) { return changed, nil }, s, index())
	if asked["gemma4"] != 2 {
		t.Errorf("a week later: asked %v", asked)
	}
}

func TestFamiliesComeFromTheRegistryConfigOfEachMLXVersion(t *testing.T) {
	useCacheDir(t)
	x := newMLXIndex()
	x.cache.Models["qwen3.5"] = cacheEntry{Fetched: now().Unix(), Tags: []tagInfo{{Name: "qwen3.5:9b"}, {Name: "qwen3.5:9b-mlx", MLX: true}}}
	x.cache.Models["llama3.1"] = cacheEntry{Fetched: now().Unix(), Tags: []tagInfo{{Name: "llama3.1:8b"}}}
	var manifests atomic.Int32
	x.manifest = func(url, accept string) ([]byte, int, error) {
		manifests.Add(1)
		if url != "https://registry.ollama.ai/v2/library/qwen3.5/manifests/9b-mlx" || accept != mediaManifest {
			return nil, http.StatusNotFound, nil
		}
		return []byte(`{"layers":[{"name":"tokenizer.json","digest":"sha256:aa"},{"name":"config.json","digest":"sha256:bb"}]}`), http.StatusOK, nil
	}
	x.blob = func(url string) ([]byte, error) {
		if url != "https://registry.ollama.ai/v2/library/qwen3.5/blobs/sha256:bb" {
			return nil, errors.New("wrong blob " + url)
		}
		return []byte(`{"architectures":["Qwen3_5ForConditionalGeneration"],"model_type":"qwen3_5"}`), nil
	}
	if got := x.families(); !reflect.DeepEqual(got, map[string]bool{"qwen3_5": true}) {
		t.Errorf("families %v", got)
	}
	x.save()
	// Cached: the registry isn't asked again.
	y := newMLXIndex()
	y.manifest = x.manifest
	if got := y.families(); !got["qwen3_5"] || manifests.Load() != 1 {
		t.Errorf("cached families %v after %d manifests", got, manifests.Load())
	}

	// Nothing readable: the families known when this was written.
	useCacheDir(t)
	z := newMLXIndex()
	if got := z.families(); !got["qwen3_5"] || !got["gemma4"] || len(got) != len(fallbackFamilies) {
		t.Errorf("fallback %v", got)
	}
}

// fakeHF serves Hugging Face's API and files, and counts what was asked.
type fakeHF struct {
	t      *testing.T
	api    map[string]string // path?query -> JSON
	files  map[string][]byte // repo/resolve/sha/name -> content
	ranges []string
	mu     sync.Mutex
	root   string // the staging root downloads go in
}

// staging is a download folder in the fake staging root.
func (f *fakeHF) staging(name string) string { return filepath.Join(f.root, name) }

// gitBlobID is git's name for a file's contents, as Hugging Face lists it.
func gitBlobID(b []byte) string {
	h := sha1.New() //nolint:gosec // G401: git's blob IDs are SHA-1
	_, _ = fmt.Fprintf(h, "blob %d\x00", len(b))
	_, _ = h.Write(b)
	return hex.EncodeToString(h.Sum(nil))
}

func useFakeHF(t *testing.T) *fakeHF {
	t.Helper()
	f := &fakeHF{t: t, api: map[string]string{}, files: map[string][]byte{}, root: t.TempDir()}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		if body, ok := f.api[r.URL.Path+"?"+r.URL.RawQuery]; ok {
			_, _ = w.Write([]byte(body))
			return
		}
		content, ok := f.files[strings.TrimPrefix(r.URL.Path, "/")]
		if !ok {
			http.NotFound(w, r)
			return
		}
		if rg := r.Header.Get("Range"); rg != "" {
			f.ranges = append(f.ranges, rg)
			var start int
			_, _ = fmt.Sscanf(rg, "bytes=%d-", &start)
			w.WriteHeader(http.StatusPartialContent)
			_, _ = w.Write(content[start:])
			return
		}
		_, _ = w.Write(content)
	}))
	t.Cleanup(srv.Close)
	saved, savedGet, savedFree, savedRoot := hfSite, hfGet, freeBytes, hfStagingRoot
	hfSite = srv.URL
	freeBytes = func(string) (int64, error) { return 1 << 40, nil }
	hfStagingRoot = func() string { return f.root }
	t.Cleanup(func() { hfSite, hfGet, freeBytes, hfStagingRoot = saved, savedGet, savedFree, savedRoot })
	return f
}

func sum(b []byte) string {
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}

func TestHFListOffersOpenChatModelsOfOllamasMLXFamiliesOnly(t *testing.T) {
	useCacheDir(t)
	f := useFakeHF(t)
	list := func(models ...map[string]any) string {
		b, _ := json.Marshal(models)
		return string(b)
	}
	cfg := func(family string, bits int) map[string]any {
		c := map[string]any{"model_type": family}
		if bits > 0 {
			c["quantization_config"] = map[string]any{"bits": bits}
		}
		return c
	}
	params := map[string]any{"parameters": map[string]any{"U32": 8000, "BF16": 100}}
	first := hfListURL()
	page2 := hfAPI() + "?cursor=2"
	hfGet = func(u string, limit int64) ([]byte, string, error) {
		switch u {
		case first:
			return []byte(list(
				map[string]any{"id": "mlx-community/Qwen3.5-9B-4bit", "pipeline_tag": "image-text-to-text", "downloads": 900, "gated": false, "config": cfg("qwen3_5", 4), "safetensors": params, "lastModified": "2026-10-01T00:00:00.000Z", "createdAt": "2026-03-02T00:00:00.000Z"},
				map[string]any{"id": "mlx-community/Llama-3.2-1B-4bit", "pipeline_tag": "text-generation", "downloads": 800, "gated": false, "config": cfg("llama", 4), "safetensors": params},
				map[string]any{"id": "google/gated-gemma", "pipeline_tag": "text-generation", "downloads": 700, "gated": "manual", "config": cfg("gemma4", 4), "safetensors": params},
				map[string]any{"id": "mlx-community/whisper", "pipeline_tag": "automatic-speech-recognition", "downloads": 600, "gated": false, "config": cfg("qwen3_5", 4)},
				map[string]any{"id": "bad name/x", "pipeline_tag": "text-generation", "gated": false, "config": cfg("qwen3_5", 4)},
			)), page2, nil
		case page2:
			return []byte(list(
				map[string]any{"id": "someone/Gemma-4-bf16", "pipeline_tag": "text-generation", "downloads": 10, "gated": false, "config": cfg("gemma4", 0), "safetensors": map[string]any{"parameters": map[string]any{"BF16": 1000}}},
				map[string]any{"id": "mlx-community/Qwen3.5-9B-4bit", "pipeline_tag": "image-text-to-text", "gated": false, "config": cfg("qwen3_5", 4)},
			)), "", nil
		}
		return nil, "", errors.New("unexpected " + u)
	}
	_ = f
	x := newMLXIndex()
	x.cache.Models["qwen3.5"] = cacheEntry{Fetched: now().Unix(), Family: "qwen3_5", Tags: []tagInfo{{Name: "qwen3.5:9b-mlx", MLX: true}}}
	x.cache.Models["gemma4"] = cacheEntry{Fetched: now().Unix(), Family: "gemma4", Tags: []tagInfo{{Name: "gemma4:e2b-mlx", MLX: true}}}
	s := fakeService(t, `{"models":[{"name":"hf.co/mlx-community/qwen3.5-9b-4bit:latest"}]}`, `{"models":[]}`)
	lines := hfListLines(func() (string, error) { return "", errors.New("offline") }, x, s)
	want := []string{
		// 8000 4-bit weights at 4.5 bits, plus 100 bf16 values.
		row("hf", "mlx-community/Qwen3.5-9B-4bit", "qwen3_5", "4-bit", "4700", "900", "1790812800", "1", "Text, Image", "1772409600"),
		row("hf", "someone/Gemma-4-bf16", "gemma4", "bf16", "2000", "10", "0", "0", "Text", "0"),
	}
	if !reflect.DeepEqual(lines, want) {
		t.Errorf("got %q\nwant %q", lines, want)
	}

	hfGet = func(string, int64) ([]byte, string, error) { return nil, "", errors.New("HTTP 503") }
	if got := hfListLines(func() (string, error) { return "", errors.New("offline") }, x, s); len(got) != 1 || !strings.Contains(got[0], "hf-failed") || !strings.Contains(got[0], "HTTP 503") {
		t.Errorf("unreachable: %q", got)
	}
}

const testSHA = "0123456789abcdef0123456789abcdef01234567"

// serveRepo puts a model's files on the fake Hugging Face at a commit.
func (f *fakeHF) serveRepo(repo, sha string, files map[string][]byte, extra ...string) {
	var siblings []map[string]any
	// In name order, as Hugging Face lists them; a map's order changes
	// from run to run.
	names := make([]string, 0, len(files))
	for name := range files {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		content := files[name]
		s := map[string]any{"rfilename": name, "size": len(content), "blobId": gitBlobID(content)}
		if strings.HasSuffix(name, ".safetensors") {
			s["lfs"] = map[string]any{"sha256": sum(content), "size": len(content)}
		}
		siblings = append(siblings, s)
		f.files[repo+"/resolve/"+sha+"/"+name] = content
	}
	for _, name := range extra {
		siblings = append(siblings, map[string]any{"rfilename": name, "size": 5})
	}
	info, _ := json.Marshal(map[string]any{"id": repo, "sha": sha, "gated": false, "siblings": siblings})
	f.api["/api/models/"+repo+"/revision/"+sha+"?blobs=true"] = string(info)
	f.api["/api/models/"+repo+"?blobs=true"] = string(info)
}

func TestHFDownloadTakesOnlyTheWeightsTheIndexNames(t *testing.T) {
	f := useFakeHF(t)
	f.serveRepo("someone/Two-Sets", testSHA, map[string][]byte{
		"config.json":                      []byte(`{"model_type":"qwen3_5"}`),
		"model-00001-of-00002.safetensors": bytes.Repeat([]byte("a"), 100),
		"model-00002-of-00002.safetensors": bytes.Repeat([]byte("b"), 100),
		"model-00001-of-00003.safetensors": bytes.Repeat([]byte("c"), 70),
		"model-00002-of-00003.safetensors": bytes.Repeat([]byte("d"), 70),
		"model-00003-of-00003.safetensors": bytes.Repeat([]byte("e"), 70),
		hfIndexName:                        []byte(`{"weight_map":{"x.weight":"model-00001-of-00002.safetensors","y.weight":"model-00002-of-00002.safetensors"}}`),
	})
	lines := hfFilesLines([]string{"someone/Two-Sets"})
	// config.json and the index (132 bytes) and the two parts it names
	// (200); the three-part set (210) is left out.
	if len(lines) != 1 || fields(lines[0])[3] != "332" || fields(lines[0])[4] != "4" {
		t.Fatalf("files %q", lines)
	}
	dir := f.staging("someone--Two-Sets")
	// A download that stopped before left a part of the other set, and of
	// an earlier commit; `ollama create` would add both to the model.
	if err := os.MkdirAll(filepath.Join(dir, "sub"), 0o700); err != nil {
		t.Fatal(err)
	}
	for _, stale := range []string{"model-00001-of-00003.safetensors", "model-00002-of-00003.safetensors.part", "old.json"} {
		if err := os.WriteFile(filepath.Join(dir, stale), []byte("old"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	var out bytes.Buffer
	if err := hfDownload("someone/Two-Sets", testSHA, dir, &out); err != nil {
		t.Fatalf("download: %v\n%s", err, out.String())
	}
	for _, stale := range []string{"model-00001-of-00003.safetensors", "model-00002-of-00003.safetensors.part", "old.json"} {
		if _, err := os.Stat(filepath.Join(dir, stale)); err == nil {
			t.Errorf("%s is still in the download folder", stale)
		}
	}
	if _, err := os.Stat(filepath.Join(dir, "sub")); err != nil {
		t.Error("a folder in the download folder was deleted")
	}
	if _, err := os.Stat(filepath.Join(dir, "model-00002-of-00002.safetensors")); err != nil {
		t.Error("a part the index names is missing")
	}

	// An index naming a part the model doesn't have stops the download.
	f.serveRepo("someone/Broken-Index", testSHA, map[string][]byte{
		"config.json":       []byte(`{"model_type":"qwen3_5"}`),
		"model.safetensors": []byte("w"),
		hfIndexName:         []byte(`{"weight_map":{"x":"model-00009-of-00009.safetensors"}}`),
	})
	if lines := hfFilesLines([]string{"someone/Broken-Index"}); len(lines) != 1 || !strings.Contains(lines[0], "model-00009-of-00009.safetensors, which the model doesn't have") {
		t.Errorf("broken index %q", lines)
	}
}

func TestHFDownloadChecksEveryFileFillsTheQuantizationModeAndContinuesAPartialFile(t *testing.T) {
	f := useFakeHF(t)
	weights := bytes.Repeat([]byte("w"), 5000)
	f.serveRepo("mlx-community/Old-Llama-4bit", testSHA, map[string][]byte{
		"model.safetensors": weights,
		"config.json":       []byte(`{"model_type":"qwen3_5","quantization":{"bits":4,"group_size":64}}`),
		"tokenizer.json":    []byte(`{}`),
	}, "README.md", "sample.png", "original/consolidated.pth")

	lines := hfFilesLines([]string{"mlx-community/Old-Llama-4bit", "mlx-community/missing"})
	if len(lines) != 2 || lines[0] != row("files", "mlx-community/Old-Llama-4bit", testSHA, "5068", "3", "hf.co/mlx-community/old-llama-4bit") ||
		!strings.Contains(lines[1], "hf-failed") || !strings.Contains(lines[1], "mlx-community/missing: HTTP 404") {
		t.Errorf("files %q", lines)
	}

	dir := f.staging("mlx-community--Old-Llama-4bit")
	// A download that stopped partway continues where it stopped.
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "model.safetensors.part"), weights[:2000], 0o600); err != nil {
		t.Fatal(err)
	}
	// Each read comes a second after the last, so every one shows.
	saved, clock := now, time.Unix(1790000000, 0)
	now = func() time.Time { clock = clock.Add(time.Second); return clock }
	t.Cleanup(func() { now = saved })
	var out bytes.Buffer
	if err := hfDownload("mlx-community/Old-Llama-4bit", testSHA, dir, &out); err != nil {
		t.Fatalf("download: %v\n%s", err, out.String())
	}
	if !reflect.DeepEqual(f.ranges, []string{"bytes=2000-"}) {
		t.Errorf("ranges %q", f.ranges)
	}
	if got, _ := os.ReadFile(filepath.Join(dir, "model.safetensors")); !bytes.Equal(got, weights) {
		t.Errorf("weights not whole: %d bytes", len(got))
	}
	for _, skipped := range []string{"README.md", "sample.png", "consolidated.pth", "model.safetensors.part"} {
		if _, err := os.Stat(filepath.Join(dir, skipped)); err == nil {
			t.Errorf("%s was downloaded", skipped)
		}
	}
	var cfg struct {
		Quantization map[string]any `json:"quantization"`
	}
	data, _ := os.ReadFile(filepath.Join(dir, "config.json"))
	if json.Unmarshal(data, &cfg) != nil || cfg.Quantization["mode"] != "affine" || cfg.Quantization["bits"] != float64(4) {
		t.Errorf("config %s", data)
	}
	if mf, _ := os.ReadFile(filepath.Join(dir, "Modelfile")); string(mf) != "FROM .\n" {
		t.Errorf("Modelfile %q", mf)
	}
	if !strings.Contains(out.String(), "downloading model.safetensors  2 KB of 5 KB  40%") || !strings.HasSuffix(out.String(), "\rdownloaded 5 KB in 3 files\033[K\n") {
		t.Errorf("progress %q", out.String())
	}

	// Done files aren't downloaded again.
	f.ranges = nil
	if err := hfDownload("mlx-community/Old-Llama-4bit", testSHA, dir, &out); err != nil || len(f.ranges) != 0 {
		t.Errorf("second run: %v, ranges %q", err, f.ranges)
	}
}

func TestHFDownloadRefusesABadFileOrTooLittleSpace(t *testing.T) {
	f := useFakeHF(t)
	f.serveRepo("me/Model-4bit", testSHA, map[string][]byte{
		"model.safetensors": []byte("good weights"),
		"config.json":       []byte(`{"model_type":"qwen3_5"}`),
	})
	f.files["me/Model-4bit/resolve/"+testSHA+"/model.safetensors"] = []byte("evil weights")
	dir := f.staging("me--Model-4bit")
	var out bytes.Buffer
	err := hfDownload("me/Model-4bit", testSHA, dir, &out)
	if err == nil || !strings.Contains(err.Error(), "model.safetensors: its SHA-256 doesn't match Hugging Face's, so it was deleted") {
		t.Errorf("bad file: %v", err)
	}
	for _, name := range []string{"model.safetensors", "model.safetensors.part"} {
		if _, statErr := os.Stat(filepath.Join(dir, name)); statErr == nil {
			t.Errorf("%s kept after a bad download", name)
		}
	}

	freeBytes = func(string) (int64, error) { return 30, nil }
	err = hfDownload("me/Model-4bit", testSHA, f.staging("me--Model-4bit-2"), &out)
	if err == nil || !strings.Contains(err.Error(), "not enough free space: it needs 72 B (the download and Ollama's copy of it), and 30 B is free") {
		t.Errorf("no space: %v", err)
	}

	// No MLX weights, or a name that isn't a model's.
	f.serveRepo("me/Readme-only", testSHA, map[string][]byte{"config.json": []byte(`{}`)})
	if err := hfDownload("me/Readme-only", testSHA, f.staging("me--Readme-only"), &out); err == nil || !strings.Contains(err.Error(), "no MLX safetensors") {
		t.Errorf("no weights: %v", err)
	}
	if err := hfDownload("../etc", testSHA, f.staging("etc"), &out); err == nil {
		t.Error("accepted a bad name")
	}

	// A small file is checked by its git blob ID; one of the same size but
	// other contents, kept from an earlier commit or sent wrong, is not used.
	freeBytes = func(string) (int64, error) { return 1 << 40, nil }
	f.serveRepo("me/Small-4bit", testSHA, map[string][]byte{
		"model.safetensors": []byte("weights"),
		"config.json":       []byte(`{"model_type":"qwen3_5"}`),
	})
	small := f.staging("me--Small-4bit")
	if err := os.MkdirAll(small, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(small, "config.json"), []byte(`{"model_type":"qwen3_6"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := hfDownload("me/Small-4bit", testSHA, small, &out); err != nil {
		t.Fatalf("small: %v", err)
	}
	if got, _ := os.ReadFile(filepath.Join(small, "config.json")); string(got) != `{"model_type":"qwen3_5"}` {
		t.Errorf("kept the old config.json: %s", got)
	}
	f.files["me/Small-4bit/resolve/"+testSHA+"/config.json"] = []byte(`{"model_type":"evil3_5"}`)
	if err := hfDownload("me/Small-4bit", testSHA, f.staging("me--Small-4bit-2"), &out); err == nil || !strings.Contains(err.Error(), "config.json: its contents don't match Hugging Face's, so it was deleted") {
		t.Errorf("bad small file: %v", err)
	}

	// Only a download's own folder in the staging root, whose other files
	// are deleted, is used.
	for _, dir := range []string{t.TempDir(), f.root, filepath.Join(f.root, "a", "b"), filepath.Join(f.root, "..")} {
		if err := hfDownload("me/Model-4bit", testSHA, dir, &out); err == nil || !strings.Contains(err.Error(), "isn't a download folder") {
			t.Errorf("%s: %v", dir, err)
		}
	}
}

func TestVerifyNeedsAChatTemplateAndAModelThatStarts(t *testing.T) {
	for _, tc := range []struct {
		show, generate string
		code           int
		want           string
	}{
		{`{"renderer":"qwen3.5","template":"{{ .Prompt }}"}`, `{"response":"Hi"}`, 200, ""},
		{`{"renderer":"","template":"{{ .Prompt }}"}`, `{"response":"Hi"}`, 200, "no chat template"},
		{`{"renderer":"gemma4"}`, `{"error":"mlx runner failed: panic: mlx: [dequantize] Invalid quantization mode ''."}`, 500, "it didn't start (mlx runner failed"},
	} {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			switch r.URL.Path {
			case "/api/show":
				_, _ = w.Write([]byte(tc.show))
			case "/api/generate":
				var req map[string]any
				_ = json.NewDecoder(r.Body).Decode(&req)
				if req["keep_alive"] != float64(0) || req["stream"] != false {
					t.Errorf("generate asked %v", req)
				}
				w.WriteHeader(tc.code)
				_, _ = w.Write([]byte(tc.generate))
			}
		}))
		err := verifyModel(service{base: srv.URL, client: srv.Client()}, "hf.co/me/m")
		srv.Close()
		if tc.want == "" && err != nil || tc.want != "" && (err == nil || !strings.Contains(err.Error(), tc.want)) {
			t.Errorf("show %s: %v, want %q", tc.show, err, tc.want)
		}
	}
}

func TestModelsAddedFromHuggingFaceAreCheckedThereByTheirFiles(t *testing.T) {
	f := useFakeHF(t)
	const newer = "fedcba9876543210fedcba9876543210fedcba98"
	files := map[string][]byte{"model.safetensors": []byte("weights"), "config.json": []byte(`{}`)}
	f.serveRepo("me/M-4bit", testSHA, files)
	r := hfRecord{Repo: "me/M-4bit", SHA: testSHA}
	if got := checkHFModel(r); got != "current" {
		t.Errorf("same commit: %s", got)
	}
	// A newer commit with the same files (a readme edit) is no update.
	f.serveRepo("me/M-4bit", newer, files, "README.md")
	f.serveRepo("me/M-4bit", testSHA, files)
	f.api["/api/models/me/M-4bit?blobs=true"] = f.api["/api/models/me/M-4bit/revision/"+newer+"?blobs=true"]
	if got := checkHFModel(r); got != "current" {
		t.Errorf("readme commit: %s", got)
	}
	f.serveRepo("me/M-4bit", newer, map[string][]byte{"model.safetensors": []byte("better weights"), "config.json": []byte(`{}`)})
	if got := checkHFModel(r); got != "update" {
		t.Errorf("new weights: %s", got)
	}
	if got := checkHFModel(hfRecord{Repo: "me/Gone", SHA: testSHA}); got != "unknown" {
		t.Errorf("gone: %s", got)
	}

	// The record, as the script writes it.
	path := filepath.Join(t.TempDir(), "moremole-hf-models")
	saved := hfRecordPath
	hfRecordPath = func() string { return path }
	t.Cleanup(func() { hfRecordPath = saved })
	_ = os.WriteFile(path, []byte("hf.co/me/m-4bit:latest\tme/M-4bit\t"+testSHA+"\nbroken line\n"), 0o600)
	if got := loadHFRecord(); !reflect.DeepEqual(got, map[string]hfRecord{"hf.co/me/m-4bit:latest": r}) {
		t.Errorf("record %v", got)
	}

	// The list checks those with Hugging Face and names their repo.
	tags := `{"models":[{"name":"hf.co/me/m-4bit:latest","size":7,"digest":"00"}]}`
	s := fakeService(t, tags, `{"models":[]}`)
	var asked []hfRecord
	lines := listLines(s, true, registry{}.fetch, loadHFRecord(), func(r hfRecord) string { asked = append(asked, r); return "update" })
	if len(lines) != 1 || fields(lines[0])[4] != "update" || fields(lines[0])[6] != "me/M-4bit" || len(asked) != 1 {
		t.Errorf("list %q, asked %v", lines, asked)
	}
}

func TestHFEstimatesAndNames(t *testing.T) {
	m := hfModel{}
	if m.estimatedBytes() != 0 || m.quantText() != "" {
		t.Error("an empty model has no size or quantization")
	}
	// 4 bits plus a 16-bit scale and bias per group: half a bit a weight in
	// groups of 64 (MLX's default), a quarter in groups of 128.
	for _, c := range []struct {
		quant string
		want  int64
	}{{`{"bits":4}`, 4500 + 200}, {`{"bits":4,"group_size":128}`, 4250 + 200}, {`{"bits":8,"group_size":32}`, 9000 + 200}} {
		var q hfModel
		if err := json.Unmarshal([]byte(`{"config":{"quantization":`+c.quant+`},"safetensors":{"parameters":{"U32":8000,"BF16":100}}}`), &q); err != nil {
			t.Fatal(err)
		}
		if got := q.estimatedBytes(); got != c.want {
			t.Errorf("%s: %d bytes, want %d", c.quant, got, c.want)
		}
	}
	for d, want := range map[time.Duration]string{40*time.Second + time.Millisecond: "41s", 3*time.Minute + 20*time.Second: "3m", 65 * time.Minute: "1h 5m"} {
		if got := shortDuration(d); got != want {
			t.Errorf("%v: %q, want %q", d, got, want)
		}
	}
	// After a few seconds the line gives the speed and the time left;
	// bytes already on disk count toward the total but not the speed.
	clock := time.Unix(1790000000, 0)
	saved := now
	now = func() time.Time { return clock }
	t.Cleanup(func() { now = saved })
	var out bytes.Buffer
	p := &progress{out: &out, size: 40e6, file: "model.safetensors"}
	p.skip(10e6)
	clock = clock.Add(5 * time.Second)
	p.add(10e6)
	if !strings.HasSuffix(out.String(), "downloading model.safetensors  20 MB of 40 MB  50%  2 MB/s  10s left\033[K") {
		t.Errorf("progress %q", out.String())
	}
	if got := ollamaNameFor("mlx-community/Qwen3.5-0.8B-4bit"); got != "hf.co/mlx-community/qwen3.5-0.8b-4bit" {
		t.Errorf("name %q", got)
	}
	for gated, open := range map[any]bool{nil: true, false: true, true: false, "auto": false, "manual": false} {
		if got := (hfModel{Gated: gated}).open(); got != open {
			t.Errorf("gated %v: open %v", gated, got)
		}
	}
}

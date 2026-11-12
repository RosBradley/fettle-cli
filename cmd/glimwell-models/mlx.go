package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
)

// On Apple silicon, Ollama runs a model's MLX versions on Apple's MLX
// engine. mlxIndex knows, through the cache, which library models have MLX
// versions, and which model families (Hugging Face's model_type, such as
// qwen3_5) those versions are: the families Ollama's MLX engine runs, which
// decide which MLX models from Hugging Face are worth offering.

const (
	mlxWorkers = 8
	blobMax    = 1 << 20
)

// fallbackFamilies are the families of Ollama's own MLX models on
// 2026-11-05, for when the registry can't be read and nothing is cached.
var fallbackFamilies = []string{
	"cohere2_moe", "gemma4", "laguna", "lfm3", "lfm3_audio", "lfm3_omni", "lfm3_vl",
	"muse_glimmer", "nemotron_h", "nemotron_h_omni", "qwen3_5", "qwen3_5_moe", "qwen4_exp",
}

type mlxIndex struct {
	cache    tagsCache
	fetch    func(string) (string, error) // a model's tags page
	manifest manifestFetcher
	blob     func(url string) ([]byte, error)
	changed  bool
}

func newMLXIndex() *mlxIndex {
	return &mlxIndex{cache: loadCache(), fetch: fetchTags, manifest: fetchManifest, blob: fetchBlob}
}

// refresh reads the tags pages of the models whose entry is stale. A page
// that can't be read keeps the old entry, or none.
func (x *mlxIndex) refresh(models []libraryModel) {
	var stale []libraryModel
	for _, m := range models {
		if len(m.Sizes) == 0 && m.Cloud {
			continue
		}
		if e, ok := x.cache.Models[m.Name]; !ok || !e.fresh(unixOrZero(m.Updated)) {
			stale = append(stale, m)
		}
	}
	if len(stale) == 0 {
		return
	}
	results := make([]*cacheEntry, len(stale))
	jobs := make(chan int)
	var wg sync.WaitGroup
	for range min(mlxWorkers, len(stale)) {
		wg.Go(func() {
			for i := range jobs {
				m := stale[i]
				page, err := x.fetch(m.Name)
				if err != nil {
					continue
				}
				tags := parseTags(m.Name, page)
				if len(tags) == 0 {
					continue
				}
				results[i] = &cacheEntry{Updated: unixOrZero(m.Updated), Fetched: now().Unix(), Tags: tags}
			}
		})
	}
	for i := range stale {
		jobs <- i
	}
	close(jobs)
	wg.Wait()
	for i, e := range results {
		if e != nil {
			x.cache.Models[stale[i].Name] = *e
			x.changed = true
		}
	}
}

// count is how many MLX versions a model has, or -1 when unknown.
func (x *mlxIndex) count(name string) int {
	e, ok := x.cache.Models[name]
	if !ok {
		return -1
	}
	return e.mlxCount()
}

// defaultBytes is the download size of what the model's name alone
// downloads: its default version, else its latest tag; 0 when unknown.
func (x *mlxIndex) defaultBytes(name string) int64 {
	tags := x.cache.Models[name].Tags
	for _, t := range tags {
		if t.Default {
			return t.Bytes
		}
	}
	for _, t := range tags {
		if t.Name == name+":latest" {
			return t.Bytes
		}
	}
	return 0
}

// families lists the model families of the library's MLX versions, reading
// from the registry the families not yet cached.
func (x *mlxIndex) families() map[string]bool {
	var todo []string
	for name, e := range x.cache.Models {
		if e.Family == "" && e.mlxCount() > 0 {
			todo = append(todo, name)
		}
	}
	found := make([]string, len(todo))
	jobs := make(chan int)
	var wg sync.WaitGroup
	for range min(mlxWorkers, len(todo)) {
		wg.Go(func() {
			for i := range jobs {
				found[i] = x.familyOf(todo[i])
			}
		})
	}
	for i := range todo {
		jobs <- i
	}
	close(jobs)
	wg.Wait()
	for i, family := range found {
		if family != "" {
			e := x.cache.Models[todo[i]]
			e.Family = family
			x.cache.Models[todo[i]] = e
			x.changed = true
		}
	}
	set := map[string]bool{}
	for _, e := range x.cache.Models {
		if e.Family != "" {
			set[e.Family] = true
		}
	}
	if len(set) == 0 {
		for _, f := range fallbackFamilies {
			set[f] = true
		}
	}
	return set
}

// familyOf reads the model_type of a model's first MLX version from the
// Hugging Face config.json that its registry manifest carries.
func (x *mlxIndex) familyOf(model string) string {
	var tag string
	for _, t := range x.cache.Models[model].Tags {
		if t.MLX {
			tag = t.Name
			break
		}
	}
	ref, ok := parseModelName(tag)
	if !ok {
		return ""
	}
	body, code, err := x.manifest(ref.manifestURL(), mediaManifest)
	if err != nil || code != http.StatusOK {
		return ""
	}
	var doc struct {
		Layers []struct {
			Name   string `json:"name"`
			Digest string `json:"digest"`
		} `json:"layers"`
	}
	if json.Unmarshal(body, &doc) != nil {
		return ""
	}
	for _, l := range doc.Layers {
		if l.Name != "config.json" || !strings.HasPrefix(l.Digest, "sha256:") {
			continue
		}
		data, err := x.blob(fmt.Sprintf("https://%s/v2/%s/%s/blobs/%s", ref.Host, ref.Namespace, ref.Model, l.Digest))
		if err != nil {
			return ""
		}
		var cfg struct {
			ModelType string `json:"model_type"`
		}
		if json.Unmarshal(data, &cfg) == nil && libraryName.MatchString(cfg.ModelType) {
			return cfg.ModelType
		}
		return ""
	}
	return ""
}

func (x *mlxIndex) save() {
	if x.changed {
		x.cache.save()
	}
}

// fetchBlob downloads a small file from a registry. Tests replace it.
var fetchBlob = func(url string) ([]byte, error) {
	req, err := http.NewRequest(http.MethodGet, url, nil) //nolint:gosec // G704: Ollama's own registry
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "Glimwell (model families)")
	resp, err := registryClient.Do(req) //nolint:gosec // G704: Ollama's own registry
	if err != nil {
		return nil, err
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, blobMax+1))
	if err == nil && len(data) > blobMax {
		err = errors.New("too large")
	}
	return data, err
}

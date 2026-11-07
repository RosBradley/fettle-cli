package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"time"
)

// Which models on ollama.com/library have MLX versions is only on each
// model's tags page, one page per model. The library page says when each
// model last changed, so a model's versions are read again only when it
// changed, or after a week; the first look reads every page, which takes a
// few seconds.

const (
	cacheFile    = "library-tags.json"
	cacheMaxAge  = 7 * 24 * time.Hour
	cacheNoDate  = 24 * time.Hour // for a model whose date the page left out
	cacheVersion = 2              // 2: each version's date
)

// cacheDir is where MoreMole keeps what it read. Tests replace it.
var cacheDir = func() string {
	dir, err := os.UserCacheDir()
	if err != nil || dir == "" {
		return ""
	}
	return filepath.Join(dir, "moremole", "models")
}

// cacheEntry is what one model's tags page said.
type cacheEntry struct {
	Updated int64     `json:"updated"` // the model's date on the library page
	Fetched int64     `json:"fetched"`
	Tags    []tagInfo `json:"tags"`
	// Family is the model_type of its MLX versions ("qwen3_5"), from the
	// registry; "" until read.
	Family string `json:"family,omitempty"`
}

type tagsCache struct {
	Version int                   `json:"version"`
	Models  map[string]cacheEntry `json:"models"`
}

var now = time.Now

func loadCache() tagsCache {
	c := tagsCache{Version: cacheVersion, Models: map[string]cacheEntry{}}
	dir := cacheDir()
	if dir == "" {
		return c
	}
	data, err := os.ReadFile(filepath.Join(dir, cacheFile))
	if err != nil {
		return c
	}
	var read tagsCache
	if json.Unmarshal(data, &read) != nil || read.Version != cacheVersion || read.Models == nil {
		return c
	}
	return read
}

// save writes the cache whole, through a temporary file, so a run that
// stops halfway leaves the old one.
func (c tagsCache) save() {
	dir := cacheDir()
	if dir == "" || os.MkdirAll(dir, 0o700) != nil {
		return
	}
	data, err := json.Marshal(c)
	if err != nil {
		return
	}
	tmp, err := os.CreateTemp(dir, cacheFile+".*")
	if err != nil {
		return
	}
	_, werr := tmp.Write(data)
	cerr := tmp.Close()
	if werr != nil || cerr != nil || os.Rename(tmp.Name(), filepath.Join(dir, cacheFile)) != nil {
		_ = os.Remove(tmp.Name())
	}
}

// fresh says whether a model's entry still holds for its date on the page.
func (e cacheEntry) fresh(updated int64) bool {
	age := now().Sub(time.Unix(e.Fetched, 0))
	if age < 0 || age > cacheMaxAge {
		return false
	}
	if updated == 0 {
		return age <= cacheNoDate
	}
	return e.Updated == updated
}

// recentTags gives a model's versions from the cache when they were read
// within the cache's week, so a model's screen opens without reading its
// page again; the library list reads again those whose model changed.
func (c tagsCache) recentTags(model string) []tagInfo {
	e, ok := c.Models[model]
	if !ok {
		return nil
	}
	if age := now().Sub(time.Unix(e.Fetched, 0)); age < 0 || age > cacheMaxAge {
		return nil
	}
	return e.Tags
}

func (e cacheEntry) mlxCount() int {
	n := 0
	for _, t := range e.Tags {
		if t.MLX {
			n++
		}
	}
	return n
}

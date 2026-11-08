package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

// A model's registry keeps a small manifest per name and tag that lists the
// model's files. `ollama pull` saves that manifest exactly as served, and the
// model's digest in Ollama's list is the SHA-256 of those bytes, so comparing
// the digest with the registry's current manifest shows whether the model
// changed, without downloading it.

const (
	registryTimeout = 15 * time.Second
	registryWorkers = 8
	manifestMax     = 4 << 20

	defaultRegistry = "registry.ollama.ai"
	// The media types Ollama asks for (manifest.MediaTypeManifestList and
	// manifest.MediaTypeManifest in Ollama's source). Older versions of
	// Ollama asked only for the second, and saved what that returned.
	mediaManifestList = "application/vnd.ollama.manifest.list.v2+json"
	mediaManifest     = "application/vnd.docker.distribution.manifest.v2+json"
)

// modelRef is a model name split the way Ollama splits it:
// [host/][namespace/]model[:tag], by default registry.ollama.ai/library/...:latest.
type modelRef struct {
	Host, Namespace, Model, Tag string
}

func parseModelName(name string) (modelRef, bool) {
	if name == "" || strings.ContainsAny(name, "@ ") {
		return modelRef{}, false
	}
	ref := modelRef{Host: defaultRegistry, Namespace: "library", Tag: "latest"}
	if i := strings.LastIndex(name, ":"); i > strings.LastIndex(name, "/") {
		ref.Tag, name = name[i+1:], name[:i]
	}
	parts := strings.Split(name, "/")
	switch len(parts) {
	case 1:
		ref.Model = parts[0]
	case 2:
		ref.Namespace, ref.Model = parts[0], parts[1]
	case 3:
		ref.Host, ref.Namespace, ref.Model = parts[0], parts[1], parts[2]
	default:
		return modelRef{}, false
	}
	for _, p := range []string{ref.Host, ref.Namespace, ref.Model, ref.Tag} {
		if p == "" || p == "." || p == ".." {
			return modelRef{}, false
		}
	}
	return ref, true
}

func (r modelRef) manifestURL() string {
	return fmt.Sprintf("https://%s/v2/%s/%s/manifests/%s", r.Host, r.Namespace, r.Model, r.Tag)
}

// manifestFetcher gets a manifest: its body and HTTP status. Tests replace it.
type manifestFetcher func(url, accept string) ([]byte, int, error)

var registryClient = &http.Client{Timeout: registryTimeout}

func fetchManifest(url, accept string) ([]byte, int, error) {
	// The model's own registry, the one `ollama pull` would ask.
	req, err := http.NewRequest(http.MethodGet, url, nil) //nolint:gosec // G704: see above
	if err != nil {
		return nil, 0, err
	}
	req.Header.Set("Accept", accept)
	req.Header.Set("User-Agent", "Fettle (model update check)")
	resp, err := registryClient.Do(req) //nolint:gosec // G704: the model's own registry
	if err != nil {
		return nil, 0, err
	}
	defer func() { _ = resp.Body.Close() }()
	body, err := io.ReadAll(io.LimitReader(resp.Body, manifestMax))
	return body, resp.StatusCode, err
}

func sha256Hex(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

// manifestDoc holds what Fettle reads from a manifest: a plain manifest's
// files, or a manifest list's entries.
type manifestDoc struct {
	MediaType string `json:"mediaType"`
	Config    struct {
		Size int64 `json:"size"`
	} `json:"config"`
	Layers []struct {
		Size int64 `json:"size"`
	} `json:"layers"`
	Manifests []struct {
		Digest string `json:"digest"`
		Size   int64  `json:"size"`
	} `json:"manifests"`
}

func bareDigest(d string) string { return strings.TrimPrefix(strings.TrimSpace(d), "sha256:") }

// checkModel compares an installed model with its registry. A model the
// registry does not have was made on this Mac (or removed upstream).
func checkModel(m localModel, fetch manifestFetcher) string {
	ref, ok := parseModelName(m.Name)
	digest := bareDigest(m.Digest)
	if !ok || digest == "" {
		return "unknown"
	}
	url := ref.manifestURL()
	body, code, err := fetch(url, mediaManifestList+", "+mediaManifest)
	switch {
	case err != nil:
		return "unknown"
	case code == http.StatusNotFound:
		return "local"
	case code != http.StatusOK:
		return "unknown"
	}
	if sha256Hex(body) == digest {
		return "current"
	}
	var doc manifestDoc
	if json.Unmarshal(body, &doc) == nil && doc.MediaType == mediaManifestList {
		for _, child := range doc.Manifests {
			if bareDigest(child.Digest) == digest {
				return "current"
			}
		}
	}
	// A model pulled by an older Ollama holds the plain manifest.
	if plain, code, err := fetch(url, mediaManifest); err == nil && code == http.StatusOK && sha256Hex(plain) == digest {
		return "current"
	}
	return "update"
}

// checkModels checks several models at once, keeping their order. A model
// Fettle added from Hugging Face is checked there.
func checkModels(models []localModel, fetch manifestFetcher, records map[string]hfRecord, checkHF func(hfRecord) string) []string {
	statuses := make([]string, len(models))
	jobs := make(chan int)
	var wg sync.WaitGroup
	for range registryWorkers {
		wg.Go(func() {
			for i := range jobs {
				if r, ok := records[models[i].Name]; ok && checkHF != nil {
					statuses[i] = checkHF(r)
					continue
				}
				statuses[i] = checkModel(models[i], fetch)
			}
		})
	}
	for i := range models {
		jobs <- i
	}
	close(jobs)
	wg.Wait()
	return statuses
}

var errNotFound = errors.New("not in the registry")

// downloadSize adds up a model's files from its plain manifest; for a
// manifest list it takes the largest entry. 0 means unknown.
func downloadSize(name string, fetch manifestFetcher) (int64, error) {
	ref, ok := parseModelName(name)
	if !ok {
		return 0, errors.New("not a model name")
	}
	body, code, err := fetch(ref.manifestURL(), mediaManifest)
	if err != nil {
		return 0, err
	}
	if code == http.StatusNotFound {
		return 0, errNotFound
	}
	if code != http.StatusOK {
		return 0, fmt.Errorf("HTTP %d", code)
	}
	var doc manifestDoc
	if err := json.Unmarshal(body, &doc); err != nil {
		return 0, err
	}
	size := doc.Config.Size
	for _, l := range doc.Layers {
		size += l.Size
	}
	for _, m := range doc.Manifests {
		size = max(size, m.Size)
	}
	return size, nil
}

// sizeLines prints each model's download size, or a notice for a model the
// registry does not have.
func sizeLines(names []string, fetch manifestFetcher) []string {
	var lines []string
	for _, name := range names {
		size, err := downloadSize(name, fetch)
		if errors.Is(err, errNotFound) {
			lines = append(lines, notice("not-found", name))
			continue
		}
		lines = append(lines, row("size", name, strconv.FormatInt(size, 10)))
	}
	return lines
}

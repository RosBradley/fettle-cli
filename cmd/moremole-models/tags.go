package main

import (
	"fmt"
	"html"
	"io"
	"math"
	"net/http"
	"net/url"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"
)

// Each model's tags page, ollama.com/library/<model>/tags, lists every
// version of it: its size, context window, what it reads (text, images) and
// a badge on the MLX versions, which run on Apple's MLX engine on Apple
// silicon. The library page has none of this, so Download reads the tags
// pages of only the models picked from it.

const (
	tagsURL     = "https://ollama.com/library/%s/tags"
	tagsWorkers = 4
)

// tagInfo is one version on a tags page.
type tagInfo struct {
	Name     string // model:tag
	SizeText string // as the page shows it: "4.9GB", or "6.6GB - 7.6GB"
	Bytes    int64  // the smaller size, 0 when unknown
	Context  string // "128K"
	Input    string // "Text, Image"
	MLX      bool
	Default  bool // what "model" alone (model:latest) downloads
}

var (
	tagBlock = regexp.MustCompile(`<div class="group px-4 py-3">`)
	tagHref  = regexp.MustCompile(`href="/library/([A-Za-z0-9][A-Za-z0-9._-]*):([A-Za-z0-9][A-Za-z0-9._-]*)"`)
	tagBadge = regexp.MustCompile(`rounded-full[^"]*"[^>]*>\s*([^<]+?)\s*<`)
	tagCell  = regexp.MustCompile(`(?s)class="col-span-2[^"]*"[^>]*>(.*?)</(?:p|div)>`)
	tagSize  = regexp.MustCompile(`^(\d+(?:\.\d+)?)\s*([KMGT]?B)\b`)
)

// appleSilicon says whether MLX versions can run here. The helper is built
// for the Mac it runs on, so its architecture is the Mac's.
var appleSilicon = runtime.GOARCH == "arm64"

func parseTags(model, page string) []tagInfo {
	var tags []tagInfo
	seen := map[string]bool{}
	for _, block := range tagBlock.Split(page, -1)[1:] {
		m := tagHref.FindStringSubmatch(block)
		if m == nil || m[1] != model || seen[m[2]] {
			continue
		}
		tag := m[2]
		cells := tagCell.FindAllStringSubmatch(block, -1)
		if len(cells) < 3 || strings.Contains(tag, "cloud") {
			continue // versions that run only on Ollama's servers have no size
		}
		size := cellText(cells[0][1])
		bytes, ok := sizeBytes(size)
		if !ok {
			continue
		}
		seen[tag] = true
		info := tagInfo{Name: model + ":" + tag, SizeText: strings.ReplaceAll(size, " ", ""), Bytes: bytes, Context: cellText(cells[1][1]), Input: cellText(cells[2][1])}
		for _, b := range tagBadge.FindAllStringSubmatch(block, -1) {
			switch strings.ToLower(b[1]) {
			case "mlx":
				info.MLX = true
			case "latest":
				info.Default = tag != "latest"
			}
		}
		tags = append(tags, info)
	}
	// "latest" repeats the version marked as the default; keep it only when
	// it is all there is.
	if len(tags) > 1 {
		kept := tags[:0]
		for _, t := range tags {
			if !strings.HasSuffix(t.Name, ":latest") {
				kept = append(kept, t)
			}
		}
		tags = kept
	}
	return tags
}

func flag(b bool) string {
	if b {
		return "1"
	}
	return "0"
}

func cellText(s string) string {
	return strings.Join(strings.Fields(html.UnescapeString(stripTags(s))), " ")
}

// sizeBytes reads the first size of "4.9GB" or "6.6GB - 7.6GB"; Ollama's
// units are decimal.
func sizeBytes(text string) (int64, bool) {
	m := tagSize.FindStringSubmatch(strings.TrimSpace(text))
	if m == nil {
		return 0, false
	}
	n, err := strconv.ParseFloat(m[1], 64)
	if err != nil {
		return 0, false
	}
	scale := map[string]float64{"B": 1, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12}[m[2]]
	return int64(math.Round(n * scale)), true
}

// fetchTags downloads a model's tags page. Tests replace it.
var fetchTags = func(model string) (string, error) {
	client := &http.Client{Timeout: libraryTimeout}
	req, err := http.NewRequest(http.MethodGet, fmt.Sprintf(tagsURL, url.PathEscape(model)), nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("User-Agent", "MoreMole (model versions)")
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, libraryMax))
	return string(body), err
}

// tagsLines lists the versions of each model, in the order the models were
// given and each page lists them. MLX versions are left out on an Intel Mac,
// which can't run them. A page that can't be read gives a notice instead.
// cached gives a model's versions as the cache last read them, nil when it
// has none recent enough; then the page is read.
func tagsLines(models []string, fetch func(string) (string, error), s service, mlxOK bool, cached func(string) []tagInfo) []string {
	results := make([][]string, len(models))
	jobs := make(chan int)
	var wg sync.WaitGroup
	installed := map[string]bool{}
	if local, err := s.models(); err == nil {
		for _, m := range local {
			installed[m.Name] = true
		}
	}
	for range min(tagsWorkers, len(models)) {
		wg.Go(func() {
			for i := range jobs {
				results[i] = modelTagLines(models[i], fetch, installed, mlxOK, cached)
			}
		})
	}
	for i := range models {
		jobs <- i
	}
	close(jobs)
	wg.Wait()
	var lines []string
	for _, r := range results {
		lines = append(lines, r...)
	}
	return lines
}

func modelTagLines(model string, fetch func(string) (string, error), installed map[string]bool, mlxOK bool, cached func(string) []tagInfo) []string {
	if !libraryName.MatchString(model) {
		return []string{notice("tags-failed", model)}
	}
	var tags []tagInfo
	if cached != nil {
		tags = cached(model)
	}
	if len(tags) == 0 {
		if page, err := fetch(model); err == nil {
			tags = parseTags(model, page)
		}
	}
	if len(tags) == 0 {
		return []string{notice("tags-failed", model)}
	}
	var lines []string
	for _, t := range tags {
		if t.MLX && !mlxOK {
			continue
		}
		isInstalled := "0"
		if installed[t.Name] || (t.Default && installed[model+":latest"]) {
			isInstalled = "1"
		}
		lines = append(lines, row("tag", t.Name, strconv.FormatInt(t.Bytes, 10), t.SizeText, t.Context, t.Input, flag(t.MLX), flag(t.Default), isInstalled))
	}
	return lines
}

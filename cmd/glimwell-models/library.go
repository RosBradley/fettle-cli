package main

import (
	"errors"
	"fmt"
	"html"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Ollama publishes no list of its models for programs to read; the list is
// the web page ollama.com/library, most pulled first. This reads that page,
// so a redesign of it can break the list: the script then asks for a name.

const (
	libraryURL     = "https://ollama.com/library"
	libraryTimeout = 30 * time.Second
	libraryMax     = 16 << 20
)

// libraryModel is one entry of the library page.
type libraryModel struct {
	Name         string
	Description  string
	Capabilities []string // tools, thinking, vision, embedding, ...
	Sizes        []string // the size tags: 8b, 70b, ...
	Cloud        bool     // also, or only, runs on Ollama's servers
	Pulls        string   // as the page shows it: "120.6M"
	Updated      time.Time
}

var (
	libraryEntry   = regexp.MustCompile(`(?s)<li[^>]*>\s*<a href="/library/([^"/?#]+)"(.*?)</li>`)
	libraryDesc    = regexp.MustCompile(`(?s)<p class="max-w-lg[^"]*"[^>]*>(.*?)</p>`)
	libraryCap     = regexp.MustCompile(`text-indigo-600[^"]*"[^>]*>([^<]+)<`)
	librarySize    = regexp.MustCompile(`text-blue-600[^"]*"[^>]*>([^<]+)<`)
	libraryCloud   = regexp.MustCompile(`bg-cyan-50[^"]*"[^>]*>\s*cloud\s*<`)
	libraryPulls   = regexp.MustCompile(`(?s)<span\s*>([^<]+)</span>\s*<span[^>]*>&nbsp;Pulls</span>`)
	libraryUpdated = regexp.MustCompile(`title="([A-Z][a-z]{2} \d{1,2}, \d{4} \d{1,2}:\d{2} [AP]M UTC)"`)
	libraryName    = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]*$`)
)

func parseLibrary(page string) []libraryModel {
	var models []libraryModel
	for _, m := range libraryEntry.FindAllStringSubmatch(page, -1) {
		name, body := m[1], m[2]
		if !libraryName.MatchString(name) {
			continue
		}
		model := libraryModel{Name: name, Cloud: libraryCloud.MatchString(body)}
		if d := libraryDesc.FindStringSubmatch(body); d != nil {
			model.Description = strings.Join(strings.Fields(html.UnescapeString(stripTags(d[1]))), " ")
		}
		for _, c := range libraryCap.FindAllStringSubmatch(body, -1) {
			model.Capabilities = append(model.Capabilities, strings.TrimSpace(html.UnescapeString(c[1])))
		}
		for _, s := range librarySize.FindAllStringSubmatch(body, -1) {
			if size := strings.TrimSpace(html.UnescapeString(s[1])); libraryName.MatchString(size) {
				model.Sizes = append(model.Sizes, size)
			}
		}
		if p := libraryPulls.FindStringSubmatch(body); p != nil {
			model.Pulls = strings.TrimSpace(html.UnescapeString(p[1]))
		}
		if u := libraryUpdated.FindStringSubmatch(body); u != nil {
			if t, err := time.Parse("Jan 2, 2006 3:04 PM MST", u[1]); err == nil {
				model.Updated = t
			}
		}
		models = append(models, model)
	}
	return models
}

var tags = regexp.MustCompile(`<[^>]*>`)

func stripTags(s string) string { return tags.ReplaceAllString(s, "") }

// fetchLibrary downloads the library page. Tests replace it.
var fetchLibrary = func() (string, error) {
	client := &http.Client{Timeout: libraryTimeout}
	req, err := http.NewRequest(http.MethodGet, libraryURL, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("User-Agent", "Glimwell (model list)")
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

var errEmptyLibrary = errors.New("no models found on the page")

func unixOrZero(t time.Time) int64 {
	if t.IsZero() {
		return 0
	}
	return t.Unix()
}

// readLibrary reads and parses the library page.
func readLibrary(fetch func() (string, error)) ([]libraryModel, error) {
	page, err := fetch()
	if err != nil {
		return nil, err
	}
	models := parseLibrary(page)
	if len(models) == 0 {
		return nil, errEmptyLibrary
	}
	return models, nil
}

func libraryFailed(err error) string {
	return notice("library-failed", "Couldn't read Ollama's model list at ollama.com/library ("+err.Error()+").")
}

// libraryLines lists one row per model that can be downloaded, with the
// size tags it comes in (8b,70b), or none for a model with only "latest".
// Models that only run on Ollama's servers are left out. A model is marked
// installed when any of its versions is. The index reads each model's tags
// page into the cache, which gives each row the download size of the
// version the model's name alone downloads (0 when unknown) and, with
// showMLX (Apple silicon), how many MLX versions the model has; that is
// empty when its tags page couldn't be read, and on an Intel Mac.
func libraryLines(fetch func() (string, error), s service, mlx *mlxIndex, showMLX bool) []string {
	models, err := readLibrary(fetch)
	if err != nil {
		return []string{libraryFailed(err)}
	}
	if mlx != nil {
		mlx.refresh(models)
		mlx.save()
	}
	installed := map[string]bool{}
	if local, err := s.models(); err == nil {
		for _, m := range local {
			name, _, _ := strings.Cut(m.Name, ":")
			installed[name] = true
		}
	}
	var lines []string
	for _, m := range models {
		if len(m.Sizes) == 0 && m.Cloud {
			continue
		}
		updated := ""
		if !m.Updated.IsZero() {
			updated = strconv.FormatInt(m.Updated.Unix(), 10)
		}
		isInstalled := "0"
		if installed[m.Name] {
			isInstalled = "1"
		}
		mlxVersions, bytes := "", int64(0)
		if mlx != nil {
			if n := mlx.count(m.Name); n >= 0 && showMLX {
				mlxVersions = strconv.Itoa(n)
			}
			bytes = mlx.defaultBytes(m.Name)
		}
		lines = append(lines, row("model", m.Name, strings.Join(m.Capabilities, ","), m.Pulls, updated, isInstalled, strings.Join(m.Sizes, ","), mlxVersions, strconv.FormatInt(bytes, 10), m.Description))
	}
	return lines
}

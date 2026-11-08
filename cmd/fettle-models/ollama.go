package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Ollama runs a local service (the Ollama app starts it, or `ollama serve`)
// that lists and loads models; `ollama pull` and `ollama rm` talk to it too.

const serviceTimeout = 5 * time.Second

// ollamaInstall is where Ollama is on this Mac: the app, the command, or both.
type ollamaInstall struct {
	App string // "/Applications/Ollama.app", or ""
	CLI string // the ollama command, or ""
}

// appDirs and cliDirs are where Ollama installs. Tests replace them.
var (
	appDirs = func() []string {
		dirs := []string{"/Applications"}
		if home, err := os.UserHomeDir(); err == nil {
			dirs = append(dirs, filepath.Join(home, "Applications"))
		}
		return dirs
	}
	cliDirs = []string{"/usr/local/bin", "/opt/homebrew/bin"}
)

func findOllama() ollamaInstall {
	var in ollamaInstall
	for _, dir := range appDirs() {
		app := filepath.Join(dir, "Ollama.app")
		if info, err := os.Stat(app); err == nil && info.IsDir() {
			in.App = app
			break
		}
	}
	if path, err := exec.LookPath("ollama"); err == nil {
		in.CLI = path
	} else {
		for _, dir := range cliDirs {
			if isExecutable(filepath.Join(dir, "ollama")) {
				in.CLI = filepath.Join(dir, "ollama")
				break
			}
		}
	}
	// The app carries the command inside it.
	if in.CLI == "" && in.App != "" && isExecutable(filepath.Join(in.App, "Contents", "Resources", "ollama")) {
		in.CLI = filepath.Join(in.App, "Contents", "Resources", "ollama")
	}
	return in
}

func isExecutable(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir() && info.Mode()&0o111 != 0
}

// memoryBytes is the Mac's memory, or 0 when unknown. Tests replace it.
var memoryBytes = func() int64 {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "/usr/sbin/sysctl", "-n", "hw.memsize").Output()
	if err != nil {
		return 0
	}
	n, _ := strconv.ParseInt(strings.TrimSpace(string(out)), 10, 64)
	return n
}

func statusLines(in ollamaInstall, running bool, memory int64) []string {
	yes := func(b bool) string {
		if b {
			return "1"
		}
		return "0"
	}
	return []string{
		"app=" + in.App,
		"cli=" + in.CLI,
		"running=" + yes(running),
		"memory=" + strconv.FormatInt(memory, 10),
	}
}

// service talks to Ollama's local service.
type service struct {
	base   string
	client *http.Client
}

// newService finds the service where `ollama` would: OLLAMA_HOST, else
// 127.0.0.1:11434.
func newService() service {
	return service{base: serviceURL(os.Getenv("OLLAMA_HOST")), client: &http.Client{Timeout: serviceTimeout}}
}

func serviceURL(host string) string {
	host = strings.TrimSpace(host)
	if host == "" {
		return "http://127.0.0.1:11434"
	}
	if !strings.Contains(host, "://") {
		host = "http://" + host
	}
	u, err := url.Parse(host)
	if err != nil || u.Host == "" {
		return "http://127.0.0.1:11434"
	}
	hostname, port := u.Hostname(), u.Port()
	if hostname == "" || hostname == "0.0.0.0" {
		hostname = "127.0.0.1"
	}
	if port == "" {
		port = "11434"
	}
	return u.Scheme + "://" + net.JoinHostPort(hostname, port)
}

func (s service) get(path string, v any) error {
	resp, err := s.client.Get(s.base + path)
	if err != nil {
		return err
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	return json.NewDecoder(resp.Body).Decode(v)
}

// post sends a request with its own time limit, for a model that takes
// minutes to load.
func (s service) post(path string, body, v any, timeout time.Duration) error {
	data, err := json.Marshal(body)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, s.base+path, bytes.NewReader(data))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	client := *s.client
	client.Timeout = 0
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		var e struct {
			Error string `json:"error"`
		}
		if json.NewDecoder(io.LimitReader(resp.Body, 1<<16)).Decode(&e) == nil && e.Error != "" {
			return errors.New(e.Error)
		}
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	return json.NewDecoder(resp.Body).Decode(v)
}

func (s service) running() bool {
	var v struct {
		Version string `json:"version"`
	}
	return s.get("/api/version", &v) == nil
}

// localModel is one installed model, from /api/tags.
type localModel struct {
	Name     string    `json:"name"`
	Size     int64     `json:"size"`
	Digest   string    `json:"digest"`
	Modified time.Time `json:"modified_at"`
	Details  struct {
		Format string `json:"format"` // gguf, or safetensors for MLX
		Runner string `json:"runner"` // ggml, or mlx: the engine that runs it
	} `json:"details"`
}

// mlx says whether the model runs on Ollama's MLX engine (Apple silicon),
// as Ollama reports it; Ollamas that predate the runner field leave it
// out, and then MLX models are the ones stored as safetensors.
func (m localModel) mlx() bool {
	if m.Details.Runner != "" {
		return m.Details.Runner == "mlx"
	}
	return m.Details.Format == "safetensors"
}

func (s service) models() ([]localModel, error) {
	var v struct {
		Models []localModel `json:"models"`
	}
	if err := s.get("/api/tags", &v); err != nil {
		return nil, err
	}
	sort.Slice(v.Models, func(i, j int) bool { return strings.ToLower(v.Models[i].Name) < strings.ToLower(v.Models[j].Name) })
	return v.Models, nil
}

// loaded lists the models in memory now, from /api/ps.
func (s service) loaded() map[string]bool {
	var v struct {
		Models []struct {
			Name string `json:"name"`
		} `json:"models"`
	}
	names := map[string]bool{}
	if s.get("/api/ps", &v) == nil {
		for _, m := range v.Models {
			names[m.Name] = true
		}
	}
	return names
}

// listLines lists the installed models; with check, it asks the registry
// whether each has changed, or Hugging Face for a model Fettle added from
// there, whose row ends with its Hugging Face name.
func listLines(s service, check bool, fetch manifestFetcher, records map[string]hfRecord, checkHF func(hfRecord) string) []string {
	models, err := s.models()
	if err != nil {
		return []string{notice("service-failed", "Couldn't get the model list from Ollama ("+err.Error()+").")}
	}
	loaded := s.loaded()
	statuses := make([]string, len(models))
	if check {
		statuses = checkModels(models, fetch, records, checkHF)
	}
	lines := make([]string, 0, len(models))
	for i, m := range models {
		isLoaded := "0"
		if loaded[m.Name] {
			isLoaded = "1"
		}
		modified := ""
		if !m.Modified.IsZero() {
			modified = strconv.FormatInt(m.Modified.Unix(), 10)
		}
		lines = append(lines, row("model", m.Name, strconv.FormatInt(m.Size, 10), modified, statuses[i], isLoaded, records[m.Name].Repo, flag(m.mlx())))
	}
	return lines
}

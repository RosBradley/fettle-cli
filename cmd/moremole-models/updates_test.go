package main

import (
	"encoding/json"
	"net/http"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestUpdatesLinesListOnlyModelsWithAnUpdate(t *testing.T) {
	const plain = `{"layers":[{"size":1}]}`
	tags, _ := json.Marshal(map[string]any{"models": []map[string]any{
		{"name": "qwen3:4b", "digest": sha256Hex([]byte(plain))},
		{"name": "llama3.2:latest", "digest": "00"},
		{"name": "my-assistant:latest", "digest": "11"},
		{"name": "hf.co/mlx-community/gemma:latest", "digest": "22"},
		{"name": "offline:latest", "digest": "33"},
	}})
	s := fakeService(t, string(tags), `{"models":[]}`)
	reg := registry{
		"https://registry.ollama.ai/v2/library/qwen3/manifests/4b":        plain,
		"https://registry.ollama.ai/v2/library/llama3.2/manifests/latest": `{"layers":[{"size":2}]}`,
	}
	fetch := func(url, accept string) ([]byte, int, error) {
		if strings.Contains(url, "/offline/") {
			return nil, 0, os.ErrDeadlineExceeded
		}
		return reg.fetch(url, accept)
	}
	records := map[string]hfRecord{"hf.co/mlx-community/gemma:latest": {Repo: "mlx-community/gemma"}}
	checkHF := func(hfRecord) string { return "update" }
	in := ollamaInstall{CLI: "/usr/local/bin/ollama"}

	got := updatesLines(in, s, fetch, records, checkHF)
	want := []string{
		row("model-hf", "hf.co/mlx-community/gemma:latest", "hf.co/mlx-community/gemma:latest", "", "", "newer files on Hugging Face", ""),
		row("model", "llama3.2:latest", "llama3.2:latest", "", "", "newer download on Ollama", ""),
		updatesNotice("models-unchecked", "Couldn't check 1 of 5 Ollama models for updates. Check the internet connection, then try again."),
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %q\nwant %q", got, want)
	}

	// No Ollama: nothing at all, not even a notice.
	if got := updatesLines(ollamaInstall{}, s, fetch, records, checkHF); got != nil {
		t.Errorf("no Ollama: %q", got)
	}
	// Ollama off: one notice, in the updates helper's shape (text in field 6),
	// and nothing asked of the registry.
	off := service{base: "http://127.0.0.1:1", client: &http.Client{Timeout: time.Second}}
	never := func(string, string) ([]byte, int, error) {
		t.Fatal("asked the registry with Ollama off")
		return nil, 0, nil
	}
	got = updatesLines(in, off, never, records, checkHF)
	if len(got) != 1 || fields(got[0])[0] != "notice" || fields(got[0])[1] != "ollama-off" || !strings.HasPrefix(fields(got[0])[5], "Ollama is off") {
		t.Errorf("Ollama off: %q", got)
	}
}

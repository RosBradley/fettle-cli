package main

import (
	"errors"
	"reflect"
	"strings"
	"testing"
)

func TestModelNamesSplitIntoFamilyGenerationAndKind(t *testing.T) {
	for name, want := range map[string]modelGen{
		"qwen2.5-coder":   {prefix: "qwen", version: []int{2, 5}, suffix: "-coder"},
		"qwen3":           {prefix: "qwen", version: []int{3}},
		"llama3.2-vision": {prefix: "llama", version: []int{3, 2}, suffix: "-vision"},
		"deepseek-r1":     {prefix: "deepseek-r", version: []int{1}},
	} {
		got, ok := parseGen(name)
		if !ok || !reflect.DeepEqual(got, want) {
			t.Errorf("%s: %+v, want %+v", name, got, want)
		}
	}
	for _, name := range []string{"mistral", "gpt-oss", "nomic-embed-text"} {
		if _, ok := parseGen(name); ok {
			t.Errorf("%s has no generation", name)
		}
	}
	a, _ := parseGen("qwen3.5")
	b, _ := parseGen("qwen3.10")
	c, _ := parseGen("qwen3")
	if !b.newerThan(a) || !a.newerThan(c) || c.newerThan(a) {
		t.Error("generations compare wrong")
	}
	coder, _ := parseGen("qwen3-coder")
	if coder.sameLine(c) {
		t.Error("qwen3-coder is not a qwen3")
	}
}

func TestTagParameters(t *testing.T) {
	for tag, want := range map[string]int64{
		"8b-instruct-q4_K_M": 8000, "35b-a3b-coding-mxfp8": 35000, "270m": 270,
		"e4b-mlx-bf16": 4000, "8x7b": 56000, "1.5b": 1500, "latest": 0, "mlx": 0,
	} {
		if got := tagParams(tag); got != want {
			t.Errorf("%s: %d, want %d", tag, got, want)
		}
	}
}

func betterIndex(tags map[string][]tagInfo) *mlxIndex {
	x := &mlxIndex{cache: tagsCache{Models: map[string]cacheEntry{}}}
	for name, ts := range tags {
		x.cache.Models[name] = cacheEntry{Tags: ts}
	}
	return x
}

func TestBetterVersionsAreMLXTwinsAndNewerGenerationsOfAboutTheSize(t *testing.T) {
	const gb = 1000000000
	x := betterIndex(map[string][]tagInfo{
		"qwen3.5": {
			{Name: "qwen3.5:9b", Bytes: 6 * gb, Default: true},
			{Name: "qwen3.5:9b-mlx-bf16", Bytes: 18 * gb, MLX: true},
			{Name: "qwen3.5:9b-mlx", Bytes: 6 * gb, MLX: true},
			{Name: "qwen3.5:27b", Bytes: 17 * gb},
		},
		"qwen3.8": {
			{Name: "qwen3.8:27b", Bytes: 17 * gb},
			{Name: "qwen3.8:27b-mlx", Bytes: 18 * gb, MLX: true},
			{Name: "qwen3.8:122b", Bytes: 80 * gb},
		},
		"qwen3.6":  {{Name: "qwen3.6:9b", Bytes: 6 * gb}},
		"llama3.2": {{Name: "llama3.2:3b", Bytes: 2 * gb, Default: true}},
		"llama3.3": {{Name: "llama3.3:70b", Bytes: 43 * gb}},
	})
	library := []libraryModel{{Name: "qwen3.5"}, {Name: "qwen3.6"}, {Name: "qwen3.8"}, {Name: "llama3.2"}, {Name: "llama3.3"}}

	// The MLX twin of qwen3.5:latest (9b) is its plain -mlx, not bf16.
	if tw, ok := mlxTwin(x.cache.Models["qwen3.5"].Tags, 9000); !ok || tw.Name != "qwen3.5:9b-mlx" {
		t.Errorf("twin %+v", tw)
	}
	// 27b: qwen3.8 is the newest with about that size, its MLX version.
	if nt, fam, ok := newerGeneration("qwen3.5", 27000, library, x, 128*gb, true, false); !ok || fam != "qwen3.8" || nt.Name != "qwen3.8:27b-mlx" {
		t.Errorf("newer for 27b: %s %+v", fam, nt)
	}
	// 9b: qwen3.8 has no version near 9b, so qwen3.6:9b.
	if nt, fam, ok := newerGeneration("qwen3.5", 9000, library, x, 128*gb, true, false); !ok || fam != "qwen3.6" || nt.Name != "qwen3.6:9b" {
		t.Errorf("newer for 9b: %s %+v", fam, nt)
	}
	// llama3.3 comes only in 70b: no replacement for a 3b.
	if nt, _, ok := newerGeneration("llama3.2", 3000, library, x, 128*gb, true, false); ok {
		t.Errorf("llama3.2:3b got %+v", nt)
	}
	// A version too big for the memory isn't offered: 18GB on 16GB.
	if nt, fam, ok := newerGeneration("qwen3.5", 27000, library, x, 16*gb, true, false); ok && fam == "qwen3.8" {
		t.Errorf("too big offered: %+v", nt)
	}
	// From Hugging Face, only MLX: qwen3.6 has none at 9b.
	if nt, _, ok := newerGeneration("qwen3.5", 9000, library, x, 128*gb, true, true); ok {
		t.Errorf("non-MLX offered for a Hugging Face model: %+v", nt)
	}

	// The whole list, with installed models from Ollama.
	s := fakeService(t, `{"models":[
		{"name":"qwen3.5:latest","details":{"format":"gguf","runner":"ggml"}},
		{"name":"qwen3.5:27b-mlx","details":{"format":"safetensors","runner":"mlx"}},
		{"name":"llama3.2:3b","details":{"format":"gguf","runner":"ggml"}},
		{"name":"hf.co/me/qwen3.5-9b-4bit:latest","details":{"format":"safetensors","runner":"mlx"}}
	]}`, `{"models":[]}`)
	useCacheDir(t)
	x.fetch = func(string) (string, error) { return "", errors.New("offline") }
	lib := func() ([]libraryModel, error) { return library, nil }
	records := map[string]hfRecord{"hf.co/me/qwen3.5-9b-4bit:latest": {Repo: "me/Qwen3.5-9B-4bit"}}
	got := betterLines(s, lib, x, records, 128*gb, true)
	var rows []string
	for _, l := range got {
		f := fields(l)
		rows = append(rows, strings.Join(f[1:5], " "))
	}
	// A-Z by installed model; the Hugging Face one's only newer
	// generation, qwen3.6, has no MLX version, and llama3.2 none at all.
	want := []string{
		"qwen3.5:27b-mlx qwen3.8:27b-mlx newer 18000000000",
		"qwen3.5:latest qwen3.5:9b-mlx mlx 6000000000",
		"qwen3.5:latest qwen3.6:9b newer 6000000000",
	}
	if !reflect.DeepEqual(rows, want) {
		t.Errorf("rows %q\nwant %q", rows, want)
	}
}

func TestHuggingFaceNamesFindTheirLibraryModel(t *testing.T) {
	library := []libraryModel{{Name: "qwen3"}, {Name: "qwen3.5"}, {Name: "gemma4"}}
	for repo, want := range map[string]struct {
		name   string
		params int64
	}{
		"mlx-community/Qwen3.5-9B-4bit":     {"qwen3.5", 9000},
		"lmstudio-community/gemma-4-E4B-it": {"gemma4", 4000},
		"someone/Llama-3.2-3B":              {"", 0},
	} {
		name, params := hfLibraryName(repo, library)
		if name != want.name || params != want.params {
			t.Errorf("%s: %s %d, want %+v", repo, name, params, want)
		}
	}
}

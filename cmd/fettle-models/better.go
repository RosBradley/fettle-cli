package main

import (
	"regexp"
	"slices"
	"strconv"
	"strings"
)

// Better versions of the installed models, for this Mac, for Ollama model
// updates to offer as replacements:
//
//   - mlx: the same model, at the same size, built for Apple's MLX engine,
//     for a model that runs on Ollama's standard engine (Apple silicon).
//   - newer: a newer generation of the same model, by its name (qwen3.5 to
//     qwen3.8, qwen2.5-coder to qwen3-coder), in a version of about the same
//     size (half to twice the parameters) that fits this Mac's memory, its
//     MLX version first on Apple silicon. A generation that only comes in
//     other sizes (llama3.3 is 70b only) is no replacement for a 3b.
//
// Models Fettle added from Hugging Face get the second, named by their
// Hugging Face name (Qwen3.5-9B-4bit is qwen3.5 at 9b), and only in MLX.
//
//	better  installed  suggested  kind  bytes  mlx  note

// modelGen is a model's name as family, generation and kind: qwen2.5-coder
// is "qwen", 2.5 and "-coder".
type modelGen struct {
	prefix, suffix string
	version        []int
}

var genName = regexp.MustCompile(`^([a-z][a-z-]*?)(\d+(?:\.\d+)*)(-[a-z0-9.-]+)?$`)

func parseGen(name string) (modelGen, bool) {
	m := genName.FindStringSubmatch(strings.ToLower(name))
	if m == nil {
		return modelGen{}, false
	}
	g := modelGen{prefix: m[1], suffix: m[3]}
	for part := range strings.SplitSeq(m[2], ".") {
		n, err := strconv.Atoi(part)
		if err != nil {
			return modelGen{}, false
		}
		g.version = append(g.version, n)
	}
	return g, true
}

// sameLine says whether two names are generations of one model.
func (g modelGen) sameLine(o modelGen) bool { return g.prefix == o.prefix && g.suffix == o.suffix }

// newerThan compares generations part by part: 3.5 is newer than 3, 3.10
// newer than 3.9.
func (g modelGen) newerThan(o modelGen) bool { return slices.Compare(g.version, o.version) > 0 }

// hfJoin joins a name's first word to its generation: gemma-4 is gemma4.
var hfJoin = regexp.MustCompile(`^([a-z]+)-(\d)`)

var paramWord = regexp.MustCompile(`^(?:(\d+)x)?e?(\d+(?:\.\d+)?)([bm])$`)

// tagParams is a tag's parameters in millions ("8b-instruct-q4_K_M" is
// 8000, "8x7b" 56000, "270m" 270), 0 when the tag doesn't say.
func tagParams(tag string) int64 {
	for word := range strings.SplitSeq(strings.ToLower(tag), "-") {
		m := paramWord.FindStringSubmatch(word)
		if m == nil {
			continue
		}
		n, err := strconv.ParseFloat(m[2], 64)
		if err != nil {
			return 0
		}
		if m[3] == "b" {
			n *= 1000
		}
		if m[1] != "" {
			k, _ := strconv.ParseFloat(m[1], 64)
			n *= k
		}
		return int64(n)
	}
	return 0
}

// hfLibraryName finds the library model a Hugging Face model is a version
// of, by name: Qwen3.5-9B-4bit is qwen3.5, gemma-4-E4B-it is gemma4; and
// its parameters. The longest library name that starts it wins.
func hfLibraryName(repo string, library []libraryModel) (string, int64) {
	base := strings.ToLower(repo[strings.Index(repo, "/")+1:])
	// "gemma-4" is gemma4 in the library.
	joined := hfJoin.ReplaceAllString(base, "$1$2")
	best := ""
	for _, m := range library {
		if (strings.HasPrefix(joined, m.Name+"-") || joined == m.Name) && len(m.Name) > len(best) {
			best = m.Name
		}
	}
	if best == "" {
		return "", 0
	}
	return best, tagParams(strings.TrimPrefix(joined, best+"-"))
}

// betterLines lists the better versions of the installed models.
func betterLines(s service, readLib func() ([]libraryModel, error), x *mlxIndex, records map[string]hfRecord, memory int64, mlxOK bool) []string {
	installed, err := s.models()
	if err != nil {
		return []string{notice("service-failed", "Couldn't get the model list from Ollama ("+err.Error()+").")}
	}
	library, err := readLib()
	if err != nil {
		return []string{libraryFailed(err)}
	}
	x.refresh(library)
	x.save()
	// What is installed, and each library model's installed sizes: a newer
	// generation already installed at about the size is no suggestion.
	have := map[string]bool{}
	haveSizes := map[string][]int64{}
	for _, m := range installed {
		have[m.Name] = true
		name, tag, _ := strings.Cut(m.Name, ":")
		if p := tagParams(tag); p > 0 {
			haveSizes[name] = append(haveSizes[name], p)
		}
	}
	var lines []string
	for _, m := range installed {
		name, tag, _ := strings.Cut(m.Name, ":")
		fromHF := false
		var params int64
		if r, ok := records[m.Name]; ok {
			fromHF = true
			name, params = hfLibraryName(r.Repo, library)
			if name == "" || params == 0 {
				continue
			}
		} else {
			if strings.Contains(name, "/") {
				continue // another registry's or a namespace's model
			}
			tags := x.cache.Models[name].Tags
			if tag == "" || tag == "latest" {
				for _, t := range tags {
					if t.Default {
						_, tag, _ = strings.Cut(t.Name, ":")
					}
				}
			}
			params = tagParams(tag)
			if params == 0 {
				continue
			}
			// The same model and size, on MLX.
			if mlxOK && !m.mlx() {
				if t, ok := mlxTwin(tags, params); ok && !have[t.Name] {
					lines = append(lines, row("better", m.Name, t.Name, "mlx", strconv.FormatInt(t.Bytes, 10), "1", "the same model, built for Apple silicon"))
				}
			}
		}
		// A newer generation.
		if t, family, ok := newerGeneration(name, params, library, x, memory, mlxOK, fromHF); ok && !have[t.Name] && !hasNear(haveSizes[family], params) {
			lines = append(lines, row("better", m.Name, t.Name, "newer", strconv.FormatInt(t.Bytes, 10), flag(t.MLX), "a newer generation: "+family))
		}
	}
	return lines
}

// hasNear says whether any of these sizes is about params: half to twice.
func hasNear(sizes []int64, params int64) bool {
	for _, p := range sizes {
		if p*2 >= params && p <= params*2 {
			return true
		}
	}
	return false
}

// mlxTwin is the MLX version of a model at these parameters: its plain
// "-mlx" version when there is one, else the smallest.
func mlxTwin(tags []tagInfo, params int64) (tagInfo, bool) {
	var best tagInfo
	found := false
	for _, t := range tags {
		_, tag, _ := strings.Cut(t.Name, ":")
		if !t.MLX || tagParams(tag) != params {
			continue
		}
		plain := strings.HasSuffix(tag, "-mlx")
		if !found || plain && !strings.HasSuffix(best.Name, "-mlx") || (plain == strings.HasSuffix(best.Name, "-mlx") && t.Bytes < best.Bytes) {
			best, found = t, true
		}
	}
	return best, found
}

// newerGeneration finds the newest generation of model name with a version
// of about these parameters that fits this Mac's memory: its MLX version
// first on Apple silicon (only MLX for a model from Hugging Face), then the
// closest in size, then the smallest download.
func newerGeneration(name string, params int64, library []libraryModel, x *mlxIndex, memory int64, mlxOK, mlxOnly bool) (tagInfo, string, bool) {
	g, ok := parseGen(name)
	if !ok {
		return tagInfo{}, "", false
	}
	var families []libraryModel
	var gens []modelGen
	for _, m := range library {
		if og, ok := parseGen(m.Name); ok && og.sameLine(g) && og.newerThan(g) {
			families = append(families, m)
			gens = append(gens, og)
		}
	}
	// Newest first.
	order := make([]int, len(families))
	for i := range order {
		order[i] = i
	}
	slices.SortFunc(order, func(a, b int) int { return slices.Compare(gens[b].version, gens[a].version) })
	for _, i := range order {
		var best tagInfo
		found := false
		score := func(t tagInfo) (int, int64, int64) {
			mlxRank := 1
			if mlxOK && t.MLX {
				mlxRank = 0
			}
			_, tag, _ := strings.Cut(t.Name, ":")
			d := tagParams(tag) - params
			if d < 0 {
				d = -d
			}
			return mlxRank, d, t.Bytes
		}
		for _, t := range x.cache.Models[families[i].Name].Tags {
			_, tag, _ := strings.Cut(t.Name, ":")
			p := tagParams(tag)
			if p == 0 || p*2 < params || p > params*2 {
				continue
			}
			if memory > 0 && t.Bytes*4 > memory*3 {
				continue // tight at best: three quarters of the memory
			}
			if (mlxOnly || !mlxOK) && t.MLX != mlxOnly {
				continue
			}
			if !found {
				best, found = t, true
				continue
			}
			ar, ad, ab := score(t)
			br, bd, bb := score(best)
			if ar < br || ar == br && (ad < bd || ad == bd && ab < bb) {
				best = t
			}
		}
		if found {
			return best, families[i].Name, true
		}
	}
	return tagInfo{}, "", false
}

package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// Hugging Face holds far more MLX models than Ollama's library. `ollama
// pull hf.co/...` takes only GGUF files, but `ollama create` adds a folder
// of MLX safetensors files as a model that runs on Ollama's MLX engine, when
// Ollama knows its family (its model_type, such as qwen3_5): for another
// family it adds the model, which then fails to start or has no chat
// template. So MoreMole lists only the families of Ollama's own MLX models,
// downloads the picked model's files and checks each against Hugging Face's
// SHA-256, and after `ollama create` starts the model once to prove it works.
//
// Each model is named hf.co/<owner>/<repo>, lowercased, as `ollama pull`
// names models from Hugging Face; `ollama pull` refuses MLX models, so it can
// never replace one with something else. MoreMole records each one it adds,
// with the Hugging Face commit, so Ollama models can say when it changed.

// hfSite is Hugging Face. Tests replace it.
var hfSite = "https://huggingface.co"

func hfAPI() string { return hfSite + "/api/models" }

const (
	hfTimeout  = 30 * time.Second
	hfPages    = 2
	hfListMax  = 64 << 20
	hfInfoMax  = 16 << 20
	hfStartMax = 10 * time.Minute
	rawPrompt  = "{{ .Prompt }}"
	hfHost     = "hf.co/"
)

var (
	hfRepoName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$`)
	hfFileName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]*$`)
	hfNextLink = regexp.MustCompile(`<([^>]+)>;\s*rel="next"`)
	hfSHA      = regexp.MustCompile(`^[0-9a-f]{40}$`)
)

// hfPipelines are the kinds of model Ollama chats with.
var hfPipelines = map[string]string{
	"text-generation":    "Text",
	"image-text-to-text": "Text, Image",
	"any-to-any":         "Text, Image",
}

// hfModel is one model from Hugging Face's model API.
type hfModel struct {
	ID           string    `json:"id"`
	SHA          string    `json:"sha"`
	Private      bool      `json:"private"`
	Disabled     bool      `json:"disabled"`
	Gated        any       `json:"gated"` // false, or "auto" / "manual"
	Downloads    int64     `json:"downloads"`
	LastModified time.Time `json:"lastModified"`
	CreatedAt    time.Time `json:"createdAt"`
	PipelineTag  string    `json:"pipeline_tag"`
	Config       *struct {
		ModelType          string    `json:"model_type"`
		QuantizationConfig *hfQuant `json:"quantization_config"`
		Quantization       *hfQuant `json:"quantization"`
	} `json:"config"`
	Safetensors *struct {
		Parameters map[string]int64 `json:"parameters"`
	} `json:"safetensors"`
	Siblings []hfFile `json:"siblings"`
}

type hfQuant struct {
	Bits      int `json:"bits"`
	GroupSize int `json:"group_size"`
}

type hfFile struct {
	Name   string `json:"rfilename"`
	Size   int64  `json:"size"`
	BlobID string `json:"blobId"`
	LFS    *struct {
		SHA256 string `json:"sha256"`
		Size   int64  `json:"size"`
	} `json:"lfs"`
}

// open says whether anyone can download the model without signing in.
func (m hfModel) open() bool {
	gated, isBool := m.Gated.(bool)
	return !m.Private && !m.Disabled && (m.Gated == nil || (isBool && !gated))
}

func (m hfModel) bits() int {
	b, _ := m.quant()
	return b
}

// quant gives the quantization's bits and group size; a group size the
// config leaves out is MLX's default, 64. 0 bits means not quantized.
func (m hfModel) quant() (bits, group int) {
	if m.Config == nil {
		return 0, 0
	}
	for _, q := range []*hfQuant{m.Config.QuantizationConfig, m.Config.Quantization} {
		if q != nil && q.Bits > 0 && q.Bits <= 16 {
			group = q.GroupSize
			if group <= 0 {
				group = 64
			}
			return q.Bits, group
		}
	}
	return 0, 0
}

// quantText is how the weights are stored: "4-bit", or "bf16" unquantized.
func (m hfModel) quantText() string {
	if b := m.bits(); b > 0 {
		return strconv.Itoa(b) + "-bit"
	}
	if m.Safetensors == nil {
		return ""
	}
	p := m.Safetensors.Parameters
	switch {
	case p["U32"] > 0:
		return ""
	case p["BF16"] > 0:
		return "bf16"
	case p["F16"] > 0:
		return "fp16"
	case p["F32"] > 0:
		return "fp32"
	}
	return ""
}

var dtypeBytes = map[string]int64{"BF16": 2, "F16": 2, "F32": 4, "F64": 8, "I64": 8, "I32": 4, "I16": 2, "I8": 1, "U8": 1, "BOOL": 1, "F8_E4M3": 1, "F8_E5M2": 1}

// estimatedBytes guesses the download from the parameter counts Hugging Face
// lists. Quantized weights count as U32, one per weight; MLX stores them at
// their bits plus a 16-bit scale and bias per group of weights (64 unless
// the config says otherwise). A model quantized with different bits per
// layer comes out wrong, so the exact size is read before downloading.
// 0 means unknown.
func (m hfModel) estimatedBytes() int64 {
	if m.Safetensors == nil {
		return 0
	}
	var total int64
	for dtype, n := range m.Safetensors.Parameters {
		if dtype == "U32" {
			b, g := m.quant()
			if b == 0 {
				return 0
			}
			total += n * (int64(b)*int64(g) + 32) / (8 * int64(g))
			continue
		}
		size, ok := dtypeBytes[dtype]
		if !ok {
			return 0
		}
		total += n * size
	}
	return total
}

// ollamaNameFor is the name a Hugging Face model gets in Ollama.
func ollamaNameFor(repo string) string { return hfHost + strings.ToLower(repo) }

// hfGet downloads an API answer and its next-page link. Tests replace it.
var hfGet = func(rawURL string, limit int64) ([]byte, string, error) {
	client := &http.Client{Timeout: hfTimeout}
	req, err := http.NewRequest(http.MethodGet, rawURL, nil)
	if err != nil {
		return nil, "", err
	}
	req.Header.Set("User-Agent", "MoreMole (MLX models)")
	resp, err := client.Do(req)
	if err != nil {
		return nil, "", err
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		return nil, "", fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, limit+1))
	if err == nil && int64(len(body)) > limit {
		err = errors.New("answer too large")
	}
	next := ""
	if m := hfNextLink.FindStringSubmatch(resp.Header.Get("Link")); m != nil && strings.HasPrefix(m[1], hfAPI()+"?") {
		next = m[1]
	}
	return body, next, err
}

func hfListURL() string {
	q := url.Values{}
	q.Set("filter", "mlx")
	q.Set("sort", "downloads")
	q.Set("direction", "-1")
	q.Set("limit", "1000")
	for _, e := range []string{"config", "downloads", "lastModified", "createdAt", "safetensors", "pipeline_tag", "gated", "sha"} {
		q.Add("expand[]", e)
	}
	return hfAPI() + "?" + q.Encode()
}

// hfListLines lists the most downloaded MLX models on Hugging Face that
// Ollama's MLX engine runs, most downloaded first:
//
//	hf  repo  family  quant  bytes  downloads  updated  installed  input  created
//
// bytes is an estimate, 0 when unknown.
func hfListLines(libFetch func() (string, error), x *mlxIndex, s service) []string {
	models, err := readLibrary(libFetch)
	if err == nil {
		x.refresh(models)
	}
	families := x.families()
	x.save()

	var found []hfModel
	next := hfListURL()
	for page := 0; page < hfPages && next != ""; page++ {
		body, more, err := hfGet(next, hfListMax)
		if err != nil {
			if page == 0 {
				return []string{notice("hf-failed", "Couldn't read Hugging Face's model list ("+err.Error()+").")}
			}
			break
		}
		var batch []hfModel
		if err := json.Unmarshal(body, &batch); err != nil {
			if page == 0 {
				return []string{notice("hf-failed", "Couldn't read Hugging Face's model list ("+err.Error()+").")}
			}
			break
		}
		found = append(found, batch...)
		next = more
	}

	installed := map[string]bool{}
	if local, err := s.models(); err == nil {
		for _, m := range local {
			installed[strings.ToLower(strings.TrimSuffix(m.Name, ":latest"))] = true
		}
	}
	var lines []string
	seen := map[string]bool{}
	for _, m := range found {
		input, chat := hfPipelines[m.PipelineTag]
		if !chat || !m.open() || m.Config == nil || !families[m.Config.ModelType] || !hfRepoName.MatchString(m.ID) || seen[m.ID] {
			continue
		}
		seen[m.ID] = true
		isInstalled := "0"
		if installed[ollamaNameFor(m.ID)] {
			isInstalled = "1"
		}
		lines = append(lines, row("hf", m.ID, m.Config.ModelType, m.quantText(),
			strconv.FormatInt(m.estimatedBytes(), 10), strconv.FormatInt(m.Downloads, 10),
			strconv.FormatInt(unixOrZero(m.LastModified), 10), isInstalled, input,
			strconv.FormatInt(unixOrZero(m.CreatedAt), 10)))
	}
	return lines
}

// hfInfo reads one model, at a commit or the newest one.
func hfInfo(repo, sha string) (hfModel, error) {
	if !hfRepoName.MatchString(repo) {
		return hfModel{}, errors.New("not a Hugging Face model name")
	}
	u := hfAPI() + "/" + repo
	if sha != "" {
		if !hfSHA.MatchString(sha) {
			return hfModel{}, errors.New("not a commit")
		}
		u += "/revision/" + sha
	}
	body, _, err := hfGet(u+"?blobs=true", hfInfoMax)
	if err != nil {
		return hfModel{}, err
	}
	var m hfModel
	if err := json.Unmarshal(body, &m); err != nil {
		return hfModel{}, err
	}
	if !m.open() {
		return hfModel{}, errors.New("it needs signing in to Hugging Face")
	}
	if !hfSHA.MatchString(m.SHA) {
		return hfModel{}, errors.New("no commit was listed for it")
	}
	return m, nil
}

// modelFiles are the files `ollama create` reads: the model's own folder,
// without its readme, pictures and other formats' weights.
func modelFiles(m hfModel) ([]hfFile, error) {
	var files []hfFile
	weights, config := false, false
	for _, f := range m.Siblings {
		lower := strings.ToLower(f.Name)
		if !hfFileName.MatchString(f.Name) || strings.HasPrefix(lower, "readme") || lower == ".gitattributes" {
			continue
		}
		switch filepath.Ext(lower) {
		case ".md", ".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".gguf", ".bin", ".pt", ".pth", ".onnx", ".h5", ".msgpack", ".ckpt":
			continue
		case ".safetensors":
			weights = true
		}
		if lower == "config.json" {
			config = true
		}
		if f.LFS != nil {
			f.Size = f.LFS.Size
		}
		files = append(files, f)
	}
	if !weights || !config {
		return nil, errors.New("it has no MLX safetensors files")
	}
	return files, nil
}

const (
	hfIndexName = "model.safetensors.index.json"
	hfIndexMax  = 32 << 20
)

// downloadFiles is modelFiles, minus weights the model's index doesn't use.
// Some models hold two whole sets of weights (one of 18 parts and one of 28,
// say); the index names the set the model loads, and downloading both
// doubled the download and gave Ollama every tensor twice.
func downloadFiles(m hfModel) ([]hfFile, error) {
	files, err := modelFiles(m)
	if err != nil {
		return nil, err
	}
	hasIndex := false
	for _, f := range files {
		hasIndex = hasIndex || f.Name == hfIndexName
	}
	if !hasIndex {
		return files, nil
	}
	body, _, err := hfGet(hfFileURL(m.ID, m.SHA, hfIndexName), hfIndexMax)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", hfIndexName, err)
	}
	var index struct {
		WeightMap map[string]string `json:"weight_map"`
	}
	if json.Unmarshal(body, &index) != nil || len(index.WeightMap) == 0 {
		return nil, errors.New(hfIndexName + " names no weights")
	}
	used := map[string]bool{}
	for _, shard := range index.WeightMap {
		used[shard] = true
	}
	var kept []hfFile
	for _, f := range files {
		if strings.HasSuffix(strings.ToLower(f.Name), ".safetensors") && !used[f.Name] {
			continue
		}
		delete(used, f.Name)
		kept = append(kept, f)
	}
	for shard := range used {
		return nil, fmt.Errorf("%s names %s, which the model doesn't have", hfIndexName, shard)
	}
	return kept, nil
}

func totalSize(files []hfFile) int64 {
	var n int64
	for _, f := range files {
		n += f.Size
	}
	return n
}

// hfFilesLines gives each model's commit and download size:
//
//	files  repo  sha  bytes  count  ollama-name
func hfFilesLines(repos []string) []string {
	var lines []string
	for _, repo := range repos {
		m, err := hfInfo(repo, "")
		var files []hfFile
		if err == nil {
			files, err = downloadFiles(m)
		}
		if err != nil {
			lines = append(lines, notice("hf-failed", repo+": "+err.Error()))
			continue
		}
		lines = append(lines, row("files", repo, m.SHA, strconv.FormatInt(totalSize(files), 10), strconv.Itoa(len(files)), ollamaNameFor(repo)))
	}
	return lines
}

// freeBytes is the space free where dir is. Tests replace it.
var freeBytes = func(dir string) (int64, error) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(dir, &st); err != nil {
		return 0, err
	}
	return int64(st.Bavail) * int64(st.Bsize), nil //nolint:gosec // G115: block counts fit
}

// hfFileURL is where Hugging Face serves a file at a commit.
func hfFileURL(repo, sha, name string) string {
	return fmt.Sprintf("%s/%s/resolve/%s/%s", hfSite, repo, sha, url.PathEscape(name))
}

// hfDownloadClient has no overall timeout, since a model can take an hour;
// a stalled connection still ends.
var hfDownloadClient = &http.Client{Transport: &http.Transport{
	Proxy:                 http.ProxyFromEnvironment,
	ResponseHeaderTimeout: 60 * time.Second,
	IdleConnTimeout:       90 * time.Second,
	TLSHandshakeTimeout:   30 * time.Second,
}}

// progress prints one updating line for the whole download: the file, how
// much of the model is here, and once it has run a few seconds, the speed
// and the time left. Parts already on disk don't count toward the speed.
type progress struct {
	out         io.Writer
	done, size  int64
	file        string
	last        time.Time
	start       time.Time
	startDone   int64
	startedOnce bool
}

func (p *progress) add(n int64) {
	if !p.startedOnce {
		p.startedOnce = true
		p.start = now()
	}
	p.done += n
	if now().Sub(p.last) >= 250*time.Millisecond || p.done == p.size {
		p.print()
	}
}

// skip counts bytes that were already downloaded, so they show in the
// total but not in the speed.
func (p *progress) skip(n int64) {
	p.add(n)
	p.startDone += n
}

func (p *progress) print() {
	p.last = now()
	pct := int64(100)
	if p.size > 0 {
		pct = p.done * 100 / p.size
	}
	line := fmt.Sprintf("\rdownloading %s  %s of %s  %d%%", p.file, humanBytes(p.done), humanBytes(p.size), pct)
	if elapsed := p.last.Sub(p.start); elapsed >= 2*time.Second && p.done > p.startDone {
		rate := float64(p.done-p.startDone) / elapsed.Seconds()
		line += "  " + humanBytes(int64(rate)) + "/s"
		if left := p.size - p.done; left > 0 {
			line += "  " + shortDuration(time.Duration(float64(left)/rate*float64(time.Second))) + " left"
		}
	}
	_, _ = fmt.Fprint(p.out, line+"\033[K")
}

// shortDuration is a time left as people say it: 45s, 3m, 1h 5m.
func shortDuration(d time.Duration) string {
	switch {
	case d < time.Minute:
		return strconv.Itoa(int((d+time.Second-1)/time.Second)) + "s"
	case d < time.Hour:
		return strconv.Itoa(int(d.Minutes()+0.5)) + "m"
	}
	h := int(d.Hours())
	return fmt.Sprintf("%dh %dm", h, int(d.Minutes())-h*60)
}

func (p *progress) Write(b []byte) (int, error) {
	p.add(int64(len(b)))
	return len(b), nil
}

func humanBytes(n int64) string {
	switch {
	case n >= 1e9:
		return fmt.Sprintf("%.1f GB", float64(n)/1e9)
	case n >= 1e6:
		return fmt.Sprintf("%.0f MB", float64(n)/1e6)
	case n >= 1e3:
		return fmt.Sprintf("%.0f KB", float64(n)/1e3)
	}
	return fmt.Sprintf("%d B", n)
}

// hfDownload downloads a model's files at a commit into dir, checks each
// against its size and SHA-256, and writes the Modelfile `ollama create`
// reads. A file already there and whole is kept, and a partial one is
// continued, so trying again after a failure picks up where it stopped.
func hfDownload(repo, sha, dir string, out io.Writer) error {
	m, err := hfInfo(repo, sha)
	if err != nil {
		return err
	}
	files, err := downloadFiles(m)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	size := totalSize(files)
	var have int64
	for _, f := range files {
		if info, err := os.Stat(filepath.Join(dir, f.Name)); err == nil && info.Size() == f.Size {
			have += f.Size
		} else if info, err := os.Stat(filepath.Join(dir, f.Name+".part")); err == nil && info.Size() < f.Size {
			have += info.Size()
		}
	}
	// The files, then Ollama's own copy of them.
	if free, err := freeBytes(dir); err == nil && free < size-have+size {
		return fmt.Errorf("not enough free space: it needs %s (the download and Ollama's copy of it), and %s is free", humanBytes(size-have+size), humanBytes(free))
	}
	p := &progress{out: out, size: size}
	for _, f := range files {
		p.file = f.Name
		if err := downloadFile(repo, sha, dir, f, p); err != nil {
			_, _ = fmt.Fprintln(out)
			return fmt.Errorf("%s: %w", f.Name, err)
		}
	}
	_, _ = fmt.Fprintf(out, "\rdownloaded %s in %d files\033[K\n", humanBytes(size), len(files))
	if err := fillQuantizationMode(filepath.Join(dir, "config.json")); err != nil {
		return fmt.Errorf("config.json: %w", err)
	}
	return os.WriteFile(filepath.Join(dir, "Modelfile"), []byte("FROM .\n"), 0o600)
}

func downloadFile(repo, sha, dir string, f hfFile, p *progress) error {
	final := filepath.Join(dir, f.Name)
	if info, err := os.Stat(final); err == nil && info.Size() == f.Size && verifyFile(final, f) == nil {
		p.skip(f.Size)
		return nil
	}
	part := final + ".part"
	var start int64
	if info, err := os.Stat(part); err == nil && info.Size() < f.Size {
		start = info.Size()
	}
	req, err := http.NewRequest(http.MethodGet, hfFileURL(repo, sha, f.Name), nil)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", "MoreMole (MLX models)")
	if start > 0 {
		req.Header.Set("Range", "bytes="+strconv.FormatInt(start, 10)+"-")
	}
	resp, err := hfDownloadClient.Do(req)
	if err != nil {
		return err
	}
	defer func() { _ = resp.Body.Close() }()
	flags := os.O_CREATE | os.O_WRONLY | os.O_TRUNC
	switch {
	case resp.StatusCode == http.StatusPartialContent && start > 0:
		flags = os.O_WRONLY | os.O_APPEND
		p.skip(start)
	case resp.StatusCode == http.StatusOK:
	default:
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	w, err := os.OpenFile(part, flags, 0o600)
	if err != nil {
		return err
	}
	_, copyErr := io.Copy(io.MultiWriter(w, p), io.LimitReader(resp.Body, f.Size+1))
	closeErr := w.Close()
	if copyErr != nil {
		return copyErr
	}
	if closeErr != nil {
		return closeErr
	}
	if err := verifyFile(part, f); err != nil {
		_ = os.Remove(part)
		return err
	}
	return os.Rename(part, final)
}

// verifyFile checks a download's size, and the SHA-256 Hugging Face lists for
// its large files.
func verifyFile(path string, f hfFile) error {
	info, err := os.Stat(path)
	if err != nil {
		return err
	}
	if info.Size() != f.Size {
		return fmt.Errorf("downloaded %s, expected %s", humanBytes(info.Size()), humanBytes(f.Size))
	}
	if f.LFS == nil || f.LFS.SHA256 == "" {
		return nil
	}
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer func() { _ = file.Close() }()
	h := sha256.New()
	if _, err := io.Copy(h, bufio.NewReaderSize(file, 1<<20)); err != nil {
		return err
	}
	if got := hex.EncodeToString(h.Sum(nil)); got != strings.ToLower(f.LFS.SHA256) {
		return errors.New("its SHA-256 doesn't match Hugging Face's, so it was deleted")
	}
	return nil
}

// fillQuantizationMode names MLX's default quantization, "affine", in a
// config.json that leaves it out: models converted before MLX had other
// modes omit it, and Ollama's MLX engine then fails to start them.
func fillQuantizationMode(path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	var cfg map[string]any
	if err := json.Unmarshal(data, &cfg); err != nil {
		return err
	}
	changed := false
	for _, key := range []string{"quantization", "quantization_config"} {
		q, ok := cfg[key].(map[string]any)
		if !ok {
			continue
		}
		if _, hasBits := q["bits"]; !hasBits {
			continue
		}
		if mode, ok := q["mode"].(string); !ok || mode == "" {
			q["mode"] = "affine"
			changed = true
		}
	}
	if !changed {
		return nil
	}
	out, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, out, 0o600)
}

// verifyModel shows that Ollama can chat with a model it just added: it has a
// chat template, and it starts and answers. It answers one word, then
// leaves memory.
func verifyModel(s service, name string) error {
	var show struct {
		Renderer string `json:"renderer"`
		Template string `json:"template"`
	}
	if err := s.post("/api/show", map[string]any{"model": name}, &show, serviceTimeout); err != nil {
		return fmt.Errorf("couldn't read it back from Ollama (%w)", err)
	}
	if tpl := strings.TrimSpace(show.Template); show.Renderer == "" && (tpl == "" || tpl == rawPrompt) {
		return errors.New("its family has no chat template in Ollama, so Ollama couldn't chat with it")
	}
	var gen struct {
		Error string `json:"error"`
	}
	req := map[string]any{"model": name, "prompt": "Hi", "stream": false, "keep_alive": 0, "options": map[string]any{"num_predict": 1}}
	if err := s.post("/api/generate", req, &gen, hfStartMax); err != nil {
		return fmt.Errorf("it didn't start (%w)", err)
	}
	if gen.Error != "" {
		return fmt.Errorf("it didn't start (%s)", gen.Error)
	}
	return nil
}

// hfRecordPath is the list of models MoreMole added from Hugging Face, one
// "name<TAB>repo<TAB>commit" line each; bin/moremole-models.sh writes it.
// Tests replace it.
var hfRecordPath = func() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".config", "mole", "moremole-hf-models")
}

type hfRecord struct{ Repo, SHA string }

func loadHFRecord() map[string]hfRecord {
	records := map[string]hfRecord{}
	path := hfRecordPath()
	if path == "" {
		return records
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return records
	}
	for line := range strings.Lines(string(data)) {
		fields := strings.Split(strings.TrimRight(line, "\r\n"), "\t")
		if len(fields) == 3 && hfRepoName.MatchString(fields[1]) && hfSHA.MatchString(fields[2]) {
			records[fields[0]] = hfRecord{Repo: fields[1], SHA: fields[2]}
		}
	}
	return records
}

// checkHFModel compares a model added from Hugging Face with the newest
// commit there. A commit that changes only the readme is no update: the
// model's files are compared.
func checkHFModel(r hfRecord) string {
	latest, err := hfInfo(r.Repo, "")
	if err != nil {
		return "unknown"
	}
	if latest.SHA == r.SHA {
		return "current"
	}
	added, err := hfInfo(r.Repo, r.SHA)
	if err != nil {
		return "unknown"
	}
	a, errA := modelFiles(added)
	b, errB := modelFiles(latest)
	if errA != nil || errB != nil {
		return "unknown"
	}
	if fingerprint(a) == fingerprint(b) {
		return "current"
	}
	return "update"
}

// fingerprint names each file by its name, size and content hash.
func fingerprint(files []hfFile) string {
	parts := make([]string, 0, len(files))
	for _, f := range files {
		id := f.BlobID
		if f.LFS != nil && f.LFS.SHA256 != "" {
			id = f.LFS.SHA256
		}
		parts = append(parts, f.Name+":"+strconv.FormatInt(f.Size, 10)+":"+id)
	}
	slices.Sort(parts)
	return strings.Join(parts, "\n")
}

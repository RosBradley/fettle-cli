// Command moremole-models-go looks at Ollama models for moremole's Ollama models
// screens. bin/moremole-models.sh shows the lists and runs `ollama pull` and
// `ollama rm`; this program only looks.
//
//	moremole-models-go status          Ollama's app, command, service, the Mac's memory, and mlx=1 on Apple silicon
//	moremole-models-go list [--check]  installed models; --check asks the registry about each
//	moremole-models-go updates         installed models with an update, for the Software updates screen (updates.go)
//	moremole-models-go library         the models on ollama.com/library
//	moremole-models-go tags MODEL...   the versions of each model, from its tags page
//	moremole-models-go size NAME...    download size of each model, from the registry
//	moremole-models-go better          better versions of the installed models for this Mac (better.go)
//	moremole-models-go hf-list         MLX models on Hugging Face that Ollama's MLX engine runs
//	moremole-models-go hf-files REPO...  each one's newest commit and download size
//	moremole-models-go hf-download REPO SHA DIR  download its files, checked, into DIR
//	moremole-models-go hf-verify NAME  start a model Ollama just added, to show it works
//
// status prints key=value lines. The others print one row per item, fields
// separated by the ASCII unit separator (0x1f) so empty fields survive a
// shell read:
//
//	list:     model  name  size  modified  status  loaded  hf-repo  mlx
//	library:  model  name  capabilities  pulls  updated  installed  sizes  mlx  bytes  description
//	tags:     tag    name  bytes  size  context  input  mlx  default  installed  updated
//	size:     size   name  bytes
//	hf-list:  hf     repo  family  quant  bytes  downloads  updated  installed  input
//	hf-files: files  repo  sha  bytes  count  ollama-name
//	hf-verify: verified name
//	better:   better installed  suggested  kind  bytes  mlx  note
//	notice:   notice key   text
//
// hf-download prints its progress, and on failure exits 1 with an "Error:"
// line on stderr. DIR must be a folder directly in MoreMole's download cache
// (~/Library/Caches/moremole/models/hf), since files in it that aren't the
// model's are deleted.
//
// status in list is update, current, local (the registry has no such model:
// made on this Mac or removed upstream) or unknown (could not check); it is
// empty without --check. loaded is 1 for a model in memory now. Times are
// Unix seconds; sizes are bytes, 0 when unknown. In library, sizes are the
// size tags a model comes in (8b,70b) and installed is 1 when any version
// is installed, and on Apple silicon mlx is how many MLX versions it has
// (in list, mlx is 1 for a model Ollama runs on its MLX engine)
// (empty when unknown). bytes is the download size of the version the
// model's name alone downloads, from its tags page, 0 when unknown. hf-repo is the Hugging Face model a model was added
// from by MoreMole, whose status then compares it with Hugging Face. In tags, size is as the page shows it ("6.6GB - 7.6GB"),
// mlx is 1 for a version built for Apple's MLX engine (left out on Intel),
// and default is 1 for the version the model's name alone downloads. A tags page that can't be read gives the
// notice tags-failed with the model's name.
package main

import (
	"fmt"
	"io"
	"os"
	"strings"
)

const fieldSeparator = "\x1f"

// row joins fields for the shell script, keeping each on one line.
func row(fields ...string) string {
	for i, f := range fields {
		fields[i] = strings.Map(func(c rune) rune {
			if c == '\t' || c == '\n' || c == '\r' || c == 0x1f {
				return ' '
			}
			return c
		}, f)
	}
	return strings.Join(fields, fieldSeparator)
}

func notice(key, text string) string { return row("notice", key, text) }

func usage(w io.Writer) {
	_, _ = fmt.Fprintln(w, "Usage: moremole-models-go status|list [--check]|updates|better|library|tags MODEL...|size NAME...|hf-list|hf-files REPO...|hf-download REPO SHA DIR|hf-verify NAME")
}

func main() {
	if len(os.Args) < 2 {
		usage(os.Stderr)
		os.Exit(2)
	}
	var lines []string
	switch os.Args[1] {
	case "status":
		lines = append(statusLines(findOllama(), newService().running(), memoryBytes()), "mlx="+flag(appleSilicon))
	case "list":
		check := len(os.Args) > 2 && os.Args[2] == "--check"
		lines = listLines(newService(), check, fetchManifest, loadHFRecord(), checkHFModel)
	case "updates":
		lines = updatesLines(findOllama(), newService(), fetchManifest, loadHFRecord(), checkHFModel)
	case "library":
		lines = libraryLines(fetchLibrary, newService(), newMLXIndex(), appleSilicon)
	case "tags":
		lines = tagsLines(os.Args[2:], fetchTags, newService(), appleSilicon, loadCache().recentTags)
	case "size":
		lines = sizeLines(os.Args[2:], fetchManifest)
	case "better":
		lines = betterLines(newService(), func() ([]libraryModel, error) { return readLibrary(fetchLibrary) }, newMLXIndex(), loadHFRecord(), memoryBytes(), appleSilicon)
	case "hf-list":
		lines = hfListLines(fetchLibrary, newMLXIndex(), newService())
	case "hf-files":
		lines = hfFilesLines(os.Args[2:])
	case "hf-download":
		if len(os.Args) != 5 {
			usage(os.Stderr)
			os.Exit(2)
		}
		if err := hfDownload(os.Args[2], os.Args[3], os.Args[4], os.Stdout); err != nil {
			_, _ = fmt.Fprintln(os.Stderr, "Error: "+err.Error())
			os.Exit(1)
		}
		return
	case "hf-verify":
		if len(os.Args) != 3 {
			usage(os.Stderr)
			os.Exit(2)
		}
		if err := verifyModel(newService(), os.Args[2]); err != nil {
			lines = []string{notice("verify-failed", err.Error())}
		} else {
			lines = []string{row("verified", os.Args[2])}
		}
	case "-h", "--help":
		usage(os.Stdout)
		return
	default:
		usage(os.Stderr)
		os.Exit(2)
	}
	for _, l := range lines {
		fmt.Println(l)
	}
}

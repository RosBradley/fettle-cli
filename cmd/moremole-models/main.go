// Command moremole-models-go looks at Ollama models for moremole's Ollama models
// screens. bin/moremole-models.sh shows the lists and runs `ollama pull` and
// `ollama rm`; this program only looks.
//
//	moremole-models-go status          Ollama's app, command, service, the Mac's memory, and mlx=1 on Apple silicon
//	moremole-models-go list [--check]  installed models; --check asks the registry about each
//	moremole-models-go library         the models on ollama.com/library
//	moremole-models-go tags MODEL...   the versions of each model, from its tags page
//	moremole-models-go size NAME...    download size of each model, from the registry
//
// status prints key=value lines. The others print one row per item, fields
// separated by the ASCII unit separator (0x1f) so empty fields survive a
// shell read:
//
//	list:     model  name  size  modified  status  loaded
//	library:  model  name  capabilities  pulls  updated  installed  sizes  description
//	tags:     tag    name  bytes  size  context  input  mlx  default  installed
//	size:     size   name  bytes
//	notice:   notice key   text
//
// status in list is update, current, local (the registry has no such model:
// made on this Mac or removed upstream) or unknown (could not check); it is
// empty without --check. loaded is 1 for a model in memory now. Times are
// Unix seconds; sizes are bytes, 0 when unknown. In library, sizes are the
// size tags a model comes in (8b,70b) and installed is 1 when any version
// is installed. In tags, size is as the page shows it ("6.6GB - 7.6GB"),
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
	_, _ = fmt.Fprintln(w, "Usage: moremole-models-go status|list [--check]|library|tags MODEL...|size NAME...")
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
		lines = listLines(newService(), check, fetchManifest)
	case "library":
		lines = libraryLines(fetchLibrary, newService())
	case "tags":
		lines = tagsLines(os.Args[2:], fetchTags, newService(), appleSilicon)
	case "size":
		lines = sizeLines(os.Args[2:], fetchManifest)
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

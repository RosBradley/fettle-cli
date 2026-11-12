package main

import (
	"strconv"
)

// updatesLines lists the installed models that have an update, as rows for
// glimwell's Software updates screen (bin/glimwell-updates.sh), in that
// helper's format:
//
//	model  name  name  installed  available  note  bundle
//
// kind is model-hf for a model Glimwell added from Hugging Face. installed,
// available and bundle are empty: a model has no version number, only a
// newer download. Without Ollama there are no rows. With Ollama off there is
// a notice instead: only its service lists the models, since the folder it
// keeps them in has changed layout between versions (manifests, then
// manifests-v2) and still holds manifests it no longer uses. Models it
// couldn't check are a notice too. A notice's text is in the note field, as
// that helper's notices are.
func updatesLines(in ollamaInstall, s service, fetch manifestFetcher, records map[string]hfRecord, checkHF func(hfRecord) string) []string {
	if in.App == "" && in.CLI == "" {
		return nil
	}
	models, err := s.models()
	if err != nil {
		if !s.running() {
			return []string{updatesNotice("ollama-off", "Ollama is off, so your Ollama models weren't checked. Open the Ollama app, then check again to include them.")}
		}
		return []string{updatesNotice("service-failed", "Couldn't get the model list from Ollama ("+err.Error()+"), so your Ollama models weren't checked.")}
	}
	statuses := checkModels(models, fetch, records, checkHF)
	var lines []string
	unchecked := 0
	for i, m := range models {
		switch statuses[i] {
		case "update":
			kind, note := "model", "newer download on Ollama"
			if _, ok := records[m.Name]; ok {
				kind, note = "model-hf", "newer files on Hugging Face"
			}
			lines = append(lines, row(kind, m.Name, m.Name, "", "", note, ""))
		case "unknown":
			unchecked++
		}
	}
	if unchecked > 0 {
		lines = append(lines, updatesNotice("models-unchecked", "Couldn't check "+strconv.Itoa(unchecked)+" of "+strconv.Itoa(len(models))+" Ollama models for updates. Check the internet connection, then try again."))
	}
	return lines
}

func updatesNotice(key, text string) string { return row("notice", key, "", "", "", text, "") }

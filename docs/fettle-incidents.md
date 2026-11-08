# Fettle incidents

Defects in Fettle's own code that reached a published Fettle release, kept apart from Mole's
`docs/incidents.md` so syncing with Mole never conflicts in that table. The rules are Mole's: a row names the
fix commit, the commit that introduced the defect when known, the earliest layer that should have caught it (the
layers listed in `docs/incidents.md`), and the test or gate that catches it now, in backticks.
`scripts/audit_incidents.py --ledger docs/fettle-incidents.md` checks every row; the test
`Fettle's incident ledger names real commits, layers and catchers` in `tests/fettle_release.bats` runs it, so
the release workflow does too.

## Incidents

| ID | Reported | Symptom | Introduced | Fixed | Layer | Caught by |
| --- | --- | --- | --- | --- | --- | --- |
| M-1 | 2026-11-05 | A Hugging Face download that stopped kept its folder, and trying again left in it the files the new download doesn't name: weights of the set the index doesn't use (from a download before e95ab599) or parts of an earlier commit, which `ollama create` added to the model; files outside LFS were checked by size alone, so a same-size file of an earlier commit was used | 7bb544bd | 1437ab92 | review | `TestHFDownloadTakesOnlyTheWeightsTheIndexNames`, `TestHFDownloadRefusesABadFileOrTooLittleSpace` |
| M-2 | 2026-11-05 | Ctrl-C while a model from Hugging Face was added or started once to check it left its `<name>-moremole-check` model in Ollama at full size, with nothing recording it | 7bb544bd | b02a6958 | review | `a run stopped while a Hugging Face model starts removes its check model from Ollama` |
| M-3 | 2026-11-05 | A model update from Software updates that stopped partway wrote no results, so every picked model was counted and logged FAILED, including the ones it had already updated and logged REBUILT | e95ab599 | 85c0714c | review | `Ollama models with an update join the list, and the picked ones update after the rest in one run` |

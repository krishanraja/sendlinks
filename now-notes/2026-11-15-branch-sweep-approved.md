Status: the branch sweep takes an approved list (branch@sha) on a hand run and deletes each named branch only at that exact commit, skipping and logging anything else; the weekly run is unchanged. Copied from ai-harness's canonical script and workflow.
Next: run the sweep by hand with dry_run false and this repository's approved list, and read its log.
North Star check (2026-11-15): holds.

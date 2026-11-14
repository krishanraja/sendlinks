# sendlinks

SendLinks: expiring, revocable, view-limited links to a file, text or url, made by Krish's engine (Control Center, n8n) for any venture and opened by the person they were meant for, with read receipts. It runs as two Supabase edge functions (`sendlinks-api`, `sendlinks-open`) and the `sendlinks` schema on the Mindmaker OS project. `NOW.md` says where it stands; `docs/STATE.md` is the one current-truth file; `docs/DECISIONS.md` says why.

<!-- north-star:start -->
## North Star: read it first, every session

[`docs/NORTH_STAR.md`](docs/NORTH_STAR.md). It is not set yet: only Krish sets it. Say so before starting, and check the state line, the first line under "Where it is right now" in `NOW.md` (U4 until Krish sets a number), by [the harness contract](https://github.com/krishanraja/ai-harness/blob/main/contract/north-star-metric.md).
<!-- north-star:end -->

## Rules

- This repository is public. Never write the database project address or its ref, a key, a JWT, a SendLinks bearer or a Postgres URL into any file, commit or pull request; name them as `$SUPABASE_URL`, `$SUPABASE_PROJECT_REF` and the secret's name. `scripts/check-no-secrets.sh` fails CI on any of them.
- SendLinks never emails or sends anything. Sending stays with the callers' own lanes and their approvals.
- Every rule lives in a `sendlinks.*` SQL function; a schema change is a new migration in `supabase/migrations/`, applied to the Mindmaker OS project and read back from its migration history.
- Krish's yes, immediately before, for each of: minting or revoking a bearer, changing a client's `ventures`, deleting uploads (the expired sweep), and changing a bucket's permission (`skill-deliveries`). `docs/STATE.md`, "Open items", lists the ones waiting.
- The default branch is `claude/drive-folder-rebuild-e0suzz` (there is no `main`); making `main` the default is a repository setting, Krish's call.
- No em dashes in anything new.

## Checks

```sh
bash scripts/check-no-secrets.sh   # what CI runs on every push and pull request
bash tests/run-local.sh            # needs a local Postgres and Deno: SQL suites, then the handler tests
```

## Close out

Before a session that changed the repository ends, write `now-notes/YYYY-MM-DD-<slug>.md` with `Status:`, `Next:` (the single next action) and the line `North Star check (YYYY-MM-DD): holds.` with nothing in front of it. It folds into `NOW.md` on the default branch.

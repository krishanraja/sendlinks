---
repo: krishanraja/sendlinks
product: SendLinks
as_of: 2026-11-14
head: 11454a8
lifecycle: live
production_url: none (two Supabase edge functions on the Mindmaker OS project)
state_doc: docs/STATE.md
history_log: now-notes/
truth_files: [docs/STATE.md, docs/DECISIONS.md, docs/NORTH_STAR.md]
authority_order: [docs/NORTH_STAR.md, docs/STATE.md, docs/DECISIONS.md, README.md]
steward: https://github.com/krishanraja/ai-harness/blob/main/docs/steward/RUNBOOK.md
---

# sendlinks: where it is right now

## What it is

Expiring, revocable, view-limited links to a file, text or url, made by the engine for any venture, with read receipts (`README.md`). The full current truth is `docs/STATE.md`; this file points.

## Who it is for and why it matters for Mindmake

Krish's engine: every file that reaches a customer goes as a tracked link (DEL-002), so Control Center knows who opened what was sent.

## Where it is right now (as of 2026-11-14)

<!-- north-star-state {"week_of":"2026-11-09","week_target":null,"current":null,"current_as_of":null,"current_source":null,"urgency":4,"urgency_reason":"no North Star of its own yet; Krish sets one"} --> **North Star number: U4, not measured.** sendlinks has no North Star of its own yet (`docs/NORTH_STAR.md`); Krish sets one.

- Live on Mindmaker OS: `sendlinks-api` v7 and `sendlinks-open` v6. Callers: Control Center (asset links in growth-mindmake emails, and the connector's `make_send_link` and `read_send_link`) and n8n (credential `SendLinks`). (2026-11-14)
- Byte ranges are live: migration `20261114123717_sendlinks_ranges` applied (18 functions, 11 wrappers, none open to anon or signed-in users); `sendlinks-open` answers `206` with `Content-Range`. Not yet checked on a real phone. (2026-11-14)
- The project address is out of the docs (named as `$SUPABASE_URL` / `$SUPABASE_PROJECT_REF`) and `scripts/check-no-secrets.sh` fails CI on a JWT, a key, a bearer, a project address or ref, or a Postgres URL (fleet audit I-01). Older commits still hold the address. (2026-11-14)
- `docs/STATE.md` names the `control-center` bearer and caller and the function versions, read live on 14 Nov. (2026-11-14)

## What changed recently

- 2026-11-14 NOW.md in the steward's schema with its North Star line, and AGENTS.md and CLAUDE.md added, so a new session reads true instructions first.
- 2026-11-14 Byte ranges for file links (I-07); the database address out of the docs and a CI guard (I-01).

## What is next and what is waiting on Krish

- Next (2026-11-14): a live phone check of an mp4 link (inline playback, seeking, time to first frame) once an existing caller mints one, or Krish opens a real video link on an iPhone and an Android.
- Then: mock the recipient click-through page (branded per venture, password form, read receipts) for Krish's approval; it also stops mail scanners counting as opens.
- Waiting on Krish (fleet decisions, batch 2): narrowing Control Center's bearer to the ventures it uses and revoking the unused n8n bearer; the expired upload sweep; making `skill-deliveries` private; making `main` the default branch.
- North Star check (2026-11-14): holds.

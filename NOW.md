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

- Android phone check failed (broken video: later byte ranges refused because they were bound to one ip and agent); fixed live with migration `20261114175146_sendlinks_ranges_any_viewer` (PR #11) and replayed: later ranges 206, bytes identical, iPhone player agent included. On Krish's approval: Control Center's bearer scoped to `{mindmake}` and still working, the n8n bearer revoked (its Vault bearer no longer authenticates), the sweep applied and run (18 canary files removed through the Storage API, second dry run 0). (2026-11-14)
- Sent marks are live (migration `20261114171820_sendlinks_sent`, `sendlinks-api` v9, `POST /links/{id}/sent`, first call wins). The expired upload sweep is built with tests (PR #8) but not applied: the Supabase connector asked a confirmation question that got no answer; its read-only dry run finds 18 canary files, 614 bytes. The recipient page mock is rendered, Mindmake, light and dark (PR #9), waiting on Krish. A phone-check video link was minted through Control Center's `make_send_link`; the result waits on his iPhone and Android. Bearer narrowing, the n8n bearer revocation and `skill-deliveries` are ready with evidence in `docs/STATE.md` and not done: each is a permission change or deletion and Krish's written yes could not be read from this session. (2026-11-14)
- closeout notes now fold into NOW.md on the default branch (.github/workflows/closeout-fold.yml runs the harness's own fold, after checking the hook is the ai-harness copy by sha256). (2026-11-14)
- Live on Mindmaker OS: `sendlinks-api` v7 and `sendlinks-open` v6. Callers: Control Center (asset links in growth-mindmake emails, and the connector's `make_send_link` and `read_send_link`) and n8n (credential `SendLinks`). (2026-11-14)
- Byte ranges are live: migration `20261114123717_sendlinks_ranges` applied (18 functions, 11 wrappers, none open to anon or signed-in users); `sendlinks-open` answers `206` with `Content-Range`. Not yet checked on a real phone. (2026-11-14)
- The project address is out of the docs (named as `$SUPABASE_URL` / `$SUPABASE_PROJECT_REF`) and `scripts/check-no-secrets.sh` fails CI on a JWT, a key, a bearer, a project address or ref, or a Postgres URL (fleet audit I-01). Older commits still hold the address. (2026-11-14)
- `docs/STATE.md` names the `control-center` bearer and caller and the function versions, read live on 14 Nov. (2026-11-14)

## What changed recently

- 2026-11-14 NOW.md in the steward's schema with its North Star line, and AGENTS.md and CLAUDE.md added, so a new session reads true instructions first.
- 2026-11-14 Byte ranges for file links (I-07); the database address out of the docs and a CI guard (I-01).

## What is next and what is waiting on Krish

- Next (2026-11-14): Krish retests the phone-check link on Android and an iPhone and the result goes into `docs/STATE.md`.
- Then: mock the recipient click-through page (branded per venture, password form, read receipts) for Krish's approval; it also stops mail scanners counting as opens.
- Waiting on Krish (fleet decisions, batch 2): narrowing Control Center's bearer to the ventures it uses and revoking the unused n8n bearer; the expired upload sweep; making `skill-deliveries` private; making `main` the default branch.
- North Star check (2026-11-14): holds.

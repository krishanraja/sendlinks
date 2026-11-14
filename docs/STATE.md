# State

The one current-truth file for SendLinks. Updated at every phase change.

Updated: 2026-11-14 (byte ranges)

## Outcome

The engine can create a link to a resource for any active venture, put it in a send, and later
read whether the recipient opened and downloaded it. Links expire, can be read-once, password
protected and revoked. Every venture's agents are told this is how things reach customers (DEL-002).

## Phase

Live on Mindmaker OS. Control Center is the main caller. Recipient page not started.

| | status | evidence |
|---|---|---|
| Schema and SQL engine | live | migrations `20261022120252_sendlinks_core`, `20261022122402_sendlinks_receipts` in history (the hand-written duplicate row was deleted on Krish's approval); 4 tables, 16 functions; anon and authenticated cannot reach the schema or the 9 wrappers |
| `sendlinks-api` v7, `sendlinks-open` v6 | live, verify_jwt off | api deployed 2026-10-22 from this code; open redeployed 2026-11-14 for byte ranges (the live v5 source matched this repository's code before it, read through the Management API); live canary 2026-10-22: 20/20 JSON creates and 10/10 uploads 201 (slowest 5.1 s cold); read-once text 200 then 410; unfurler preview spends nothing; uploaded file streams back byte-identical; content-library file 2,055,849 bytes in 1.9 s |
| Byte ranges (phone video playback and seeking) | live 2026-11-14: migration applied, `sendlinks-open` v6 | migration `20261114123717_sendlinks_ranges` (`continue_link`, `record_range_download`); the open route answers `206` with `Content-Range` and `Accept-Ranges: bytes`. Before it, every request got `200` and the whole file, so seeking failed and iPhone Safari was expected not to play an mp4 inline (code reading, 2026-11-14). Local tests: 10 SQL suites, 23 HTTP steps, including a continuation from another IP or agent refused and read-once and password links unchanged; three mutations each fail the suite. Live phone check not run: it needs a canary bearer, and minting one is a wall |
| Receipts | live | canary link: opened and downloaded recorded, events `created`, `opened`, `downloaded` |
| Receipt webhooks | live | pg_net delivered 4 POSTs for 2 canary links (open and download each) |
| `sendlinks` bucket | live | private, 26214400 byte limit |
| Bearers | `n8n` and `control-center`, both all ventures (`ventures` null) | `n8n`: in Vault as `sendlinks_n8n_bearer`; proven by creating and revoking a Pulse link. `control-center`: minted 2026-10-23, used by Control Center as `SENDLINKS_BEARER`; made its first file links 2026-11-13, last used 2026-11-14 (`sendlinks.clients`, read 2026-11-14). Canary bearers revoked |
| Control Center caller | live | `api/_sendLinks.ts` creates asset links for growth-mindmake emails (venture `mindmake`); the harness connector tools `make_send_link` and `read_send_link` (`api/harness/_sendlinks-mcp.ts`) mint a file link and read its opens back. Same routes, fields and bearer as `sendlinks-api` |
| n8n credential | live | `SendLinks` (httpHeaderAuth, id `SNBwrviRkkamYMfN`), restricted to the project's own host (`$SUPABASE_URL`); bearer copied Vault to n8n without leaving the shell; listed back through the n8n MCP |
| DEL-002 standard | active in `standards_registry`, scope all, pre-check | inferred: reaches agents in the next nightly digest (renderer `regenerate-standards-digest.py` on the VPS, not readable from here) |
| Local tests | pass | `tests/run-local.sh`: 9 SQL suites, 20 HTTP steps; `deno check` and `deno lint` clean |
| Live phone check of an mp4 link (inline playback, seeking, time to first frame) | not run | needs a link minted by an existing caller; no new bearer is made for it |
| Recipient page (branded, password form, read receipts) | not started | material surface: mock first (D5) |
| Expired upload sweep | not started | uploads are kept until a sweep exists |

## Live facts (read 2026-10-22)

- Project "Mindmaker OS" (`$SUPABASE_PROJECT_REF`), Postgres 17.
- Active ventures: circle, full-time, heartside, legibility, mindmake, mm-ctrl, publication, pulse,
  signal-noise.
- The edge runtime's direct Postgres connections hung on about one request in three; the functions
  use PostgREST instead (D7).
- `skill-deliveries` is a public bucket whose zip links never expire: the first flow to move.

## Open items

1. Rotate the n8n API key that was pasted into chat on 2026-10-22 (n8n Settings, API). It created
   the `SendLinks` credential and is no longer needed by SendLinks; the credential keeps working
   after rotation.
2. Control Center's bearer is all ventures, while its code files every link under `mindmake`
   (`api/_sendLinks.ts:33`). Narrowing it is a permission change and needs Krish's yes:
   `update sendlinks.clients set ventures = '{mindmake}' where name = 'control-center'`, then one
   `make_send_link` call to read it back.
3. File links minted by `make_send_link` are not written to `growth_asset_links`, so Control
   Center's 30-minute asset read does not pick up their opens; `read_send_link` reads them on
   demand. The fix lives in `krishanraja/control-center` (audit finding lane5-1, 2026-11-14).
4. Expired upload sweep and moving `skill-deliveries` behind SendLinks: each deletes files or
   changes a bucket's permission, so each needs Krish's yes.

Control Center documents this service in its own `docs/app/tools/links.md`; the architecture-doc
item from 2026-10-22 is closed by that page.

## Next action

Mock the recipient page (branded per venture, click-through so scanners cannot spend read-once
links, password form, read receipts) for Krish's approval.

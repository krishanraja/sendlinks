# State

The one current-truth file for SendLinks. Updated at every phase change.

Updated: 2026-11-14 (wave S3: sent marks, sweep, recipient mock, phone link)

## Outcome

The engine can create a link to a resource for any active venture, put it in a send, and later
read whether the recipient opened and downloaded it. Links expire, can be read-once, password
protected and revoked. Every venture's agents are told this is how things reach customers (DEL-002).

## Phase

Live on Mindmaker OS. Control Center is the main caller. Recipient page: mock waiting on Krish (PR #9).

| | status | evidence |
|---|---|---|
| Schema and SQL engine | live | migrations `20261022120252_sendlinks_core`, `20261022122402_sendlinks_receipts` in history (the hand-written duplicate row was deleted on Krish's approval); 4 tables, 18 functions since `20261114123717_sendlinks_ranges` (16 before it); anon and authenticated cannot reach the schema or the 11 wrappers (read live on 2026-11-14) |
| `sendlinks-api` v9, `sendlinks-open` v6 | live, verify_jwt off | api v9 deployed 2026-11-14 for the sent route (v8, the 2026-10-22 code, is the rollback; its source was read before the deploy); v9 source read back through the Management API and answers 401 without a bearer; open redeployed 2026-11-14 for byte ranges (the live v5 source matched this repository's code before it, read through the Management API); live canary 2026-10-22: 20/20 JSON creates and 10/10 uploads 201 (slowest 5.1 s cold); read-once text 200 then 410; unfurler preview spends nothing; uploaded file streams back byte-identical; content-library file 2,055,849 bytes in 1.9 s |
| Byte ranges (phone video playback and seeking) | live 2026-11-14: migration applied, `sendlinks-open` v6 | migration `20261114123717_sendlinks_ranges` (`continue_link`, `record_range_download`); the open route answers `206` with `Content-Range` and `Accept-Ranges: bytes`. Before it, every request got `200` and the whole file, so seeking failed and iPhone Safari was expected not to play an mp4 inline (code reading, 2026-11-14). Local tests: 10 SQL suites, 23 HTTP steps, including a continuation from another IP or agent refused and read-once and password links unchanged; three mutations each fail the suite. Live phone check not run: it needs a canary bearer, and minting one is a wall |
| Receipts | live | canary link: opened and downloaded recorded, events `created`, `opened`, `downloaded` |
| Receipt webhooks | live | pg_net delivered 4 POSTs for 2 canary links (open and download each) |
| `sendlinks` bucket | live | private, 26214400 byte limit |
| Sent marks: a link's life counts from the send (I-28, D19) | live 2026-11-14 | migration `20261114171820_sendlinks_sent` in history (19 functions, 12 wrappers, none open to anon or signed-in users, read live); `POST /links/{id}/sent`, first call wins, dead links stay dead. Local tests: 11 SQL blocks, 24 HTTP steps; a mutation dropping the first-call guard fails the suite (PR #7). The Control Center half (marking sends from the push's SendLinks step) is not built: control-center could not be attached to this session |
| Bearers | `n8n` and `control-center`, both all ventures (`ventures` null) | `n8n`: in Vault as `sendlinks_n8n_bearer`; proven by creating and revoking a Pulse link. `control-center`: minted 2026-10-23, used by Control Center as `SENDLINKS_BEARER`; made its first file links 2026-11-13, last used 2026-11-14 (`sendlinks.clients`, read 2026-11-14). Canary bearers revoked |
| Control Center caller | live | `api/_sendLinks.ts` creates asset links for growth-mindmake emails (venture `mindmake`); the harness connector tools `make_send_link` and `read_send_link` (`api/harness/_sendlinks-mcp.ts`) mint a file link and read its opens back. Same routes, fields and bearer as `sendlinks-api` |
| n8n credential | live | `SendLinks` (httpHeaderAuth, id `SNBwrviRkkamYMfN`), restricted to the project's own host (`$SUPABASE_URL`); bearer copied Vault to n8n without leaving the shell; listed back through the n8n MCP |
| DEL-002 standard | active in `standards_registry`, scope all, pre-check | inferred: reaches agents in the next nightly digest (renderer `regenerate-standards-digest.py` on the VPS, not readable from here) |
| Local tests | pass | `tests/run-local.sh`: 10 SQL suites, 23 HTTP steps since the byte ranges (9 and 20 before); `deno check` and `deno lint` clean |
| Live phone check of an mp4 link (inline playback, seeking, time to first frame) | waiting on Krish's phones | link minted 2026-11-14 through Control Center's `make_send_link` (link `2b99f43a-133b-4cb7-943d-89cfc2a35557`, Mindmake, a 1,589,435 byte mp4 from his Drive, no view limit or password so ranges apply, open until 2026-11-21); state active, 0 views, a HEAD preview answers 200. Result: iPhone not yet, Android not yet |
| Recipient page (branded, password form, read receipts) | mock waiting on Krish (I-29, D20) | `web/mock/recipient-page.html`, Mindmake only, light and dark, states ready, password and closed; six renders in `web/mock/renders/` (PR #9). Not deployed, not wired |
| Expired upload sweep (2.6) | built, not applied | `sendlinks.sweep_expired_uploads(p_dry_run default true)` and tests (PR #8). Applying it stopped: the Supabase connector asked a confirmation question that got no answer. Read-only dry run with the same rule (2026-11-14): 18 of 21 objects in `sendlinks`, 614 bytes, all from the 2026-10-22 canary; kept: the two one-pager PDFs and the phone-check video. Nothing deleted |

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
2. Control Center's bearer is all ventures. Ready to narrow, not done (it is a permission change
   and this session could not read Krish's written yes): every link it has made is `mindmake`
   (5 links, read 2026-11-14), so `update sendlinks.clients set ventures = '{mindmake}' where name
   = 'control-center'` matches what it mints today; read back with one `make_send_link` call.
3. The `n8n` bearer is unused: last used 2026-10-22 (the Pulse proof link, its only link), and
   `authenticate` stamps `last_used_at` on every call, so no workflow has called SendLinks with it
   since. Ready to revoke, not done (revoking a bearer needs Krish's yes):
   `update sendlinks.clients set revoked_at = now() where name = 'n8n'`. The n8n credential
   `SendLinks` then stops working and can be deleted in n8n.
4. File links minted by `make_send_link` are not written to `growth_asset_links`, so Control
   Center's 30-minute asset read does not pick up their opens; `read_send_link` reads them on
   demand. The fix lives in `krishanraja/control-center` (audit finding lane5-1, 2026-11-14).
5. `skill-deliveries` is still public, and making it private would break plain URLs that are still
   handed out: `public.skill_deliveries.zip_url` holds the 3 zips' public URLs (6 rows, the last
   written 2026-05-11, no reads in the last 24 hours of logs). The code that writes and shows
   them is not in this repository or the Mindmaker OS functions, so moving them behind SendLinks
   is more than a small change: find that writer, have it mint a SendLinks link instead of
   storing a public URL, reissue the 3 existing zips as links, then make the bucket private.
6. The expired upload sweep (PR #8) is built and waits to be applied; the real run deletes 18
   canary files through the Storage API and needs Krish's yes at the time.

Control Center documents this service in its own `docs/app/tools/links.md`; the architecture-doc
item from 2026-10-22 is closed by that page.

## Next action

Krish opens the phone-check link on an iPhone and an Android (inline playback, seeking, time to
first frame) and the result goes in the table above. Then his verdict on the recipient page mock
(PR #9). `NOW.md` carries the same order.

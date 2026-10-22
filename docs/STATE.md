# State

The one current-truth file for SendLinks. Updated at every phase change.

Updated: 2026-10-22

## Outcome

The engine can create a link to a resource for any active venture, put it in a send, and later
read whether the recipient opened and downloaded it. Links expire, can be read-once, password
protected and revoked. Every venture's agents are told this is how things reach customers (DEL-002).

## Phase

Live on Mindmaker OS. Recipient page not started.

| | status | evidence |
|---|---|---|
| Schema and SQL engine | live | migrations `20261022120252_sendlinks_core`, `20261022122402_sendlinks_receipts` in history; 4 tables, 16 functions; anon and authenticated cannot reach the schema or the 9 wrappers |
| `sendlinks-api` v6, `sendlinks-open` v3 | live, verify_jwt off | live canary 2026-10-22: 20/20 JSON creates and 10/10 uploads 201 (slowest 5.1 s cold); read-once text 200 then 410; unfurler preview spends nothing; uploaded file streams back byte-identical; content-library file 2,055,849 bytes in 1.9 s |
| Receipts | live | canary link: opened and downloaded recorded, events `created`, `opened`, `downloaded` |
| Receipt webhooks | live | pg_net delivered 4 POSTs for 2 canary links (open and download each) |
| `sendlinks` bucket | live | private, 26214400 byte limit |
| Bearers | `n8n`, all ventures | in Vault as `sendlinks_n8n_bearer`; proven by creating and revoking a Pulse link. Canary bearers revoked |
| DEL-002 standard | active in `standards_registry`, scope all, pre-check | inferred: reaches agents in the next nightly digest (renderer `regenerate-standards-digest.py` on the VPS, not readable from here) |
| Local tests | pass | `tests/run-local.sh`: 9 SQL suites, 20 HTTP steps; `deno check` and `deno lint` clean |
| Recipient page (branded, password form, read receipts) | not started | material surface: mock first (D5) |
| Expired upload sweep | not started | uploads are kept until a sweep exists |

## Live facts (read 2026-10-22)

- Project `gojpffsrxybbpbdzzrvs` "Mindmaker OS", Postgres 17.
- Active ventures: circle, full-time, heartside, legibility, mindmake, mm-ctrl, publication, pulse,
  signal-noise.
- The edge runtime's direct Postgres connections hung on about one request in three; the functions
  use PostgREST instead (D7).
- `skill-deliveries` is a public bucket whose zip links never expire: the first flow to move.

## Open items

1. Copy the Vault bearer into an n8n Header Auth credential named `SendLinks` (the n8n REST API
   refused this session's injected credential, so it could not be created from here).
2. Approve deleting the duplicate migration history row `20261022120000 sendlinks_core` (written
   by hand before the endpoint was found to record its own row; harmless, but two rows claim one
   migration).
3. Architecture doc entry in `krishanraja/control-center` (`## 4` table list, `## 20` changelog)
   by pull request.

## Next action

Mock the recipient page (branded per venture, click-through so scanners cannot spend read-once
links, password form, read receipts) for Krish's approval.

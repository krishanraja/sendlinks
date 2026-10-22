# SendLinks

Expiring, revocable, view-limited links to resources, created by the Mindmake engine for any
venture and opened by the person it was meant for. Modelled on Bitwarden Send (text, file or url;
expiry; max views; optional password; revoke), rebuilt lean on the Mindmaker OS Supabase project.

The engine (n8n, Control Center, agents) asks for a link, puts it in whatever it is sending, and
can later ask whether it was opened. Sending the message itself stays with the existing send lanes
and their approvals; SendLinks never emails anyone.

## What it guarantees

- A link is a 43 character random token. Only its SHA-256 is stored, so a database read cannot
  produce a working link.
- Every link expires: 7 days by default, 90 days at most.
- Files stay in private buckets and stream through SendLinks itself, so no Storage URL ever
  reaches the recipient and the last byte leaving is what writes the download receipt. PDFs,
  images, plain text, mp4 and mp3 open in the browser; anything else downloads, sandboxed.
- Optional `max_views` (1 means read once), optional password (bcrypt, locks after 10 wrong tries).
- Chat unfurlers and scanners that name themselves (Slack, LinkedIn, WhatsApp, Googlebot, `HEAD`,
  curl) see the title only and never spend a view. Mail scanners that pose as browsers (Outlook
  Safe Links, Proofpoint, Mimecast) do spend views and can see the content, so do not email a
  `max_views: 1` link until the recipient page with a click-through exists.
- If the content cannot be handed over (Storage error), the view is given back and the
  recipient gets a 503 to retry.
- Every open, denial and preview is written to an append-only event log. IPs are kept only as a
  hash salted with the token, so one visitor cannot be followed across links.
- It is not end-to-end encrypted, unlike Bitwarden Send: the engine holds the content, so the
  protection is the token, private storage and expiry.

## API

Base: `https://gojpffsrxybbpbdzzrvs.supabase.co/functions/v1/sendlinks-api`
Auth: `Authorization: Bearer sl_...` (one bearer per caller, see docs/DEPLOY.md).

### Create a link: `POST /links`

JSON body:

| field | | |
|---|---|---|
| `venture` | required | an active `public.ventures.id`, e.g. `mindmake`, `pulse`, `heartside` |
| `kind` | required | `url`, `text` or `file` |
| `title` | required | shown to the recipient and to unfurlers, up to 200 chars |
| `url` | for `url` | https only |
| `text` | for `text` | up to 100,000 chars |
| `bucket`, `path` | for `file` | an object that already exists in an allowed bucket: `content-library`, or `sendlinks` under this venture's prefix |
| `file_name` | | download name, defaults to the last path segment; characters outside `A-Z a-z 0-9 space . _ ( ) -` become `-` |
| `message` | | short note shown with text links |
| `recipient_email`, `recipient_name` | | who it is for, so opens can be read back per person |
| `purpose` | | e.g. `lead-magnet`, `client-delivery`, `workshop-pack` |
| `ref` | | your idempotency key, unique per caller |
| `on_duplicate` | | `error` (default, 409) or `reissue`: new token on the existing link, old token stops working; a link that is no longer active is not reissued (409 `link_inactive`) |
| `expires_in_hours` or `expires_at` | | default 168 hours, max 90 days |
| `max_views` | | 1 to 100,000 |
| `password` | | recipient must POST it (see below) |
| `metadata` | | any JSON you want back later |

To upload instead, send `multipart/form-data` with a `file` part (up to 25 MB) and a `meta` part
holding the same JSON minus `kind`, `bucket` and `path`. The file goes to the private `sendlinks`
bucket under `<venture>/<yyyy-mm>/<uuid>/`.

Response `201` (or `200` on reissue):

```json
{ "ok": true, "link_id": "8f0c...", "url": "https://.../sendlinks-open/Qm9...", "expires_at": "...", "state": "active", "reissued": false }
```

Errors: `401 unauthorized`, `409 duplicate_ref | link_inactive`, `400 unknown_venture | venture_not_allowed |
bucket_not_allowed | object_not_found | bad_expiry | invalid`, `413 file_size`.

### Read a link: `GET /links/{link_id}`

State (`active`, `expired`, `revoked`, `exhausted`, `locked`), receipts, and the latest 50 events.
A caller only ever sees its own links.

```json
"receipts": {
  "opened": true,  "first_opened_at": "...", "last_opened_at": "...", "opens": 2,
  "downloaded": true, "first_downloaded_at": "...", "last_downloaded_at": "...", "downloads": 1,
  "previews": 3, "denied": 0
}
```

- **Open receipt**: the recipient opened the link (unfurlers and named scanners excluded).
- **Download receipt**: every byte of the file reached them. A tab closed mid-file is logged as
  `download_incomplete` and does not count.
- **Read receipt**: not yet. Knowing they actually spent time on it needs the recipient page,
  which will report time on page; until then `opened` plus `downloaded` is the signal.

### List links with receipts: `GET /links`

Query: `venture`, `recipient_email`, `purpose`, `since` (ISO time), `opened` (`true`/`false`),
`limit` (max 200). Newest first. `GET /links?purpose=proposal&opened=false` is the follow-up list.

### Receipt webhook: `PUT /webhook` with `{"url": "https://...", "secret": "16+ chars"}`

Every open, download, incomplete download and refusal on this caller's links is POSTed to the URL
as JSON (`type: sendlinks.receipt`, `event`, `link_id`, `ref`, `recipient_email`, `receipts`, ...)
with header `X-SendLinks-Secret: <secret>`, so an n8n Webhook node with Header Auth can check it.
`DELETE /webhook` stops it. Delivery is fire and forget through pg_net; the stored receipts
are the record.

### Revoke: `POST /links/{link_id}/revoke` with `{"reason": "..."}`

## Opening a link

`GET {url}`: a url link redirects to its target, a file link streams the file, a text link
returns plain text. `POST {url}` with `{"password": "..."}` streams a file link and returns JSON
(`kind`, `title`, `url` or `text`) for the others; password links need this until the recipient
page exists. Refusals: `404` unknown, `410` expired, withdrawn or used up, `401` password needed,
`403` wrong password, `423` locked, `503` try again (view refunded).

## From n8n

The n8n bearer (all ventures) is in Supabase Vault as `sendlinks_n8n_bearer` and already in n8n as
the **Header Auth** credential `SendLinks`, which only sends to the SendLinks domain. Select that
credential on an HTTP Request node, `POST`, URL as above, JSON body:

```json
{
  "venture": "mindmake",
  "kind": "file",
  "title": "AI readiness guide",
  "bucket": "content-library",
  "path": "guides/ai-readiness.pdf",
  "recipient_email": "{{ $json.email }}",
  "purpose": "lead-magnet",
  "ref": "lead-magnet:{{ $json.lead_id }}",
  "on_duplicate": "reissue",
  "expires_in_hours": 336
}
```

Use `{{ $json.url }}` from the response in the email draft. A `ref` per send makes retries safe.

## Develop

`tests/run-local.sh` builds a throwaway Postgres database with the Supabase pieces the migration
needs, applies `supabase/migrations/`, runs the SQL tests, then drives both HTTP handlers against
it with a fake Storage. Needs `psql`, a local Postgres and Deno.

```
supabase/migrations/   schema and the SQL engine (all rules live here)
supabase/functions/    sendlinks-api, sendlinks-open, _shared (HTTP layer, wiring, tests)
tests/                 local harness and SQL tests
docs/                  STATE.md (current truth), DECISIONS.md, DEPLOY.md
```

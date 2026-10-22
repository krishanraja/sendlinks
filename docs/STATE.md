# State

The one current-truth file for SendLinks. Updated at every phase change.

Updated: 2026-10-22

## Outcome

The engine can create a link to a resource for any active venture, put it in a send, and later
read whether the recipient opened it. Links expire, can be read-once, password protected and
revoked.

## Phase

Engine slice built and tested locally. Nothing is deployed.

| | status | evidence |
|---|---|---|
| Schema and SQL engine | built, tested locally | `tests/run-local.sh`: 8 SQL suites pass |
| `sendlinks-api`, `sendlinks-open` | built, tested locally | 16 HTTP steps pass against the same database; `deno check` clean |
| Independent review | done, 7 findings fixed | D6; one regression test per finding |
| Migration on Mindmaker OS | not applied | needs approval, docs/DEPLOY.md step 1 |
| `sendlinks` bucket | not created | step 2 |
| Functions deployed | no | step 3 |
| Bearers minted | none | step 4 |
| Recipient page (branded, password form) | not started | material surface: mock first (D5) |
| Expired upload sweep | not started | uploads are kept until a sweep exists |

## Live facts this was built against (read 2026-10-22)

- Project `gojpffsrxybbpbdzzrvs` "Mindmaker OS", Postgres 17, database 750 MB.
- `public.ventures.id` is text; active: circle, full-time, heartside, legibility, mindmake, mm-ctrl,
  publication, pulse, signal-noise.
- `postgres` has BYPASSRLS and SELECT on `storage.objects`, so file links resolve when deployed.
- Private buckets include `content-library`; `skill-deliveries` is public and its zip links never
  expire. That flow is the first candidate to move onto SendLinks.

## Open approvals

1. Apply the migration, create the bucket and deploy both functions on Mindmaker OS (DEPLOY.md 1 to 3).
2. Which callers get bearers, and for which ventures (DEPLOY.md 4).

## Next action

Krish approves DEPLOY.md steps 1 to 3; then run the step 5 canary and record its readback here.

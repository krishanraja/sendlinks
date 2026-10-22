# Decisions

Append only. Newest at the bottom.

## D1 2026-10-22: Lean rebuild of Send, not the Bitwarden server

The Drive folder `sendlinks` is an unmodified copy of `bitwarden/server` (C#, SQL Server, about
fifteen services). Krish chose a lean SendLinks app on the existing Mindmaker OS Supabase project,
as part of the engine that sends resources for the ventures. Rejected: mirroring the whole
codebase (AGPL plus the restricted `bitwarden_license` tree, trademark rules, none of it fits the
stack) and extracting the Send module in .NET. No Bitwarden code or marks are used.

## D2 2026-10-22: No end-to-end encryption

Bitwarden Send encrypts in the sender's client and keeps the key in the URL fragment. Here the
sender is the engine, which already holds the plaintext, so client-side encryption would protect
nothing. Protection is an unguessable token stored only as a hash, private buckets, 60 second
signed URLs, expiry and view limits. Revisit if a human ever sends secrets through it directly.

## D3 2026-10-22: Own schema, rules in SQL, functions over SUPABASE_DB_URL

Follows the `lozatron` and `compound` pattern. Every rule (validation, scoping, idempotency, view
counting, password lockout) is a `sendlinks.*` SQL function, so it is testable in plain Postgres
and atomic under `for update`. The edge functions connect over `SUPABASE_DB_URL`, so the schema
is never added to the PostgREST exposed schemas and the anon key cannot reach it.

## D4 2026-10-22: Idempotency by ref, recovery by reissue

Tokens cannot be recovered from their hash. A caller that loses a response retries with the same
`ref` and `on_duplicate: reissue`, which rotates the token on the same link and keeps its history.

## D5 2026-10-22: No recipient page in the first slice

Supabase serves function responses as plain text on its own domain, so a branded page needs
Vercel, and it is a material visual surface that needs a rendered mock and Krish's approval first.
The first slice therefore redirects url and file links straight to their target, returns text
links as plain text, and takes passwords by POST. Previews never spend views, which keeps scanners
from burning read-once links that announce themselves.

## D6 2026-10-22: Fixes from the independent review

No critical findings. Fixed: a view spent before delivery failed (IDN urls are stored punycoded;
a Storage error refunds the view and returns 503); uploads are scoped to their venture's prefix;
the unfurler pattern no longer catches phones like Cubot; a ref race returns 409 instead of 500;
dead links are not reissued and reissued uploads are removed; download names are restricted to a
safe character set; error details no longer expose constraint names. Accepted risk: mail
scanners posing as browsers spend views until the recipient page adds a click-through (D5).

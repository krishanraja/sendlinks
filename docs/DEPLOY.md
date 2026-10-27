# Deploy runbook

Target: Supabase project `gojpffsrxybbpbdzzrvs` (Mindmaker OS, us-west-2). Each step below is a
separate production action and needs Krish's approval at the time it runs.

Status: steps 1 to 5 done on 2026-10-22 (docs/STATE.md has the readback).

## 1. Apply the migrations

Apply `supabase/migrations/*.sql` in order through the Management API migrations endpoint
(`POST /v1/projects/{ref}/database/migrations`, which records history itself) or `supabase db push`.
`sendlinks_core` creates the `sendlinks` schema. `sendlinks_receipts` adds receipts, webhooks and
nine `public.sendlinks_*` wrappers that only the service role can execute. Neither writes the
storage schema.

Readback:

```sql
select count(*) from information_schema.tables where table_schema = 'sendlinks';      -- 4
select count(*) from pg_proc where pronamespace = 'sendlinks'::regnamespace;          -- 16
select count(*) from pg_proc p where pronamespace = 'public'::regnamespace and proname like 'sendlinks\_%'
   and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'));  -- 0
select has_schema_privilege('anon', 'sendlinks', 'usage');                            -- false
```

## 2. Create the private bucket

Storage API or dashboard: bucket `sendlinks`, public off, file size limit 26214400 bytes.
Readback: `select id, public, file_size_limit from storage.buckets where id = 'sendlinks';`

## 3. Deploy the two functions without gateway JWT checks

Each function ships its `index.ts` plus `supabase/functions/_shared/sendlinks.ts` and
`supabase/functions/_shared/runtime.ts` (never `supabase/functions/_shared/pg_db_test_only.ts`,
which only the local tests import).

Both authenticate themselves (`sendlinks-api` by bearer hash, `sendlinks-open` is public by design).

```
supabase functions deploy sendlinks-api  --project-ref gojpffsrxybbpbdzzrvs --no-verify-jwt
supabase functions deploy sendlinks-open --project-ref gojpffsrxybbpbdzzrvs --no-verify-jwt
```

They use the platform-injected `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`, and reach the
database only through PostgREST (D7).
Optional secret `SENDLINKS_PUBLIC_BASE` once a short domain fronts `sendlinks-open`.

## 4. Mint a bearer per caller

Done for n8n (all ventures), written straight into Vault so it never left the database:
`select vault.create_secret(sendlinks.mint_client('n8n', null), 'sendlinks_n8n_bearer', '...')`.
Read it in the SQL editor with
`select decrypted_secret from vault.decrypted_secrets where name = 'sendlinks_n8n_bearer'`.

For another caller, one per caller, scoped to the ventures it may send for:

```sql
select sendlinks.mint_client('vps-agents', null);                -- any active venture
select sendlinks.mint_client('control-center', array['mindmake']);
```

The bearer is shown once. Put it straight into that caller's secret store (n8n credential,
Vercel env). Revoke with `update sendlinks.clients set revoked_at = now() where name = '...'`.

## 5. Canary

With a canary bearer: create a `text` link with `max_views: 1`, open it once (200; from curl pass a
browser `-A` user agent or use POST, since curl counts as a preview), open it again
(410), read `GET /links/{id}` (state `exhausted`, events `created`, `opened`, `denied_exhausted`),
create one `content-library` file link and open it (200, the file streams through `sendlinks-open`
and a `downloaded` event is written once the last byte has gone; no Storage URL reaches the
caller), then revoke the canary client.

## Rollback

Functions: `supabase functions delete sendlinks-api` and `sendlinks-open` (nothing else calls them).
Database: `drop schema sendlinks cascade;` removes everything this migration created and nothing
else. Bucket: empty and delete `sendlinks` through the Storage API. Each of these is a deletion and
needs its own approval.

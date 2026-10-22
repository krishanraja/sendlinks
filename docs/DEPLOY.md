# Deploy runbook

Target: Supabase project `gojpffsrxybbpbdzzrvs` (Mindmaker OS, us-west-2). Each step below is a
separate production action and needs Krish's approval at the time it runs.

## 1. Apply the migration

Apply `supabase/migrations/20261022120000_sendlinks_core.sql` (MCP `apply_migration`, name
`sendlinks_core`, or `supabase db push`). It only creates the `sendlinks` schema, its tables and
functions, and the pgcrypto extension if missing. It reads `public.ventures` and `storage.objects`
and writes nothing outside `sendlinks`.

Readback:

```sql
select count(*) from information_schema.tables where table_schema = 'sendlinks';      -- 4
select count(*) from pg_proc where pronamespace = 'sendlinks'::regnamespace;          -- 10
select has_schema_privilege('anon', 'sendlinks', 'usage');                            -- false
```

## 2. Create the private bucket

Storage API or dashboard: bucket `sendlinks`, public off, file size limit 26214400 bytes.
Readback: `select id, public, file_size_limit from storage.buckets where id = 'sendlinks';`

## 3. Deploy the two functions without gateway JWT checks

Both authenticate themselves (`sendlinks-api` by bearer hash, `sendlinks-open` is public by design).

```
supabase functions deploy sendlinks-api  --project-ref gojpffsrxybbpbdzzrvs --no-verify-jwt
supabase functions deploy sendlinks-open --project-ref gojpffsrxybbpbdzzrvs --no-verify-jwt
```

They use the platform-injected `SUPABASE_URL`, `SUPABASE_DB_URL` and `SUPABASE_SERVICE_ROLE_KEY`.
Optional secret `SENDLINKS_PUBLIC_BASE` once a short domain fronts `sendlinks-open`.

## 4. Mint a bearer per caller

In the SQL editor, one per caller, scoped to the ventures it may send for:

```sql
select sendlinks.mint_client('n8n', null);                       -- any active venture
select sendlinks.mint_client('control-center', array['mindmake']);
```

The bearer is shown once. Put it straight into that caller's secret store (n8n credential,
Vercel env). Revoke with `update sendlinks.clients set revoked_at = now() where name = '...'`.

## 5. Canary

With a canary bearer: create a `text` link with `max_views: 1`, open it once (200), open it again
(410), read `GET /links/{id}` (state `exhausted`, events `created`, `opened`, `denied_exhausted`),
then revoke the canary client.

## Rollback

Functions: `supabase functions delete sendlinks-api` and `sendlinks-open` (nothing else calls them).
Database: `drop schema sendlinks cascade;` removes everything this migration created and nothing
else. Bucket: empty and delete `sendlinks` through the Storage API. Each of these is a deletion and
needs its own approval.

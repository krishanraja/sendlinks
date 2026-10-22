-- The slice of a Supabase project the SendLinks migration depends on, for a plain local Postgres.
-- Roles are cluster wide, so they survive the database being dropped between runs.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin bypassrls; end if;
end $$;
create schema extensions;
create schema storage;
create table storage.objects (
  id        uuid primary key default gen_random_uuid(),
  bucket_id text not null,
  name      text not null,
  metadata  jsonb,
  unique (bucket_id, name)
);
create table public.ventures (id text primary key, name text, status text);
insert into public.ventures values
  ('mindmake', 'Mindmake', 'active'),
  ('pulse', 'Pulse', 'active'),
  ('ops', 'Operations', 'archived');
insert into storage.objects (bucket_id, name, metadata) values
  ('content-library', 'guides/ai-readiness.pdf', '{"size": 48213, "mimetype": "application/pdf"}'),
  ('private-stuff', 'secret.txt', '{"size": 10, "mimetype": "text/plain"}');

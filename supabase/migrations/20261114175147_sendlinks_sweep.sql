-- The expired upload sweep (fleet decision 2.6).
--
-- Uploads made through the API sit in the private 'sendlinks' bucket after their links die.
-- sendlinks.sweep_expired_uploads picks the objects in that bucket whose every link has an
-- expiry in the past (revoked links included, once their expiry has passed too). It never
-- looks at another bucket, and an object with no link at all is left alone.
--
-- Dry run (the default) only lists. The real run records the sweep on each of the object's
-- links (links.swept_at and one 'upload_swept' event per link) and returns the paths. SQL
-- cannot delete Storage objects on Supabase (storage.protect_delete), so the operator removes
-- the returned paths through the Storage API and then reruns the dry run, which must list
-- nothing. A path that was not removed is listed again; its links are not recorded twice.
-- Service role only: no public wrapper, the operator runs it from SQL.

alter table sendlinks.links add column swept_at timestamptz;

alter table sendlinks.events drop constraint events_kind_check;
alter table sendlinks.events add constraint events_kind_check check (kind in (
  'created', 'reissued', 'opened', 'previewed', 'revoked',
  'denied_expired', 'denied_revoked', 'denied_exhausted',
  'denied_password', 'denied_locked', 'password_required', 'delivery_failed',
  'downloaded', 'download_incomplete', 'sent', 'upload_swept'));

create function sendlinks.sweep_expired_uploads(p_dry_run boolean default true) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_paths  jsonb;
  v_count  int;
  v_bytes  bigint;
begin
  create temp table if not exists pg_temp.sweep_pick (path text primary key, bytes bigint) on commit drop;
  truncate pg_temp.sweep_pick;

  insert into pg_temp.sweep_pick (path, bytes)
  select o.name, coalesce((o.metadata->>'size')::bigint, 0)
    from storage.objects o
   where o.bucket_id = 'sendlinks'
     and exists (select 1 from sendlinks.links l
                  where l.storage_bucket = 'sendlinks' and l.storage_path = o.name)
     and not exists (select 1 from sendlinks.links l
                      where l.storage_bucket = 'sendlinks' and l.storage_path = o.name
                        and l.expires_at > now());

  select coalesce(jsonb_agg(path order by path), '[]'::jsonb), count(*), coalesce(sum(bytes), 0)
    into v_paths, v_count, v_bytes
    from pg_temp.sweep_pick;

  if not p_dry_run then
    with marked as (
      update sendlinks.links l
         set swept_at = now()
       where l.storage_bucket = 'sendlinks'
         and l.swept_at is null
         and l.storage_path in (select path from pg_temp.sweep_pick)
      returning l.id, l.storage_path
    )
    insert into sendlinks.events (link_id, kind, detail)
    select id, 'upload_swept', jsonb_build_object('path', storage_path) from marked;
  end if;

  return jsonb_build_object('dry_run', p_dry_run, 'bucket', 'sendlinks',
    'count', v_count, 'bytes', v_bytes, 'paths', v_paths);
end $$;

revoke all on function sendlinks.sweep_expired_uploads(boolean) from public;
grant execute on function sendlinks.sweep_expired_uploads(boolean) to service_role;

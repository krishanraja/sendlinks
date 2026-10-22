-- SendLinks receipts, receipt webhooks, and HTTPS access for the edge functions.
--
-- Receipts. An open was already recorded. Files now stream through sendlinks-open instead of
-- redirecting to Storage, so the function sees the last byte leave and records a download
-- receipt ('downloaded', or 'download_incomplete' when the recipient stops early). A read
-- receipt (time actually spent on the content) needs the recipient page and is not here.
--
-- Webhooks. Each client may register a URL; every receipt is POSTed there by pg_net after the
-- event commits, carrying the client's secret in X-SendLinks-Secret (n8n Header Auth checks it).
--
-- HTTPS. The edge runtime's direct Postgres connections hung on about one request in three in
-- the live canary (2026-10-22), so the functions now call these SQL functions through PostgREST
-- with the service role. The public.sendlinks_* wrappers are security invoker, executable by
-- service_role only, and add no rules of their own.

-- Receipts ----------------------------------------------------------------------------------

alter table sendlinks.events drop constraint events_kind_check;
alter table sendlinks.events add constraint events_kind_check check (kind in (
  'created', 'reissued', 'opened', 'previewed', 'revoked',
  'denied_expired', 'denied_revoked', 'denied_exhausted',
  'denied_password', 'denied_locked', 'password_required', 'delivery_failed',
  'downloaded', 'download_incomplete'));

alter table sendlinks.links
  add column first_downloaded_at timestamptz,
  add column last_downloaded_at  timestamptz,
  add column download_count      integer not null default 0;

-- Called by sendlinks-open when a streamed file finishes or is cut off.
create function sendlinks.record_download(
  p_link_id    uuid,
  p_bytes      bigint,
  p_complete   boolean,
  p_ip_sha256  text default null,
  p_user_agent text default null
) returns void
language plpgsql volatile security definer set search_path = '' as $$
begin
  if p_complete then
    update sendlinks.links
       set download_count = download_count + 1,
           first_downloaded_at = coalesce(first_downloaded_at, now()),
           last_downloaded_at = now()
     where id = p_link_id;
  end if;
  insert into sendlinks.events (link_id, kind, ip_sha256, user_agent, detail)
  values (p_link_id, case when p_complete then 'downloaded' else 'download_incomplete' end,
          p_ip_sha256, left(p_user_agent, 300), jsonb_build_object('bytes', p_bytes));
end $$;

create function sendlinks.receipts(l sendlinks.links) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'opened', l.first_opened_at is not null,
    'first_opened_at', l.first_opened_at,
    'last_opened_at', l.last_opened_at,
    'opens', l.view_count,
    'downloaded', l.first_downloaded_at is not null,
    'first_downloaded_at', l.first_downloaded_at,
    'last_downloaded_at', l.last_downloaded_at,
    'downloads', l.download_count,
    'previews', (select count(*) from sendlinks.events e where e.link_id = l.id and e.kind = 'previewed'),
    'denied', (select count(*) from sendlinks.events e
                where e.link_id = l.id and (e.kind like 'denied\_%' or e.kind = 'password_required')))
$$;

create or replace function sendlinks.link_status(p_client_id uuid, p_link_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'ok', true,
    'link_id', l.id, 'venture', l.venture_id, 'kind', l.kind, 'title', l.title,
    'purpose', l.purpose, 'ref', l.ref, 'recipient_email', l.recipient_email,
    'recipient_name', l.recipient_name,
    'state', sendlinks.link_state(l), 'views', l.view_count, 'max_views', l.max_views,
    'has_password', l.password_hash is not null,
    'expires_at', l.expires_at, 'created_at', l.created_at,
    'first_opened_at', l.first_opened_at, 'last_opened_at', l.last_opened_at,
    'revoked_at', l.revoked_at,
    'receipts', sendlinks.receipts(l),
    'metadata', l.metadata,
    'events', coalesce((
      select jsonb_agg(jsonb_build_object('kind', e.kind, 'at', e.at) order by e.at desc, e.id desc)
        from (select * from sendlinks.events where link_id = l.id order by at desc, id desc limit 50) e
    ), '[]'::jsonb))
  from sendlinks.links l
  where l.id = p_link_id and l.client_id = p_client_id
$$;

-- f: venture, recipient_email, purpose, since (created_at >=), opened (true|false), limit (<= 200).
create function sendlinks.list_links(p_client_id uuid, f jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_since timestamptz;
  v_limit int;
begin
  v_since := (f->>'since')::timestamptz;
  v_limit := least(greatest(coalesce((f->>'limit')::int, 50), 1), 200);
  return jsonb_build_object('ok', true, 'links', coalesce((
    select jsonb_agg(x.j order by x.created_at desc)
      from (
        select l.created_at, jsonb_build_object(
          'link_id', l.id, 'venture', l.venture_id, 'kind', l.kind, 'title', l.title,
          'purpose', l.purpose, 'ref', l.ref, 'recipient_email', l.recipient_email,
          'state', sendlinks.link_state(l), 'created_at', l.created_at, 'expires_at', l.expires_at,
          'receipts', sendlinks.receipts(l)) as j
          from sendlinks.links l
         where l.client_id = p_client_id
           and (f->>'venture' is null or l.venture_id = f->>'venture')
           and (f->>'recipient_email' is null or l.recipient_email = lower(f->>'recipient_email'))
           and (f->>'purpose' is null or l.purpose = f->>'purpose')
           and (v_since is null or l.created_at >= v_since)
           and (f->>'opened' is null or (l.first_opened_at is not null) = (f->>'opened')::boolean)
         order by l.created_at desc
         limit v_limit
      ) x), '[]'::jsonb));
exception
  when invalid_text_representation or invalid_datetime_format or datetime_field_overflow then
    return jsonb_build_object('ok', false, 'error', 'invalid', 'detail', 'since, limit or opened is malformed');
end $$;

-- Receipt webhooks --------------------------------------------------------------------------

alter table sendlinks.clients
  add column receipt_webhook_url    text check (receipt_webhook_url ~ '^https://[!-~]+$'),
  add column receipt_webhook_secret text check (char_length(receipt_webhook_secret) between 16 and 200);
comment on column sendlinks.clients.receipt_webhook_secret is
  'Sent back verbatim in X-SendLinks-Secret so the receiver can check the call came from here. Service role only.';

create function sendlinks.set_receipt_webhook(p_client_id uuid, p_url text, p_secret text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
begin
  if p_url is not null and (p_secret is null or char_length(p_secret) < 16) then
    return jsonb_build_object('ok', false, 'error', 'invalid', 'detail', 'secret of at least 16 characters required');
  end if;
  update sendlinks.clients
     set receipt_webhook_url = p_url,
         receipt_webhook_secret = case when p_url is null then null else p_secret end
   where id = p_client_id and revoked_at is null;
  return jsonb_build_object('ok', true, 'receipt_webhook_url', p_url);
exception
  when check_violation then
    return jsonb_build_object('ok', false, 'error', 'invalid', 'detail', 'url must be https');
end $$;

-- Which events are receipts worth pushing. Created, previewed and reissued are not.
create function sendlinks.notify_receipt() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_link   sendlinks.links;
  v_client sendlinks.clients;
begin
  if new.kind not in ('opened', 'downloaded', 'download_incomplete', 'password_required',
                      'denied_password', 'denied_locked', 'denied_expired', 'denied_revoked',
                      'denied_exhausted') then
    return null;
  end if;
  select * into v_link from sendlinks.links where id = new.link_id;
  select * into v_client from sendlinks.clients where id = v_link.client_id;
  if v_client.receipt_webhook_url is null or v_client.revoked_at is not null then
    return null;
  end if;
  perform net.http_post(
    url := v_client.receipt_webhook_url,
    body := jsonb_build_object(
      'type', 'sendlinks.receipt',
      'event_id', new.id, 'event', new.kind, 'at', new.at, 'detail', new.detail,
      'link_id', v_link.id, 'venture', v_link.venture_id, 'title', v_link.title,
      'purpose', v_link.purpose, 'ref', v_link.ref,
      'recipient_email', v_link.recipient_email, 'recipient_name', v_link.recipient_name,
      'metadata', v_link.metadata,
      'receipts', sendlinks.receipts(v_link)),
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'X-SendLinks-Secret', v_client.receipt_webhook_secret),
    timeout_milliseconds := 5000);
  return null;
exception
  -- A broken webhook must never cost the recipient their open.
  when others then
    raise warning 'sendlinks receipt webhook failed for event %: %', new.id, sqlerrm;
    return null;
end $$;

create trigger events_notify_receipt after insert on sendlinks.events
  for each row execute function sendlinks.notify_receipt();

revoke all on all functions in schema sendlinks from public;
grant execute on all functions in schema sendlinks to service_role;

-- HTTPS wrappers for the edge functions -----------------------------------------------------

create function public.sendlinks_authenticate(p_bearer text) returns uuid
language sql volatile security invoker set search_path = '' as $$
  select sendlinks.authenticate(p_bearer)
$$;
create function public.sendlinks_create_link(p_client_id uuid, p jsonb) returns jsonb
language sql volatile security invoker set search_path = '' as $$
  select sendlinks.create_link(p_client_id, p)
$$;
create function public.sendlinks_link_status(p_client_id uuid, p_link_id uuid) returns jsonb
language sql stable security invoker set search_path = '' as $$
  select sendlinks.link_status(p_client_id, p_link_id)
$$;
create function public.sendlinks_list_links(p_client_id uuid, f jsonb) returns jsonb
language sql stable security invoker set search_path = '' as $$
  select sendlinks.list_links(p_client_id, f)
$$;
create function public.sendlinks_revoke_link(p_client_id uuid, p_link_id uuid, p_reason text) returns jsonb
language sql volatile security invoker set search_path = '' as $$
  select sendlinks.revoke_link(p_client_id, p_link_id, p_reason)
$$;
create function public.sendlinks_set_receipt_webhook(p_client_id uuid, p_url text, p_secret text) returns jsonb
language sql volatile security invoker set search_path = '' as $$
  select sendlinks.set_receipt_webhook(p_client_id, p_url, p_secret)
$$;
create function public.sendlinks_open_link(
  p_token text, p_password text, p_ip_sha256 text, p_user_agent text, p_consume boolean
) returns jsonb
language sql volatile security invoker set search_path = '' as $$
  select sendlinks.open_link(p_token, p_password, p_ip_sha256, p_user_agent, p_consume)
$$;
create function public.sendlinks_refund_view(p_link_id uuid, p_detail text) returns void
language sql volatile security invoker set search_path = '' as $$
  select sendlinks.refund_view(p_link_id, p_detail)
$$;
create function public.sendlinks_record_download(
  p_link_id uuid, p_bytes bigint, p_complete boolean, p_ip_sha256 text, p_user_agent text
) returns void
language sql volatile security invoker set search_path = '' as $$
  select sendlinks.record_download(p_link_id, p_bytes, p_complete, p_ip_sha256, p_user_agent)
$$;

-- Supabase grants EXECUTE on new public functions to anon and authenticated by default.
-- These must be reachable with the service role only.
do $$
declare
  f text;
begin
  for f in
    select p.oid::regprocedure::text from pg_proc p
     where p.pronamespace = 'public'::regnamespace and p.proname like 'sendlinks\_%'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;

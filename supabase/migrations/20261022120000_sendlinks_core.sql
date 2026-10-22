-- SendLinks core: expiring, revocable, view-limited links to resources, created by the engine
-- (n8n, Control Center, agents) on behalf of a venture, and opened by a recipient.
--
-- Shape follows the Bitwarden Send model (text / file / url, expiry, max views, optional
-- password, revoke) without its client-side encryption: the engine holds the plaintext, so
-- the protections here are an unguessable token, private storage and short-lived signed URLs.
--
-- Everything lives in its own schema, like lozatron and compound. Tables are service role
-- only (RLS on, no policies). The edge functions talk to these SQL functions over
-- SUPABASE_DB_URL, so the schema never has to be exposed through PostgREST.
-- This migration reads storage.objects and never writes the storage schema; the private
-- 'sendlinks' bucket is created through the Storage API (see docs/DEPLOY.md).

create extension if not exists pgcrypto with schema extensions;

create schema if not exists sendlinks;
revoke all on schema sendlinks from public;
grant usage on schema sendlinks to service_role;

-- Callers of the API. token_sha256 is the hash of the bearer; the bearer itself is shown once
-- by mint_client and never stored. ventures null means any active venture.
create table sendlinks.clients (
  id            uuid primary key default gen_random_uuid(),
  name          text not null unique check (name ~ '^[a-z0-9][a-z0-9-]{1,62}$'),
  token_sha256  text not null unique,
  ventures      text[],
  created_at    timestamptz not null default now(),
  last_used_at  timestamptz,
  revoked_at    timestamptz
);
comment on table sendlinks.clients is
  'Hashed, individually revocable bearer identities for the SendLinks API. Mint with sendlinks.mint_client; revoke by setting revoked_at.';

-- Buckets a file link may point into. Anything else is refused at create time.
create table sendlinks.allowed_buckets (
  bucket  text primary key,
  note    text not null
);
insert into sendlinks.allowed_buckets (bucket, note) values
  ('sendlinks', 'Uploads made through the SendLinks API. Private.'),
  ('content-library', 'The makeyourmindup asset library. Private.');

create table sendlinks.links (
  id                     uuid primary key default gen_random_uuid(),
  token_sha256           text not null unique,
  client_id              uuid not null references sendlinks.clients(id),
  venture_id             text not null references public.ventures(id),
  kind                   text not null check (kind in ('file', 'url', 'text')),
  title                  text not null check (char_length(title) between 1 and 200),
  message                text check (char_length(message) <= 2000),
  target_url             text check (target_url ~ '^https://[!-~]+$' and char_length(target_url) <= 2048),
  text_body              text check (char_length(text_body) <= 100000),
  storage_bucket         text references sendlinks.allowed_buckets(bucket),
  storage_path           text check (storage_path !~ '(^/|\.\.)'),
  file_name              text check (file_name ~ '^[A-Za-z0-9 ._()-]{1,255}$'),
  content_type           text,
  bytes                  bigint,
  recipient_email        text check (recipient_email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  recipient_name         text check (char_length(recipient_name) <= 200),
  purpose                text check (char_length(purpose) <= 64),
  ref                    text check (char_length(ref) <= 200),
  password_hash          text,
  max_views              integer check (max_views between 1 and 100000),
  view_count             integer not null default 0,
  failed_password_count  integer not null default 0,
  expires_at             timestamptz not null,
  revoked_at             timestamptz,
  revoked_reason         text,
  first_opened_at        timestamptz,
  last_opened_at         timestamptz,
  metadata               jsonb not null default '{}'::jsonb,
  created_at             timestamptz not null default now(),
  constraint links_kind_shape check (
    (kind = 'url'  and target_url is not null and text_body is null and storage_path is null) or
    (kind = 'text' and text_body is not null and target_url is null and storage_path is null) or
    (kind = 'file' and storage_bucket is not null and storage_path is not null and target_url is null and text_body is null)
  ),
  constraint links_ref_unique unique (client_id, ref)
);
create index links_venture_created on sendlinks.links (venture_id, created_at desc);
create index links_recipient on sendlinks.links (lower(recipient_email)) where recipient_email is not null;
comment on table sendlinks.links is
  'One row per link. Only the SHA-256 of the token is stored, so a lost token cannot be recovered, only reissued.';

-- Append only. A denied open is written too, so "did they try and fail" has an answer.
create table sendlinks.events (
  id          bigint generated always as identity primary key,
  link_id     uuid not null references sendlinks.links(id),
  kind        text not null check (kind in (
                'created', 'reissued', 'opened', 'previewed', 'revoked',
                'denied_expired', 'denied_revoked', 'denied_exhausted',
                'denied_password', 'denied_locked', 'password_required', 'delivery_failed')),
  at          timestamptz not null default now(),
  ip_sha256   text,
  user_agent  text,
  detail      jsonb not null default '{}'::jsonb
);
create index events_link_at on sendlinks.events (link_id, at desc);

create function sendlinks.events_append_only() returns trigger
language plpgsql set search_path = '' as $$
begin
  raise exception 'sendlinks.events is append only';
end $$;
create trigger events_append_only before update or delete on sendlinks.events
  for each row execute function sendlinks.events_append_only();

alter table sendlinks.clients enable row level security;
alter table sendlinks.allowed_buckets enable row level security;
alter table sendlinks.links enable row level security;
alter table sendlinks.events enable row level security;
grant select, insert, update on all tables in schema sendlinks to service_role;

-- Helpers ---------------------------------------------------------------------------------

create function sendlinks.sha256_hex(p text) returns text
language sql immutable set search_path = '' as $$
  select encode(extensions.digest(p, 'sha256'), 'hex')
$$;

create function sendlinks.new_token() returns text
language sql volatile set search_path = '' as $$
  -- 32 random bytes, base64url without padding: 43 characters.
  select translate(encode(extensions.gen_random_bytes(32), 'base64'), '+/=', '-_')
$$;

create function sendlinks.link_state(l sendlinks.links) returns text
language sql stable set search_path = '' as $$
  select case
    when l.revoked_at is not null then 'revoked'
    when l.expires_at <= now() then 'expired'
    when l.max_views is not null and l.view_count >= l.max_views then 'exhausted'
    when l.failed_password_count >= 10 then 'locked'
    else 'active'
  end
$$;

-- Admin -----------------------------------------------------------------------------------

-- Returns the bearer once. Run from the SQL editor; store the result in the caller's secret store.
create function sendlinks.mint_client(p_name text, p_ventures text[] default null) returns text
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_token text := 'sl_' || sendlinks.new_token();
begin
  insert into sendlinks.clients (name, token_sha256, ventures)
  values (p_name, sendlinks.sha256_hex(v_token), p_ventures);
  return v_token;
end $$;

-- API -------------------------------------------------------------------------------------

create function sendlinks.authenticate(p_bearer text) returns uuid
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_id uuid;
begin
  update sendlinks.clients
     set last_used_at = now()
   where token_sha256 = sendlinks.sha256_hex(coalesce(p_bearer, ''))
     and revoked_at is null
  returning id into v_id;
  return v_id;
end $$;

-- p is the request body: venture, kind, title, message, url, text, bucket, path, file_name,
-- content_type, bytes, recipient_email, recipient_name, purpose, ref, password, max_views,
-- expires_in_hours | expires_at, metadata, on_duplicate ('error' | 'reissue').
-- Returns {ok, link_id, token, expires_at, reissued} or {ok:false, error, detail}.
create function sendlinks.create_link(p_client_id uuid, p jsonb) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_client     sendlinks.clients;
  v_venture    text := p->>'venture';
  v_kind       text := p->>'kind';
  v_ref        text := nullif(p->>'ref', '');
  v_token      text := sendlinks.new_token();
  v_expires    timestamptz;
  v_existing   sendlinks.links;
  v_link_id    uuid;
  v_bucket     text := p->>'bucket';
  v_path       text := p->>'path';
  v_bytes      bigint;
  v_ctype      text := p->>'content_type';
  v_constraint text;
  v_column     text;
begin
  v_bytes := (p->>'bytes')::bigint;
  select * into v_client from sendlinks.clients where id = p_client_id and revoked_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'unauthorized');
  end if;

  if v_venture is null or not exists (
       select 1 from public.ventures where id = v_venture and status = 'active') then
    return jsonb_build_object('ok', false, 'error', 'unknown_venture', 'detail', v_venture);
  end if;
  if v_client.ventures is not null and not (v_venture = any (v_client.ventures)) then
    return jsonb_build_object('ok', false, 'error', 'venture_not_allowed', 'detail', v_venture);
  end if;

  if v_ref is not null then
    select * into v_existing from sendlinks.links where client_id = p_client_id and ref = v_ref;
    if found then
      if coalesce(p->>'on_duplicate', 'error') <> 'reissue' then
        return jsonb_build_object('ok', false, 'error', 'duplicate_ref', 'link_id', v_existing.id);
      end if;
      if sendlinks.link_state(v_existing) <> 'active' then
        return jsonb_build_object('ok', false, 'error', 'link_inactive', 'link_id', v_existing.id,
          'detail', sendlinks.link_state(v_existing));
      end if;
      -- Retry after a lost response: rotate the token on the existing link. The old token dies.
      update sendlinks.links set token_sha256 = sendlinks.sha256_hex(v_token)
       where id = v_existing.id;
      insert into sendlinks.events (link_id, kind) values (v_existing.id, 'reissued');
      return jsonb_build_object('ok', true, 'link_id', v_existing.id, 'token', v_token,
        'expires_at', v_existing.expires_at, 'state', 'active', 'reissued', true);
    end if;
  end if;

  if p ? 'expires_at' then
    v_expires := (p->>'expires_at')::timestamptz;
  else
    v_expires := now() + make_interval(hours => coalesce((p->>'expires_in_hours')::int, 168));
  end if;
  if v_expires <= now() or v_expires > now() + interval '90 days' then
    return jsonb_build_object('ok', false, 'error', 'bad_expiry',
      'detail', 'expiry must be in the future and at most 90 days away');
  end if;

  if v_kind = 'file' then
    if not exists (select 1 from sendlinks.allowed_buckets where bucket = v_bucket) then
      return jsonb_build_object('ok', false, 'error', 'bucket_not_allowed', 'detail', v_bucket);
    end if;
    -- API uploads are filed under their venture; a caller may only link its own venture's.
    if v_bucket = 'sendlinks' and coalesce(v_path, '') not like v_venture || '/%' then
      return jsonb_build_object('ok', false, 'error', 'object_not_found',
        'detail', v_bucket || '/' || coalesce(v_path, ''));
    end if;
    select coalesce(v_bytes, (o.metadata->>'size')::bigint),
           coalesce(v_ctype, o.metadata->>'mimetype')
      into v_bytes, v_ctype
      from storage.objects o where o.bucket_id = v_bucket and o.name = v_path;
    if not found then
      return jsonb_build_object('ok', false, 'error', 'object_not_found',
        'detail', v_bucket || '/' || coalesce(v_path, ''));
    end if;
  end if;

  begin
    insert into sendlinks.links (
      token_sha256, client_id, venture_id, kind, title, message, target_url, text_body,
      storage_bucket, storage_path, file_name, content_type, bytes,
      recipient_email, recipient_name, purpose, ref, password_hash, max_views, expires_at, metadata)
    values (
      sendlinks.sha256_hex(v_token), p_client_id, v_venture, v_kind, p->>'title', p->>'message',
      p->>'url', p->>'text',
      case when v_kind = 'file' then v_bucket end,
      case when v_kind = 'file' then v_path end,
      case when v_kind = 'file' then left(regexp_replace(
             coalesce(nullif(p->>'file_name', ''), regexp_replace(v_path, '^.*/', '')),
             '[^A-Za-z0-9 ._()-]+', '-', 'g'), 255) end,
      case when v_kind = 'file' then v_ctype end,
      case when v_kind = 'file' then v_bytes end,
      lower(p->>'recipient_email'), p->>'recipient_name', p->>'purpose', v_ref,
      case when nullif(p->>'password', '') is not null
           then extensions.crypt(p->>'password', extensions.gen_salt('bf', 10)) end,
      (p->>'max_views')::int, v_expires, coalesce(p->'metadata', '{}'::jsonb))
    returning id into v_link_id;
  exception
    when unique_violation then
      -- A concurrent request with the same ref won the insert. Answer as its duplicate.
      if v_ref is null then raise; end if;
      return sendlinks.create_link(p_client_id, p);
    when check_violation or not_null_violation then
      get stacked diagnostics v_constraint = constraint_name, v_column = column_name;
      return jsonb_build_object('ok', false, 'error', 'invalid', 'detail', case
        when v_constraint = 'links_kind_shape' then
          'kind must be url, text or file, with url, text, or bucket and path to match'
        when v_constraint = 'links_target_url_check' then 'url must be https and at most 2048 chars'
        when v_constraint like 'links\_%\_check' then
          regexp_replace(v_constraint, '^links_(.*)_check$', '\1') || ' is out of range'
        when v_column is not null then v_column || ' is required'
        else 'request is not valid' end);
  end;

  insert into sendlinks.events (link_id, kind, detail)
  values (v_link_id, 'created', jsonb_build_object('client', v_client.name));

  return jsonb_build_object('ok', true, 'link_id', v_link_id, 'token', v_token,
    'expires_at', v_expires, 'state', 'active', 'reissued', false);
exception
  when invalid_text_representation or invalid_datetime_format or datetime_field_overflow
    or numeric_value_out_of_range then
    return jsonb_build_object('ok', false, 'error', 'invalid',
      'detail', 'a number, date or id field is malformed');
end $$;

create function sendlinks.link_status(p_client_id uuid, p_link_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'ok', true,
    'link_id', l.id, 'venture', l.venture_id, 'kind', l.kind, 'title', l.title,
    'purpose', l.purpose, 'ref', l.ref, 'recipient_email', l.recipient_email,
    'state', sendlinks.link_state(l), 'views', l.view_count, 'max_views', l.max_views,
    'has_password', l.password_hash is not null,
    'expires_at', l.expires_at, 'created_at', l.created_at,
    'first_opened_at', l.first_opened_at, 'last_opened_at', l.last_opened_at,
    'revoked_at', l.revoked_at,
    'events', coalesce((
      select jsonb_agg(jsonb_build_object('kind', e.kind, 'at', e.at) order by e.at desc)
        from (select * from sendlinks.events where link_id = l.id order by at desc limit 50) e
    ), '[]'::jsonb))
  from sendlinks.links l
  where l.id = p_link_id and l.client_id = p_client_id
$$;

create function sendlinks.revoke_link(p_client_id uuid, p_link_id uuid, p_reason text default null)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_link sendlinks.links;
begin
  update sendlinks.links
     set revoked_at = coalesce(revoked_at, now()),
         revoked_reason = coalesce(revoked_reason, p_reason)
   where id = p_link_id and client_id = p_client_id
  returning * into v_link;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;
  insert into sendlinks.events (link_id, kind, detail)
  values (v_link.id, 'revoked', jsonb_build_object('reason', p_reason));
  return jsonb_build_object('ok', true, 'link_id', v_link.id, 'state', 'revoked');
end $$;

-- Recipient side --------------------------------------------------------------------------

-- p_consume false is a link-preview fetch (chat unfurlers, mail scanners that announce
-- themselves): it reveals only the title and never spends a view.
-- Returns {ok:true, ...payload} or {ok:false, reason} where reason is one of
-- not_found, revoked, expired, exhausted, locked, password_required, bad_password.
create function sendlinks.open_link(
  p_token      text,
  p_password   text default null,
  p_ip_sha256  text default null,
  p_user_agent text default null,
  p_consume    boolean default true
) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_link   sendlinks.links;
  v_state  text;
  v_ua     text := left(p_user_agent, 300);
begin
  select * into v_link from sendlinks.links
   where token_sha256 = sendlinks.sha256_hex(coalesce(p_token, ''))
   for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;

  v_state := sendlinks.link_state(v_link);
  if v_state <> 'active' then
    insert into sendlinks.events (link_id, kind, ip_sha256, user_agent)
    values (v_link.id, 'denied_' || v_state, p_ip_sha256, v_ua);
    return jsonb_build_object('ok', false, 'reason', v_state);
  end if;

  if not p_consume then
    insert into sendlinks.events (link_id, kind, ip_sha256, user_agent)
    values (v_link.id, 'previewed', p_ip_sha256, v_ua);
    return jsonb_build_object('ok', true, 'preview', true, 'title', v_link.title,
      'venture', v_link.venture_id, 'has_password', v_link.password_hash is not null);
  end if;

  if v_link.password_hash is not null then
    if nullif(p_password, '') is null then
      insert into sendlinks.events (link_id, kind, ip_sha256, user_agent)
      values (v_link.id, 'password_required', p_ip_sha256, v_ua);
      return jsonb_build_object('ok', false, 'reason', 'password_required',
        'title', v_link.title, 'venture', v_link.venture_id);
    end if;
    if extensions.crypt(p_password, v_link.password_hash) <> v_link.password_hash then
      update sendlinks.links set failed_password_count = failed_password_count + 1
       where id = v_link.id;
      insert into sendlinks.events (link_id, kind, ip_sha256, user_agent)
      values (v_link.id, 'denied_password', p_ip_sha256, v_ua);
      return jsonb_build_object('ok', false, 'reason', 'bad_password');
    end if;
  end if;

  update sendlinks.links
     set view_count = view_count + 1,
         first_opened_at = coalesce(first_opened_at, now()),
         last_opened_at = now()
   where id = v_link.id
  returning * into v_link;
  insert into sendlinks.events (link_id, kind, ip_sha256, user_agent, detail)
  values (v_link.id, 'opened', p_ip_sha256, v_ua, jsonb_build_object('view', v_link.view_count));

  return jsonb_build_object(
    'ok', true, 'preview', false, 'link_id', v_link.id, 'venture', v_link.venture_id,
    'kind', v_link.kind, 'title', v_link.title, 'message', v_link.message,
    'url', v_link.target_url, 'text', v_link.text_body,
    'bucket', v_link.storage_bucket, 'path', v_link.storage_path,
    'file_name', v_link.file_name, 'content_type', v_link.content_type, 'bytes', v_link.bytes,
    'views', v_link.view_count, 'max_views', v_link.max_views, 'expires_at', v_link.expires_at);
end $$;

-- The view was spent but the bytes never left (Storage error, bad redirect): give it back.
create function sendlinks.refund_view(p_link_id uuid, p_detail text default null) returns void
language plpgsql volatile security definer set search_path = '' as $$
begin
  update sendlinks.links set view_count = greatest(view_count - 1, 0) where id = p_link_id;
  insert into sendlinks.events (link_id, kind, detail)
  values (p_link_id, 'delivery_failed', jsonb_build_object('detail', left(p_detail, 300)));
end $$;

revoke all on all functions in schema sendlinks from public;
grant execute on all functions in schema sendlinks to service_role;

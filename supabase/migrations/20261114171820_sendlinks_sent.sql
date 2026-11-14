-- A link's life counts from the send, not from when it was made (fleet integration I-28, D19).
--
-- A caller makes a link while it drafts a message and the message can sit for days before it
-- goes. The caller now marks the send: POST /links/{id}/sent. The first mark sets sent_at and
-- moves expires_at so the link keeps the whole life it was made with, counted from the send.
-- Later marks change nothing and answer with the first one (first call wins), so a retry or a
-- second sender cannot stretch a link. A link that is already revoked, expired, used up or
-- locked is not brought back. A link never marked keeps the expiry it was made with.

alter table sendlinks.links add column sent_at timestamptz;

alter table sendlinks.events drop constraint events_kind_check;
alter table sendlinks.events add constraint events_kind_check check (kind in (
  'created', 'reissued', 'opened', 'previewed', 'revoked',
  'denied_expired', 'denied_revoked', 'denied_exhausted',
  'denied_password', 'denied_locked', 'password_required', 'delivery_failed',
  'downloaded', 'download_incomplete', 'sent'));

-- p: optional message_id (the sending lane's own id for the message, kept in the event, cut to 200).
create function sendlinks.mark_sent(p_client_id uuid, p_link_id uuid, p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_link  sendlinks.links;
  v_state text;
begin
  select * into v_link from sendlinks.links
   where id = p_link_id and client_id = p_client_id
   for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  if v_link.sent_at is not null then
    return jsonb_build_object('ok', true, 'first', false, 'link_id', v_link.id,
      'sent_at', v_link.sent_at, 'expires_at', v_link.expires_at, 'state', sendlinks.link_state(v_link));
  end if;

  v_state := sendlinks.link_state(v_link);
  if v_state <> 'active' then
    return jsonb_build_object('ok', false, 'error', 'link_inactive', 'link_id', v_link.id, 'detail', v_state);
  end if;

  update sendlinks.links
     set sent_at = now(),
         expires_at = now() + (expires_at - created_at)
   where id = v_link.id
  returning * into v_link;

  insert into sendlinks.events (link_id, kind, detail)
  values (v_link.id, 'sent', jsonb_strip_nulls(jsonb_build_object(
    'message_id', left(nullif(p->>'message_id', ''), 200),
    'expires_at', v_link.expires_at)));

  return jsonb_build_object('ok', true, 'first', true, 'link_id', v_link.id,
    'sent_at', v_link.sent_at, 'expires_at', v_link.expires_at, 'state', 'active');
end $$;

-- Status and list carry sent_at; everything else is as in sendlinks_receipts.
create or replace function sendlinks.link_status(p_client_id uuid, p_link_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'ok', true,
    'link_id', l.id, 'venture', l.venture_id, 'kind', l.kind, 'title', l.title,
    'purpose', l.purpose, 'ref', l.ref, 'recipient_email', l.recipient_email,
    'recipient_name', l.recipient_name,
    'state', sendlinks.link_state(l), 'views', l.view_count, 'max_views', l.max_views,
    'has_password', l.password_hash is not null,
    'expires_at', l.expires_at, 'created_at', l.created_at, 'sent_at', l.sent_at,
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

create or replace function sendlinks.list_links(p_client_id uuid, f jsonb default '{}'::jsonb) returns jsonb
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
          'state', sendlinks.link_state(l), 'created_at', l.created_at, 'sent_at', l.sent_at,
          'expires_at', l.expires_at, 'receipts', sendlinks.receipts(l)) as j
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

revoke all on function sendlinks.mark_sent(uuid, uuid, jsonb) from public;
grant execute on function sendlinks.mark_sent(uuid, uuid, jsonb) to service_role;

create function public.sendlinks_mark_sent(p_client_id uuid, p_link_id uuid, p jsonb) returns jsonb
language sql volatile security invoker set search_path = '' as $$
  select sendlinks.mark_sent(p_client_id, p_link_id, p)
$$;
revoke all on function public.sendlinks_mark_sent(uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.sendlinks_mark_sent(uuid, uuid, jsonb) to service_role;

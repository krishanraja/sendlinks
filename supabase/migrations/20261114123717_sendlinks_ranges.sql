-- Byte ranges for file links, so a phone can play and seek a video (fleet integration I-07).
--
-- A player fetches a video in pieces. A piece that starts at byte 0 is an open and spends a view
-- through sendlinks.open_link exactly as before. A later piece is a continuation: it spends
-- nothing and is served only when all of these hold:
--   * the link is a file link that is not read-once (max_views = 1) and has no password; those
--     keep today's behaviour exactly (whole file, one spend);
--   * the link is active: not revoked, expired, locked, or exhausted by real views (continuations
--     never count as views, so they can never exhaust a link);
--   * the same ip hash AND the same user agent spent a view on this link in the last 30 minutes.
-- The download receipt is written once per viewer per 30 minutes, when the last byte of the file
-- has been served in any range (sendlinks.record_range_download).

create function sendlinks.continue_link(
  p_token      text,
  p_ip_sha256  text default null,
  p_user_agent text default null
) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_link  sendlinks.links;
  v_ua    text := left(p_user_agent, 300);
begin
  select * into v_link from sendlinks.links
   where token_sha256 = sendlinks.sha256_hex(coalesce(p_token, ''));
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;

  -- Read-once, password and non-file links never continue: the caller serves them as before.
  if v_link.kind <> 'file' or v_link.password_hash is not null or v_link.max_views = 1 then
    return jsonb_build_object('ok', false, 'reason', 'whole_file_only');
  end if;

  if sendlinks.link_state(v_link) <> 'active' then
    return jsonb_build_object('ok', false, 'reason', sendlinks.link_state(v_link));
  end if;

  if p_ip_sha256 is null or v_ua is null or not exists (
    select 1 from sendlinks.events e
     where e.link_id = v_link.id
       and e.kind = 'opened'
       and e.ip_sha256 = p_ip_sha256
       and e.user_agent = v_ua
       and e.at > now() - interval '30 minutes'
  ) then
    return jsonb_build_object('ok', false, 'reason', 'no_recent_view');
  end if;

  return jsonb_build_object(
    'ok', true, 'continued', true, 'link_id', v_link.id, 'kind', v_link.kind,
    'title', v_link.title, 'bucket', v_link.storage_bucket, 'path', v_link.storage_path,
    'file_name', v_link.file_name, 'content_type', v_link.content_type, 'bytes', v_link.bytes,
    'views', v_link.view_count, 'max_views', v_link.max_views, 'expires_at', v_link.expires_at);
end $$;

-- The last byte of the file left in a range. A player can fetch the tail more than once in one
-- sitting, so one viewer's download is counted at most once per 30 minutes.
create function sendlinks.record_range_download(
  p_link_id    uuid,
  p_bytes      bigint,
  p_ip_sha256  text default null,
  p_user_agent text default null
) returns void
language plpgsql volatile security definer set search_path = '' as $$
begin
  if exists (
    select 1 from sendlinks.events e
     where e.link_id = p_link_id
       and e.kind = 'downloaded'
       and e.ip_sha256 is not distinct from p_ip_sha256
       and e.user_agent is not distinct from left(p_user_agent, 300)
       and e.at > now() - interval '30 minutes'
  ) then
    return;
  end if;
  perform sendlinks.record_download(p_link_id, p_bytes, true, p_ip_sha256, p_user_agent);
end $$;

revoke all on function sendlinks.continue_link(text, text, text) from public;
revoke all on function sendlinks.record_range_download(uuid, bigint, text, text) from public;
grant execute on function sendlinks.continue_link(text, text, text) to service_role;
grant execute on function sendlinks.record_range_download(uuid, bigint, text, text) to service_role;

-- PostgREST wrappers, service role only, like the nine before them.
create function public.sendlinks_continue_link(p_token text, p_ip_sha256 text, p_user_agent text)
returns jsonb
language sql stable security invoker set search_path = '' as $$
  select sendlinks.continue_link(p_token, p_ip_sha256, p_user_agent)
$$;

create function public.sendlinks_record_range_download(
  p_link_id uuid, p_bytes bigint, p_ip_sha256 text, p_user_agent text
) returns void
language sql volatile security invoker set search_path = '' as $$
  select sendlinks.record_range_download(p_link_id, p_bytes, p_ip_sha256, p_user_agent)
$$;

revoke all on function public.sendlinks_continue_link(text, text, text) from public, anon, authenticated;
revoke all on function public.sendlinks_record_range_download(uuid, bigint, text, text) from public, anon, authenticated;
grant execute on function public.sendlinks_continue_link(text, text, text) to service_role;
grant execute on function public.sendlinks_record_range_download(uuid, bigint, text, text) to service_role;

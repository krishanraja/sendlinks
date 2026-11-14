-- Byte ranges: a later piece is served while anyone has opened the link in the last 30 minutes,
-- not only the exact ip and user agent that opened it.
--
-- The phone check on 2026-11-14 failed: Android Chrome opened the link (two views spent), read
-- 73,728 bytes, and every later piece was refused 403 "Open the link again to keep watching".
-- Phones fetch later pieces from another address (a 5G phone moves between IPv6 and IPv4 and
-- between carrier NAT addresses) and iPhone Safari's player asks under another agent
-- (AppleCoreMedia), so binding pieces to one ip hash and agent breaks playback on both.
--
-- What still holds: read-once and password links stay whole file, one spend; a link nobody has
-- opened in 30 minutes gives out no piece past the start; continuations never spend or count a
-- view; revoked, expired, exhausted and locked links give out nothing. The token stays the secret.

create or replace function sendlinks.continue_link(
  p_token      text,
  p_ip_sha256  text default null,
  p_user_agent text default null
) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_link  sendlinks.links;
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

  if not exists (
    select 1 from sendlinks.events e
     where e.link_id = v_link.id
       and e.kind = 'opened'
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

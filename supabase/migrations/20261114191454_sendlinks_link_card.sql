-- The recipient page's card (fleet I-29, D20): what a link is, without spending it.
--
-- The page at mindmake.co/l/{token} shows the title, what kind of thing it is, its size and
-- when it closes, and only the recipient's click opens it. sendlinks.link_meta gives the page
-- that card. It never spends a view and never returns the content or where it is stored; it
-- writes a 'previewed' event like any unfurler fetch, so a mail scanner that runs the page's
-- script is counted as a preview, not an open.

create function sendlinks.link_meta(
  p_token      text,
  p_ip_sha256  text default null,
  p_user_agent text default null
) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_link  sendlinks.links;
  v_state text;
begin
  select * into v_link from sendlinks.links
   where token_sha256 = sendlinks.sha256_hex(coalesce(p_token, ''));
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;

  v_state := sendlinks.link_state(v_link);
  if v_state <> 'active' then
    return jsonb_build_object('ok', false, 'reason', v_state, 'venture', v_link.venture_id,
      'title', v_link.title, 'expires_at', v_link.expires_at);
  end if;

  insert into sendlinks.events (link_id, kind, ip_sha256, user_agent, detail)
  values (v_link.id, 'previewed', p_ip_sha256, left(p_user_agent, 300), '{"card": true}'::jsonb);

  return jsonb_build_object(
    'ok', true, 'state', v_state, 'venture', v_link.venture_id, 'kind', v_link.kind,
    'title', v_link.title, 'message', v_link.message,
    'file_name', v_link.file_name, 'content_type', v_link.content_type, 'bytes', v_link.bytes,
    'has_password', v_link.password_hash is not null, 'max_views', v_link.max_views,
    'expires_at', v_link.expires_at);
end $$;

revoke all on function sendlinks.link_meta(text, text, text) from public;
grant execute on function sendlinks.link_meta(text, text, text) to service_role;

create function public.sendlinks_link_meta(p_token text, p_ip_sha256 text, p_user_agent text)
returns jsonb
language sql volatile security invoker set search_path = '' as $$
  select sendlinks.link_meta(p_token, p_ip_sha256, p_user_agent)
$$;
revoke all on function public.sendlinks_link_meta(text, text, text) from public, anon, authenticated;
grant execute on function public.sendlinks_link_meta(text, text, text) to service_role;

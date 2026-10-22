-- Behaviour of the SendLinks SQL engine. Each block raises on the first failed assertion.
\set ON_ERROR_STOP on

create temp table t (k text primary key, v text);

do $$
declare
  v_token text;
  v_client uuid;
begin
  v_token := sendlinks.mint_client('n8n-test', array['mindmake']);
  assert v_token like 'sl_%' and length(v_token) = 46, 'bearer shape';
  v_client := sendlinks.authenticate(v_token);
  assert v_client is not null, 'bearer authenticates';
  assert sendlinks.authenticate('sl_wrong') is null, 'wrong bearer refused';
  assert sendlinks.authenticate(null) is null, 'missing bearer refused';
  assert not exists (select 1 from sendlinks.clients where token_sha256 = v_token), 'bearer not stored';
  insert into t values ('client', v_client);
  raise notice 'ok: clients';
end $$;

do $$
declare
  c uuid := (select v from t where k = 'client');
  r jsonb;
begin
  r := sendlinks.create_link(c, '{"venture":"pulse","kind":"url","title":"x","url":"https://a.b"}');
  assert r->>'error' = 'venture_not_allowed', 'client scoped to its ventures: ' || r;
  r := sendlinks.create_link(c, '{"venture":"nope","kind":"url","title":"x","url":"https://a.b"}');
  assert r->>'error' = 'unknown_venture', 'unknown venture: ' || r;
  r := sendlinks.create_link(c, '{"venture":"mindmake","kind":"url","title":"x","url":"http://a.b"}');
  assert r->>'error' = 'invalid', 'https only: ' || r;
  r := sendlinks.create_link(c, '{"venture":"mindmake","kind":"url","title":"x"}');
  assert r->>'error' = 'invalid', 'url kind needs url: ' || r;
  r := sendlinks.create_link(c, '{"venture":"mindmake","kind":"url","title":"x","url":"https://a.b","expires_in_hours":5000}');
  assert r->>'error' = 'bad_expiry', 'expiry capped at 90 days: ' || r;
  r := sendlinks.create_link(c, '{"venture":"mindmake","kind":"url","title":"x","url":"https://a.b","max_views":"lots"}');
  assert r->>'error' = 'invalid', 'bad number: ' || r;
  r := sendlinks.create_link(c, '{"venture":"mindmake","kind":"url","title":"x","url":"https://a.b","expires_in_hours":"soon"}');
  assert r->>'error' = 'invalid', 'bad expiry number: ' || r;
  r := sendlinks.create_link(c, '{"venture":"mindmake","kind":"file","title":"x","bucket":"private-stuff","path":"secret.txt"}');
  assert r->>'error' = 'bucket_not_allowed', 'bucket allowlist: ' || r;
  r := sendlinks.create_link(c, '{"venture":"mindmake","kind":"file","title":"x","bucket":"content-library","path":"missing.pdf"}');
  assert r->>'error' = 'object_not_found', 'object must exist: ' || r;
  r := sendlinks.create_link(c, '{"venture":"mindmake","kind":"file","title":"x","bucket":"content-library","path":"../etc"}');
  assert r->>'error' = 'object_not_found', 'traversal refused: ' || r;
  raise notice 'ok: create validation';
end $$;

do $$
declare
  c uuid := (select v from t where k = 'client');
  r jsonb;
  o jsonb;
begin
  r := sendlinks.create_link(c, '{"venture":"mindmake","kind":"file","title":"AI readiness guide",
        "bucket":"content-library","path":"guides/ai-readiness.pdf","recipient_email":"Sam@Example.com",
        "purpose":"lead-magnet","ref":"lead-42"}');
  assert (r->>'ok')::boolean, 'file link created: ' || r;
  assert length(r->>'token') = 43, 'token is 43 chars';
  assert not exists (select 1 from sendlinks.links where token_sha256 = r->>'token'), 'token not stored';
  insert into t values ('file_token', r->>'token'), ('file_id', r->>'link_id');

  o := sendlinks.open_link(r->>'token', null, 'iphash', 'Mozilla/5.0');
  assert (o->>'ok')::boolean and o->>'kind' = 'file', 'file opens: ' || o;
  assert o->>'bytes' = '48213' and o->>'content_type' = 'application/pdf', 'metadata from storage: ' || o;
  assert o->>'file_name' = 'ai-readiness.pdf', 'default file name';
  assert (select recipient_email from sendlinks.links where id = (r->>'link_id')::uuid) = 'sam@example.com', 'email lowercased';

  -- Idempotency: same ref is refused, or reissued with a new token that replaces the old one.
  o := sendlinks.create_link(c, '{"venture":"mindmake","kind":"url","title":"x","url":"https://a.b","ref":"lead-42"}');
  assert o->>'error' = 'duplicate_ref' and o->>'link_id' = r->>'link_id', 'duplicate ref: ' || o;
  o := sendlinks.create_link(c, '{"venture":"mindmake","kind":"url","title":"x","url":"https://a.b","ref":"lead-42","on_duplicate":"reissue"}');
  assert (o->>'reissued')::boolean and o->>'link_id' = r->>'link_id' and o->>'token' <> r->>'token', 'reissue: ' || o;
  assert sendlinks.open_link(r->>'token')->>'reason' = 'not_found', 'old token dead after reissue';
  assert (sendlinks.open_link(o->>'token')->>'ok')::boolean, 'new token works';
  assert (sendlinks.open_link(o->>'token')->>'views')::int = 3, 'views accumulate across reissue';
  raise notice 'ok: file link, idempotency';
end $$;

do $$
declare
  c uuid := (select v from t where k = 'client');
  r jsonb;
  o jsonb;
begin
  r := sendlinks.create_link(c, '{"venture":"mindmake","kind":"text","title":"Access code","text":"XK-22","max_views":2}');
  o := sendlinks.open_link(r->>'token', null, null, null, false);
  assert (o->>'preview')::boolean and o->>'text' is null, 'preview hides content: ' || o;
  assert (sendlinks.open_link(r->>'token')->>'text') = 'XK-22', 'first view';
  assert (sendlinks.open_link(r->>'token')->>'views') = '2', 'second view';
  o := sendlinks.open_link(r->>'token');
  assert o->>'reason' = 'exhausted', 'third view refused: ' || o;
  assert (select view_count from sendlinks.links where id = (r->>'link_id')::uuid) = 2, 'preview did not spend a view';
  assert sendlinks.open_link(r->>'token', null, null, null, false)->>'reason' = 'exhausted', 'preview of exhausted link refused';
  raise notice 'ok: max views, previews';
end $$;

do $$
declare
  c uuid := (select v from t where k = 'client');
  r jsonb;
  i int;
begin
  r := sendlinks.create_link(c, '{"venture":"mindmake","kind":"url","title":"Deck","url":"https://example.com/deck","password":"hunter2"}');
  assert sendlinks.open_link(r->>'token')->>'reason' = 'password_required', 'password asked';
  assert sendlinks.open_link(r->>'token', 'nope')->>'reason' = 'bad_password', 'wrong password';
  assert sendlinks.open_link(r->>'token', 'hunter2')->>'url' = 'https://example.com/deck', 'right password';
  assert not exists (select 1 from sendlinks.links where password_hash like '%hunter2%'), 'password hashed';
  for i in 1..9 loop perform sendlinks.open_link(r->>'token', 'nope'); end loop;
  assert sendlinks.open_link(r->>'token', 'hunter2')->>'reason' = 'locked', 'locked after 10 failures';
  raise notice 'ok: passwords';
end $$;

do $$
declare
  c uuid := (select v from t where k = 'client');
  other uuid;
  r jsonb;
  s jsonb;
begin
  r := sendlinks.create_link(c, '{"venture":"mindmake","kind":"url","title":"x","url":"https://a.b","expires_in_hours":1}');
  update sendlinks.links set expires_at = now() - interval '1 second' where id = (r->>'link_id')::uuid;
  assert sendlinks.open_link(r->>'token')->>'reason' = 'expired', 'expired';

  r := sendlinks.create_link(c, '{"venture":"mindmake","kind":"url","title":"x","url":"https://a.b"}');
  perform sendlinks.mint_client('other-client');
  other := (select id from sendlinks.clients where name = 'other-client');
  assert sendlinks.revoke_link(other, (r->>'link_id')::uuid)->>'error' = 'not_found', 'cannot revoke another client''s link';
  assert sendlinks.link_status(other, (r->>'link_id')::uuid) is null, 'cannot read another client''s link';
  assert (sendlinks.revoke_link(c, (r->>'link_id')::uuid, 'sent to wrong person')->>'ok')::boolean, 'revoke';
  assert sendlinks.open_link(r->>'token')->>'reason' = 'revoked', 'revoked link refused';

  s := sendlinks.link_status(c, (select v from t where k = 'file_id')::uuid);
  assert s->>'state' = 'active' and (s->>'views')::int = 3, 'status: ' || s;
  assert jsonb_array_length(s->'events') = 5, 'events: created, opened, reissued, opened, opened: ' || (s->'events');
  raise notice 'ok: expiry, revoke, status, client isolation';
end $$;

do $$
begin
  begin
    delete from sendlinks.events;
    raise exception 'delete should have failed';
  exception when raise_exception then
    assert sqlerrm = 'sendlinks.events is append only', 'append only: ' || sqlerrm;
  end;
  assert not has_schema_privilege('anon', 'sendlinks', 'usage'), 'anon has no schema access';
  assert not has_schema_privilege('authenticated', 'sendlinks', 'usage'), 'authenticated has no schema access';
  assert not has_function_privilege('anon', 'sendlinks.open_link(text,text,text,text,boolean)', 'execute'), 'anon cannot execute';
  raise notice 'ok: append only, privileges';
end $$;

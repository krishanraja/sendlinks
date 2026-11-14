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
declare
  c uuid := (select v from t where k = 'client');
  r jsonb;
  o jsonb;
begin
  -- Review findings, 2026-10-22.
  r := sendlinks.create_link(c, '{"venture":"mindmake","kind":"file","title":"x","bucket":"sendlinks","path":"pulse/2026-10/0b7e/pulse-only.pdf"}');
  assert r->>'error' = 'object_not_found', 'another venture''s upload cannot be linked: ' || r;

  r := sendlinks.create_link(c, '{"venture":"mindmake","kind":"file","title":"x","bucket":"content-library","path":"odd/R&D #3?.pdf"}');
  assert (select file_name from sendlinks.links where id = (r->>'link_id')::uuid) = 'R-D -3-.pdf', 'file name made url safe: ' || r;

  r := sendlinks.create_link(c, '{"venture":"mindmake","kind":"url","title":"x","url":"http://a.b"}');
  assert r->>'detail' = 'url must be https and at most 2048 chars', 'readable detail: ' || r;
  r := sendlinks.create_link(c, '{"venture":"mindmake","kind":"url","title":"x","url":"https://例え.jp/"}');
  assert r->>'error' = 'invalid', 'non-ascii url refused in sql: ' || r;
  r := sendlinks.create_link(c, '{"venture":"mindmake","kind":"text","title":"x","url":"https://a.b"}');
  assert r->>'detail' like 'kind must be%', 'shape detail: ' || r;
  assert r::text !~ 'constraint|links_', 'no internal names leak: ' || r;
  r := sendlinks.create_link(c, '{"venture":"mindmake","kind":"url","title":"x","url":"https://a.b","max_views":"lots"}');
  assert r->>'detail' = 'a number, date or id field is malformed', 'cast detail: ' || r;

  r := sendlinks.create_link(c, '{"venture":"mindmake","kind":"url","title":"x","url":"https://a.b","ref":"dead-1"}');
  perform sendlinks.revoke_link(c, (r->>'link_id')::uuid);
  o := sendlinks.create_link(c, '{"venture":"mindmake","kind":"url","title":"x","url":"https://a.b","ref":"dead-1","on_duplicate":"reissue"}');
  assert o->>'error' = 'link_inactive' and o->>'detail' = 'revoked', 'dead link not reissued: ' || o;

  r := sendlinks.create_link(c, '{"venture":"mindmake","kind":"text","title":"x","text":"y","max_views":1}');
  o := sendlinks.open_link(r->>'token');
  perform sendlinks.refund_view((o->>'link_id')::uuid, 'storage down');
  assert (sendlinks.open_link(r->>'token')->>'ok')::boolean, 'refunded view can be used again';
  assert exists (select 1 from sendlinks.events where link_id = (r->>'link_id')::uuid and kind = 'delivery_failed'), 'refund logged';
  raise notice 'ok: review regressions';
end $$;

do $$
declare
  c uuid := (select v from t where k = 'client');
  r jsonb;
  s jsonb;
  n int;
begin
  -- Receipts and webhooks.
  r := sendlinks.create_link(c, '{"venture":"mindmake","kind":"file","title":"Deck","bucket":"content-library","path":"guides/ai-readiness.pdf","recipient_email":"a@b.co","purpose":"proposal"}');
  perform sendlinks.open_link(r->>'token');
  perform sendlinks.record_download((r->>'link_id')::uuid, 48213, true);
  perform sendlinks.record_download((r->>'link_id')::uuid, 100, false);
  s := sendlinks.link_status(c, (r->>'link_id')::uuid);
  assert (s->'receipts'->>'opened')::boolean and (s->'receipts'->>'downloads')::int = 1, 'receipts: ' || (s->'receipts')::text;
  assert s->'events'->0->>'kind' = 'download_incomplete', 'incomplete logged: ' || (s->'events')::text;

  assert (sendlinks.list_links(c, '{"purpose":"proposal"}')->'links'->0->>'link_id') = r->>'link_id', 'list by purpose';
  assert sendlinks.list_links(c, '{"since":"nope"}')->>'error' = 'invalid', 'bad since';
  assert jsonb_array_length(sendlinks.list_links(c, '{"opened":"false","limit":"1"}')->'links') = 1, 'limit and opened filter';

  assert sendlinks.set_receipt_webhook(c, 'http://insecure.example', 'a-long-enough-secret')->>'error' = 'invalid', 'webhook must be https';
  assert sendlinks.set_receipt_webhook(c, 'https://hook.example/x', 'short')->>'error' = 'invalid', 'webhook secret length';
  perform sendlinks.set_receipt_webhook(c, 'https://hook.example/x', 'a-long-enough-secret');
  select count(*) into n from net.http_requests;
  perform sendlinks.open_link((sendlinks.create_link(c, '{"venture":"mindmake","kind":"text","title":"x","text":"y"}'))->>'token');
  assert (select count(*) from net.http_requests) = n + 1, 'open pushed once';
  perform sendlinks.set_receipt_webhook(c, null, null);
  assert (select receipt_webhook_secret from sendlinks.clients where id = c) is null, 'clearing removes the secret';
  raise notice 'ok: receipts, list, webhooks';
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
  assert not exists (
    select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname like 'sendlinks\_%'
       and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))
  ), 'public wrappers are closed to anon and authenticated';
  assert (select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname like 'sendlinks\_%'
           and has_function_privilege('service_role', p.oid, 'execute')) = 13, 'service role can call all thirteen wrappers';
  raise notice 'ok: append only, privileges';
end $$;

-- Byte ranges (20261114123717_sendlinks_ranges): a later piece of a file spends nothing, and only
-- only while someone has spent a view on the link in the last 30 minutes. Read-once and password links are
-- never continued.
do $$
declare
  c   uuid := (select v from t where k = 'client');
  tok text;
  lid uuid;
  r   jsonb;
  ip  text := 'ip-hash-a';
  ua  text := 'Mozilla/5.0 (iPhone)';
begin
  r := sendlinks.create_link(c, '{"venture":"mindmake","kind":"file","title":"Cut","bucket":"content-library","path":"guides/ai-readiness.pdf","max_views":2}');
  tok := r->>'token'; lid := (r->>'link_id')::uuid;

  r := sendlinks.continue_link(tok, ip, ua);
  assert r->>'reason' = 'no_recent_view', 'no continuation before a spent view: ' || r;

  r := sendlinks.open_link(tok, null, ip, ua, true);
  assert (r->>'views')::int = 1, 'the first piece spends one view: ' || r;

  r := sendlinks.continue_link(tok, ip, ua);
  assert (r->>'ok')::boolean and r->>'path' = 'guides/ai-readiness.pdf', 'same viewer continues: ' || r;
  assert (select view_count from sendlinks.links where id = lid) = 1, 'a continuation spends nothing';

  -- Phones fetch later pieces from another address (a 5G phone moving between IPv6 and IPv4)
  -- and iPhone Safari under another agent (AppleCoreMedia), so any recent open on the link counts.
  assert (sendlinks.continue_link(tok, 'ip-hash-b', ua)->>'ok')::boolean, 'another ip continues';
  assert (sendlinks.continue_link(tok, ip, 'AppleCoreMedia/1.0.0.22A3354 (iPhone; U; CPU OS 18_0 like Mac OS X; en_us)')->>'ok')::boolean, 'the iPhone media agent continues';
  assert (sendlinks.continue_link(tok, null, null)->>'ok')::boolean, 'no ip or agent continues';
  assert (select view_count from sendlinks.links where id = lid) = 1, 'still nothing spent';
  assert sendlinks.continue_link('x', ip, ua)->>'reason' = 'not_found', 'unknown token';

  -- A spent view older than 30 minutes no longer opens a continuation (events are append only,
  -- so the old open is inserted already old).
  r := sendlinks.create_link(c, '{"venture":"mindmake","kind":"file","title":"Old","bucket":"content-library","path":"guides/ai-readiness.pdf"}');
  insert into sendlinks.events (link_id, kind, ip_sha256, user_agent, at)
  values ((r->>'link_id')::uuid, 'opened', 'ip-hash-old', ua, now() - interval '31 minutes');
  assert sendlinks.continue_link(r->>'token', 'ip-hash-old', ua)->>'reason' = 'no_recent_view', 'an open 31 minutes ago is too old';

  -- Exhausted by real views: the second view is the last, and then nobody continues.
  perform sendlinks.open_link(tok, null, 'ip-hash-b', ua, true);
  assert sendlinks.continue_link(tok, ip, ua)->>'reason' = 'exhausted', 'an exhausted link is not continued';

  -- Revoked: refused even for the recent viewer.
  r := sendlinks.create_link(c, '{"venture":"mindmake","kind":"file","title":"Cut 2","bucket":"content-library","path":"guides/ai-readiness.pdf"}');
  perform sendlinks.open_link(r->>'token', null, ip, ua, true);
  assert (sendlinks.continue_link(r->>'token', ip, ua)->>'ok')::boolean, 'unlimited link continues';
  perform sendlinks.revoke_link(c, (r->>'link_id')::uuid, 'test');
  assert sendlinks.continue_link(r->>'token', ip, ua)->>'reason' = 'revoked', 'a revoked link is not continued';

  -- Read-once and password links keep today's behaviour: never continued.
  r := sendlinks.create_link(c, '{"venture":"mindmake","kind":"file","title":"Once","bucket":"content-library","path":"guides/ai-readiness.pdf","max_views":1}');
  perform sendlinks.open_link(r->>'token', null, ip, ua, true);
  assert sendlinks.continue_link(r->>'token', ip, ua)->>'reason' = 'whole_file_only', 'read-once is whole file only';
  r := sendlinks.create_link(c, '{"venture":"mindmake","kind":"file","title":"Locked","bucket":"content-library","path":"guides/ai-readiness.pdf","password":"open sesame"}');
  perform sendlinks.open_link(r->>'token', 'open sesame', ip, ua, true);
  assert sendlinks.continue_link(r->>'token', ip, ua)->>'reason' = 'whole_file_only', 'password link is whole file only';
  r := sendlinks.create_link(c, '{"venture":"mindmake","kind":"text","title":"T","text":"x"}');
  assert sendlinks.continue_link(r->>'token', ip, ua)->>'reason' = 'whole_file_only', 'text link is whole file only';

  -- The tail of the file counts as a download once per viewer per 30 minutes.
  perform sendlinks.record_range_download(lid, 10, ip, ua);
  perform sendlinks.record_range_download(lid, 10, ip, ua);
  assert (select download_count from sendlinks.links where id = lid) = 1, 'range download counted once';
  perform sendlinks.record_range_download(lid, 10, 'ip-hash-b', ua);
  assert (select download_count from sendlinks.links where id = lid) = 2, 'another viewer counts';
  raise notice 'ok: byte ranges';
end $$;

-- I-28: a link's life counts from the send. The first mark wins; later marks change nothing.
do $$
declare
  c   uuid := (select v from t where k = 'client');
  r   jsonb;
  m   jsonb;
  m2  jsonb;
  lid uuid;
  e0  timestamptz;
begin
  r := sendlinks.create_link(c, '{"venture":"mindmake","kind":"url","title":"Sent later","url":"https://a.b","expires_in_hours":24}');
  lid := (r->>'link_id')::uuid;
  -- Made a day ago: without a send mark it would have 0 hours left.
  update sendlinks.links set created_at = now() - interval '23 hours',
                              expires_at = now() + interval '1 hour' where id = lid;
  e0 := (select expires_at from sendlinks.links where id = lid);

  m := sendlinks.mark_sent(c, lid, '{"message_id":"gmail-123"}');
  assert (m->>'ok')::boolean and (m->>'first')::boolean, 'first mark: ' || m;
  assert (m->>'expires_at')::timestamptz between now() + interval '23 hours 59 minutes' and now() + interval '24 hours 1 minute',
    'life restarts at the send, same length: ' || m;
  assert (select sent_at from sendlinks.links where id = lid) is not null, 'sent_at stored';
  assert (select count(*) from sendlinks.events where link_id = lid and kind = 'sent') = 1, 'one sent event';
  assert (select detail->>'message_id' from sendlinks.events where link_id = lid and kind = 'sent') = 'gmail-123', 'message id kept';

  m2 := sendlinks.mark_sent(c, lid, '{}');
  assert (m2->>'ok')::boolean and not (m2->>'first')::boolean, 'second mark is not first: ' || m2;
  assert m2->>'sent_at' = m->>'sent_at' and m2->>'expires_at' = m->>'expires_at', 'first call wins';
  assert (select count(*) from sendlinks.events where link_id = lid and kind = 'sent') = 1, 'still one sent event';

  assert (sendlinks.link_status(c, lid)->>'sent_at') is not null, 'status shows sent_at';
  assert exists (select 1 from jsonb_array_elements(sendlinks.list_links(c, '{}')->'links') x
                  where x->>'link_id' = lid::text and x->>'sent_at' is not null), 'list shows sent_at';

  -- Another caller's link is not found; nor is an unknown id.
  assert sendlinks.mark_sent(sendlinks.authenticate(sendlinks.mint_client('other-sender', null)), lid, '{}')->>'error' = 'not_found', 'scoped to caller';
  assert sendlinks.mark_sent(c, gen_random_uuid(), '{}')->>'error' = 'not_found', 'unknown link';

  -- A dead link is not brought back by a send mark.
  r := sendlinks.create_link(c, '{"venture":"mindmake","kind":"url","title":"Dead","url":"https://a.b"}');
  perform sendlinks.revoke_link(c, (r->>'link_id')::uuid, 'test');
  m := sendlinks.mark_sent(c, (r->>'link_id')::uuid, '{}');
  assert m->>'error' = 'link_inactive' and m->>'detail' = 'revoked', 'revoked link stays dead: ' || m;
  r := sendlinks.create_link(c, '{"venture":"mindmake","kind":"url","title":"Old","url":"https://a.b"}');
  update sendlinks.links set expires_at = now() - interval '1 minute' where id = (r->>'link_id')::uuid;
  assert sendlinks.mark_sent(c, (r->>'link_id')::uuid, '{}')->>'error' = 'link_inactive', 'expired link stays dead';

  -- An overlong message id is cut, not refused.
  r := sendlinks.create_link(c, '{"venture":"mindmake","kind":"url","title":"Long id","url":"https://a.b"}');
  m := sendlinks.mark_sent(c, (r->>'link_id')::uuid, jsonb_build_object('message_id', repeat('x', 500)));
  assert (m->>'ok')::boolean, 'long id accepted: ' || m;
  assert (select char_length(detail->>'message_id') from sendlinks.events
           where link_id = (r->>'link_id')::uuid and kind = 'sent') = 200, 'message id cut to 200';
  raise notice 'ok: sent marks';
end $$;

-- 2.6: the expired upload sweep. Only objects in the 'sendlinks' bucket whose every link has
-- expired are picked. The dry run changes nothing; the real run records the sweep on each link
-- and hands back the paths for the Storage API to remove (SQL cannot delete Storage objects).
do $$
declare
  c    uuid := (select v from t where k = 'client');
  r    jsonb;
  s    jsonb;
  dead uuid;
  n0   bigint := (select count(*) from sendlinks.events);
begin
  insert into storage.objects (bucket_id, name, metadata) values
    ('sendlinks', 'mindmake/2026-01/a/dead.pdf',     '{"size": 100, "mimetype": "application/pdf"}'),
    ('sendlinks', 'mindmake/2026-01/b/mixed.pdf',    '{"size": 200, "mimetype": "application/pdf"}'),
    ('sendlinks', 'mindmake/2026-01/c/revoked.pdf',  '{"size": 300, "mimetype": "application/pdf"}'),
    ('sendlinks', 'mindmake/2026-01/d/orphan.pdf',   '{"size": 400, "mimetype": "application/pdf"}'),
    ('content-library', 'old/expired-in-library.pdf','{"size": 500, "mimetype": "application/pdf"}');

  -- dead.pdf: two links, both expired. Picked.
  r := sendlinks.create_link(c, '{"venture":"mindmake","kind":"file","title":"d1","bucket":"sendlinks","path":"mindmake/2026-01/a/dead.pdf"}');
  dead := (r->>'link_id')::uuid;
  update sendlinks.links set expires_at = now() - interval '2 days' where id = dead;
  r := sendlinks.create_link(c, '{"venture":"mindmake","kind":"file","title":"d2","bucket":"sendlinks","path":"mindmake/2026-01/a/dead.pdf"}');
  perform sendlinks.revoke_link(c, (r->>'link_id')::uuid, 'test');
  update sendlinks.links set expires_at = now() - interval '1 day' where id = (r->>'link_id')::uuid;
  -- mixed.pdf: one expired link, one still active. Kept.
  r := sendlinks.create_link(c, '{"venture":"mindmake","kind":"file","title":"m1","bucket":"sendlinks","path":"mindmake/2026-01/b/mixed.pdf"}');
  update sendlinks.links set expires_at = now() - interval '1 day' where id = (r->>'link_id')::uuid;
  perform sendlinks.create_link(c, '{"venture":"mindmake","kind":"file","title":"m2","bucket":"sendlinks","path":"mindmake/2026-01/b/mixed.pdf"}');
  -- revoked.pdf: revoked, but its expiry is still ahead. Kept until the expiry passes.
  r := sendlinks.create_link(c, '{"venture":"mindmake","kind":"file","title":"r1","bucket":"sendlinks","path":"mindmake/2026-01/c/revoked.pdf"}');
  perform sendlinks.revoke_link(c, (r->>'link_id')::uuid, 'test');
  -- orphan.pdf has no link at all: kept (not this sweep's call). The library file: never touched.
  r := sendlinks.create_link(c, '{"venture":"mindmake","kind":"file","title":"lib","bucket":"content-library","path":"old/expired-in-library.pdf"}');
  update sendlinks.links set expires_at = now() - interval '9 days' where id = (r->>'link_id')::uuid;
  n0 := (select count(*) from sendlinks.events);

  s := sendlinks.sweep_expired_uploads();
  assert (s->>'dry_run')::boolean, 'dry run by default: ' || s;
  assert (s->>'count')::int = 1 and (s->>'bytes')::bigint = 100, 'only dead.pdf: ' || s;
  assert s->'paths' = '["mindmake/2026-01/a/dead.pdf"]'::jsonb, 'path list: ' || s;
  assert (select count(*) from sendlinks.events) = n0, 'dry run writes nothing';
  assert (select count(*) from sendlinks.links where swept_at is not null) = 0, 'dry run marks nothing';

  s := sendlinks.sweep_expired_uploads(false);
  assert not (s->>'dry_run')::boolean and (s->>'count')::int = 1, 'real run: ' || s;
  assert (select count(*) from sendlinks.links where swept_at is not null) = 2, 'both links of dead.pdf marked';
  assert (select count(*) from sendlinks.events where kind = 'upload_swept') = 2, 'one event per link';

  -- Until the Storage API removes the object, a rerun lists it again but records nothing twice.
  s := sendlinks.sweep_expired_uploads(false);
  assert (s->>'count')::int = 1, 'still listed until removed';
  assert (select count(*) from sendlinks.events where kind = 'upload_swept') = 2, 'no duplicate events';

  -- After the Storage API removal (simulated), the sweep finds nothing.
  delete from storage.objects where bucket_id = 'sendlinks' and name = 'mindmake/2026-01/a/dead.pdf';
  assert (sendlinks.sweep_expired_uploads()->>'count')::int = 0, 'nothing left to sweep';
  assert sendlinks.open_link((select 'x'))->>'reason' = 'not_found', 'opening still answers';
  assert not has_function_privilege('anon', 'sendlinks.sweep_expired_uploads(boolean)', 'execute'), 'anon cannot sweep';
  raise notice 'ok: expired upload sweep';
end $$;

-- I-29: the recipient page reads a link's card without spending a view.
do $$
declare
  c  uuid := (select v from t where k = 'client');
  r  jsonb;
  m  jsonb;
begin
  r := sendlinks.create_link(c, '{"venture":"mindmake","kind":"file","title":"Card","bucket":"content-library","path":"guides/ai-readiness.pdf","max_views":1}');
  m := sendlinks.link_meta(r->>'token', 'ip-page', 'Mozilla/5.0 (Android)');
  assert (m->>'ok')::boolean and m->>'state' = 'active', 'meta of an active link: ' || m;
  assert m->>'title' = 'Card' and m->>'kind' = 'file' and m->>'venture' = 'mindmake', 'card fields';
  assert m->>'content_type' = 'application/pdf' and (m->>'bytes')::bigint = 48213, 'file facts';
  assert not (m->>'has_password')::boolean and (m->>'max_views')::int = 1, 'flags';
  assert m->>'expires_at' is not null, 'expiry';
  assert not (m ? 'path') and not (m ? 'bucket') and not (m ? 'text') and not (m ? 'url'), 'no content in the card';
  assert (select view_count from sendlinks.links where id = (r->>'link_id')::uuid) = 0, 'meta spends nothing';
  assert (select count(*) from sendlinks.events where link_id = (r->>'link_id')::uuid and kind = 'previewed') = 1, 'meta is a preview';
  -- the read-once link still opens once after any number of card reads
  perform sendlinks.link_meta(r->>'token', 'ip-scanner', 'Mozilla/5.0');
  assert (sendlinks.open_link(r->>'token', null, 'ip-page', 'Mozilla/5.0 (Android)')->>'ok')::boolean, 'read-once survives card reads';
  m := sendlinks.link_meta(r->>'token', null, null);
  assert not (m->>'ok')::boolean and m->>'reason' = 'exhausted', 'used-up link: ' || m;
  assert sendlinks.link_meta('nope', null, null)->>'reason' = 'not_found', 'unknown token';
  r := sendlinks.create_link(c, '{"venture":"mindmake","kind":"text","title":"Secret","text":"hidden","password":"pw"}');
  m := sendlinks.link_meta(r->>'token', null, null);
  assert (m->>'has_password')::boolean and m->>'kind' = 'text' and not (m ? 'text'), 'password card hides the text';
  raise notice 'ok: link card';
end $$;

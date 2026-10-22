// End to end through the HTTP handlers against a real Postgres built by tests/run-local.sh.
// Storage is faked: uploads land in the stub storage.objects table so create_link can see them,
// and their bytes are kept in memory so downloads can be streamed back.
import { assert, assertEquals, assertMatch } from "jsr:@std/assert@1.0.13";
import postgres from "npm:postgres@3.4.5";
import { makeApiHandler, makeOpenHandler, type Storage } from "./sendlinks.ts";
import { pgDb } from "./pg_db_test_only.ts";

const dbUrl = Deno.env.get("SENDLINKS_TEST_DB_URL");
const BASE = "https://x.supabase.co/functions/v1";

Deno.test({
  name: "sendlinks http",
  ignore: !dbUrl,
  sanitizeResources: false,
  sanitizeOps: false,
  async fn(t) {
    const sql = postgres(dbUrl!, { max: 1 });
    const removed: string[] = [];
    let storageDown = false;
    const objects = new Map<string, Uint8Array<ArrayBuffer>>([
      ["content-library/guides/ai-readiness.pdf", new TextEncoder().encode("%PDF-1.7 guide")],
    ]);
    const storage: Storage = {
      fetchObject(b, p) {
        if (storageDown) return Promise.reject(new Error("storage unavailable"));
        const bytes = objects.get(`${b}/${p}`);
        return Promise.resolve(bytes ? new Response(bytes.slice(), { headers: { "content-length": String(bytes.length) } }) : new Response("missing", { status: 404 }));
      },
      async upload(b, p, bytes, ct) {
        objects.set(`${b}/${p}`, new Uint8Array(bytes));
        await sql`insert into storage.objects (bucket_id, name, metadata)
                  values (${b}, ${p}, ${sql.json({ size: bytes.length, mimetype: ct })})`;
      },
      remove: (b, p) => (removed.push(`${b}/${p}`), Promise.resolve()),
    };
    const pending: Promise<unknown>[] = [];
    const db = pgDb(dbUrl!);
    const deps = { db, storage, publicBase: `${BASE}/sendlinks-open`, waitUntil: (p: Promise<unknown>) => void pending.push(p) };
    const settled = () => Promise.all(pending.splice(0));
    const status = async (id: string) =>
      await (await api(new Request(`${BASE}/sendlinks-api/links/${id}`, { headers: auth }))).json();
    const api = makeApiHandler(deps);
    const open = makeOpenHandler(deps);
    const [{ token: bearer }] = await sql`select sendlinks.mint_client('http-test', array['mindmake']) as token`;
    const auth = { authorization: `Bearer ${bearer}` };
    const post = (path: string, body: unknown, headers: Record<string, string> = auth) =>
      api(new Request(`${BASE}/sendlinks-api${path}`, {
        method: "POST",
        headers: { ...headers, "content-type": "application/json" },
        body: JSON.stringify(body),
      }));
    const visit = (url: string, init: RequestInit = {}) =>
      open(new Request(url, { ...init, headers: { "user-agent": "Mozilla/5.0 (Macintosh)", "x-forwarded-for": "203.0.113.9", ...(init.headers ?? {}) } }));

    await t.step("rejects a missing or wrong bearer", async () => {
      assertEquals((await post("/links", {}, {})).status, 401);
      assertEquals((await post("/links", {}, { authorization: "Bearer sl_nope" })).status, 401);
    });

    let urlLink = "";
    let urlLinkId = "";
    await t.step("creates a url link and redirects a browser to it", async () => {
      const res = await post("/links", {
        venture: "mindmake", kind: "url", title: "Workshop deck",
        url: "https://example.com/deck", ref: "deck-1",
      });
      assertEquals(res.status, 201);
      const body = await res.json();
      assert(!("token" in body), "raw token only travels inside url");
      assertMatch(body.url, /^https:\/\/x\.supabase\.co\/functions\/v1\/sendlinks-open\/[A-Za-z0-9_-]{43}$/);
      urlLink = body.url;
      urlLinkId = body.link_id;
      const go = await visit(urlLink);
      assertEquals(go.status, 302);
      assertEquals(go.headers.get("location"), "https://example.com/deck");
      assertEquals(go.headers.get("cache-control"), "no-store");
      assertEquals(go.headers.get("referrer-policy"), "no-referrer");
    });

    await t.step("unfurlers see the title and spend nothing", async () => {
      const res = await visit(urlLink, { headers: { "user-agent": "Slackbot-LinkExpanding 1.0" } });
      assertEquals(res.status, 200);
      assertMatch(await res.text(), /^Workshop deck\n/);
      const head = await visit(urlLink, { method: "HEAD" });
      assertEquals(head.status, 200);
      const status = await (await api(new Request(`${BASE}/sendlinks-api/links/${urlLinkId}`, { headers: auth }))).json();
      assertEquals(status.views, 1);
      assertEquals(status.events.filter((e: { kind: string }) => e.kind === "previewed").length, 2);
    });

    await t.step("duplicate ref is 409, reissue is 200 with a fresh url", async () => {
      const dup = await post("/links", { venture: "mindmake", kind: "url", title: "x", url: "https://a.b", ref: "deck-1" });
      assertEquals(dup.status, 409);
      await dup.body?.cancel();
      const re = await post("/links", { venture: "mindmake", kind: "url", title: "x", url: "https://a.b", ref: "deck-1", on_duplicate: "reissue" });
      assertEquals(re.status, 200);
      const body = await re.json();
      assert(body.url !== urlLink);
      assertEquals((await visit(urlLink)).status, 404);
      urlLink = body.url;
    });

    await t.step("uploads a file, streams it back inline, and writes a download receipt", async () => {
      const form = new FormData();
      form.append("meta", JSON.stringify({ venture: "mindmake", title: "Proposal", max_views: 1 }));
      form.append("file", new File([new Uint8Array([1, 2, 3])], "Mindmake proposal (v2).pdf", { type: "application/pdf" }));
      const res = await api(new Request(`${BASE}/sendlinks-api/links`, { method: "POST", headers: auth, body: form }));
      assertEquals(res.status, 201);
      const { url, link_id } = await res.json();
      const go = await visit(url);
      assertEquals(go.status, 200);
      assertEquals(go.headers.get("content-type"), "application/pdf");
      assertEquals(go.headers.get("content-disposition"), 'inline; filename="Mindmake proposal (v2).pdf"');
      assertEquals(go.headers.get("content-security-policy"), null, "pdf viewers refuse a sandbox");
      assertEquals([...new Uint8Array(await go.arrayBuffer())], [1, 2, 3]);
      await settled();
      const s = await status(link_id);
      assertEquals([s.receipts.opened, s.receipts.downloaded, s.receipts.downloads], [true, true, 1]);
      assertEquals(s.events[0].kind, "downloaded");
      const again = await visit(url);
      assertEquals(again.status, 410);
      assertMatch(await again.text(), /maximum number of times/);
    });

    await t.step("removes the upload when the link is refused", async () => {
      const form = new FormData();
      form.append("meta", JSON.stringify({ venture: "pulse", title: "Not mine" }));
      form.append("file", new File(["hello"], "a.txt", { type: "text/plain" }));
      const res = await api(new Request(`${BASE}/sendlinks-api/links`, { method: "POST", headers: auth, body: form }));
      assertEquals(res.status, 400);
      assertEquals((await res.json()).error, "venture_not_allowed");
      assertEquals(removed.length, 1);
      assertMatch(removed[0], /^sendlinks\/pulse\//);
    });

    await t.step("password links answer POST with JSON", async () => {
      const res = await post("/links", { venture: "mindmake", kind: "text", title: "Wifi", text: "pa55", password: "open sesame" });
      const { url } = await res.json();
      const get = await visit(url);
      assertEquals(get.status, 401);
      assertMatch(await get.text(), /needs a password/);
      const wrong = await visit(url, { method: "POST", body: JSON.stringify({ password: "x" }) });
      assertEquals(wrong.status, 403);
      await wrong.body?.cancel();
      const right = await visit(url, { method: "POST", body: JSON.stringify({ password: "open sesame" }) });
      assertEquals(right.status, 200);
      const body = await right.json();
      assertEquals([body.kind, body.text, body.views], ["text", "pa55", 1]);
    });

    await t.step("text links render as plain text", async () => {
      const res = await post("/links", { venture: "mindmake", kind: "text", title: "Code", message: "For the workshop", text: "ABC-123" });
      const go = await visit((await res.json()).url);
      assertEquals(go.headers.get("content-type"), "text/plain; charset=utf-8");
      assertEquals(await go.text(), "Code\n\nFor the workshop\n\nABC-123\n");
    });

    await t.step("revoke, then the link is gone", async () => {
      const r = await post(`/links/${urlLinkId}/revoke`, { reason: "wrong recipient" });
      assertEquals(r.status, 200);
      await r.body?.cancel();
      assertEquals((await visit(urlLink)).status, 410);
    });

    await t.step("malformed tokens and ids never reach the database", async () => {
      assertEquals((await visit(`${BASE}/sendlinks-open/short`)).status, 404);
      const r = await api(new Request(`${BASE}/sendlinks-api/links/not-a-uuid`, { headers: auth }));
      assertEquals(r.status, 404);
      await r.body?.cancel();
      const bad = await api(new Request(`${BASE}/sendlinks-api/links`, { method: "POST", headers: auth, body: "[1]" }));
      assertEquals(bad.status, 400);
      await bad.body?.cancel();
    });

    await t.step("idn urls are stored in redirectable form", async () => {
      const res = await post("/links", { venture: "mindmake", kind: "url", title: "x", url: "https://例え.jp/パス", max_views: 1 });
      assertEquals(res.status, 201);
      const go = await visit((await res.json()).url);
      assertEquals(go.status, 302);
      assertEquals(go.headers.get("location"), "https://xn--r8jz45g.jp/%E3%83%91%E3%82%B9");
    });

    await t.step("a storage failure refunds the view", async () => {
      const res = await post("/links", {
        venture: "mindmake", kind: "file", title: "Guide", bucket: "content-library",
        path: "guides/ai-readiness.pdf", max_views: 1,
      });
      const { url, link_id } = await res.json();
      storageDown = true;
      const fail = await visit(url);
      assertEquals(fail.status, 503);
      await fail.body?.cancel();
      storageDown = false;
      const ok = await visit(url);
      assertEquals(ok.status, 200);
      assertEquals(await ok.text(), "%PDF-1.7 guide");
      await settled();
      const s = await status(link_id);
      assertEquals([s.views, s.state, s.receipts.downloads], [1, "exhausted", 1]);
    });

    await t.step("phones named like bots are browsers, real unfurlers are not", async () => {
      const res = await post("/links", { venture: "mindmake", kind: "text", title: "T", text: "body" });
      const { url } = await res.json();
      const cubot = "Mozilla/5.0 (Linux; Android 10; CUBOT_X30) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36";
      assertMatch(await (await visit(url, { headers: { "user-agent": cubot } })).text(), /body/);
      for (const ua of ["Googlebot/2.1 (+http://www.google.com/bot.html)", "LinkedInBot/1.0", "WhatsApp/2.23", "facebookexternalhit/1.1", "curl/8.4.0", "SomeNewBot/3.1"]) {
        const r = await visit(url, { headers: { "user-agent": ua } });
        assertEquals(await r.text(), "T\nOpen this link in a browser to view it.\n", ua);
      }
    });

    await t.step("concurrent creates with one ref: one wins, the other is a duplicate", async () => {
      const body = { venture: "mindmake", kind: "url", title: "x", url: "https://a.b", ref: "race-1" };
      const [{ id: clientId }] = await sql`select id from sendlinks.clients where name = 'http-test'`;
      let second: Promise<Response> | null = null;
      await sql.begin(async (tx) => {
        await tx`select sendlinks.create_link(${clientId}::uuid, ${tx.json(body)})`;
        second = post("/links", body); // blocks on the unique index until this commits
        await new Promise((r) => setTimeout(r, 200));
      });
      const res = await second!;
      assertEquals(res.status, 409);
      assertEquals((await res.json()).error, "duplicate_ref");
    });

    await t.step("an upload sent as a reissue is not orphaned", async () => {
      const form = () => {
        const f = new FormData();
        f.append("meta", JSON.stringify({ venture: "mindmake", title: "Pack", ref: "pack-1", on_duplicate: "reissue" }));
        f.append("file", new File(["zip"], "pack.zip", { type: "application/zip" }));
        return f;
      };
      const send = () => api(new Request(`${BASE}/sendlinks-api/links`, { method: "POST", headers: auth, body: form() }));
      assertEquals((await send()).status, 201);
      const before = removed.length;
      const again = await send();
      assertEquals(again.status, 200);
      await again.body?.cancel();
      assertEquals(removed.length, before + 1);
    });

    await t.step("a download cut off mid-file is an open without a download receipt", async () => {
      const res = await post("/links", { venture: "mindmake", kind: "file", title: "Guide", bucket: "content-library", path: "guides/ai-readiness.pdf" });
      const { url, link_id } = await res.json();
      const go = await visit(url);
      const reader = go.body!.getReader();
      await reader.read();
      await reader.cancel("tab closed");
      await settled();
      const s = await status(link_id);
      assertEquals([s.receipts.opened, s.receipts.downloaded], [true, false]);
      assertEquals(s.events[0].kind, "download_incomplete");
    });

    await t.step("non-inline files download as attachments inside a sandbox", async () => {
      const form = new FormData();
      form.append("meta", JSON.stringify({ venture: "mindmake", title: "Page" }));
      form.append("file", new File(["<script>alert(1)</script>"], "x.html", { type: "text/html" }));
      const { url } = await (await api(new Request(`${BASE}/sendlinks-api/links`, { method: "POST", headers: auth, body: form }))).json();
      const go = await visit(url);
      assertEquals(go.headers.get("content-disposition"), 'attachment; filename="x.html"');
      assertMatch(go.headers.get("content-security-policy")!, /^sandbox/);
      await go.body?.cancel();
      await settled();
    });

    await t.step("list links with receipts, filtered", async () => {
      await post("/links", { venture: "mindmake", kind: "url", title: "Proposal for Acme", url: "https://a.b/p", recipient_email: "Jo@Acme.com", purpose: "proposal" });
      const all = await (await api(new Request(`${BASE}/sendlinks-api/links?purpose=proposal`, { headers: auth }))).json();
      assertEquals(all.links.length, 1);
      assertEquals([all.links[0].recipient_email, all.links[0].receipts.opened], ["jo@acme.com", false]);
      const opened = await (await api(new Request(`${BASE}/sendlinks-api/links?opened=true&limit=500`, { headers: auth }))).json();
      assert(opened.links.length > 0 && opened.links.every((l: { receipts: { opened: boolean } }) => l.receipts.opened));
      const bad = await api(new Request(`${BASE}/sendlinks-api/links?since=not-a-date`, { headers: auth }));
      assertEquals(bad.status, 400);
      await bad.body?.cancel();
    });

    await t.step("receipts are pushed to the caller's webhook", async () => {
      const put = (body: unknown) => api(new Request(`${BASE}/sendlinks-api/webhook`, { method: "PUT", headers: { ...auth, "content-type": "application/json" }, body: JSON.stringify(body) }));
      const weak = await put({ url: "https://hooks.example/n8n", secret: "short" });
      assertEquals(weak.status, 400);
      await weak.body?.cancel();
      const okPut = await put({ url: "https://hooks.example/n8n", secret: "a-long-enough-secret" });
      assertEquals(okPut.status, 200);
      await okPut.body?.cancel();
      const res = await post("/links", { venture: "mindmake", kind: "text", title: "Hello", text: "hi", recipient_email: "sam@example.com", ref: "hook-1" });
      const { url, link_id } = await res.json();
      await (await visit(url)).text();
      await (await visit(url, { headers: { "user-agent": "Slackbot 1.0" } })).text();
      const calls = await sql`select url, body, headers from net.http_requests where body->>'link_id' = ${link_id} order by id`;
      assertEquals(calls.length, 1, "previews and creates are not receipts");
      assertEquals(calls[0].url, "https://hooks.example/n8n");
      assertEquals(calls[0].headers["X-SendLinks-Secret"], "a-long-enough-secret");
      assertEquals([calls[0].body.event, calls[0].body.ref, calls[0].body.receipts.opened], ["opened", "hook-1", true]);
      const del = await api(new Request(`${BASE}/sendlinks-api/webhook`, { method: "DELETE", headers: auth }));
      assertEquals(del.status, 200);
      await del.body?.cancel();
    });

    await t.step("ip is stored only as a per-link hash", async () => {
      const rows = await sql`select e.ip_sha256 from sendlinks.events e
        join sendlinks.links l on l.id = e.link_id
        join sendlinks.clients c on c.id = l.client_id
        where c.name = 'http-test' and e.ip_sha256 is not null`;
      assert(rows.length > 0);
      assert(rows.every((r) => /^[0-9a-f]{64}$/.test(r.ip_sha256)));
      assertEquals((await sql`select count(*)::int as n from sendlinks.events where ip_sha256 like '%203.0.113%'`)[0].n, 0);
    });

    await db.end();
    await sql.end();
  },
});

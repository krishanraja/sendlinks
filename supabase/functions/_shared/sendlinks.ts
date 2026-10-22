// HTTP layer for SendLinks. All rules live in the sendlinks SQL functions; this file only
// authenticates, moves bytes to and from Storage, and maps results onto HTTP.

export type Json = Record<string, unknown>;

export interface Db {
  authenticate(bearer: string): Promise<string | null>;
  createLink(clientId: string, body: Json): Promise<Json>;
  linkStatus(clientId: string, linkId: string): Promise<Json | null>;
  listLinks(clientId: string, filters: Json): Promise<Json>;
  revokeLink(clientId: string, linkId: string, reason: string | null): Promise<Json>;
  setReceiptWebhook(clientId: string, url: string | null, secret: string | null): Promise<Json>;
  openLink(token: string, password: string | null, ipSha256: string | null, userAgent: string | null, consume: boolean): Promise<Json>;
  refundView(linkId: string, detail: string): Promise<void>;
  recordDownload(linkId: string, bytes: number, complete: boolean, ipSha256: string | null, userAgent: string | null): Promise<void>;
}

export interface Storage {
  // A streaming GET of the object. Throws, or returns a non-2xx Response, when it cannot.
  fetchObject(bucket: string, path: string): Promise<Response>;
  upload(bucket: string, path: string, bytes: Uint8Array, contentType: string): Promise<void>;
  remove(bucket: string, path: string): Promise<void>;
}

export interface Deps {
  db: Db;
  storage: Storage;
  publicBase: string; // links are `${publicBase}/${token}`
  // Keeps the worker alive for a write that finishes after the response (EdgeRuntime.waitUntil).
  waitUntil?: (p: Promise<unknown>) => void;
}

export const UPLOAD_BUCKET = "sendlinks";
export const MAX_UPLOAD_BYTES = 25 * 1024 * 1024;
const TOKEN_RE = /^[A-Za-z0-9_-]{43}$/;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// Link unfurlers and scanners that say who they are. They see the title, never the content,
// and never spend a view. Named or `Somethingbot/1.0` style only: a bare "bot" substring would
// also catch real phones (Cubot). Scanners posing as browsers are not caught here (README).
const PREVIEW_UA_RE =
  /\b(?:google|bing|apple|duckduck|yandex|slack|twitter|linkedin|discord|telegram|pinterest|ahrefs|semrush)bot\b|\b\w+bot\/\d|\bbot\b|crawler|spider|slack-imgproxy|facebookexternalhit|facebot|whatsapp|skypeuripreview|embedly|outbrain|vkshare|googleother|headlesschrome|\bcurl\/|\bwget\//i;

// Shown in the browser rather than saved. Nothing that can run script (no HTML, no SVG).
const INLINE_TYPES = /^(application\/pdf|image\/(png|jpeg|gif|webp)|text\/plain|video\/mp4|audio\/mpeg)\b/i;

const SAFE_HEADERS = {
  "Cache-Control": "no-store",
  "Referrer-Policy": "no-referrer",
  "X-Robots-Tag": "noindex, nofollow",
  "X-Content-Type-Options": "nosniff",
};

function json(status: number, body: Json): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...SAFE_HEADERS, "Content-Type": "application/json" },
  });
}

function text(status: number, body: string, extra: Record<string, string> = {}): Response {
  return new Response(body, {
    status,
    headers: { ...SAFE_HEADERS, "Content-Type": "text/plain; charset=utf-8", ...extra },
  });
}

async function sha256Hex(s: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

// Path after the function name, e.g. /functions/v1/sendlinks-api/links/x -> ["links", "x"].
function segmentsAfter(url: URL, fnName: string): string[] {
  const parts = url.pathname.split("/").filter(Boolean);
  const i = parts.indexOf(fnName);
  return i === -1 ? parts : parts.slice(i + 1);
}

function safeFileName(name: string): string {
  const cleaned = name.replace(/[^A-Za-z0-9._-]+/g, "-").replace(/^[.-]+/, "").slice(0, 120);
  return cleaned || "file";
}

// --- Engine API -------------------------------------------------------------------------

const API_ERRORS: Record<string, number> = {
  unauthorized: 401,
  duplicate_ref: 409,
  link_inactive: 409,
  not_found: 404,
};

export function makeApiHandler(deps: Deps, fnName = "sendlinks-api") {
  return async (incoming: Request): Promise<Response> => {
    // Take the whole body before any other I/O, so nothing downstream reads a half-consumed
    // stream after an await.
    const req = incoming.body
      ? new Request(incoming.url, { method: incoming.method, headers: incoming.headers, body: await incoming.arrayBuffer() })
      : incoming;
    const url = new URL(req.url);
    const seg = segmentsAfter(url, fnName);
    const bearer = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
    const clientId = bearer ? await deps.db.authenticate(bearer) : null;
    if (!clientId) return json(401, { ok: false, error: "unauthorized" });

    if (seg[0] === "webhook" && seg.length === 1) {
      if (req.method === "DELETE") return json(200, await deps.db.setReceiptWebhook(clientId, null, null));
      if (req.method === "PUT") {
        const body = await req.json().catch(() => ({})) as Json;
        const r = await deps.db.setReceiptWebhook(
          clientId,
          typeof body.url === "string" ? body.url : null,
          typeof body.secret === "string" ? body.secret : null,
        );
        return json(r.ok ? 200 : 400, r);
      }
      return json(405, { ok: false, error: "method_not_allowed" });
    }

    if (seg[0] !== "links") return json(404, { ok: false, error: "not_found" });

    if (seg.length === 1) {
      if (req.method === "POST") return createLink(deps, clientId, req);
      if (req.method === "GET") {
        const f: Json = {};
        for (const k of ["venture", "recipient_email", "purpose", "since", "opened", "limit"]) {
          const v = url.searchParams.get(k);
          if (v !== null && v !== "") f[k] = v;
        }
        const r = await deps.db.listLinks(clientId, f);
        return json(r.ok ? 200 : 400, r);
      }
      return json(405, { ok: false, error: "method_not_allowed" });
    }

    const linkId = seg[1] ?? "";
    if (!UUID_RE.test(linkId)) return json(404, { ok: false, error: "not_found" });

    if (req.method === "GET" && seg.length === 2) {
      const status = await deps.db.linkStatus(clientId, linkId);
      return status ? json(200, status) : json(404, { ok: false, error: "not_found" });
    }
    if (req.method === "POST" && seg.length === 3 && seg[2] === "revoke") {
      const body = await req.json().catch(() => ({})) as Json;
      const reason = typeof body.reason === "string" ? body.reason.slice(0, 500) : null;
      const r = await deps.db.revokeLink(clientId, linkId, reason);
      return json(r.ok ? 200 : API_ERRORS[String(r.error)] ?? 400, r);
    }
    return json(405, { ok: false, error: "method_not_allowed" });
  };
}

async function createLink(deps: Deps, clientId: string, req: Request): Promise<Response> {
  const ctype = req.headers.get("content-type") ?? "";
  let body: Json;
  let uploaded: { bucket: string; path: string } | null = null;

  if (ctype.startsWith("multipart/form-data")) {
    const form = await req.formData().catch(() => null);
    const file = form?.get("file");
    let meta: unknown = null;
    try {
      meta = JSON.parse(String(form?.get("meta") ?? "{}"));
    } catch { /* reported below */ }
    if (!(file instanceof File) || !meta || typeof meta !== "object") {
      return json(400, { ok: false, error: "invalid", detail: "multipart needs a file part and a JSON meta part" });
    }
    if (file.size === 0 || file.size > MAX_UPLOAD_BYTES) {
      return json(413, { ok: false, error: "file_size", detail: `1 byte to ${MAX_UPLOAD_BYTES} bytes` });
    }
    body = meta as Json;
    const venture = typeof body.venture === "string" ? body.venture : "";
    if (!/^[a-z0-9-]{1,64}$/.test(venture)) {
      return json(400, { ok: false, error: "unknown_venture", detail: venture });
    }
    const month = new Date().toISOString().slice(0, 7);
    const path = `${venture}/${month}/${crypto.randomUUID()}/${safeFileName(file.name)}`;
    const contentType = file.type || "application/octet-stream";
    await deps.storage.upload(UPLOAD_BUCKET, path, new Uint8Array(await file.arrayBuffer()), contentType);
    uploaded = { bucket: UPLOAD_BUCKET, path };
    body = {
      ...body,
      kind: "file",
      bucket: UPLOAD_BUCKET,
      path,
      file_name: typeof body.file_name === "string" ? body.file_name : file.name,
      content_type: contentType,
      bytes: file.size,
    };
  } else {
    const parsed = await req.json().catch(() => null);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      return json(400, { ok: false, error: "invalid", detail: "body must be a JSON object" });
    }
    body = parsed as Json;
  }

  // Store the browser-safe form: IDN hosts to punycode, non-ASCII percent-encoded, so the
  // redirect header can always be built. Anything not https is left for the database to refuse.
  if (typeof body.url === "string") {
    try {
      const u = new URL(body.url);
      if (u.protocol === "https:") body = { ...body, url: u.href };
    } catch { /* refused as invalid below */ }
  }

  const r = await deps.db.createLink(clientId, body);
  // A refused or reissued link never points at this upload, so it would be orphaned.
  if (uploaded && (!r.ok || r.reissued)) {
    await deps.storage.remove(uploaded.bucket, uploaded.path).catch(() => {});
  }
  if (!r.ok) return json(API_ERRORS[String(r.error)] ?? 400, r);
  const { token, ...rest } = r;
  return json(r.reissued ? 200 : 201, { ...rest, url: `${deps.publicBase}/${token}` });
}

// --- Recipient side ---------------------------------------------------------------------

const OPEN_ERRORS: Record<string, [number, string]> = {
  not_found: [404, "This link does not exist."],
  expired: [410, "This link has expired."],
  revoked: [410, "This link has been withdrawn."],
  exhausted: [410, "This link has already been used the maximum number of times."],
  locked: [423, "This link is locked after too many wrong passwords."],
  password_required: [401, "This link needs a password."],
  bad_password: [403, "That password is not right."],
  unavailable: [503, "This link could not be opened just now. Try again in a minute."],
};

export function makeOpenHandler(deps: Deps, fnName = "sendlinks-open") {
  return async (req: Request): Promise<Response> => {
    const url = new URL(req.url);
    const token = segmentsAfter(url, fnName)[0] ?? "";
    const asJson = req.method === "POST";
    const fail = (reason: string) => {
      const [status, message] = OPEN_ERRORS[reason] ?? [400, "This link cannot be opened."];
      return asJson ? json(status, { ok: false, reason, message }) : text(status, message + "\n");
    };

    if (!["GET", "HEAD", "POST"].includes(req.method)) return text(405, "Method not allowed\n");
    if (!TOKEN_RE.test(token)) return fail("not_found");

    const ua = req.headers.get("user-agent");
    const ip = (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim();
    // Salted with the token, so the same visitor cannot be linked across links.
    const ipHash = ip ? await sha256Hex(`${token}:${ip}`) : null;
    const preview = req.method === "HEAD" || (!asJson && PREVIEW_UA_RE.test(ua ?? ""));

    let password: string | null = null;
    if (asJson) {
      const body = await req.json().catch(() => ({})) as Json;
      password = typeof body.password === "string" ? body.password : null;
    }

    const r = await deps.db.openLink(token, password, ipHash, ua, !preview);
    if (!r.ok) return fail(String(r.reason));

    if (r.preview) {
      return text(200, `${r.title}\nOpen this link in a browser to view it.\n`);
    }

    // The view is already spent. If the content cannot be handed over, give it back so a
    // read-once link survives a Storage hiccup.
    const refund = async (e: unknown) => {
      await deps.db.refundView(String(r.link_id), e instanceof Error ? e.message : String(e));
      return fail("unavailable");
    };

    if (r.kind === "file") {
      // Files always stream through here, for GET and POST alike, so the last byte leaving is
      // what writes the download receipt.
      let upstream: Response;
      try {
        upstream = await deps.storage.fetchObject(String(r.bucket), String(r.path));
        if (!upstream.ok || !upstream.body) throw new Error(`storage answered ${upstream.status}`);
      } catch (e) {
        return refund(e);
      }
      return streamFile(deps, r, upstream, ipHash, ua);
    }

    let target: string | null = null;
    if (r.kind === "url") {
      try {
        target = new URL(String(r.url)).href;
        new Headers({ Location: target });
      } catch (e) {
        return refund(e);
      }
    }

    if (asJson) {
      return json(200, {
        ok: true,
        kind: r.kind,
        title: r.title,
        message: r.message ?? null,
        url: target,
        text: r.kind === "text" ? r.text : null,
        views: r.views,
        max_views: r.max_views ?? null,
        expires_at: r.expires_at,
      });
    }
    if (target) return new Response(null, { status: 302, headers: { ...SAFE_HEADERS, Location: target } });
    const head = r.message ? `${r.title}\n\n${r.message}\n\n` : `${r.title}\n\n`;
    return text(200, head + String(r.text) + "\n");
  };
}

function streamFile(deps: Deps, r: Json, upstream: Response, ipHash: string | null, ua: string | null): Response {
  const linkId = String(r.link_id);
  const contentType = String(r.content_type || upstream.headers.get("content-type") || "application/octet-stream");
  const fileName = String(r.file_name || "download");
  const length = upstream.headers.get("content-length");
  const reader = upstream.body!.getReader();
  let sent = 0;
  let settled = false;
  const settle = (complete: boolean) => {
    if (settled) return;
    settled = true;
    const write = deps.db.recordDownload(linkId, sent, complete, ipHash, ua).catch(() => {});
    deps.waitUntil?.(write);
  };

  const body = new ReadableStream<Uint8Array>({
    async pull(controller) {
      try {
        const { done, value } = await reader.read();
        if (done) {
          controller.close();
          settle(true);
          return;
        }
        sent += value.byteLength;
        controller.enqueue(value);
      } catch (e) {
        settle(false);
        controller.error(e);
      }
    },
    cancel(reason) {
      // The recipient closed the tab or lost the connection mid-file.
      settle(false);
      return reader.cancel(reason);
    },
  });

  const headers: Record<string, string> = {
    ...SAFE_HEADERS,
    "Content-Type": contentType,
    "Content-Disposition": `${INLINE_TYPES.test(contentType) ? "inline" : "attachment"}; filename="${fileName}"`,
  };
  // Chrome will not render a PDF inside a sandboxed document; everything else gets the sandbox.
  if (!/^application\/pdf\b/i.test(contentType)) {
    headers["Content-Security-Policy"] = "sandbox; default-src 'none'; img-src 'self'; media-src 'self'; style-src 'unsafe-inline'";
  }
  if (length) headers["Content-Length"] = length;
  return new Response(body, { status: 200, headers });
}

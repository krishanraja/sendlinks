// HTTP layer for SendLinks. All rules live in the sendlinks SQL functions; this file only
// authenticates, moves bytes to and from Storage, and maps results onto HTTP.

export type Json = Record<string, unknown>;

export interface Db {
  authenticate(bearer: string): Promise<string | null>;
  createLink(clientId: string, body: Json): Promise<Json>;
  linkStatus(clientId: string, linkId: string): Promise<Json | null>;
  revokeLink(clientId: string, linkId: string, reason: string | null): Promise<Json>;
  openLink(token: string, password: string | null, ipSha256: string | null, userAgent: string | null, consume: boolean): Promise<Json>;
}

export interface Storage {
  signedUrl(bucket: string, path: string, fileName: string, ttlSeconds: number): Promise<string>;
  upload(bucket: string, path: string, bytes: Uint8Array, contentType: string): Promise<void>;
  remove(bucket: string, path: string): Promise<void>;
}

export interface Deps {
  db: Db;
  storage: Storage;
  publicBase: string; // links are `${publicBase}/${token}`
}

export const UPLOAD_BUCKET = "sendlinks";
export const MAX_UPLOAD_BYTES = 25 * 1024 * 1024;
const SIGNED_URL_TTL = 60;
const TOKEN_RE = /^[A-Za-z0-9_-]{43}$/;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// Link unfurlers and scanners that say who they are. They see the title, never the content,
// and never spend a view.
const PREVIEW_UA_RE =
  /bot\b|crawler|spider|slack|facebookexternalhit|twitterbot|linkedinbot|discord|whatsapp|telegram|skypeuripreview|embedly|preview|outbrain|pinterest|vkshare|googleother|headlesschrome|curl\/|wget\//i;

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
  not_found: 404,
};

export function makeApiHandler(deps: Deps, fnName = "sendlinks-api") {
  return async (req: Request): Promise<Response> => {
    const url = new URL(req.url);
    const seg = segmentsAfter(url, fnName);
    const bearer = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
    const clientId = bearer ? await deps.db.authenticate(bearer) : null;
    if (!clientId) return json(401, { ok: false, error: "unauthorized" });

    if (seg[0] !== "links") return json(404, { ok: false, error: "not_found" });

    if (req.method === "POST" && seg.length === 1) return createLink(deps, clientId, req);

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

  const r = await deps.db.createLink(clientId, body);
  if (!r.ok) {
    if (uploaded) await deps.storage.remove(uploaded.bucket, uploaded.path).catch(() => {});
    return json(API_ERRORS[String(r.error)] ?? 400, r);
  }
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

    let target: string | null = null;
    if (r.kind === "url") target = String(r.url);
    if (r.kind === "file") {
      target = await deps.storage.signedUrl(String(r.bucket), String(r.path), String(r.file_name), SIGNED_URL_TTL);
    }

    if (asJson) {
      return json(200, {
        ok: true,
        kind: r.kind,
        title: r.title,
        message: r.message ?? null,
        url: r.kind === "url" ? target : null,
        download_url: r.kind === "file" ? target : null,
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

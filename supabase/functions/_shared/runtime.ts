// Production wiring. The SQL functions are reached over HTTPS through PostgREST, using the
// public.sendlinks_* wrappers that only the service role may execute. The edge runtime's
// direct Postgres connections hung on about one request in three (live canary, 2026-10-22),
// so nothing here holds a database connection. Storage goes through the same service role.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import type { Db, Deps, Json, Storage } from "./sendlinks.ts";

const RPC_TIMEOUT_MS = 10_000;

export function restDb(supabaseUrl: string, serviceKey: string): Db {
  const rpc = async <T>(fn: string, args: Json): Promise<T> => {
    const res = await fetch(`${supabaseUrl}/rest/v1/rpc/sendlinks_${fn}`, {
      method: "POST",
      headers: {
        apikey: serviceKey,
        Authorization: `Bearer ${serviceKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(args),
      signal: AbortSignal.timeout(RPC_TIMEOUT_MS),
    });
    const body = await res.text();
    if (!res.ok) throw new Error(`rpc ${fn} answered ${res.status}: ${body.slice(0, 200)}`);
    return (body ? JSON.parse(body) : null) as T;
  };
  return {
    authenticate: (bearer) => rpc("authenticate", { p_bearer: bearer }),
    createLink: (clientId, body) => rpc("create_link", { p_client_id: clientId, p: body }),
    linkStatus: (clientId, linkId) => rpc("link_status", { p_client_id: clientId, p_link_id: linkId }),
    listLinks: (clientId, f) => rpc("list_links", { p_client_id: clientId, f }),
    revokeLink: (clientId, linkId, reason) =>
      rpc("revoke_link", { p_client_id: clientId, p_link_id: linkId, p_reason: reason }),
    setReceiptWebhook: (clientId, url, secret) =>
      rpc("set_receipt_webhook", { p_client_id: clientId, p_url: url, p_secret: secret }),
    openLink: (token, password, ipSha256, userAgent, consume) =>
      rpc("open_link", {
        p_token: token, p_password: password, p_ip_sha256: ipSha256, p_user_agent: userAgent, p_consume: consume,
      }),
    refundView: async (linkId, detail) => {
      await rpc("refund_view", { p_link_id: linkId, p_detail: detail });
    },
    recordDownload: async (linkId, bytes, complete, ipSha256, userAgent) => {
      await rpc("record_download", {
        p_link_id: linkId, p_bytes: bytes, p_complete: complete, p_ip_sha256: ipSha256, p_user_agent: userAgent,
      });
    },
  };
}

export function supabaseStorage(url: string, serviceKey: string): Storage {
  const sb = createClient(url, serviceKey, { auth: { persistSession: false } });
  return {
    async fetchObject(bucket, path) {
      const { data, error } = await sb.storage.from(bucket).createSignedUrl(path, 60);
      if (error || !data) throw new Error(`signed url failed: ${error?.message}`);
      return fetch(data.signedUrl, { signal: AbortSignal.timeout(30_000) });
    },
    async upload(bucket, path, bytes, contentType) {
      const { error } = await sb.storage.from(bucket).upload(path, bytes, { contentType, upsert: false });
      if (error) throw new Error(`upload failed: ${error.message}`);
    },
    async remove(bucket, path) {
      await sb.storage.from(bucket).remove([path]);
    },
  };
}

export function depsFromEnv(): Deps {
  const env = (k: string) => {
    const v = Deno.env.get(k);
    if (!v) throw new Error(`missing env ${k}`);
    return v;
  };
  const supabaseUrl = env("SUPABASE_URL");
  const serviceKey = env("SUPABASE_SERVICE_ROLE_KEY");
  const runtime = (globalThis as { EdgeRuntime?: { waitUntil(p: Promise<unknown>): void } }).EdgeRuntime;
  return {
    db: restDb(supabaseUrl, serviceKey),
    storage: supabaseStorage(supabaseUrl, serviceKey),
    publicBase: (Deno.env.get("SENDLINKS_PUBLIC_BASE") ?? `${supabaseUrl}/functions/v1/sendlinks-open`).replace(/\/$/, ""),
    waitUntil: runtime ? (p) => runtime.waitUntil(p) : undefined,
  };
}

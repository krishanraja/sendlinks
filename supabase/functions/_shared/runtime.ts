// Production wiring: Postgres over SUPABASE_DB_URL (the sendlinks schema is never exposed
// through PostgREST) and Storage through the service role, both injected by the platform.
import postgres from "npm:postgres@3.4.5";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import type { Db, Deps, Json, Storage } from "./sendlinks.ts";

export function pgDb(dbUrl: string): Db {
  const sql = postgres(dbUrl, { prepare: false, max: 3, idle_timeout: 20 });
  const one = async <T>(q: Promise<{ r: T }[]>) => (await q)[0]?.r ?? null;
  return {
    authenticate: (bearer) => one(sql`select sendlinks.authenticate(${bearer}) as r`),
    createLink: async (clientId, body) =>
      (await one(sql`select sendlinks.create_link(${clientId}::uuid, ${sql.json(body as never)}) as r`)) as Json,
    linkStatus: (clientId, linkId) =>
      one(sql`select sendlinks.link_status(${clientId}::uuid, ${linkId}::uuid) as r`),
    revokeLink: async (clientId, linkId, reason) =>
      (await one(sql`select sendlinks.revoke_link(${clientId}::uuid, ${linkId}::uuid, ${reason}) as r`)) as Json,
    openLink: async (token, password, ipSha256, userAgent, consume) =>
      (await one(sql`select sendlinks.open_link(${token}, ${password}, ${ipSha256}, ${userAgent}, ${consume}) as r`)) as Json,
  };
}

export function supabaseStorage(url: string, serviceKey: string): Storage {
  const sb = createClient(url, serviceKey, { auth: { persistSession: false } });
  return {
    async signedUrl(bucket, path, fileName, ttl) {
      const { data, error } = await sb.storage.from(bucket).createSignedUrl(path, ttl, { download: fileName });
      if (error || !data) throw new Error(`signed url failed: ${error?.message}`);
      return data.signedUrl;
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
  return {
    db: pgDb(env("SUPABASE_DB_URL")),
    storage: supabaseStorage(supabaseUrl, env("SUPABASE_SERVICE_ROLE_KEY")),
    publicBase: (Deno.env.get("SENDLINKS_PUBLIC_BASE") ?? `${supabaseUrl}/functions/v1/sendlinks-open`).replace(/\/$/, ""),
  };
}

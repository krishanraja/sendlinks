// Test wiring: the same Db contract over a direct Postgres connection, for tests/run-local.sh.
// Production uses restDb in runtime.ts; this file is never deployed.
import postgres from "npm:postgres@3.4.5";
import type { Db, Json } from "./sendlinks.ts";

export function pgDb(dbUrl: string): Db & { end(): Promise<void> } {
  const sql = postgres(dbUrl, { prepare: false, max: 3 });
  const one = async <T>(q: Promise<{ r: T }[]>) => (await q)[0]?.r ?? null;
  return {
    authenticate: (bearer) => one(sql`select public.sendlinks_authenticate(${bearer}) as r`),
    createLink: async (clientId, body) =>
      (await one(sql`select public.sendlinks_create_link(${clientId}::uuid, ${sql.json(body as never)}) as r`)) as Json,
    linkStatus: (clientId, linkId) =>
      one(sql`select public.sendlinks_link_status(${clientId}::uuid, ${linkId}::uuid) as r`),
    listLinks: async (clientId, f) =>
      (await one(sql`select public.sendlinks_list_links(${clientId}::uuid, ${sql.json(f as never)}) as r`)) as Json,
    revokeLink: async (clientId, linkId, reason) =>
      (await one(sql`select public.sendlinks_revoke_link(${clientId}::uuid, ${linkId}::uuid, ${reason}) as r`)) as Json,
    setReceiptWebhook: async (clientId, url, secret) =>
      (await one(sql`select public.sendlinks_set_receipt_webhook(${clientId}::uuid, ${url}, ${secret}) as r`)) as Json,
    openLink: async (token, password, ipSha256, userAgent, consume) =>
      (await one(sql`select public.sendlinks_open_link(${token}, ${password}, ${ipSha256}, ${userAgent}, ${consume}) as r`)) as Json,
    refundView: async (linkId, detail) => {
      await sql`select public.sendlinks_refund_view(${linkId}::uuid, ${detail})`;
    },
    recordDownload: async (linkId, bytes, complete, ipSha256, userAgent) => {
      await sql`select public.sendlinks_record_download(${linkId}::uuid, ${bytes}, ${complete}, ${ipSha256}, ${userAgent})`;
    },
    end: () => sql.end(),
  };
}

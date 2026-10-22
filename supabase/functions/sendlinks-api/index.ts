import { makeApiHandler } from "../_shared/sendlinks.ts";
import { depsFromEnv } from "../_shared/runtime.ts";

const handler = makeApiHandler(depsFromEnv());

Deno.serve(async (req) => {
  try {
    return await handler(req);
  } catch (e) {
    console.error("sendlinks-api", e instanceof Error ? e.message : e);
    return Response.json({ ok: false, error: "internal" }, { status: 500 });
  }
});

import { makeOpenHandler } from "../_shared/sendlinks.ts";
import { depsFromEnv } from "../_shared/runtime.ts";

const handler = makeOpenHandler(depsFromEnv());

Deno.serve(async (req) => {
  try {
    return await handler(req);
  } catch (e) {
    console.error("sendlinks-open", e instanceof Error ? e.message : e);
    return new Response("Something went wrong opening this link. Try again shortly.\n", {
      status: 500,
      headers: { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store" },
    });
  }
});

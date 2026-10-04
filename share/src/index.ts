// atlas-share: serves Atlas share links from R2. See ../CONTRACT.md.

import { handleAdmin } from "./admin";
import { handlePublic, notice } from "./public";
import { type Env, sweep } from "./store";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    try {
      if (url.pathname === "/api" || url.pathname.startsWith("/api/")) return await handleAdmin(request, env, url);
      if (url.pathname.startsWith("/s/")) return await handlePublic(request, env, url);
      if (url.pathname === "/favicon.ico") return new Response(null, { status: 204 });
      if (url.pathname === "/robots.txt")
        return new Response("User-agent: *\nDisallow: /\n", {
          headers: { "Content-Type": "text/plain; charset=utf-8", "X-Robots-Tag": "noindex, nofollow" },
        });
      return notice(404);
    } catch (e) {
      console.error("request failed", url.pathname, e);
      if (url.pathname.startsWith("/api/"))
        return new Response(JSON.stringify({ error: "internal error" }), {
          status: 500,
          headers: { "Content-Type": "application/json; charset=utf-8" },
        });
      return notice(500);
    }
  },

  async scheduled(_controller: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
    ctx.waitUntil(
      sweep(env.SHARES, Math.floor(Date.now() / 1000)).then(
        (r) => console.log(`sweep: ${r.checked} shares checked, ${r.deleted.length} deleted`),
        (e) => console.error("sweep failed", e),
      ),
    );
  },
} satisfies ExportedHandler<Env>;

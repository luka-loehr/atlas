// The recipient's side: the share page, the password gate and the files.

import { sessionExpiry, signSession, verifySession, verifyPassword } from "./crypto";
import { contentSecurityPolicy, creatingPage, galleryPage, gatePage, newNonce, noticePage } from "./html";
import { ASSET_ID_RE, fileKey, isFileKind, isLive, type Manifest, type Progress, SHARE_ID_RE } from "./manifest";
import { parseRange } from "./range";
import { type Env, loadManifest, loadProgress } from "./store";

const now = () => Math.floor(Date.now() / 1000);

function page(html: string, nonce: string, status = 200, extra: Record<string, string> = {}): Response {
  return new Response(html, {
    status,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Robots-Tag": "noindex, nofollow",
      "Content-Security-Policy": contentSecurityPolicy(nonce),
      "Referrer-Policy": "no-referrer",
      "X-Content-Type-Options": "nosniff",
      "X-Frame-Options": "DENY",
      ...extra,
    },
  });
}

export function notice(status: 404 | 410 | 500 | 405): Response {
  const nonce = newNonce();
  const [title, line] =
    status === 410
      ? ["Link expired", "This link has expired."]
      : status === 500
        ? ["Unavailable", "This link can’t be opened right now."]
        : status === 405
          ? ["Not allowed", "This request isn’t supported."]
          : ["Not found", "This link doesn’t exist."];
  return page(noticePage(nonce, title, line), nonce, status);
}

function fileError(status: number): Response {
  return new Response(null, {
    status,
    headers: { "X-Robots-Tag": "noindex, nofollow", "Cache-Control": "no-store" },
  });
}

export function cookieName(id: string): string {
  return `as_${id}`;
}

function readCookie(request: Request, name: string): string | null {
  const header = request.headers.get("Cookie");
  if (!header) return null;
  for (const part of header.split(";")) {
    const eq = part.indexOf("=");
    if (eq < 0) continue;
    if (part.slice(0, eq).trim() === name) return part.slice(eq + 1).trim();
  }
  return null;
}

/** True when the share has no password, or the request carries a valid session. */
async function unlocked(request: Request, env: Env, id: string, m: Manifest): Promise<boolean | "no-secret"> {
  if (!m.password_hash) return true;
  if (!env.SESSION_SECRET) return "no-secret";
  const value = readCookie(request, cookieName(id));
  return value !== null && (await verifySession(env.SESSION_SECRET, id, value, now()));
}

export async function handlePublic(request: Request, env: Env, url: URL): Promise<Response> {
  const parts = url.pathname.split("/");
  // ["", "s", id, ...rest]
  const id = parts[2] ?? "";
  if (!SHARE_ID_RE.test(id)) return notice(404);
  const rest = parts.slice(3);
  const method = request.method;

  if (rest.length === 0) {
    if (method !== "GET" && method !== "HEAD") return notice(405);
    return sharePage(request, env, url, id, false);
  }
  if (rest.length === 1 && rest[0] === "") {
    return Response.redirect(`${url.origin}/s/${id}`, 308);
  }
  if (rest.length === 1 && rest[0] === "status") {
    if (method !== "GET") return fileError(405);
    return status(env, id);
  }
  if (rest.length === 1 && rest[0] === "unlock") {
    if (method !== "POST") return Response.redirect(`${url.origin}/s/${id}`, 303);
    return unlock(request, env, url, id);
  }
  if (rest.length === 3 && rest[0] === "f") {
    if (method !== "GET" && method !== "HEAD") return fileError(405);
    return serveFile(request, env, id, rest[1]!, rest[2]!);
  }
  return notice(404);
}

/**
 * A share atlas is still creating: its progress (written every few seconds),
 * or a bare marker when only files are there yet.
 */
async function creating(env: Env, id: string): Promise<Progress | "unknown" | null> {
  const p = await loadProgress(env.SHARES, id);
  if (p) return p;
  const listed = await env.SHARES.list({ prefix: `s/${id}/`, limit: 1 });
  return listed.objects.length > 0 ? "unknown" : null;
}

/** What the "being created" page polls. `ready` → load the gallery. */
async function status(env: Env, id: string): Promise<Response> {
  const headers = { "Content-Type": "application/json", "Cache-Control": "no-store", "X-Robots-Tag": "noindex, nofollow" };
  const m = await loadManifest(env.SHARES, id);
  if (m) return new Response(JSON.stringify({ ready: isLive(m, now()) }), { headers });
  const p = await creating(env, id);
  if (!p) return new Response(JSON.stringify({ gone: true }), { status: 404, headers });
  if (p !== "unknown" && !isLive(p, now())) return new Response(JSON.stringify({ gone: true }), { status: 410, headers });
  return new Response(JSON.stringify(progressView(p)), { headers });
}

/** The numbers the page shows; a report older than a minute means atlas paused. */
function progressView(p: Progress | "unknown") {
  if (p === "unknown") return { ready: false };
  const stale = now() - p.updated_at > 60;
  return {
    ready: false,
    count: p.count,
    done: p.done_bytes,
    total: p.total_bytes,
    eta_s: stale ? null : p.eta_s,
    paused: stale,
  };
}

async function sharePage(request: Request, env: Env, url: URL, id: string, wrong: boolean): Promise<Response> {
  const m = await loadManifest(env.SHARES, id);
  if (!m) {
    const p = await creating(env, id);
    if (!p) return notice(404);
    if (p !== "unknown" && !isLive(p, now())) return notice(410);
    const nonce = newNonce();
    return page(creatingPage(nonce, id, p === "unknown" ? "" : p.title, progressView(p)), nonce, 202);
  }
  if (!isLive(m, now())) return notice(410);
  const access = await unlocked(request, env, id, m);
  if (access === "no-secret") return notice(500);
  const nonce = newNonce();
  if (!access) return page(gatePage(nonce, id, m.title, wrong), nonce, wrong ? 403 : 200);
  return page(
    galleryPage({ nonce, id, manifest: m, previewOrigin: m.password_hash ? undefined : url.origin }),
    nonce,
  );
}

async function unlock(request: Request, env: Env, url: URL, id: string): Promise<Response> {
  const m = await loadManifest(env.SHARES, id);
  if (!m) return notice(404);
  const t = now();
  if (!isLive(m, t)) return notice(410);
  const back = `${url.origin}/s/${id}`;
  if (!m.password_hash) return Response.redirect(back, 303);
  if (!env.SESSION_SECRET) return notice(500);

  let password = "";
  try {
    const form = await request.formData();
    const v = form.get("password");
    if (typeof v === "string") password = v;
  } catch {
    // Not a form: treated as a wrong password.
  }
  if (!password || password.length > 1024 || !(await verifyPassword(password, m.password_hash))) {
    const nonce = newNonce();
    return page(gatePage(nonce, id, m.title, true), nonce, 403);
  }

  const expiry = sessionExpiry(m.expires_at, t);
  const value = await signSession(env.SESSION_SECRET, id, expiry);
  const cookie = `${cookieName(id)}=${value}; Max-Age=${expiry - t}; Path=/s/${id}; HttpOnly; Secure; SameSite=Lax`;
  return new Response(null, {
    status: 303,
    headers: {
      Location: back,
      "Set-Cookie": cookie,
      "Cache-Control": "no-store",
      "X-Robots-Tag": "noindex, nofollow",
    },
  });
}

/** `attachment` with an ASCII fallback and the exact name per RFC 5987/6266. */
export function contentDisposition(name: string): string {
  const ascii = name.replace(/[^\x20-\x7e]/g, "_").replace(/["\\]/g, "_") || "download";
  const encoded = encodeURIComponent(name).replace(
    /['()*]/g,
    (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`,
  );
  return `attachment; filename="${ascii}"; filename*=UTF-8''${encoded}`;
}

function etagMatches(header: string | null, etag: string): boolean {
  if (!header) return false;
  if (header.trim() === "*") return true;
  const strip = (t: string) => t.trim().replace(/^W\//, "");
  return header.split(",").some((t) => strip(t) === strip(etag));
}

async function serveFile(request: Request, env: Env, id: string, kind: string, asset: string): Promise<Response> {
  if (!isFileKind(kind) || !ASSET_ID_RE.test(asset)) return fileError(404);
  const m = await loadManifest(env.SHARES, id);
  if (!m || !isLive(m, now())) return fileError(404);
  const access = await unlocked(request, env, id, m);
  if (access === "no-secret") return fileError(500);
  if (!access) return fileError(404);
  const item = m.items.find((i) => i.id === asset);
  if (!item) return fileError(404);
  // Never an original on a share without downloads, whatever is in the bucket.
  if (kind === "o" && m.allow_download !== true) return fileError(403);

  const key = fileKey(id, kind, asset);
  const head = await env.SHARES.head(key);
  if (!head) return fileError(404);

  const headers = new Headers({
    "Cache-Control": "private, max-age=86400",
    "X-Robots-Tag": "noindex, nofollow",
    "X-Content-Type-Options": "nosniff",
    "Content-Security-Policy": "default-src 'none'; sandbox",
    "Referrer-Policy": "no-referrer",
    "Accept-Ranges": "bytes",
    ETag: head.httpEtag,
  });
  if (kind === "o") {
    headers.set("Content-Type", head.httpMetadata?.contentType || "application/octet-stream");
    headers.set("Content-Disposition", contentDisposition(item.name));
  } else {
    headers.set("Content-Type", head.httpMetadata?.contentType || (kind === "t" ? "image/webp" : item.view));
  }

  if (etagMatches(request.headers.get("If-None-Match"), head.httpEtag)) {
    return new Response(null, { status: 304, headers });
  }

  const size = head.size;
  // A Range is honoured only while the file is unchanged (If-Range with an ETag).
  const ifRange = request.headers.get("If-Range");
  const rangeHeader = ifRange && !etagMatches(ifRange, head.httpEtag) ? null : request.headers.get("Range");
  const range = parseRange(rangeHeader, size);

  if (range === "unsatisfiable") {
    headers.set("Content-Range", `bytes */${size}`);
    headers.delete("Content-Type");
    headers.delete("Content-Disposition");
    return new Response(null, { status: 416, headers });
  }

  const isHead = request.method === "HEAD";
  if (range) {
    headers.set("Content-Range", `bytes ${range.offset}-${range.offset + range.length - 1}/${size}`);
    headers.set("Content-Length", String(range.length));
    if (isHead) return new Response(null, { status: 206, headers });
    const obj = await env.SHARES.get(key, { range });
    if (!obj) return fileError(404);
    return new Response(obj.body, { status: 206, headers });
  }

  headers.set("Content-Length", String(size));
  if (isHead) return new Response(null, { status: 200, headers });
  const obj = await env.SHARES.get(key);
  if (!obj) return fileError(404);
  return new Response(obj.body, { status: 200, headers });
}

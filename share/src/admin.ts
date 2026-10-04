// The admin API atlas-server talks to. Every route needs the bearer token.

import pkg from "../package.json";
import { hashPassword, safeEqual } from "./crypto";
import {
  ASSET_ID_RE,
  fileKey,
  isFileKind,
  type Manifest,
  MAX_DAYS,
  SHARE_ID_RE,
  shareKey,
  validateInput,
} from "./manifest";
import { deleteShare, type Env, loadManifest } from "./store";

/** Largest single PUT or part. Workers accept 100 MB request bodies. */
export const MAX_BODY = 95 * 1024 * 1024;
const MAX_MANIFEST = 8 * 1024 * 1024;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Robots-Tag": "noindex, nofollow",
    },
  });
}

const error = (status: number, message: string) => json({ error: message }, status);

async function authorize(request: Request, env: Env): Promise<Response | null> {
  const token = env.SHARE_TOKEN;
  // Fail closed: without a configured token nothing is accepted.
  if (!token) return error(500, "SHARE_TOKEN is not set");
  const header = request.headers.get("Authorization") ?? "";
  const m = /^Bearer[ ]+(.+)$/i.exec(header);
  const ok = await safeEqual(m ? m[1]!.trim() : "", token);
  if (!m || !ok) {
    return new Response(JSON.stringify({ error: "unauthorized" }), {
      status: 401,
      headers: { "Content-Type": "application/json; charset=utf-8", "WWW-Authenticate": "Bearer" },
    });
  }
  return null;
}

/** Content-Length is required: R2 needs a known length to stream a body. */
function bodyLength(request: Request): number | Response {
  const text = request.headers.get("Content-Length");
  if (text === null || !/^\d+$/.test(text)) return error(411, "Content-Length is required");
  const n = Number(text);
  if (n > MAX_BODY) return error(413, `body is larger than ${MAX_BODY} bytes`);
  return n;
}

export async function handleAdmin(request: Request, env: Env, url: URL): Promise<Response> {
  const denied = await authorize(request, env);
  if (denied) return denied;

  const path = url.pathname;
  const method = request.method;

  if (path === "/api/health") {
    if (method !== "GET") return error(405, "method not allowed");
    return json({ ok: true, version: pkg.version, max_days: MAX_DAYS });
  }

  const file = /^\/api\/shares\/([^/]+)\/files\/([^/]+)\/([^/]+)$/.exec(path);
  if (file) {
    const [, id, kind, asset] = file as unknown as [string, string, string, string];
    if (!SHARE_ID_RE.test(id)) return error(400, "bad share id");
    if (!isFileKind(kind)) return error(400, "kind must be t, v or o");
    if (!ASSET_ID_RE.test(asset)) return error(400, "bad asset id");
    return handleFile(request, env, url, fileKey(id, kind, asset));
  }

  const share = /^\/api\/shares\/([^/]+)$/.exec(path);
  if (share) {
    const id = share[1]!;
    if (!SHARE_ID_RE.test(id)) return error(400, "bad share id");
    if (method === "PUT") return putManifest(request, env, url, id);
    if (method === "DELETE") return json({ deleted: await deleteShare(env.SHARES, id) });
    return error(405, "method not allowed");
  }

  return error(404, "not found");
}

async function handleFile(request: Request, env: Env, url: URL, key: string): Promise<Response> {
  const q = url.searchParams;
  const method = request.method;
  const contentType = request.headers.get("Content-Type") || "application/octet-stream";

  if (method === "HEAD") {
    const obj = await env.SHARES.head(key);
    if (!obj) return new Response(null, { status: 404 });
    return new Response(null, { status: 200, headers: { "Content-Length": String(obj.size) } });
  }

  if (method === "POST" && q.has("uploads")) {
    const upload = await env.SHARES.createMultipartUpload(key, { httpMetadata: { contentType } });
    return json({ upload_id: upload.uploadId });
  }

  if (method === "POST" && q.has("upload_id") && q.has("complete")) {
    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return error(400, "body must be JSON");
    }
    const parts = (body as { parts?: unknown })?.parts;
    if (
      !Array.isArray(parts) ||
      parts.length === 0 ||
      !parts.every(
        (p) =>
          typeof p === "object" &&
          p !== null &&
          Number.isSafeInteger(p.part) &&
          p.part >= 1 &&
          typeof p.etag === "string",
      )
    )
      return error(400, 'body must be {"parts":[{"part":1,"etag":"…"}]}');
    const upload = env.SHARES.resumeMultipartUpload(key, q.get("upload_id")!);
    try {
      await upload.complete(
        (parts as { part: number; etag: string }[]).map((p) => ({ partNumber: p.part, etag: p.etag })),
      );
    } catch (e) {
      return error(400, `complete failed: ${(e as Error).message}`);
    }
    return json({ ok: true });
  }

  if (method === "PUT" && q.has("upload_id")) {
    const part = Number(q.get("part"));
    if (!Number.isSafeInteger(part) || part < 1 || part > 10_000) return error(400, "part must be 1-10000");
    const len = bodyLength(request);
    if (len instanceof Response) return len;
    const upload = env.SHARES.resumeMultipartUpload(key, q.get("upload_id")!);
    try {
      const uploaded = await upload.uploadPart(part, request.body ?? new Uint8Array(0));
      return json({ etag: uploaded.etag });
    } catch (e) {
      return error(400, `upload failed: ${(e as Error).message}`);
    }
  }

  if (method === "PUT" && [...q.keys()].length === 0) {
    const len = bodyLength(request);
    if (len instanceof Response) return len;
    await env.SHARES.put(key, request.body ?? new Uint8Array(0), { httpMetadata: { contentType } });
    return json({ ok: true });
  }

  return error(405, "method not allowed");
}

async function putManifest(request: Request, env: Env, url: URL, id: string): Promise<Response> {
  const text = await request.text();
  if (text.length > MAX_MANIFEST) return error(413, "manifest too large");
  let body: unknown;
  try {
    body = JSON.parse(text);
  } catch {
    return error(400, "body must be JSON");
  }
  const now = Math.floor(Date.now() / 1000);
  // Rewriting a manifest keeps its created_at, and its expiry stays bounded by it.
  const existing = await loadManifest(env.SHARES, id);
  const createdAt = existing && Number.isSafeInteger(existing.created_at) ? existing.created_at : undefined;
  const result = validateInput(body, now, createdAt);
  if (!result.ok) return error(400, result.error);
  const input = result.value;

  const manifest: Manifest = {
    title: input.title,
    expires_at: input.expires_at,
    allow_download: input.allow_download,
    password_hash: input.password === null ? null : await hashPassword(input.password),
    items: input.items,
    created_at: createdAt ?? now,
  };
  await env.SHARES.put(shareKey(id), JSON.stringify(manifest), {
    httpMetadata: { contentType: "application/json" },
  });
  return json({ url: `${url.origin}/s/${id}` });
}

// The Worker's routes against an in-memory bucket.

import { beforeEach, describe, expect, it } from "vitest";
import worker from "../src/index";
import type { Env } from "../src/store";
import { sweep } from "../src/store";
import { MemoryBucket } from "./memory-bucket";

const ID = "Ab3dEfGh1jKlMnOpQrStUv";
const A1 = "1".repeat(64);
const A2 = "2".repeat(64);
const TOKEN = "test-token";
const ORIGIN = "https://share.test";

let bucket: MemoryBucket;
let env: Env;

const call = (path: string, init: RequestInit = {}) =>
  worker.fetch(new Request(ORIGIN + path, init), env);
const admin = (path: string, init: RequestInit = {}) =>
  call(path, { ...init, headers: { Authorization: `Bearer ${TOKEN}`, ...(init.headers ?? {}) } });

function manifest(over: Record<string, unknown> = {}) {
  const now = Math.floor(Date.now() / 1000);
  return {
    title: "Lake <Weekend>",
    expires_at: now + 3600,
    allow_download: false,
    password: null,
    items: [
      { id: A1, kind: "photo", w: 4032, h: 3024, taken: 1759000000, duration: null, name: "IMG_0042.HEIC", bytes: 10, view: "image/webp" },
      { id: A2, kind: "video", w: 1920, h: 1080, taken: 1759003600, duration: 42, name: "IMG_0043.MOV", bytes: 20, view: "video/mp4" },
    ],
    ...over,
  };
}

async function putFile(kind: string, asset: string, body: string, type = "image/webp") {
  const r = await admin(`/api/shares/${ID}/files/${kind}/${asset}`, {
    method: "PUT",
    body,
    headers: { "Content-Type": type, "Content-Length": String(body.length) },
  });
  expect(r.status).toBe(200);
}

async function putManifest(over: Record<string, unknown> = {}) {
  return admin(`/api/shares/${ID}`, { method: "PUT", body: JSON.stringify(manifest(over)) });
}

beforeEach(() => {
  bucket = new MemoryBucket();
  env = { SHARES: bucket as unknown as R2Bucket, SHARE_TOKEN: TOKEN, SESSION_SECRET: "session-secret" };
});

describe("admin auth", () => {
  it("needs the token", async () => {
    expect((await call("/api/health")).status).toBe(401);
    expect((await call("/api/health", { headers: { Authorization: "Bearer nope" } })).status).toBe(401);
    const r = await admin("/api/health");
    expect(r.status).toBe(200);
    expect(await r.json()).toEqual({ ok: true, version: "0.1.0", max_days: 7 });
  });
  it("fails closed without SHARE_TOKEN", async () => {
    env.SHARE_TOKEN = undefined;
    expect((await call("/api/health", { headers: { Authorization: "Bearer " } })).status).toBe(500);
    env.SHARE_TOKEN = "";
    expect((await call("/api/health", { headers: { Authorization: "Bearer " } })).status).toBe(500);
  });
});

describe("files and manifest", () => {
  it("stores files, answers HEAD for resume, writes the manifest", async () => {
    await putFile("t", A1, "thumb-1");
    let r = await admin(`/api/shares/${ID}/files/t/${A1}`, { method: "HEAD" });
    expect(r.status).toBe(200);
    expect(r.headers.get("Content-Length")).toBe("7");
    r = await admin(`/api/shares/${ID}/files/v/${A1}`, { method: "HEAD" });
    expect(r.status).toBe(404);

    r = await putManifest({ password: "pw" });
    expect(await r.json()).toEqual({ url: `${ORIGIN}/s/${ID}` });
    const stored = JSON.parse(await (await bucket.get(`s/${ID}/share.json`))!.text());
    expect(stored.password).toBeUndefined();
    expect(stored.password_hash).toMatch(/^pbkdf2\$100000\$/);
    expect(typeof stored.created_at).toBe("number");
  });

  it("empties the bucket for destroy", async () => {
    await putFile("t", A1, "x");
    await putManifest();
    const r = await admin("/api/everything", { method: "DELETE" });
    expect(r.status).toBe(200);
    expect(await r.json()).toMatchObject({ more: false });
    expect((await bucket.list({})).objects.length).toBe(0);
    expect((await call("/api/everything", { method: "DELETE" })).status).toBe(401);
  });

  it("rejects a manifest that expires too late", async () => {
    const r = await putManifest({ expires_at: Math.floor(Date.now() / 1000) + 8 * 86400 });
    expect(r.status).toBe(400);
  });

  it("does multipart uploads", async () => {
    const base = `/api/shares/${ID}/files/v/${A2}`;
    let r = await admin(`${base}?uploads`, { method: "POST", headers: { "Content-Type": "video/mp4" } });
    const { upload_id } = (await r.json()) as { upload_id: string };
    const etags: string[] = [];
    for (const [n, body] of [[1, "hello "], [2, "world"]] as const) {
      r = await admin(`${base}?upload_id=${upload_id}&part=${n}`, {
        method: "PUT",
        body,
        headers: { "Content-Length": String(body.length) },
      });
      etags.push(((await r.json()) as { etag: string }).etag);
    }
    r = await admin(`${base}?upload_id=${upload_id}&complete`, {
      method: "POST",
      body: JSON.stringify({ parts: etags.map((etag, i) => ({ part: i + 1, etag })) }),
    });
    expect(await r.json()).toEqual({ ok: true });
    expect(await (await bucket.get(`s/${ID}/v/${A2}`))!.text()).toBe("hello world");
    expect((await bucket.head(`s/${ID}/v/${A2}`))!.httpMetadata.contentType).toBe("video/mp4");
  });

  it("deletes a share", async () => {
    await putFile("t", A1, "x");
    await putFile("v", A1, "y");
    await putManifest();
    const r = await admin(`/api/shares/${ID}`, { method: "DELETE" });
    expect(await r.json()).toEqual({ deleted: 3 });
    expect((await call(`/s/${ID}`)).status).toBe(404);
  });
});

describe("public", () => {
  beforeEach(async () => {
    await putFile("t", A1, "thumb-1");
    await putFile("v", A1, "0123456789");
    await putFile("o", A1, "original-bytes", "image/heic");
  });

  it("renders the gallery with escaped data and the headers", async () => {
    await putManifest();
    const r = await call(`/s/${ID}`);
    expect(r.status).toBe(200);
    const html = await r.text();
    expect(html).toContain("Lake &lt;Weekend&gt;");
    expect(html).not.toContain("<Weekend>");
    expect(html).toContain("1 photo, 1 video");
    expect(r.headers.get("X-Robots-Tag")).toBe("noindex, nofollow");
    expect(r.headers.get("Cache-Control")).toBe("no-store");
    const nonce = /script-src 'nonce-([^']+)'/.exec(r.headers.get("Content-Security-Policy")!)![1];
    expect(html).toContain(`<script nonce="${nonce}">`);
  });

  it("404 for unknown, 202 while uploading, 410 for expired", async () => {
    const other = "Zz9" + ID.slice(3);
    expect((await call(`/s/${other}`)).status).toBe(404);
    await bucket.put(`s/${other}/t/${A1}`, "thumb");
    let r = await call(`/s/${other}`);
    expect(r.status).toBe(202);
    expect(await r.text()).toContain("still being created");
    const exp = Math.floor(Date.now() / 1000) + 3600;
    r = await admin(`/api/shares/${other}/progress`, {
      method: "PUT",
      body: JSON.stringify({ title: "Weekend", count: 12, done_bytes: 50, total_bytes: 200, eta_s: 90, expires_at: exp }),
    });
    expect(r.status).toBe(200);
    r = await call(`/s/${other}/status`);
    expect(await r.json()).toMatchObject({ ready: false, count: 12, done: 50, total: 200, eta_s: 90 });
    expect(await (await call(`/s/${other}`)).text()).toContain("About 2 minutes left");
    expect((await admin("/api/shares")).status).toBe(200);
    expect((await call(`/s/short`)).status).toBe(404);
    const now = Math.floor(Date.now() / 1000);
    await bucket.put(`s/${ID}/share.json`, JSON.stringify({ ...manifest(), password_hash: null, expires_at: now - 1, created_at: now - 100 }));
    expect((await call(`/s/${ID}`)).status).toBe(410);
    expect((await call(`/s/${ID}/f/t/${A1}`)).status).toBe(404);
  });

  it("serves files with ranges, HEAD and ETags", async () => {
    await putManifest();
    let r = await call(`/s/${ID}/f/v/${A1}`);
    expect(r.status).toBe(200);
    expect(await r.text()).toBe("0123456789");
    const etag = r.headers.get("ETag")!;
    expect(r.headers.get("Cache-Control")).toBe("private, max-age=86400");

    r = await call(`/s/${ID}/f/v/${A1}`, { headers: { Range: "bytes=2-4" } });
    expect(r.status).toBe(206);
    expect(r.headers.get("Content-Range")).toBe("bytes 2-4/10");
    expect(await r.text()).toBe("234");

    r = await call(`/s/${ID}/f/v/${A1}`, { headers: { Range: "bytes=10-" } });
    expect(r.status).toBe(416);
    expect(r.headers.get("Content-Range")).toBe("bytes */10");

    r = await call(`/s/${ID}/f/v/${A1}`, { method: "HEAD" });
    expect(r.status).toBe(200);
    expect(r.headers.get("Content-Length")).toBe("10");

    r = await call(`/s/${ID}/f/v/${A1}`, { headers: { "If-None-Match": etag } });
    expect(r.status).toBe(304);

    // Not in the manifest, or a missing file.
    expect((await call(`/s/${ID}/f/t/${"3".repeat(64)}`)).status).toBe(404);
    expect((await call(`/s/${ID}/f/t/${A2}`)).status).toBe(404);
  });

  it("never serves an original without allow_download", async () => {
    await putManifest({ allow_download: false });
    expect((await call(`/s/${ID}/f/o/${A1}`)).status).toBe(403);
    expect((await call(`/s/${ID}/f/o/${A1}`, { headers: { Range: "bytes=0-1" } })).status).toBe(403);
    expect((await call(`/s/${ID}/f/o/${A1}`, { method: "HEAD" })).status).toBe(403);
  });

  it("serves originals as attachments with allow_download", async () => {
    await putManifest({ allow_download: true });
    const r = await call(`/s/${ID}/f/o/${A1}`);
    expect(r.status).toBe(200);
    expect(r.headers.get("Content-Disposition")).toBe(
      `attachment; filename="IMG_0042.HEIC"; filename*=UTF-8''IMG_0042.HEIC`,
    );
    expect(r.headers.get("Content-Type")).toBe("image/heic");
  });

  it("zips every original as one download", async () => {
    await putManifest({ allow_download: false });
    expect((await call(`/s/${ID}/zip`)).status).toBe(403);
    await putManifest({ allow_download: true, title: "Lake Weekend / Grüße" });
    await putFile("o", A2, "the-video-original", "video/quicktime");
    let r = await call(`/s/${ID}/zip`, { method: "HEAD" });
    expect(r.status).toBe(200);
    const length = Number(r.headers.get("Content-Length"));
    r = await call(`/s/${ID}/zip`);
    expect(r.status).toBe(200);
    expect(r.headers.get("Content-Type")).toBe("application/zip");
    expect(r.headers.get("Cache-Control")).toBe("private, no-store");
    expect(r.headers.get("Content-Disposition")).toBe(
      `attachment; filename="Lake Weekend Gr__e.zip"; filename*=UTF-8''Lake%20Weekend%20Gr%C3%BC%C3%9Fe.zip`,
    );
    const body = new Uint8Array(await r.arrayBuffer());
    // local headers: 2 × 30 + names (13 + 12), data 14 + 18, descriptors 2 × 16;
    // central: 2 × 46 + names; end record 22
    expect(length).toBe(30 * 2 + 25 + 14 + 18 + 32 + 46 * 2 + 25 + 22);
    expect(body.length).toBe(length);
    const text = new TextDecoder("latin1").decode(body);
    expect(text).toContain("IMG_0042.HEIC");
    expect(text).toContain("original-bytes");
    expect(text).toContain("the-video-original");
    expect(r.headers.get("X-Robots-Tag")).toBe("noindex, nofollow");
    expect((await call(`/s/${ID}/zip`, { method: "POST" })).status).toBe(405);
  });

  it("zips only what is stored and keeps password shares closed", async () => {
    await putManifest({ allow_download: true, password: "pw" });
    expect((await call(`/s/${ID}/zip`)).status).toBe(404);
    const f = new FormData();
    f.set("password", "pw");
    const r = await call(`/s/${ID}/unlock`, { method: "POST", body: f, redirect: "manual" });
    const cookie = r.headers.get("Set-Cookie")!.split(";")[0]!;
    const z = await call(`/s/${ID}/zip`, { headers: { Cookie: cookie } });
    expect(z.status).toBe(200);
    // A2 has no original in the bucket: only A1 is in the archive.
    expect(Number(z.headers.get("Content-Length"))).toBe(30 + 13 + 14 + 16 + 46 + 13 + 22);
    expect((await z.arrayBuffer()).byteLength).toBe(30 + 13 + 14 + 16 + 46 + 13 + 22);
  });

  it("gates a password share", async () => {
    await putManifest({ password: "open sesame" });
    let r = await call(`/s/${ID}`);
    expect(r.status).toBe(200);
    expect(await r.text()).toContain('type="password"');
    expect((await call(`/s/${ID}/f/t/${A1}`)).status).toBe(404);

    const form = (pw: string) => {
      const f = new FormData();
      f.set("password", pw);
      return f;
    };
    r = await call(`/s/${ID}/unlock`, { method: "POST", body: form("wrong") });
    expect(r.status).toBe(403);
    expect(await r.text()).toContain("Wrong password");

    r = await call(`/s/${ID}/unlock`, { method: "POST", body: form("open sesame"), redirect: "manual" });
    expect(r.status).toBe(303);
    expect(r.headers.get("Location")).toBe(`${ORIGIN}/s/${ID}`);
    const setCookie = r.headers.get("Set-Cookie")!;
    expect(setCookie).toMatch(new RegExp(`^as_${ID}=\\d+\\.[A-Za-z0-9_-]+; Max-Age=\\d+; Path=/s/${ID}; HttpOnly; Secure; SameSite=Lax$`));
    const cookie = setCookie.split(";")[0]!;

    r = await call(`/s/${ID}`, { headers: { Cookie: cookie } });
    expect(await r.text()).toContain('class="grid"');
    r = await call(`/s/${ID}/f/t/${A1}`, { headers: { Cookie: cookie } });
    expect(r.status).toBe(200);

    // A tampered cookie is no cookie.
    const tampered = cookie.replace(/=(\d+)\./, (_, e) => `=${Number(e) + 1}.`);
    expect((await call(`/s/${ID}/f/t/${A1}`, { headers: { Cookie: tampered } })).status).toBe(404);
  });

  it("slows password guessing per address and per share", async () => {
    await putManifest({ password: "open sesame" });
    const counts = new Map<string, number>();
    const limiter = (max: number) => ({
      limit: async ({ key }: { key: string }) => {
        counts.set(key, (counts.get(key) ?? 0) + 1);
        return { success: counts.get(key)! <= max };
      },
    });
    env.UNLOCK_LIMIT = limiter(2) as unknown as RateLimit;
    env.UNLOCK_LIMIT_SHARE = limiter(100) as unknown as RateLimit;
    const attempt = (pw: string, ip: string) => {
      const f = new FormData();
      f.set("password", pw);
      return call(`/s/${ID}/unlock`, { method: "POST", body: f, headers: { "CF-Connecting-IP": ip }, redirect: "manual" });
    };
    expect((await attempt("a", "198.51.100.1")).status).toBe(403);
    expect((await attempt("b", "198.51.100.1")).status).toBe(403);
    // the third try from this address is refused, even with the right password
    const r = await attempt("open sesame", "198.51.100.1");
    expect(r.status).toBe(429);
    expect(r.headers.get("Retry-After")).toBe("60");
    expect(r.headers.get("Set-Cookie")).toBeNull();
    expect(await r.text()).toContain("Too many tries");
    // another address still gets in
    expect((await attempt("open sesame", "198.51.100.2")).status).toBe(303);
  });

  it("fails closed without SESSION_SECRET on a password share", async () => {
    await putManifest({ password: "pw" });
    env.SESSION_SECRET = undefined;
    expect((await call(`/s/${ID}`)).status).toBe(500);
    expect((await call(`/s/${ID}/f/t/${A1}`)).status).toBe(500);
  });
});

describe("cron sweep", () => {
  it("deletes expired shares and abandoned uploads only", async () => {
    const now = Math.floor(Date.now() / 1000);
    const live = "L".repeat(22);
    const dead = "D".repeat(22);
    const stale = "S".repeat(22);
    const fresh = "F".repeat(22);
    await bucket.put(`s/${live}/share.json`, JSON.stringify({ expires_at: now + 100, items: [] }));
    await bucket.put(`s/${live}/t/${A1}`, "x");
    await bucket.put(`s/${dead}/share.json`, JSON.stringify({ expires_at: now - 1, items: [] }));
    await bucket.put(`s/${dead}/t/${A1}`, "x");
    await bucket.put(`s/${stale}/t/${A1}`, "x");
    bucket.objects.get(`s/${stale}/t/${A1}`)!.uploaded = new Date((now - 9 * 86400) * 1000);
    await bucket.put(`s/${fresh}/t/${A1}`, "x");

    const r = await sweep(bucket as unknown as R2Bucket, now);
    expect(r.checked).toBe(4);
    expect(r.deleted.sort()).toEqual([dead, stale].sort());
    expect([...bucket.objects.keys()].sort()).toEqual(
      [`s/${fresh}/t/${A1}`, `s/${live}/share.json`, `s/${live}/t/${A1}`].sort(),
    );
  });
});

import { describe, expect, it } from "vitest";
import {
  equalBytes,
  hashPassword,
  safeEqual,
  sessionExpiry,
  signSession,
  verifyPassword,
  verifySession,
} from "../src/crypto";
import { escapeHtml, formatCount, formatDayRange, formatDuration, galleryPage, scriptJson } from "../src/html";
import { expiryError, MAX_DAYS, validateInput } from "../src/manifest";
import { contentDisposition } from "../src/public";
import { parseRange } from "../src/range";

const NOW = 1_760_000_000;
const ASSET = "a".repeat(64);

describe("constant-time comparison", () => {
  it("compares strings via their hashes", async () => {
    expect(await safeEqual("secret", "secret")).toBe(true);
    expect(await safeEqual("secret", "secreT")).toBe(false);
    expect(await safeEqual("", "secret")).toBe(false);
  });
  it("rejects different lengths", () => {
    expect(equalBytes(new Uint8Array([1]), new Uint8Array([1, 2]))).toBe(false);
  });
});

describe("password", () => {
  it("hashes in the contract's format and verifies", async () => {
    const h = await hashPassword("hunter2");
    expect(h).toMatch(/^pbkdf2\$100000\$[A-Za-z0-9+/]{22}==\$[A-Za-z0-9+/]{43}=$/);
    expect(await verifyPassword("hunter2", h)).toBe(true);
    expect(await verifyPassword("hunter3", h)).toBe(false);
  });
  it("uses a fresh salt every time", async () => {
    expect(await hashPassword("x", 1000)).not.toBe(await hashPassword("x", 1000));
  });
  it("rejects malformed digests", async () => {
    expect(await verifyPassword("x", "")).toBe(false);
    expect(await verifyPassword("x", "pbkdf2$abc$AAAA$AAAA")).toBe(false);
    expect(await verifyPassword("x", "pbkdf2$200000$AAAA$AAAA")).toBe(false);
    expect(await verifyPassword("x", "bcrypt$1000$AAAA$AAAA")).toBe(false);
  });
});

describe("session cookie", () => {
  const id = "A".repeat(22);
  it("round-trips and expires", async () => {
    const v = await signSession("k", id, NOW + 60);
    expect(v).toMatch(/^\d+\.[A-Za-z0-9_-]{43}$/);
    expect(await verifySession("k", id, v, NOW)).toBe(true);
    expect(await verifySession("k", id, v, NOW + 60)).toBe(false);
  });
  it("is bound to the secret and the share", async () => {
    const v = await signSession("k", id, NOW + 60);
    expect(await verifySession("other", id, v, NOW)).toBe(false);
    expect(await verifySession("k", "B".repeat(22), v, NOW)).toBe(false);
  });
  it("cannot have its expiry extended", async () => {
    const v = await signSession("k", id, NOW + 60);
    const forged = `${NOW + 999_999}${v.slice(v.indexOf("."))}`;
    expect(await verifySession("k", id, forged, NOW)).toBe(false);
    expect(await verifySession("k", id, "garbage", NOW)).toBe(false);
    expect(await verifySession("k", id, `${NOW + 60}.`, NOW)).toBe(false);
  });
  it("lasts 24 hours or until the share expires", () => {
    expect(sessionExpiry(NOW + 3600, NOW)).toBe(NOW + 3600);
    expect(sessionExpiry(NOW + 5 * 86400, NOW)).toBe(NOW + 86400);
  });
});

describe("range", () => {
  it("parses single ranges", () => {
    expect(parseRange(null, 100)).toBeNull();
    expect(parseRange("bytes=0-9", 100)).toEqual({ offset: 0, length: 10 });
    expect(parseRange("bytes=90-", 100)).toEqual({ offset: 90, length: 10 });
    expect(parseRange("bytes=-10", 100)).toEqual({ offset: 90, length: 10 });
    expect(parseRange("bytes=-500", 100)).toEqual({ offset: 0, length: 100 });
    expect(parseRange("bytes=50-500", 100)).toEqual({ offset: 50, length: 50 });
  });
  it("reports unsatisfiable ranges", () => {
    expect(parseRange("bytes=100-", 100)).toBe("unsatisfiable");
    expect(parseRange("bytes=-0", 100)).toBe("unsatisfiable");
    expect(parseRange("bytes=0-0", 0)).toBe("unsatisfiable");
  });
  it("ignores what it does not serve", () => {
    expect(parseRange("bytes=0-1,5-6", 100)).toBeNull();
    expect(parseRange("items=0-1", 100)).toBeNull();
    expect(parseRange("bytes=9-3", 100)).toBeNull();
    expect(parseRange("bytes=-", 100)).toBeNull();
  });
});

describe("expiry", () => {
  const limit = MAX_DAYS * 86400 + 300;
  it("must be in the future and at most a week ahead", () => {
    expect(expiryError(NOW, NOW)).not.toBeNull();
    expect(expiryError(NOW + 1, NOW)).toBeNull();
    expect(expiryError(NOW + limit, NOW)).toBeNull();
    expect(expiryError(NOW + limit + 1, NOW)).not.toBeNull();
    expect(expiryError(1.5 as number, NOW)).not.toBeNull();
  });
  it("cannot be pushed past a week after creation", () => {
    expect(expiryError(NOW + 86400, NOW, NOW - 6 * 86400 - 301)).not.toBeNull();
    expect(expiryError(NOW + 86400, NOW, NOW - 6 * 86400)).toBeNull();
    expect(expiryError(NOW + 86400, NOW, NOW - 5 * 86400)).toBeNull();
  });
});

describe("manifest validation", () => {
  const item = { id: ASSET, kind: "photo", w: 1, h: 1, taken: null, duration: null, name: "a.jpg", bytes: 1, view: "image/webp" };
  const ok = { title: "T", expires_at: NOW + 3600, allow_download: false, password: null, items: [item] };
  it("accepts the contract's example shape", () => {
    expect(validateInput(ok, NOW).ok).toBe(true);
  });
  it("rejects bad input", () => {
    expect(validateInput({ ...ok, items: [] }, NOW).ok).toBe(false);
    expect(validateInput({ ...ok, items: [item, item] }, NOW).ok).toBe(false);
    expect(validateInput({ ...ok, items: [{ ...item, id: "../x" }] }, NOW).ok).toBe(false);
    expect(validateInput({ ...ok, items: [{ ...item, view: "text/html" }] }, NOW).ok).toBe(false);
    expect(validateInput({ ...ok, password: "" }, NOW).ok).toBe(false);
    expect(validateInput({ ...ok, allow_download: "yes" }, NOW).ok).toBe(false);
    expect(validateInput({ ...ok, expires_at: NOW + 30 * 86400 }, NOW).ok).toBe(false);
  });
});

describe("html", () => {
  it("escapes", () => {
    expect(escapeHtml(`<a href="x">'&'</a>`)).toBe("&lt;a href=&quot;x&quot;&gt;&#39;&amp;&#39;&lt;/a&gt;");
    expect(scriptJson({ s: "</script><!--" })).not.toContain("<");
  });
  it("never puts raw manifest strings into the page", () => {
    const evil = `</title><script>alert(1)</script>`;
    const html = galleryPage({
      nonce: "n",
      id: "A".repeat(22),
      manifest: {
        title: evil,
        expires_at: NOW + 60,
        allow_download: true,
        password_hash: null,
        created_at: NOW,
        items: [{ id: ASSET, kind: "photo", w: 1, h: 1, taken: NOW, duration: null, name: evil, bytes: 1, view: "image/webp" }],
      },
    });
    expect(html).not.toContain("<script>alert");
    expect(html).toContain("&lt;/title&gt;");
  });
  it("formats", () => {
    expect(formatCount([{ kind: "photo" }])).toBe("1 photo");
    expect(formatCount([{ kind: "photo" }, { kind: "video" }, { kind: "video" }])).toBe("1 photo, 2 videos");
    expect(formatDuration(42)).toBe("0:42");
    expect(formatDuration(3725)).toBe("1:02:05");
    const d = (s: string) => Date.parse(s) / 1000;
    expect(formatDayRange(d("2026-10-01T10:00Z"), d("2026-10-03T10:00Z"))).toBe("Oct 1 – 3, 2026");
    expect(formatDayRange(d("2026-09-30T10:00Z"), d("2026-10-02T10:00Z"))).toBe("Sep 30 – Oct 2, 2026");
    expect(formatDayRange(d("2026-10-01T10:00Z"), d("2026-10-01T22:00Z"))).toBe("Oct 1, 2026");
  });
  it("names attachments per RFC 5987", () => {
    expect(contentDisposition("IMG_0042.HEIC")).toBe(`attachment; filename="IMG_0042.HEIC"; filename*=UTF-8''IMG_0042.HEIC`);
    expect(contentDisposition(`Grüße "1".jpg`)).toBe(
      `attachment; filename="Gr__e _1_.jpg"; filename*=UTF-8''Gr%C3%BC%C3%9Fe%20%221%22.jpg`,
    );
  });
});

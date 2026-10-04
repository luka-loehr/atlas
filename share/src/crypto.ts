// Token comparison, password hashing and the session cookie. WebCrypto only.

const enc = new TextEncoder();

/** PBKDF2-SHA256 iterations. 100,000 is also the most the Workers runtime allows. */
export const PBKDF2_ITERATIONS = 100_000;
const PBKDF2_MAX_ITERATIONS = 100_000;

/** A session lasts at most this long, and never past the share's expiry. */
export const SESSION_SECONDS = 24 * 60 * 60;

export function b64(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s);
}

export function fromB64(s: string): Uint8Array {
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export function b64url(bytes: Uint8Array): string {
  return b64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function fromB64url(s: string): Uint8Array {
  const std = s.replace(/-/g, "+").replace(/_/g, "/");
  return fromB64(std + "=".repeat((4 - (std.length % 4)) % 4));
}

export async function sha256(data: string | Uint8Array): Promise<Uint8Array> {
  const bytes = typeof data === "string" ? enc.encode(data) : data;
  return new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
}

/** Compares two byte strings without an early exit. Lengths are not secret. */
export function equalBytes(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i]! ^ b[i]!;
  return diff === 0;
}

/**
 * Constant-time string comparison: both sides are hashed first, so the
 * comparison runs over 32 bytes whatever the inputs' lengths.
 */
export async function safeEqual(a: string, b: string): Promise<boolean> {
  const [ha, hb] = await Promise.all([sha256(a), sha256(b)]);
  return equalBytes(ha, hb);
}

async function pbkdf2(password: string, salt: Uint8Array, iterations: number, bits: number): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey("raw", enc.encode(password), "PBKDF2", false, ["deriveBits"]);
  const out = await crypto.subtle.deriveBits({ name: "PBKDF2", hash: "SHA-256", salt, iterations }, key, bits);
  return new Uint8Array(out);
}

/** `pbkdf2$<iterations>$<salt b64>$<hash b64>` with a random 16-byte salt. */
export async function hashPassword(password: string, iterations = PBKDF2_ITERATIONS): Promise<string> {
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const hash = await pbkdf2(password, salt, iterations, 256);
  return `pbkdf2$${iterations}$${b64(salt)}$${b64(hash)}`;
}

export async function verifyPassword(password: string, stored: string): Promise<boolean> {
  const parts = stored.split("$");
  if (parts.length !== 4 || parts[0] !== "pbkdf2" || !/^\d{1,7}$/.test(parts[1]!)) return false;
  const iterations = Number(parts[1]);
  if (iterations < 1 || iterations > PBKDF2_MAX_ITERATIONS) return false;
  let salt: Uint8Array, expected: Uint8Array;
  try {
    salt = fromB64(parts[2]!);
    expected = fromB64(parts[3]!);
  } catch {
    return false;
  }
  if (salt.length === 0 || expected.length === 0 || expected.length > 64) return false;
  const actual = await pbkdf2(password, salt, iterations, expected.length * 8);
  return equalBytes(actual, expected);
}

async function hmacKey(secret: string): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, [
    "sign",
    "verify",
  ]);
}

/** Cookie value `<expiry>.<HMAC-SHA256(secret, "<id>.<expiry>") b64url>`. */
export async function signSession(secret: string, id: string, expiry: number): Promise<string> {
  const mac = await crypto.subtle.sign("HMAC", await hmacKey(secret), enc.encode(`${id}.${expiry}`));
  return `${expiry}.${b64url(new Uint8Array(mac))}`;
}

/** The HMAC is checked (in constant time) before the expiry is trusted. */
export async function verifySession(secret: string, id: string, value: string, now: number): Promise<boolean> {
  const dot = value.indexOf(".");
  if (dot <= 0) return false;
  const expiryText = value.slice(0, dot);
  if (!/^\d{1,12}$/.test(expiryText)) return false;
  let mac: Uint8Array;
  try {
    mac = fromB64url(value.slice(dot + 1));
  } catch {
    return false;
  }
  if (mac.length !== 32) return false;
  const ok = await crypto.subtle.verify("HMAC", await hmacKey(secret), mac, enc.encode(`${id}.${expiryText}`));
  return ok && Number(expiryText) > now;
}

/** The session's expiry: the earlier of the share's and 24 hours ahead. */
export function sessionExpiry(shareExpiresAt: number, now: number): number {
  return Math.min(shareExpiresAt, now + SESSION_SECONDS);
}

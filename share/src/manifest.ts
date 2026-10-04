// The share manifest: validation of the admin input and the stored form.

export const MAX_DAYS = 7;
/** Clock skew allowed between atlas-server and the Worker. */
export const EXPIRY_SLACK_SECONDS = 5 * 60;

export const SHARE_ID_RE = /^[0-9A-Za-z]{22}$/;
export const ASSET_ID_RE = /^[0-9a-f]{64}$/;
export const FILE_KINDS = ["t", "v", "o"] as const;
export type FileKind = (typeof FILE_KINDS)[number];

const MAX_ITEMS = 20_000;
const MAX_TITLE = 200;
const MAX_NAME = 255;
const MAX_PASSWORD = 1024;
const VIEW_TYPES = ["image/webp", "video/mp4"];

export interface Item {
  id: string;
  kind: "photo" | "video";
  w: number;
  h: number;
  taken: number | null;
  duration: number | null;
  name: string;
  bytes: number;
  view: string;
}

export interface ManifestInput {
  title: string;
  expires_at: number;
  allow_download: boolean;
  password: string | null;
  items: Item[];
}

export interface Manifest {
  title: string;
  expires_at: number;
  allow_download: boolean;
  password_hash: string | null;
  items: Item[];
  created_at: number;
}

export function shareKey(id: string): string {
  return `s/${id}/share.json`;
}

export function fileKey(id: string, kind: FileKind, asset: string): string {
  return `s/${id}/${kind}/${asset}`;
}

export function isFileKind(s: string): s is FileKind {
  return (FILE_KINDS as readonly string[]).includes(s);
}

/**
 * `expires_at` must lie in the future and at most MAX_DAYS (+ slack) ahead of
 * now and, when the share already exists, of its `created_at`, so rewriting a
 * manifest can never stretch a link past a week.
 */
export function expiryError(expiresAt: number, now: number, createdAt?: number): string | null {
  if (!Number.isSafeInteger(expiresAt)) return "expires_at must be unix seconds";
  if (expiresAt <= now) return "expires_at must lie in the future";
  const limit = MAX_DAYS * 86_400 + EXPIRY_SLACK_SECONDS;
  if (expiresAt > now + limit) return `expires_at must be at most ${MAX_DAYS} days ahead`;
  if (createdAt !== undefined && expiresAt > createdAt + limit)
    return `expires_at must be at most ${MAX_DAYS} days after the share was created`;
  return null;
}

export function isLive(m: Pick<Manifest, "expires_at">, now: number): boolean {
  return now < m.expires_at;
}

const isObj = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);
const isNonNegInt = (v: unknown): v is number => Number.isSafeInteger(v) && (v as number) >= 0;
const isNumOrNull = (v: unknown): v is number | null => v === null || (typeof v === "number" && Number.isFinite(v));

function validateItem(v: unknown, i: number): Item | string {
  const at = `items[${i}]`;
  if (!isObj(v)) return `${at} must be an object`;
  if (typeof v.id !== "string" || !ASSET_ID_RE.test(v.id)) return `${at}.id must be 64 lowercase hex`;
  if (v.kind !== "photo" && v.kind !== "video") return `${at}.kind must be "photo" or "video"`;
  if (!isNonNegInt(v.w) || !isNonNegInt(v.h)) return `${at}.w and .h must be non-negative integers`;
  if (!isNumOrNull(v.taken)) return `${at}.taken must be a number or null`;
  if (!isNumOrNull(v.duration) || (v.duration !== null && v.duration < 0))
    return `${at}.duration must be a non-negative number or null`;
  if (typeof v.name !== "string" || v.name.length === 0 || v.name.length > MAX_NAME)
    return `${at}.name must be 1-${MAX_NAME} characters`;
  if (!isNonNegInt(v.bytes)) return `${at}.bytes must be a non-negative integer`;
  if (typeof v.view !== "string" || !VIEW_TYPES.includes(v.view)) return `${at}.view must be ${VIEW_TYPES.join(" or ")}`;
  return {
    id: v.id,
    kind: v.kind,
    w: v.w,
    h: v.h,
    taken: v.taken,
    duration: v.duration,
    name: v.name,
    bytes: v.bytes,
    view: v.view,
  };
}

export function validateInput(
  body: unknown,
  now: number,
  createdAt?: number,
): { ok: true; value: ManifestInput } | { ok: false; error: string } {
  const fail = (error: string) => ({ ok: false as const, error });
  if (!isObj(body)) return fail("body must be a JSON object");
  if (typeof body.title !== "string" || body.title.length > MAX_TITLE)
    return fail(`title must be a string of at most ${MAX_TITLE} characters`);
  const expiry = expiryError(body.expires_at as number, now, createdAt);
  if (expiry) return fail(expiry);
  if (typeof body.allow_download !== "boolean") return fail("allow_download must be a boolean");
  if (
    body.password !== null &&
    (typeof body.password !== "string" || body.password.length === 0 || body.password.length > MAX_PASSWORD)
  )
    return fail(`password must be null or 1-${MAX_PASSWORD} characters`);
  if (!Array.isArray(body.items) || body.items.length === 0 || body.items.length > MAX_ITEMS)
    return fail(`items must be an array of 1-${MAX_ITEMS} items`);
  const items: Item[] = [];
  const seen = new Set<string>();
  for (let i = 0; i < body.items.length; i++) {
    const item = validateItem(body.items[i], i);
    if (typeof item === "string") return fail(item);
    if (seen.has(item.id)) return fail(`items[${i}].id appears twice`);
    seen.add(item.id);
    items.push(item);
  }
  return {
    ok: true,
    value: {
      title: body.title,
      expires_at: body.expires_at as number,
      allow_download: body.allow_download,
      password: body.password as string | null,
      items,
    },
  };
}

/** Parses a stored share.json; anything malformed reads as no share. */
export function parseManifest(text: string): Manifest | null {
  try {
    const m = JSON.parse(text) as Manifest;
    if (!isObj(m) || !Number.isFinite(m.expires_at) || !Array.isArray(m.items)) return null;
    return m;
  } catch {
    return null;
  }
}

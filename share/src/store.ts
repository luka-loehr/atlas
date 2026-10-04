// R2 access shared by the admin API, the public routes and the cron.

import { type Manifest, MAX_DAYS, parseManifest, type Progress, progressKey, shareKey } from "./manifest";

export interface Env {
  SHARES: R2Bucket;
  SHARE_TOKEN?: string;
  SESSION_SECRET?: string;
}

export async function loadManifest(bucket: R2Bucket, id: string): Promise<Manifest | null> {
  const obj = await bucket.get(shareKey(id));
  if (!obj) return null;
  return parseManifest(await obj.text());
}

/**
 * Deletes every object under `s/<id>/`. The manifest goes first, so the link
 * stops working at once even if a later batch fails. Returns the count.
 */
export async function loadProgress(bucket: R2Bucket, id: string): Promise<Progress | null> {
  const obj = await bucket.get(progressKey(id));
  if (!obj) return null;
  try {
    return JSON.parse(await obj.text()) as Progress;
  } catch {
    return null;
  }
}

/** Every share id with something stored, for atlas to reconcile against. */
export async function listShareIds(bucket: R2Bucket): Promise<string[]> {
  const ids: string[] = [];
  let cursor: string | undefined;
  do {
    const page = await bucket.list({ prefix: "s/", delimiter: "/", limit: 1000, cursor });
    for (const p of page.delimitedPrefixes) ids.push(p.slice(2, -1));
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
  return ids;
}

export async function deleteShare(bucket: R2Bucket, id: string): Promise<number> {
  const prefix = `s/${id}/`;
  const keys: string[] = [];
  let cursor: string | undefined;
  do {
    const page = await bucket.list({ prefix, limit: 1000, cursor });
    for (const o of page.objects) keys.push(o.key);
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);

  const manifest = shareKey(id);
  const rest = keys.filter((k) => k !== manifest);
  if (rest.length !== keys.length) await bucket.delete(manifest);
  for (let i = 0; i < rest.length; i += 1000) await bucket.delete(rest.slice(i, i + 1000));
  return keys.length;
}

/**
 * Empties the bucket for `atlas share destroy` (a bucket must be empty to be
 * deleted). At most `pages` × 1000 objects per call, to stay inside a
 * Worker's subrequest budget; `more` says to call again.
 */
export async function deleteEverything(bucket: R2Bucket, pages = 20): Promise<{ deleted: number; more: boolean }> {
  let deleted = 0;
  for (let i = 0; i < pages; i++) {
    const page = await bucket.list({ limit: 1000 });
    if (page.objects.length === 0) return { deleted, more: false };
    await bucket.delete(page.objects.map((o) => o.key));
    deleted += page.objects.length;
    if (!page.truncated) return { deleted, more: false };
  }
  return { deleted, more: true };
}

/**
 * The daily sweep. Deletes every share whose `expires_at` has passed, and
 * every prefix without a readable manifest whose files are older than
 * MAX_DAYS + 1 days (an upload that never finished).
 */
export async function sweep(bucket: R2Bucket, now: number): Promise<{ checked: number; deleted: string[] }> {
  const deleted: string[] = [];
  let checked = 0;
  let cursor: string | undefined;
  do {
    const page = await bucket.list({ prefix: "s/", delimiter: "/", limit: 1000, cursor });
    for (const prefix of page.delimitedPrefixes) {
      const id = prefix.slice(2, -1);
      if (!id) continue;
      checked++;
      const m = await loadManifest(bucket, id);
      let expired: boolean;
      if (m) {
        expired = m.expires_at <= now;
      } else if (await loadProgress(bucket, id).then((p) => p && p.expires_at <= now)) {
        // still being created when its time ran out
        expired = true;
      } else {
        const first = await bucket.list({ prefix, limit: 1 });
        const uploaded = first.objects[0]?.uploaded.getTime() ?? 0;
        expired = uploaded / 1000 < now - (MAX_DAYS + 1) * 86_400;
      }
      if (expired) {
        await deleteShare(bucket, id);
        deleted.push(id);
      }
    }
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
  return { checked, deleted };
}

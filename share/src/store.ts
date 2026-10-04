// R2 access shared by the admin API, the public routes and the cron.

import { type Manifest, MAX_DAYS, parseManifest, shareKey } from "./manifest";

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

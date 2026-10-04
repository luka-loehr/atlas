// The slice of the R2Bucket API the Worker uses, in memory, for tests.

interface Stored {
  data: Uint8Array;
  contentType?: string;
  uploaded: Date;
  etag: string;
}

async function toBytes(body: unknown): Promise<Uint8Array> {
  if (body === null || body === undefined) return new Uint8Array(0);
  if (typeof body === "string") return new TextEncoder().encode(body);
  if (body instanceof Uint8Array) return body;
  if (body instanceof ArrayBuffer) return new Uint8Array(body);
  return new Uint8Array(await new Response(body as ReadableStream).arrayBuffer());
}

let counter = 0;

export class MemoryBucket {
  objects = new Map<string, Stored>();
  private uploads = new Map<string, { key: string; contentType?: string; parts: Map<number, Uint8Array> }>();

  private meta(key: string, o: Stored) {
    return {
      key,
      size: o.data.length,
      etag: o.etag,
      httpEtag: `"${o.etag}"`,
      uploaded: o.uploaded,
      httpMetadata: { contentType: o.contentType },
    };
  }

  async put(key: string, body: unknown, opts?: { httpMetadata?: { contentType?: string } }) {
    const o = { data: await toBytes(body), contentType: opts?.httpMetadata?.contentType, uploaded: new Date(), etag: `e${++counter}` };
    this.objects.set(key, o);
    return this.meta(key, o);
  }

  async head(key: string) {
    const o = this.objects.get(key);
    return o ? this.meta(key, o) : null;
  }

  async get(key: string, opts?: { range?: { offset: number; length: number } }) {
    const o = this.objects.get(key);
    if (!o) return null;
    const data = opts?.range ? o.data.slice(opts.range.offset, opts.range.offset + opts.range.length) : o.data;
    return {
      ...this.meta(key, o),
      body: new Response(data).body,
      text: async () => new TextDecoder().decode(data),
    };
  }

  async delete(keys: string | string[]) {
    for (const k of Array.isArray(keys) ? keys : [keys]) this.objects.delete(k);
  }

  async list(opts: { prefix?: string; delimiter?: string; limit?: number; cursor?: string }) {
    const prefix = opts.prefix ?? "";
    const limit = opts.limit ?? 1000;
    const keys = [...this.objects.keys()].filter((k) => k.startsWith(prefix)).sort();
    const entries: { key?: string; prefix?: string }[] = [];
    const seen = new Set<string>();
    for (const k of keys) {
      if (opts.delimiter) {
        const i = k.indexOf(opts.delimiter, prefix.length);
        if (i >= 0) {
          const p = k.slice(0, i + 1);
          if (!seen.has(p)) {
            seen.add(p);
            entries.push({ prefix: p });
          }
          continue;
        }
      }
      entries.push({ key: k });
    }
    const start = opts.cursor ? Number(opts.cursor) : 0;
    const page = entries.slice(start, start + limit);
    const truncated = start + limit < entries.length;
    return {
      objects: page.filter((e) => e.key).map((e) => this.meta(e.key!, this.objects.get(e.key!)!)),
      delimitedPrefixes: page.filter((e) => e.prefix).map((e) => e.prefix!),
      truncated,
      cursor: truncated ? String(start + limit) : undefined,
    };
  }

  async createMultipartUpload(key: string, opts?: { httpMetadata?: { contentType?: string } }) {
    const uploadId = `u${++counter}`;
    this.uploads.set(uploadId, { key, contentType: opts?.httpMetadata?.contentType, parts: new Map() });
    return { key, uploadId };
  }

  resumeMultipartUpload(key: string, uploadId: string) {
    const get = () => {
      const u = this.uploads.get(uploadId);
      if (!u || u.key !== key) throw new Error("no such upload");
      return u;
    };
    return {
      key,
      uploadId,
      uploadPart: async (n: number, body: unknown) => {
        get().parts.set(n, await toBytes(body));
        return { partNumber: n, etag: `p${n}` };
      },
      complete: async (parts: { partNumber: number; etag: string }[]) => {
        const u = get();
        const chunks = parts.map((p) => {
          const c = u.parts.get(p.partNumber);
          if (!c || p.etag !== `p${p.partNumber}`) throw new Error("bad part");
          return c;
        });
        const data = new Uint8Array(chunks.reduce((n, c) => n + c.length, 0));
        let off = 0;
        for (const c of chunks) {
          data.set(c, off);
          off += c.length;
        }
        this.uploads.delete(uploadId);
        return this.put(key, data, { httpMetadata: { contentType: u.contentType } });
      },
      abort: async () => void this.uploads.delete(uploadId),
    };
  }
}

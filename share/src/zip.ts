// A streaming ZIP writer for "Download all": STORE only (photos and videos do
// not compress), sizes known up front, CRC-32 computed while the bytes pass
// through, so nothing is buffered and the archive's length is exact before
// the first byte is sent. ZIP64 records appear only where a size, an offset
// or the entry count needs them (APPNOTE 6.3.x §4.3, §4.4, §4.5.3).

// ---------------------------------------------------------------- CRC-32

/** Slicing-by-8 tables (8 × 256): about 3× the speed of the byte-wise loop. */
const CRC = (() => {
  const t = new Uint32Array(8 * 256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  for (let n = 0; n < 256; n++) {
    let c = t[n]!;
    for (let k = 1; k < 8; k++) {
      c = t[c & 0xff]! ^ (c >>> 8);
      t[k * 256 + n] = c >>> 0;
    }
  }
  return t;
})();

/** Continues a CRC-32 (start with 0) over `b`. No allocations. */
export function crc32(crc: number, b: Uint8Array): number {
  const t = CRC;
  let c = ~crc;
  let i = 0;
  const n = b.length;
  const end = n - (n & 7);
  for (; i < end; i += 8) {
    const a = c ^ (b[i]! | (b[i + 1]! << 8) | (b[i + 2]! << 16) | (b[i + 3]! << 24));
    c =
      t[1792 + (a & 0xff)]! ^
      t[1536 + ((a >>> 8) & 0xff)]! ^
      t[1280 + ((a >>> 16) & 0xff)]! ^
      t[1024 + (a >>> 24)]! ^
      t[768 + b[i + 4]!]! ^
      t[512 + b[i + 5]!]! ^
      t[256 + b[i + 6]!]! ^
      t[b[i + 7]!]!;
  }
  for (; i < n; i++) c = t[(c ^ b[i]!) & 0xff]! ^ (c >>> 8);
  return ~c >>> 0;
}

// ---------------------------------------------------------------- names

/**
 * File names as they go into the archive: no folders (`/`, `\`), no control
 * characters, never `.`/`..`, and unique ignoring case (`IMG_1.HEIC`,
 * `IMG_1 (2).HEIC`), so nothing is overwritten on a case-insensitive disk.
 */
export function uniqueNames(names: string[]): string[] {
  const taken = new Set<string>();
  return names.map((raw) => {
    let name = raw.replace(/[\u0000-\u001f\u007f/\\]/g, "_").trim();
    if (name === "" || name === "." || name === "..") name = "file";
    if (!taken.has(name.toLowerCase())) {
      taken.add(name.toLowerCase());
      return name;
    }
    const dot = name.lastIndexOf(".");
    const stem = dot > 0 ? name.slice(0, dot) : name;
    const ext = dot > 0 ? name.slice(dot) : "";
    for (let n = 2; ; n++) {
      const candidate = `${stem} (${n})${ext}`;
      if (!taken.has(candidate.toLowerCase())) {
        taken.add(candidate.toLowerCase());
        return candidate;
      }
    }
  });
}

/** MS-DOS date and time of a wall-clock time in unix seconds (read as UTC). */
export function dosDateTime(seconds: number): { date: number; time: number } {
  const d = new Date(seconds * 1000);
  let y = d.getUTCFullYear();
  if (!Number.isFinite(y) || y < 1980) return { date: (1 << 5) | 1, time: 0 }; // 1980-01-01 00:00
  if (y > 2107) return { date: (127 << 9) | (12 << 5) | 31, time: (23 << 11) | (59 << 5) | 29 };
  return {
    date: ((y - 1980) << 9) | ((d.getUTCMonth() + 1) << 5) | d.getUTCDate(),
    time: (d.getUTCHours() << 11) | (d.getUTCMinutes() << 5) | (d.getUTCSeconds() >> 1),
  };
}

// ---------------------------------------------------------------- plan

const MAX32 = 0xffffffff;
const MAX16 = 0xffff;
const FLAGS = 0x0808; // bit 3: data descriptor; bit 11: UTF-8 names
const MADE_BY = (3 << 8) | 45; // Unix, spec 4.5
const FILE_ATTRS = (0o100644 << 16) >>> 0; // regular file, rw-r--r--

export interface ZipInput {
  name: string;
  size: number;
  /** wall time in unix seconds, or null (1980-01-01) */
  mtime: number | null;
}

export interface ZipEntry {
  name: Uint8Array;
  size: number;
  offset: number;
  date: number;
  time: number;
  /** sizes as 8 bytes: zip64 extra in the local header, 24-byte descriptor */
  big: boolean;
  /** the central directory's zip64 extra carries the sizes / the offset */
  size64: boolean;
  offset64: boolean;
}

export interface ZipPlan {
  entries: ZipEntry[];
  /** where the central directory starts */
  cdOffset: number;
  cdSize: number;
  /** the zip64 end records are written */
  zip64: boolean;
  /** count, size and offset in the classic end record are 0xFFFF…, read from zip64 */
  end64: { count: boolean; size: boolean; offset: boolean };
  /** the archive's exact length in bytes */
  size: number;
}

const enc = new TextEncoder();

const localLength = (e: ZipEntry) => 30 + e.name.length + (e.big ? 20 : 0);
const descriptorLength = (e: ZipEntry) => (e.big ? 24 : 16);
const centralFields = (e: ZipEntry) => (e.size64 ? 2 : 0) + (e.offset64 ? 1 : 0);
function centralLength(e: ZipEntry): number {
  const f = centralFields(e);
  return 46 + e.name.length + (f ? 4 + 8 * f : 0);
}

/**
 * Lays the archive out: every offset and the total length, before a byte is
 * read. `force64` writes ZIP64 records everywhere (for tests: the format a
 * reader meets with 4 GB files, at a size a test can afford).
 */
export function planZip(inputs: ZipInput[], force64 = false): ZipPlan {
  const names = uniqueNames(inputs.map((i) => i.name));
  let offset = 0;
  const entries: ZipEntry[] = inputs.map((input, i) => {
    const { date, time } = dosDateTime(input.mtime ?? 0);
    const big = force64 || input.size >= MAX32;
    const e: ZipEntry = {
      name: enc.encode(names[i]!),
      size: input.size,
      offset,
      date,
      time,
      big,
      size64: big,
      offset64: force64 || offset >= MAX32,
    };
    offset += localLength(e) + e.size + descriptorLength(e);
    return e;
  });
  const cdOffset = offset;
  let cdSize = 0;
  for (const e of entries) cdSize += centralLength(e);
  const end64 = {
    count: force64 || entries.length >= MAX16,
    size: force64 || cdSize >= MAX32,
    offset: force64 || cdOffset >= MAX32,
  };
  const zip64 = end64.count || end64.size || end64.offset || entries.some((e) => e.big || e.offset64);
  const size = cdOffset + cdSize + (zip64 ? 56 + 20 : 0) + 22;
  return { entries, cdOffset, cdSize, zip64, end64, size };
}

// ---------------------------------------------------------------- records

class Writer {
  readonly bytes: Uint8Array;
  private view: DataView;
  private at = 0;
  constructor(length: number) {
    this.bytes = new Uint8Array(length);
    this.view = new DataView(this.bytes.buffer);
  }
  u16(v: number) {
    this.view.setUint16(this.at, v, true);
    this.at += 2;
  }
  u32(v: number) {
    this.view.setUint32(this.at, v >>> 0, true);
    this.at += 4;
  }
  u64(v: number) {
    this.view.setUint32(this.at, v % 0x100000000, true);
    this.view.setUint32(this.at + 4, Math.floor(v / 0x100000000), true);
    this.at += 8;
  }
  raw(b: Uint8Array) {
    this.bytes.set(b, this.at);
    this.at += b.length;
  }
  get length() {
    return this.at;
  }
}

function localHeader(e: ZipEntry): Uint8Array {
  const w = new Writer(localLength(e));
  w.u32(0x04034b50);
  w.u16(e.big || e.offset64 ? 45 : 20);
  w.u16(FLAGS);
  w.u16(0); // STORE
  w.u16(e.time);
  w.u16(e.date);
  w.u32(0); // CRC, sizes: in the data descriptor (bit 3)
  w.u32(e.big ? MAX32 : 0);
  w.u32(e.big ? MAX32 : 0);
  w.u16(e.name.length);
  w.u16(e.big ? 20 : 0);
  w.raw(e.name);
  if (e.big) {
    w.u16(0x0001);
    w.u16(16);
    w.u64(e.size);
    w.u64(e.size);
  }
  return w.bytes;
}

function descriptor(e: ZipEntry, crc: number): Uint8Array {
  const w = new Writer(descriptorLength(e));
  w.u32(0x08074b50);
  w.u32(crc);
  if (e.big) {
    w.u64(e.size);
    w.u64(e.size);
  } else {
    w.u32(e.size);
    w.u32(e.size);
  }
  return w.bytes;
}

/** The central directory and the end records. */
export function zipTrailer(plan: ZipPlan, crcs: ArrayLike<number>): Uint8Array {
  const w = new Writer(plan.size - plan.cdOffset);
  plan.entries.forEach((e, i) => {
    const fields = centralFields(e);
    w.u32(0x02014b50);
    w.u16(MADE_BY);
    w.u16(fields || e.big ? 45 : 20);
    w.u16(FLAGS);
    w.u16(0); // STORE
    w.u16(e.time);
    w.u16(e.date);
    w.u32(crcs[i]!);
    w.u32(e.size64 ? MAX32 : e.size);
    w.u32(e.size64 ? MAX32 : e.size);
    w.u16(e.name.length);
    w.u16(fields ? 4 + 8 * fields : 0);
    w.u16(0); // comment
    w.u16(0); // disk
    w.u16(0); // internal attributes
    w.u32(FILE_ATTRS);
    w.u32(e.offset64 ? MAX32 : e.offset);
    w.raw(e.name);
    if (fields) {
      w.u16(0x0001);
      w.u16(8 * fields);
      if (e.size64) {
        w.u64(e.size);
        w.u64(e.size);
      }
      if (e.offset64) w.u64(e.offset);
    }
  });
  if (w.length !== plan.cdSize) throw new Error("zip: central directory length mismatch");
  const count = plan.entries.length;
  if (plan.zip64) {
    w.u32(0x06064b50);
    w.u64(44);
    w.u16(MADE_BY);
    w.u16(45);
    w.u32(0);
    w.u32(0);
    w.u64(count);
    w.u64(count);
    w.u64(plan.cdSize);
    w.u64(plan.cdOffset);
    w.u32(0x07064b50);
    w.u32(0);
    w.u64(plan.cdOffset + plan.cdSize);
    w.u32(1);
  }
  w.u32(0x06054b50);
  w.u16(0);
  w.u16(0);
  w.u16(plan.end64.count ? MAX16 : count);
  w.u16(plan.end64.count ? MAX16 : count);
  w.u32(plan.end64.size ? MAX32 : plan.cdSize);
  w.u32(plan.end64.offset ? MAX32 : plan.cdOffset);
  w.u16(0); // comment
  if (w.length !== plan.size - plan.cdOffset) throw new Error("zip: trailer length mismatch");
  return w.bytes;
}

// ---------------------------------------------------------------- stream

/**
 * The archive as a stream. `open(i)` returns the body of entry `i`; it is
 * called only when the previous entry is done, so one object is read at a
 * time. A body shorter or longer than planned errors the stream (the length
 * already sent would be a lie).
 */
export function zipStream(
  plan: ZipPlan,
  open: (index: number) => Promise<ReadableStream<Uint8Array> | null>,
): ReadableStream<Uint8Array> {
  const crcs = new Uint32Array(plan.entries.length);
  let i = 0;
  let reader: ReadableStreamDefaultReader<Uint8Array> | null = null;
  let crc = 0;
  let seen = 0;
  let done = false;

  return new ReadableStream<Uint8Array>(
    {
      async pull(controller) {
        if (done) return;
        if (i >= plan.entries.length) {
          controller.enqueue(zipTrailer(plan, crcs));
          controller.close();
          done = true;
          return;
        }
        const e = plan.entries[i]!;
        if (!reader) {
          const body = await open(i);
          if (!body) throw new Error(`zip: entry ${i} is missing`);
          reader = body.getReader();
          crc = 0;
          seen = 0;
          controller.enqueue(localHeader(e));
          return;
        }
        const r = await reader.read();
        if (!r.done) {
          const chunk = r.value;
          seen += chunk.length;
          if (seen > e.size) throw new Error(`zip: entry ${i} is longer than planned`);
          crc = crc32(crc, chunk);
          controller.enqueue(chunk);
          return;
        }
        if (seen !== e.size) throw new Error(`zip: entry ${i} is shorter than planned`);
        crcs[i] = crc;
        reader = null;
        controller.enqueue(descriptor(e, crc));
        i++;
      },
      async cancel(reason) {
        done = true;
        if (reader) await reader.cancel(reason).catch(() => {});
      },
    },
    { highWaterMark: 0 },
  );
}

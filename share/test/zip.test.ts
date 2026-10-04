// The ZIP writer: CRC-32, names, dates, and archives read back by Info-ZIP's
// `unzip` (when installed) and by a small central-directory parser.

import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { crc32 as zlibCrc32 } from "node:zlib";
import { describe, expect, it } from "vitest";
import { crc32, dosDateTime, planZip, uniqueNames, type ZipInput, zipStream } from "../src/zip";

const hasUnzip = (() => {
  try {
    execFileSync("unzip", ["-v"], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
})();

function streamOf(...chunks: Uint8Array[]): ReadableStream<Uint8Array> {
  return new ReadableStream({
    start(c) {
      for (const chunk of chunks) c.enqueue(chunk);
      c.close();
    },
  });
}

async function collect(s: ReadableStream<Uint8Array>): Promise<Uint8Array> {
  return new Uint8Array(await new Response(s).arrayBuffer());
}

/** Writes `bytes` to a temp file and runs unzip with `args` on it. */
function unzip(bytes: Uint8Array, ...args: string[]): string {
  const dir = mkdtempSync(join(tmpdir(), "atlas-zip-"));
  try {
    const file = join(dir, "t.zip");
    writeFileSync(file, bytes);
    return execFileSync("unzip", [...args, file], { encoding: "utf8", env: { ...process.env, LC_ALL: "en_US.UTF-8" } });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

interface Parsed {
  count: number;
  cdOffset: number;
  entries: { name: string; crc: number; size: number; offset: number; flags: number; date: number; time: number }[];
}

/** Reads the end records and the central directory (zip64 aware). */
function parseTrailer(tail: Uint8Array, tailStart: number): Parsed {
  const v = new DataView(tail.buffer, tail.byteOffset, tail.byteLength);
  const u64 = (at: number) => v.getUint32(at, true) + v.getUint32(at + 4, true) * 0x100000000;
  const eocd = tail.length - 22;
  expect(v.getUint32(eocd, true)).toBe(0x06054b50);
  let count = v.getUint16(eocd + 10, true);
  let cdOffset = v.getUint32(eocd + 16, true);
  if (count === 0xffff || cdOffset === 0xffffffff) {
    const loc = eocd - 20;
    expect(v.getUint32(loc, true)).toBe(0x07064b50);
    const z = u64(loc + 8) - tailStart;
    expect(v.getUint32(z, true)).toBe(0x06064b50);
    count = u64(z + 32);
    cdOffset = u64(z + 48);
  }
  let at = cdOffset - tailStart;
  const entries: Parsed["entries"] = [];
  for (let i = 0; i < count; i++) {
    expect(v.getUint32(at, true)).toBe(0x02014b50);
    const flags = v.getUint16(at + 8, true);
    const time = v.getUint16(at + 12, true);
    const date = v.getUint16(at + 14, true);
    const crc = v.getUint32(at + 16, true);
    let size = v.getUint32(at + 24, true);
    const nameLen = v.getUint16(at + 28, true);
    const extraLen = v.getUint16(at + 30, true);
    let offset = v.getUint32(at + 42, true);
    const name = new TextDecoder().decode(tail.subarray(at + 46, at + 46 + nameLen));
    let x = at + 46 + nameLen;
    const xEnd = x + extraLen;
    while (x < xEnd) {
      const id = v.getUint16(x, true);
      const len = v.getUint16(x + 2, true);
      if (id === 1) {
        let f = x + 4;
        if (size === 0xffffffff) {
          size = u64(f);
          f += 16;
        }
        if (offset === 0xffffffff) offset = u64(f);
      }
      x += 4 + len;
    }
    entries.push({ name, crc, size, offset, flags, date, time });
    at = xEnd;
  }
  return { count, cdOffset, entries };
}

describe("crc32", () => {
  it("matches zlib, in one piece and in chunks", () => {
    const data = new Uint8Array(100_003);
    for (let i = 0; i < data.length; i++) data[i] = (i * 2654435761) >>> 24;
    const want = zlibCrc32(data);
    expect(crc32(0, data)).toBe(want);
    let c = 0;
    for (const cut of [[0, 1], [1, 9], [9, 4096], [4096, 100_003]] as const) c = crc32(c, data.subarray(cut[0], cut[1]));
    expect(c).toBe(want);
    expect(crc32(0, new Uint8Array(0))).toBe(0);
    expect(crc32(0, new TextEncoder().encode("123456789"))).toBe(0xcbf43926);
  });
});

describe("names and dates", () => {
  it("de-duplicates ignoring case and strips paths", () => {
    expect(uniqueNames(["IMG_1.HEIC", "IMG_1.HEIC", "img_1.heic", "IMG_1 (2).HEIC", "a/b\\c.jpg", "..", "noext", "noext", ".hidden", ".hidden"])).toEqual([
      "IMG_1.HEIC",
      "IMG_1 (2).HEIC",
      "img_1 (3).heic",
      "IMG_1 (2) (2).HEIC",
      "a_b_c.jpg",
      "file",
      "noext",
      "noext (2)",
      ".hidden",
      ".hidden (2)",
    ]);
  });
  it("encodes MS-DOS dates from wall time", () => {
    const t = Date.parse("2026-10-04T13:45:31Z") / 1000;
    expect(dosDateTime(t)).toEqual({ date: (46 << 9) | (10 << 5) | 4, time: (13 << 11) | (45 << 5) | 15 });
    expect(dosDateTime(0)).toEqual({ date: (1 << 5) | 1, time: 0 });
  });
});

const enc = new TextEncoder();
const files: { input: ZipInput; data: Uint8Array }[] = [
  { input: { name: "IMG_0001.HEIC", size: 0, mtime: Date.parse("2026-10-01T10:00:00Z") / 1000 }, data: enc.encode("first file, a little longer than the rest") },
  { input: { name: "IMG_0001.HEIC", size: 0, mtime: null }, data: enc.encode("second") },
  { input: { name: "Grüße 🌊.jpg", size: 0, mtime: Date.parse("2026-10-02T23:59:58Z") / 1000 }, data: new Uint8Array(70_000).map((_, i) => i & 0xff) },
  { input: { name: "empty.txt", size: 0, mtime: null }, data: new Uint8Array(0) },
];
for (const f of files) f.input.size = f.data.length;

async function build(force64: boolean): Promise<Uint8Array> {
  const plan = planZip(files.map((f) => f.input), force64);
  const zip = await collect(
    zipStream(plan, async (i) => {
      const d = files[i]!.data;
      // in uneven chunks, like a network body
      return streamOf(d.subarray(0, 7), d.subarray(7, 5000), d.subarray(5000));
    }),
  );
  expect(zip.length).toBe(plan.size);
  return zip;
}

describe("zip", () => {
  for (const force64 of [false, true]) {
    it(`writes an archive that reads back${force64 ? " (ZIP64 records)" : ""}`, async () => {
      const zip = await build(force64);
      const p = parseTrailer(zip, 0);
      expect(p.entries.map((e) => e.name)).toEqual(["IMG_0001.HEIC", "IMG_0001 (2).HEIC", "Grüße 🌊.jpg", "empty.txt"]);
      p.entries.forEach((e, i) => {
        expect(e.crc).toBe(zlibCrc32(files[i]!.data));
        expect(e.size).toBe(files[i]!.data.length);
        expect(e.flags).toBe(0x0808);
        // the local header sits where the central directory says
        expect(new DataView(zip.buffer).getUint32(e.offset, true)).toBe(0x04034b50);
      });
      expect(p.entries[0]!.date).toBe((46 << 9) | (10 << 5) | 1);
      if (hasUnzip) {
        const out = unzip(zip, "-t");
        expect(out).toContain("No errors detected");
        expect(unzip(zip, "-p").length).toBeGreaterThan(70_000);
      }
    });
  }

  it("errors when a body is not the planned size", async () => {
    const plan = planZip([{ name: "a", size: 5, mtime: null }]);
    await expect(collect(zipStream(plan, async () => streamOf(enc.encode("abc"))))).rejects.toThrow(/shorter/);
    await expect(collect(zipStream(plan, async () => streamOf(enc.encode("abcdefg"))))).rejects.toThrow(/longer/);
    await expect(collect(zipStream(plan, async () => null))).rejects.toThrow(/missing/);
  });

  it("plans ZIP64 for files and offsets past 4 GB and many entries", () => {
    const big = 5 * 2 ** 30;
    const plan = planZip([
      { name: "a.mov", size: big, mtime: null },
      { name: "b.jpg", size: 10, mtime: null },
    ]);
    const [a, b] = plan.entries;
    expect(a!.big && a!.size64 && !a!.offset64).toBe(true);
    expect(!b!.big && !b!.size64 && b!.offset64).toBe(true);
    // local 30+5+20, data, descriptor 24; local 30+5, data, descriptor 16
    expect(b!.offset).toBe(55 + big + 24);
    expect(plan.cdOffset).toBe(b!.offset + 35 + 10 + 16);
    // central: 46+5 + extra 4+16 ; 46+5 + extra 4+8
    expect(plan.cdSize).toBe(71 + 63);
    expect(plan.zip64).toBe(true);
    expect(plan.end64).toEqual({ count: false, size: false, offset: true });
    expect(plan.size).toBe(plan.cdOffset + plan.cdSize + 56 + 20 + 22);

    const many = planZip(Array.from({ length: 70_000 }, (_, i) => ({ name: `${i}.jpg`, size: 1, mtime: null })));
    expect(many.zip64).toBe(true);
    expect(many.end64.count).toBe(true);
  });

  it(
    "streams a real archive past 4 GB",
    async () => {
      const big = 2 ** 32 + 12_345; // just past what 32 bits can say
      const zero = new Uint8Array(8 << 20);
      const plan = planZip([
        { name: "big.mov", size: big, mtime: null },
        { name: "after.txt", size: 5, mtime: null },
      ]);
      const zip = zipStream(plan, async (i) => {
        if (i === 1) return streamOf(enc.encode("hello"));
        let left = big;
        return new ReadableStream<Uint8Array>({
          pull(c) {
            if (left === 0) return c.close();
            const n = Math.min(left, zero.length);
            left -= n;
            c.enqueue(n === zero.length ? zero : zero.subarray(0, n));
          },
        });
      });
      // keep only the tail: the central directory and the end records
      const keep = plan.size - plan.cdOffset + 60;
      let total = 0;
      let tail = new Uint8Array(0);
      const reader = zip.getReader();
      for (;;) {
        const r = await reader.read();
        if (r.done) break;
        total += r.value.length;
        if (total > plan.size - keep) {
          const merged = new Uint8Array(tail.length + r.value.length);
          merged.set(tail);
          merged.set(r.value, tail.length);
          tail = merged.slice(Math.max(0, merged.length - keep));
        }
      }
      expect(total).toBe(plan.size);
      const p = parseTrailer(tail, plan.size - tail.length);
      expect(p.entries.map((e) => [e.name, e.size, e.offset])).toEqual([
        ["big.mov", big, 0],
        ["after.txt", 5, plan.entries[1]!.offset],
      ]);
      let want = 0;
      for (let left = big; left > 0; left -= Math.min(left, zero.length))
        want = zlibCrc32(zero.subarray(0, Math.min(left, zero.length)), want);
      expect(p.entries[0]!.crc).toBe(want);
      expect(p.entries[1]!.crc).toBe(zlibCrc32(enc.encode("hello")));
      // the second entry's local header and data, right before the directory
      const local = tail.subarray(0, 60);
      expect(new DataView(local.buffer, local.byteOffset).getUint32(0, true)).toBe(0x04034b50);
      expect(new TextDecoder().decode(local.subarray(30, 39))).toBe("after.txt");
      expect(new TextDecoder().decode(local.subarray(39, 44))).toBe("hello");
    },
    120_000,
  );
});

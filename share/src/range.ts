// Single-range `Range: bytes=…` parsing (RFC 9110 §14).

export interface ByteRange {
  offset: number;
  length: number;
}

/**
 * - `null`: serve the whole file (no header, a syntax the server may ignore,
 *   or several ranges, which this server answers with the full body).
 * - `"unsatisfiable"`: answer `416` with `Content-Range: bytes *\/size`.
 * - otherwise the one range to send as `206`.
 */
export function parseRange(header: string | null, size: number): ByteRange | "unsatisfiable" | null {
  if (header === null) return null;
  const m = /^\s*bytes\s*=\s*(\d*)\s*-\s*(\d*)\s*$/i.exec(header);
  if (!m) return null;
  const [, startText, endText] = m as unknown as [string, string, string];
  if (startText === "" && endText === "") return null;

  if (startText === "") {
    // Suffix range: the last N bytes.
    const n = Number(endText);
    if (n === 0 || size === 0) return "unsatisfiable";
    const length = Math.min(n, size);
    return { offset: size - length, length };
  }

  const start = Number(startText);
  if (start >= size) return "unsatisfiable";
  let end = endText === "" ? size - 1 : Number(endText);
  if (end < start) return null; // invalid syntax per RFC: ignore the header
  if (end > size - 1) end = size - 1;
  return { offset: start, length: end - start + 1 };
}

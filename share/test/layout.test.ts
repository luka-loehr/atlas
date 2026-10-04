// The justified mosaic: rows fill the width exactly, keep aspect ratios and
// stay near the target height; the last row is not stretched.

import { describe, expect, it } from "vitest";
import { justify } from "../src/layout";

function rows(boxes: number[]) {
  const out = new Map<number, number[]>();
  for (let i = 0; i < boxes.length / 4; i++) {
    const y = boxes[i * 4 + 1]!;
    if (!out.has(y)) out.set(y, []);
    out.get(y)!.push(i);
  }
  return [...out.entries()].map(([y, idx]) => ({ y, idx }));
}

// a mixed album: landscape, portrait, square, panorama, a tall screenshot
const ASPECTS = [4 / 3, 3 / 4, 1, 16 / 9, 3 / 4, 4 / 3, 4 / 3, 9 / 16, 1, 3, 4 / 3, 0.2, 16 / 9, 3 / 4, 4 / 3, 1, 4 / 3, 3 / 4, 4 / 3, 2, 4 / 3, 3 / 4, 16 / 9, 4 / 3, 1];

describe("justify", () => {
  for (const [width, target, gap] of [
    [393, 180, 2],
    [1280, 270, 3],
    [768, 220, 3],
  ] as const) {
    it(`fills ${width}px rows exactly`, () => {
      const { boxes, height } = justify(ASPECTS, width, target, gap);
      const rs = rows(boxes);
      expect(rs.length).toBeGreaterThan(1);
      rs.forEach((r, k) => {
        const last = k === rs.length - 1;
        const first = r.idx[0]!;
        const end = r.idx[r.idx.length - 1]!;
        const h = boxes[first * 4 + 3]!;
        // same height across a row, items side by side with the gap
        for (let j = 1; j < r.idx.length; j++) {
          const a = r.idx[j - 1]!, b = r.idx[j]!;
          expect(boxes[b * 4 + 3]).toBe(h);
          expect(boxes[b * 4]).toBe(boxes[a * 4]! + boxes[a * 4 + 2]! + gap);
        }
        expect(boxes[first * 4]).toBe(0);
        const right = boxes[end * 4]! + boxes[end * 4 + 2]!;
        if (!last) {
          expect(right).toBe(width);
          expect(h).toBeGreaterThan(target * 0.5); // a panorama makes a short row
          expect(h).toBeLessThan(target * 1.6);
        } else {
          expect(right).toBeLessThanOrEqual(width);
          expect(h).toBeLessThanOrEqual(target);
        }
        // aspect ratios kept within rounding (clamped ones aside)
        for (const i of r.idx) {
          const a = Math.min(3, Math.max(0.4, ASPECTS[i]!));
          expect(Math.abs(boxes[i * 4 + 2]! - a * h)).toBeLessThan(2 + (last ? 0 : 0.02 * a * h));
        }
        // rows stacked with the gap
        if (k > 0) {
          const prev = rs[k - 1]!.idx[0]!;
          expect(r.y).toBe(boxes[prev * 4 + 1]! + boxes[prev * 4 + 3]! + gap);
        }
      });
      const lastRow = rs[rs.length - 1]!;
      expect(height).toBe(lastRow.y + boxes[lastRow.idx[0]! * 4 + 3]!);
    });
  }

  it("does not stretch a short last row", () => {
    const { boxes, height } = justify([1, 1], 1000, 200, 2);
    expect(boxes).toEqual([0, 0, 200, 200, 202, 0, 200, 200]);
    expect(height).toBe(200);
  });

  it("puts a wide item alone on a narrow screen", () => {
    const { boxes } = justify([3, 1], 300, 180, 2);
    expect(boxes.slice(0, 4)).toEqual([0, 0, 300, 100]);
    expect(boxes[5]).toBe(102);
  });

  it("handles nothing and unknown sizes", () => {
    expect(justify([], 400, 180, 2)).toEqual({ boxes: [], height: 0 });
    const { boxes } = justify([0, NaN, Infinity], 400, 180, 2);
    expect(boxes.every((v) => Number.isFinite(v))).toBe(true);
  });

  it("lays out 20,000 items quickly", () => {
    const many = Array.from({ length: 20_000 }, (_, i) => ASPECTS[i % ASPECTS.length]!);
    const t = performance.now();
    const { boxes } = justify(many, 1440, 270, 3);
    expect(performance.now() - t).toBeLessThan(500);
    expect(boxes.length).toBe(80_000);
  });

  it("is self-contained, so the page can embed its source", () => {
    const src = justify.toString();
    const fn = new Function(`return (${src})`)() as typeof justify;
    expect(fn(ASPECTS, 393, 180, 2)).toEqual(justify(ASPECTS, 393, 180, 2));
  });
});

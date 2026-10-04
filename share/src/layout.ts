// The gallery's justified-rows mosaic. One function, used by the page as is:
// html.ts embeds its source (`justify.toString()`), so it must stay
// self-contained — no imports, no helpers, no nested functions (esbuild's
// keep-names would wrap those in a `__name` call the browser lacks).

/**
 * Lays items with the given aspect ratios (width / height) out in rows that
 * fill `width` exactly, all rows together as close to `target` px high as the
 * items allow: the row breaks are chosen by dynamic programming over the
 * squared relative deviation from the target (as Google Photos does), so a
 * panorama does not leave one row a sliver and the next a poster. `gap` px
 * between items and rows. The last row keeps the target height instead of
 * being stretched. Positions and sizes are whole pixels.
 *
 * Returns `boxes` as a flat array, `[x, y, w, h]` per item, and the total
 * `height`. Aspect ratios are clamped to 1:2.5 – 3:1 for the layout.
 */
export function justify(
  aspects: ArrayLike<number>,
  width: number,
  target: number,
  gap: number,
): { boxes: number[]; height: number } {
  const n = aspects.length;
  const as: number[] = new Array(n);
  for (let i = 0; i < n; i++) {
    let a = aspects[i]!;
    if (!(a > 0) || !Number.isFinite(a)) a = 1;
    as[i] = a < 0.4 ? 0.4 : a > 3 ? 3 : a;
  }
  // best[j]: the least cost of laying out items 0..j-1; from[j]: where the
  // last of those rows starts.
  const best: number[] = new Array(n + 1);
  const from: number[] = new Array(n + 1);
  best[0] = 0;
  for (let j = 1; j <= n; j++) {
    best[j] = Infinity;
    from[j] = j - 1;
    let sum = 0;
    for (let i = j - 1; i >= 0; i--) {
      sum += as[i]!;
      const k = j - i;
      const h = (width - gap * (k - 1)) / sum;
      // a row too crowded to be useful; more items only make it worse
      if (k > 1 && h < target * 0.5) break;
      const d = (h - target) / target;
      // the last row is not stretched: no cost while it fits at the target
      const cost = (j === n && h >= target ? 0 : d * d) + best[i]!;
      if (cost < best[j]!) {
        best[j] = cost;
        from[j] = i;
      }
    }
  }
  const starts: number[] = [];
  for (let j = n; j > 0; j = from[j]!) starts.push(from[j]!);
  starts.reverse();

  const boxes: number[] = new Array(n * 4);
  let y = 0;
  for (let r = 0; r < starts.length; r++) {
    const i = starts[r]!;
    const j = r + 1 < starts.length ? starts[r + 1]! : n;
    let sum = 0;
    for (let k = i; k < j; k++) sum += as[k]!;
    const avail = width - gap * (j - i - 1);
    let h = avail / sum;
    const full = !(j === n && h >= target);
    if (!full) h = target;
    const rowH = Math.max(1, Math.round(h));
    let acc = 0;
    for (let k = i; k < j; k++) {
      const x0 = Math.round(acc);
      acc += as[k]! * h;
      const x1 = full && k === j - 1 ? avail : Math.round(acc);
      boxes[k * 4] = x0 + gap * (k - i);
      boxes[k * 4 + 1] = y;
      boxes[k * 4 + 2] = Math.max(1, x1 - x0);
      boxes[k * 4 + 3] = rowH;
    }
    y += rowH + gap;
  }
  return { boxes, height: n > 0 ? y - gap : 0 };
}

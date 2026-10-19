// Bakes the glass panel of the share link preview (src/share/og.rs).
//
// web-glass draws liquid glass as an SVG filter (a displacement map, a tone
// curve and a rim highlight) that it builds in the browser for a shape's
// exact size. This runs the library in Chrome for each panel size the
// preview uses and writes the filter and the shape's outline to
// panel-<height>.svg; the server's renderer (resvg) applies them to the photo.
//
//   WEB_GLASS=~/Documents/web-glass node crates/server/assets/glass/bake.mjs
//
// Needs a built web-glass checkout (`bun run build` there), bun, and Chrome.
// The sizes and the look must match PANEL_* in og.rs.

import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const webGlass = process.env.WEB_GLASS?.replace(/^~/, process.env.HOME);
if (!webGlass) throw new Error("set WEB_GLASS to a web-glass checkout");
const pkg = join(webGlass, "packages/liquid-glass");
const { chromium } = await import(join(webGlass, "bench/node_modules/playwright/index.mjs"));

const PANEL = { x: 40, width: 1120, bottom: 40, heights: [189, 258] };
const LOOK = { material: "clear", appearance: "dark", radius: 40 };

const build = mkdtempSync(join(tmpdir(), "og-glass-"));
writeFileSync(
  join(build, "entry.js"),
  `import { createGlassScene } from ${JSON.stringify(join(pkg, "dist/dom.js"))};
const scene = document.getElementById("scene");
const controller = createGlassScene(scene, { onDiagnostic: (d) => { window.__diag = d; } });
controller.setContent(document.getElementById("content"));
const look = ${JSON.stringify(LOOK)};
const height = Number(new URLSearchParams(location.search).get("h"));
const el = document.createElement("div");
el.className = "lg-surface";
el.style.cssText = "position:absolute;left:${PANEL.x}px;width:${PANEL.width}px;bottom:${PANEL.bottom}px;height:" + height + "px";
el.setAttribute("data-lg-container", "");
el.setAttribute("data-lg-container-radius", String(look.radius));
el.dataset.glassMaterial = look.material;
el.dataset.glassAppearance = look.appearance;
scene.appendChild(el);
controller.addSurface(el, look);
window.__surface = el;`,
);
execFileSync("bun", ["build", join(build, "entry.js"), "--outfile", join(build, "bundle.js"), "--target", "browser"], { stdio: "inherit" });

const page_html = `<!doctype html><meta charset="utf-8"><link rel="stylesheet" href="/glass.css">
<style>html,body{margin:0}#scene{width:1200px;height:630px;overflow:hidden}#content{background:#808080}</style>
<div id="scene" class="lg-scene"><div data-glass-blur-host="" data-layout="overlay"><div id="content" class="lg-content" data-layout="overlay"></div></div></div>
<script type="module" src="/bundle.js"></script>`;
const files = {
  "/": ["text/html", page_html],
  "/glass.css": ["text/css", readFileSync(join(pkg, "dist/styles.css"))],
  "/bundle.js": ["text/javascript", readFileSync(join(build, "bundle.js"))],
};

const version = JSON.parse(readFileSync(join(pkg, "package.json"), "utf8")).version;
const commit = execFileSync("git", ["-C", webGlass, "rev-parse", "--short", "HEAD"], { encoding: "utf8" }).trim();
const browser = await chromium.launch({ channel: "chrome", args: ["--enable-unsafe-webgpu", "--ignore-gpu-blocklist"] });
const page = await browser.newPage({ viewport: { width: 1200, height: 630 }, deviceScaleFactor: 1 });
await page.route("http://bake.local/**", (route) => {
  const [type, body] = files[new URL(route.request().url()).pathname] ?? [];
  return body === undefined ? route.fulfill({ status: 404 }) : route.fulfill({ contentType: type, body });
});
for (const height of PANEL.heights) {
  await page.goto(`http://bake.local/?h=${height}`);
  await page.waitForFunction(() => window.__diag?.surfaces === 1 && window.__diag.maps >= 1, null, { timeout: 20000 });
  await page.waitForTimeout(500);
  const { filter, outline } = await page.evaluate(() => {
    const el = window.__surface;
    const style = getComputedStyle(el);
    const id = /url\("?#([^")]+)"?\)/.exec(style.backdropFilter)?.[1];
    const source = id && document.getElementById(id);
    if (!source) throw new Error(`no backdrop filter on the surface: ${style.backdropFilter}`);
    const filter = source.cloneNode(true);
    filter.id = "glass";
    for (const node of [filter, ...filter.querySelectorAll("*")])
      for (const name of [...node.getAttributeNames()]) if (name.startsWith("data-")) node.removeAttribute(name);
    const outline = /path\("(.+)"\)/.exec(style.clipPath)?.[1];
    if (!outline) throw new Error(`no outline: ${style.clipPath}`);
    return { filter: new XMLSerializer().serializeToString(filter).replace(/ xmlns="[^"]*"/, ""), outline };
  });
  const out = join(here, `panel-${height}.svg`);
  writeFileSync(
    out,
    `<!-- web-glass ${version} (${commit}), ${LOOK.material} ${LOOK.appearance}, radius ${LOOK.radius}, ${PANEL.width}x${height}: made by bake.mjs -->\n` +
      `<clipPath id="glass-shape"><path d="${outline}"/></clipPath>\n${filter}\n`,
  );
  console.log(`wrote ${out}`);
}
await browser.close();

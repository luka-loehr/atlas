// Server-rendered pages: the gallery (justified mosaic and viewer), the
// password gate, the "being created" page and the notices (404, 410, 500).
// Every manifest string is user data and is escaped.

import { justify } from "./layout";
import type { Item, Manifest } from "./manifest";

const ATLAS_URL = "https://github.com/luka-loehr/atlas";

const ESCAPES: Record<string, string> = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };

/** Escapes text for HTML element content and quoted attribute values. */
export function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ESCAPES[c]!);
}

/** JSON safe to place inside a <script> element. */
export function scriptJson(value: unknown): string {
  return JSON.stringify(value)
    .replace(/</g, "\\u003c")
    .replace(/>/g, "\\u003e")
    .replace(/&/g, "\\u0026");
}

export function newNonce(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s);
}

export function contentSecurityPolicy(nonce: string): string {
  return [
    "default-src 'none'",
    "img-src 'self'",
    "media-src 'self'",
    "connect-src 'self'",
    `style-src 'nonce-${nonce}'`,
    `script-src 'nonce-${nonce}'`,
    "form-action 'self'",
    "base-uri 'none'",
    "frame-ancestors 'none'",
  ].join("; ");
}

// ---------------------------------------------------------------- formatting

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/** "Oct 4, 2026" from unix seconds, read as UTC (wall time for `taken`). */
export function formatDay(seconds: number): string {
  const d = new Date(seconds * 1000);
  return `${MONTHS[d.getUTCMonth()]} ${d.getUTCDate()}, ${d.getUTCFullYear()}`;
}

/** "Oct 1 – 3, 2026", "Sep 30 – Oct 2, 2026", "Dec 30, 2025 – Jan 2, 2026". */
export function formatDayRange(from: number, to: number): string {
  const a = new Date(from * 1000);
  const b = new Date(to * 1000);
  const [ay, am, ad] = [a.getUTCFullYear(), a.getUTCMonth(), a.getUTCDate()];
  const [by, bm, bd] = [b.getUTCFullYear(), b.getUTCMonth(), b.getUTCDate()];
  if (ay === by && am === bm && ad === bd) return formatDay(from);
  if (ay === by && am === bm) return `${MONTHS[am]} ${ad} – ${bd}, ${ay}`;
  if (ay === by) return `${MONTHS[am]} ${ad} – ${MONTHS[bm]} ${bd}, ${ay}`;
  return `${formatDay(from)} – ${formatDay(to)}`;
}

export function formatCount(items: Pick<Item, "kind">[]): string {
  const videos = items.filter((i) => i.kind === "video").length;
  const photos = items.length - videos;
  const part = (n: number, one: string) => `${n.toLocaleString("en-US")} ${one}${n === 1 ? "" : "s"}`;
  if (videos === 0) return part(photos, "photo");
  if (photos === 0) return part(videos, "video");
  return `${part(photos, "photo")}, ${part(videos, "video")}`;
}

export function formatDuration(seconds: number): string {
  const s = Math.max(0, Math.round(seconds));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const ss = String(s % 60).padStart(2, "0");
  return h > 0 ? `${h}:${String(m).padStart(2, "0")}:${ss}` : `${m}:${ss}`;
}

function dateRange(items: Item[]): string | null {
  let min = Infinity;
  let max = -Infinity;
  for (const i of items) {
    if (i.taken === null) continue;
    if (i.taken < min) min = i.taken;
    if (i.taken > max) max = i.taken;
  }
  return Number.isFinite(min) ? formatDayRange(min, max) : null;
}

// ---------------------------------------------------------------- shared shell

const FONT = `-apple-system, BlinkMacSystemFont, "SF Pro Text", "SF Pro Display", "Helvetica Neue", Helvetica, Arial, system-ui, sans-serif`;

const BASE_CSS = `
:root{color-scheme:light dark;--bg:#fff;--fg:#1d1d1f;--muted:#6e6e73;--faint:#a1a1a6;--cell:#f0f0f2;--card:#fff;--field:#f2f2f4;--pill:#f0f0f2;--pill-hover:#e6e6e9;--line:rgba(0,0,0,.08);--accent:#0a64d6;--accent-fg:#fff;--err:#d70015;--ring:rgba(10,100,214,.28)}
@media (prefers-color-scheme:dark){:root{--bg:#000;--fg:#f5f5f7;--muted:#98989d;--faint:#636366;--cell:#1c1c1e;--card:#111113;--field:#1c1c1e;--pill:#1c1c1e;--pill-hover:#2c2c2e;--line:rgba(255,255,255,.1);--accent:#4fa8ff;--accent-fg:#00172e;--err:#ff6961;--ring:rgba(79,168,255,.35)}}
*,*::before,*::after{box-sizing:border-box}
html{-webkit-text-size-adjust:100%;text-size-adjust:100%;background:var(--bg)}
body{margin:0;background:var(--bg);color:var(--fg);font-family:${FONT};font-size:17px;line-height:1.4;-webkit-font-smoothing:antialiased;-moz-osx-font-smoothing:grayscale;overflow-x:hidden}
a{color:var(--accent);text-decoration:none}
button{font:inherit;color:inherit}
.mark{display:block;flex:none}
.foot{display:flex;justify-content:center;padding:40px max(16px,env(safe-area-inset-right)) max(32px,calc(env(safe-area-inset-bottom) + 20px)) max(16px,env(safe-area-inset-left))}
.foot a{display:inline-flex;align-items:center;gap:7px;min-height:44px;padding:0 12px;border-radius:22px;color:var(--muted);font-size:13px;letter-spacing:.01em}
.foot a b{font-weight:600;color:var(--fg)}
@media (hover:hover){.foot a:hover{background:var(--pill)}}
.center{min-height:100vh;min-height:100dvh;display:flex;flex-direction:column}
.center main{flex:1;display:flex;align-items:center;justify-content:center;padding:max(32px,env(safe-area-inset-top)) max(20px,env(safe-area-inset-right)) 0 max(20px,env(safe-area-inset-left))}
.card{width:100%;max-width:380px;text-align:center}
.badge{width:56px;height:56px;margin:0 auto 18px;border-radius:50%;background:var(--field);display:flex;align-items:center;justify-content:center;color:var(--muted)}
.card h1{margin:0 0 6px;font-size:26px;line-height:1.15;font-weight:700;letter-spacing:-.025em;overflow-wrap:anywhere}
.card .line{margin:0;font-size:16px;color:var(--muted);overflow-wrap:anywhere}
`;

const MARK_STOPS = `<stop offset="0" stop-color="#4DD0E1"/><stop offset="1" stop-color="#1565C0"/>`;

/** The Atlas app icon in small: two nested rounded diamonds on the ocean gradient. */
function atlasMark(size: number, gid: string): string {
  return `<svg class="mark" width="${size}" height="${size}" viewBox="0 0 64 64" aria-hidden="true"><defs><linearGradient id="${gid}" x1="0" y1="0" x2="1" y2="1">${MARK_STOPS}</linearGradient></defs><rect width="64" height="64" rx="15" fill="url(#${gid})"/><rect x="17" y="17" width="30" height="30" rx="7" transform="rotate(45 32 32)" fill="#B2EBF2"/><rect x="25.5" y="25.5" width="13" height="13" rx="3.2" transform="rotate(45 32 32)" fill="#fff"/></svg>`;
}

const FOOTER = `<footer class="foot"><a href="${ATLAS_URL}" rel="noopener noreferrer">${atlasMark(18, "am-f")}<span>Shared with <b>Atlas</b></span></a></footer>`;

interface ShellOptions {
  title: string;
  nonce: string;
  css: string;
  body: string;
  head?: string;
}

function shell(o: ShellOptions): string {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="robots" content="noindex, nofollow">
<meta name="referrer" content="no-referrer">
<meta name="color-scheme" content="light dark">
<meta name="theme-color" content="#ffffff" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#000000" media="(prefers-color-scheme: dark)">
<meta name="format-detection" content="telephone=no">
<title>${escapeHtml(o.title)}</title>${o.head ?? ""}
<style nonce="${o.nonce}">${BASE_CSS}${o.css}</style>
</head>
<body>
${o.body}
</body>
</html>`;
}

// ---------------------------------------------------------------- notices

const ICON_LINK_OFF = `<svg width="26" height="26" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M9.5 14.5l5-5"/><path d="M11 6.5l1.2-1.2a4.2 4.2 0 0 1 6 6L17 12.5"/><path d="M13 17.5l-1.2 1.2a4.2 4.2 0 0 1-6-6L7 11.5"/></svg>`;
const ICON_CLOCK = `<svg width="26" height="26" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="8.5"/><path d="M12 7.5V12l3 2"/></svg>`;
const ICON_ALERT = `<svg width="26" height="26" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="8.5"/><path d="M12 7.5v5"/><path d="M12 16.2v.1"/></svg>`;

/** A page with one thing to say: unknown link (404), expired (410), errors. */
export function noticePage(nonce: string, title: string, line: string, kind: "missing" | "expired" | "error" = "missing"): string {
  const icon = kind === "expired" ? ICON_CLOCK : kind === "error" ? ICON_ALERT : ICON_LINK_OFF;
  return shell({
    title,
    nonce,
    css: "",
    body: `<div class="center"><main><div class="card">
<div class="badge">${icon}</div>
<h1>${escapeHtml(title)}</h1>
<p class="line notice">${escapeHtml(line)}</p>
</div></main>${FOOTER}</div>`,
  });
}

// ---------------------------------------------------------------- being created

const CREATING_CSS = `
.card .what{margin:0 0 26px}
.mark.big{margin:0 auto 20px;border-radius:15px;box-shadow:0 8px 24px rgba(21,101,192,.28);animation:breathe 2.4s ease-in-out infinite}
@keyframes breathe{50%{transform:scale(1.05)}}
.track{height:6px;border-radius:3px;background:var(--field);overflow:hidden}
.fill{height:100%;width:0;border-radius:3px;background:linear-gradient(90deg,#4DD0E1,#1565C0);transition:width 1s linear}
.track.indeterminate .fill{width:30%;animation:slide 1.4s ease-in-out infinite}
@keyframes slide{0%{transform:translateX(-100%)}100%{transform:translateX(340%)}}
@media (prefers-reduced-motion:reduce){.track.indeterminate .fill{animation:none;width:100%;opacity:.35}.mark.big{animation:none}}
.meta{display:flex;justify-content:space-between;gap:12px;margin-top:12px;font-size:13px;color:var(--muted);font-variant-numeric:tabular-nums;text-align:left}
.meta span:last-child{text-align:right;white-space:nowrap}
`;

export interface CreatingView {
  ready: boolean;
  count?: number;
  done?: number;
  total?: number;
  eta_s?: number | null;
  paused?: boolean;
}

/** "about 3 minutes left" and the like; "" when there is nothing honest to say. */
export function formatEta(eta: number | null | undefined, paused?: boolean): string {
  if (paused) return "Paused, continues when the sender’s server is back";
  if (eta === null || eta === undefined) return "Working out the time left…";
  if (eta < 45) return "Less than a minute left";
  const min = Math.round(eta / 60);
  if (min < 60) return `About ${min} minute${min === 1 ? "" : "s"} left`;
  const h = Math.floor(min / 60), m = min % 60;
  return `About ${h} h${m ? ` ${m} min` : ""} left`;
}

export function formatBytes(n: number): string {
  if (n < 1e6) return `${Math.max(1, Math.round(n / 1e3))} KB`;
  if (n < 1e9) return `${(n / 1e6).toFixed(n < 1e7 ? 1 : 0)} MB`;
  return `${(n / 1e9).toFixed(1)} GB`;
}

/**
 * The page of a link whose photos are still on their way: what it will be,
 * a live bar and the time left, then the gallery by itself once it is ready.
 */
export function creatingPage(nonce: string, id: string, title: string, v: CreatingView): string {
  const t = title || "Shared photos";
  const known = v.total !== undefined && v.total > 0;
  const pct = known ? Math.min(100, (100 * (v.done ?? 0)) / v.total!) : 0;
  const what = v.count ? `${v.count} ${v.count === 1 ? "item" : "items"} · this link is still being created` : "This link is still being created";
  return shell({
    title: t,
    nonce,
    css: CREATING_CSS,
    body: `<div class="center"><main><div class="card">
${atlasMark(56, "am-c").replace('class="mark"', 'class="mark big"')}
<h1>${escapeHtml(t)}</h1>
<p class="line what">${escapeHtml(what)}</p>
<div class="track${known ? "" : " indeterminate"}" id="track" role="progressbar" aria-label="Upload progress"><div class="fill" id="fill" data-w="${known ? pct.toFixed(1) : ""}"></div></div>
<div class="meta"><span id="eta">${escapeHtml(formatEta(v.eta_s, v.paused))}</span><span id="bytes">${known ? escapeHtml(`${formatBytes(v.done ?? 0)} of ${formatBytes(v.total!)}`) : ""}</span></div>
</div></main>${FOOTER}</div>
<script nonce="${nonce}">
(function(){
var url=${scriptJson(`/s/${id}/status`)};
var f0=document.getElementById("fill");if(f0.dataset.w)f0.style.width=f0.dataset.w+"%";
function eta(e,p){if(p)return "Paused, continues when the sender’s server is back";if(e==null)return "Working out the time left…";if(e<45)return "Less than a minute left";var m=Math.round(e/60);if(m<60)return "About "+m+" minute"+(m===1?"":"s")+" left";var h=Math.floor(m/60),r=m%60;return "About "+h+" h"+(r?" "+r+" min":"")+" left";}
function size(n){return n<1e6?Math.max(1,Math.round(n/1e3))+" KB":n<1e9?(n/1e6).toFixed(n<1e7?1:0)+" MB":(n/1e9).toFixed(1)+" GB";}
function tick(){fetch(url,{cache:"no-store"}).then(function(r){return r.json();}).then(function(s){
if(s.ready){location.reload();return;}
if(s.gone){location.reload();return;}
var track=document.getElementById("track"),fill=document.getElementById("fill");
if(s.total>0){track.className="track";fill.style.width=Math.min(100,100*s.done/s.total).toFixed(1)+"%";document.getElementById("bytes").textContent=size(s.done)+" of "+size(s.total);}
document.getElementById("eta").textContent=eta(s.eta_s,s.paused);
}).catch(function(){}).finally(function(){setTimeout(tick,3000);});}
setTimeout(tick,3000);
})();
</script>`,
  });
}

// ---------------------------------------------------------------- gate

const GATE_CSS = `
.card form{margin:24px 0 0}
.card input{display:block;width:100%;height:50px;padding:0 16px;border:1px solid transparent;border-radius:14px;background:var(--field);color:var(--fg);font:inherit;font-size:17px;outline:none;-webkit-appearance:none;appearance:none;transition:border-color .15s,box-shadow .15s}
.card input::placeholder{color:var(--faint)}
.card input:focus{border-color:var(--accent);box-shadow:0 0 0 4px var(--ring)}
.card button{display:block;width:100%;height:50px;margin-top:12px;border:0;border-radius:14px;background:var(--fg);color:var(--bg);font-size:17px;font-weight:600;cursor:pointer;-webkit-tap-highlight-color:transparent}
.card button:active{opacity:.8}
.card button:focus-visible{outline:none;box-shadow:0 0 0 4px var(--ring)}
.err{margin:14px 0 0;color:var(--err);font-size:14px}
`;

const ICON_LOCK = `<svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="4.5" y="10.5" width="15" height="10" rx="2.8"/><path d="M8 10.5V7.5a4 4 0 0 1 8 0v3"/></svg>`;

export function gatePage(nonce: string, id: string, title: string, wrong: boolean | "limited"): string {
  const t = title || "Shared photos";
  const err = wrong === "limited" ? "Too many tries. Wait a minute, then try again." : "Wrong password. Try again.";
  return shell({
    title: t,
    nonce,
    css: GATE_CSS,
    body: `<div class="center"><main><div class="card">
<div class="badge">${ICON_LOCK}</div>
<h1>${escapeHtml(t)}</h1>
<p class="line">Enter the password to view.</p>
<form method="post" action="/s/${id}/unlock">
<input type="password" name="password" placeholder="Password" aria-label="Password" autocomplete="current-password" required autofocus>
<button type="submit">View</button>${wrong ? `\n<p class="err" role="alert">${err}</p>` : ""}
</form>
</div></main>${FOOTER}</div>`,
  });
}

// ---------------------------------------------------------------- gallery

const GALLERY_CSS = `
html{scrollbar-gutter:stable}
.hd{padding:max(28px,calc(env(safe-area-inset-top) + 18px)) max(20px,env(safe-area-inset-right)) 22px max(20px,env(safe-area-inset-left))}
.brand{display:inline-flex;align-items:center;gap:7px;margin:0 0 18px -2px;color:var(--muted);font-size:14px;font-weight:600;letter-spacing:.01em}
.brand:hover{color:var(--fg)}
.hrow{display:flex;flex-direction:column;gap:18px}
.hd h1{margin:0;font-size:34px;line-height:1.08;font-weight:700;letter-spacing:-.03em;overflow-wrap:anywhere}
.sub{margin:8px 0 0;font-size:15px;line-height:1.45;color:var(--muted)}
.sub .sep{color:var(--faint)}
.sub .until{display:block}.sub .until-sep{display:none}
.sub span{white-space:nowrap}
.pill{align-self:flex-start;display:inline-flex;align-items:center;gap:8px;height:44px;padding:0 18px 0 15px;border-radius:22px;background:var(--pill);color:var(--fg);font-size:15px;font-weight:600;white-space:nowrap;-webkit-tap-highlight-color:transparent;transition:background-color .15s,transform .15s}
.pill small{font-size:13px;font-weight:500;color:var(--muted)}
.pill:active{transform:scale(.97)}
@media (hover:hover){.pill:hover{background:var(--pill-hover)}}
.pill:focus-visible,.cell:focus-visible{outline:3px solid var(--accent);outline-offset:2px}
@media (min-width:700px){
.hd{padding:56px 40px 30px}
.brand{margin-bottom:26px}
.hrow{flex-direction:row;align-items:flex-end;justify-content:space-between;gap:32px}
.hd h1{font-size:48px}
.sub{font-size:17px;margin-top:10px}
.sub .until{display:inline}.sub .until-sep{display:inline}
.pill{align-self:auto;flex:none;margin-bottom:2px}
}
.grid{position:relative;margin:0 env(safe-area-inset-right) 0 env(safe-area-inset-left)}
@media (min-width:700px){.grid{margin:0 40px}}
.cell{position:absolute;left:0;top:0;width:0;height:0;display:block;overflow:hidden;background:var(--cell);-webkit-tap-highlight-color:transparent;-webkit-touch-callout:none}
.grid:not(.on) .cell{visibility:hidden}
@media (min-width:700px){.cell{border-radius:3px}}
.cell img{display:block;width:100%;height:100%;object-fit:cover;opacity:0;transition:opacity .35s ease;-webkit-user-select:none;user-select:none}
.cell img.in{opacity:1}
.cell.hero{visibility:hidden}
@media (hover:hover){.cell img{transition:opacity .35s ease,filter .2s}.cell:hover img{filter:brightness(.9)}}
.dur{position:absolute;right:7px;bottom:6px;display:flex;align-items:center;gap:4px;color:#fff;font-size:12px;font-weight:600;font-variant-numeric:tabular-nums;text-shadow:0 0 4px rgba(0,0,0,.55);pointer-events:none}
.dur svg{filter:drop-shadow(0 0 2px rgba(0,0,0,.5))}
.nojs{padding:0 20px;color:var(--muted)}
html.lb-open,html.lb-open body{overflow:hidden}
.lb{position:fixed;inset:0;z-index:20;color:#fff;touch-action:none;overscroll-behavior:none;-webkit-user-select:none;user-select:none;-webkit-touch-callout:none}
.lb[hidden]{display:none}
.lb-bg{position:absolute;inset:0;background:#000;will-change:opacity}
.track{position:absolute;inset:0;will-change:transform}
.slot{position:absolute;inset:0;overflow:hidden}
.slot[hidden]{display:none}
.frame{position:absolute;left:0;top:0;transform-origin:0 0;will-change:transform}
.frame img,.frame video{position:absolute;inset:0;display:block;width:100%;height:100%;object-fit:contain;-webkit-user-select:none;user-select:none;-webkit-user-drag:none}
.frame .hi{opacity:0;transition:opacity .18s ease}
.frame .hi.in{opacity:1}
.frame video{background:transparent}
.bar{position:absolute;left:0;right:0;top:0;z-index:3;display:grid;grid-template-columns:1fr auto 1fr;align-items:center;gap:8px;padding:calc(env(safe-area-inset-top) + 6px) max(10px,env(safe-area-inset-right)) 28px max(10px,env(safe-area-inset-left));background:linear-gradient(rgba(0,0,0,.6),rgba(0,0,0,.28) 60%,rgba(0,0,0,0));transition:opacity .22s ease;touch-action:manipulation}
.bar .l{justify-self:start}.bar .r{justify-self:end}
.vt{text-align:center;min-width:0;line-height:1.25;text-shadow:0 1px 6px rgba(0,0,0,.35)}
.vt b{display:block;font-size:15px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.vt span{display:block;font-size:12px;color:rgba(255,255,255,.78);font-variant-numeric:tabular-nums;white-space:nowrap}
.vb{display:inline-flex;align-items:center;justify-content:center;width:44px;height:44px;border:0;border-radius:22px;padding:0;background:rgba(255,255,255,.14);color:#fff;cursor:pointer;-webkit-backdrop-filter:blur(16px);backdrop-filter:blur(16px);-webkit-tap-highlight-color:transparent;transition:background-color .15s}
.vb:hover{background:rgba(255,255,255,.24)}
.vb:focus-visible,.vnav:focus-visible{outline:2px solid #fff;outline-offset:2px}
.vnav{position:absolute;top:50%;z-index:3;width:48px;height:48px;margin-top:-24px;border:0;border-radius:50%;padding:0;background:rgba(255,255,255,.14);-webkit-backdrop-filter:blur(16px);backdrop-filter:blur(16px);color:#fff;display:none;align-items:center;justify-content:center;cursor:pointer;transition:opacity .22s,background-color .15s}
.vnav:hover{background:rgba(255,255,255,.26)}
.vnav.prev{left:max(16px,env(safe-area-inset-left))}.vnav.next{right:max(16px,env(safe-area-inset-right))}
.vnav:disabled{opacity:0;pointer-events:none}
@media (hover:hover) and (pointer:fine){.vnav{display:flex}}
.lb.bare .bar,.lb.bare .vnav,.lb.busy .bar,.lb.busy .vnav{opacity:0;pointer-events:none}
@media (prefers-reduced-motion:reduce){.cell img,.frame .hi{transition:none}}
`;

// The page's script: mosaic, lazy thumbnails and the viewer. Plain DOM, no
// dependencies; the data comes from the JSON block, the row layout from
// layout.ts (spliced in at __JUSTIFY__). Kept free of `${` on purpose.
const GALLERY_JS = String.raw`
(function(){
'use strict';
var D=JSON.parse(document.getElementById('data').textContent);
var items=D.items,base=D.base,n=items.length;
var justify=(__JUSTIFY__);
var root=document.documentElement;
var reduce=window.matchMedia('(prefers-reduced-motion: reduce)').matches;
function url(k,i){return base+k+'/'+items[i].id}
var aspects=items.map(function(it){return it.w>0&&it.h>0?it.w/it.h:1});
var nat=aspects.slice();
function isVideo(i){return i>=0&&i<n&&items[i].kind==='video'}

/* ---- the mosaic ---- */
var grid=document.getElementById('grid');
var cells=Array.prototype.slice.call(grid.querySelectorAll('.cell'));
var boxes=null,gw=0;
function loadThumb(c){var img=c.firstElementChild;if(img.getAttribute('src'))return;
  img.onload=img.onerror=function(){img.classList.add('in')};img.src=url('t',+c.getAttribute('data-i'))}
var io=('IntersectionObserver' in window)?new IntersectionObserver(function(es){
  es.forEach(function(e){if(e.isIntersecting){io.unobserve(e.target);loadThumb(e.target)}})},{rootMargin:'900px 0px'}):null;
function layout(){
  var w=grid.clientWidth;if(!w||w===gw)return;
  var top=grid.getBoundingClientRect().top+window.scrollY,anchor=-1,off=0;
  if(boxes&&window.scrollY>top){var sy=window.scrollY-top;
    for(var k=0;k<n;k++){if(boxes[4*k+1]+boxes[4*k+3]>sy){anchor=k;off=sy-boxes[4*k+1];break}}}
  gw=w;
  var target=Math.max(170,Math.min(280,Math.round(180+(w-430)*.13))),gap=w<700?2:3;
  var r=justify(aspects,w,target,gap);boxes=r.boxes;
  for(var i=0;i<n;i++){var s=cells[i].style;s.left=boxes[4*i]+'px';s.top=boxes[4*i+1]+'px';s.width=boxes[4*i+2]+'px';s.height=boxes[4*i+3]+'px'}
  grid.style.height=r.height+'px';
  if(anchor>=0)window.scrollTo(0,top+boxes[4*anchor+1]+Math.min(off,boxes[4*anchor+3]));
}
layout();grid.classList.add('on');
cells.forEach(function(c){if(io)io.observe(c);else loadThumb(c)});
var raf=0;function relayout(){if(!raf)raf=requestAnimationFrame(function(){raf=0;layout()})}
if('ResizeObserver' in window)new ResizeObserver(relayout).observe(grid);else window.addEventListener('resize',relayout);
var until=document.getElementById('until');
if(until){var ut=new Date(+until.getAttribute('data-t')*1000);
  until.textContent='Available until '+ut.toLocaleString('en-US',{month:'short',day:'numeric',hour:'numeric',minute:'2-digit'})}

/* ---- the viewer ---- */
var lb=document.getElementById('lb'),bg=document.getElementById('lb-bg'),track=document.getElementById('track');
var vDay=document.getElementById('v-day'),vSub=document.getElementById('v-sub');
var dl=document.getElementById('dl'),closeB=document.getElementById('close');
var prevB=document.getElementById('prev'),nextB=document.getElementById('next');
var metas=Array.prototype.slice.call(document.querySelectorAll('meta[name=theme-color]'));
var themes=metas.map(function(m){return m.content});
var dayFmt=new Intl.DateTimeFormat('en-US',{timeZone:'UTC',weekday:'short',month:'short',day:'numeric',year:'numeric'});
var timeFmt=new Intl.DateTimeFormat('en-US',{timeZone:'UTC',hour:'numeric',minute:'2-digit'});
var GAP=24,EASE='cubic-bezier(.2,.8,.2,1)',W=0,H=0,cur=-1,isOpen=false,closing=false,lastFocus=null;
function size(b){var u=['bytes','KB','MB','GB'],i=0;while(b>=1000&&i<3){b/=1000;i++}return (i?b.toFixed(b<10?1:0):b)+' '+u[i]}
function mkSlot(){var el=document.createElement('div');el.className='slot';var f=document.createElement('div');f.className='frame';el.appendChild(f);track.appendChild(el);
  return {el:el,f:f,i:-2,video:null,fx:0,fy:0,fw:1,fh:1,s:1,tx:0,ty:0}}
var slots=[mkSlot(),mkSlot(),mkSlot()];
var cache=[];
function preload(i){if(i<0||i>=n||isVideo(i))return;var u=url('v',i);
  for(var k=0;k<cache.length;k++)if(cache[k].u===u)return;
  var im=new Image();im.decoding='async';im.src=u;if(im.decode)im.decode().catch(function(){});
  cache.push({u:u,im:im});if(cache.length>8)cache.shift()}
function measure(){W=lb.clientWidth;H=lb.clientHeight}
function xf(el,x,y,s,ms,ease){el.style.transition=ms?'transform '+ms+'ms '+(ease||EASE):'none';
  el.style.transform='translate3d('+x+'px,'+y+'px,0)'+(s!==1?' scale('+s+')':'')}
function apply(sl,ms){xf(sl.f,sl.tx,sl.ty,sl.s,ms)}
function fit(sl){if(sl.i<0)return;var a=nat[sl.i],fw=W,fh=W/a;if(fh>H){fh=H;fw=H*a}
  sl.fw=fw;sl.fh=fh;sl.fx=(W-fw)/2;sl.fy=(H-fh)/2;var st=sl.f.style;
  st.left=sl.fx+'px';st.top=sl.fy+'px';st.width=fw+'px';st.height=fh+'px';sl.s=1;sl.tx=0;sl.ty=0;apply(sl,0)}
function fill(sl,i){
  if(i<0||i>=n){sl.i=-1;sl.el.hidden=true;stopVideo(sl);sl.f.textContent='';return}
  sl.el.hidden=false;if(sl.i===i)return;
  stopVideo(sl);sl.f.textContent='';sl.i=i;
  var th=document.createElement('img');th.className='th';th.alt='';th.draggable=false;
  th.onload=function(){var a=th.naturalWidth/th.naturalHeight;if(a>0&&Math.abs(a/nat[i]-1)>.03){nat[i]=a;if(sl.i===i)fit(sl)}};
  th.src=url('t',i);sl.f.appendChild(th);
  if(!isVideo(i)){var hi=document.createElement('img');hi.className='hi';hi.alt=items[i].name;hi.draggable=false;hi.decoding='async';
    hi.src=url('v',i);sl.f.appendChild(hi);
    var show=function(){if(sl.i===i)hi.classList.add('in')};
    if(hi.decode)hi.decode().then(show,function(){hi.onload=show});else hi.onload=show}
  fit(sl)}
function stopVideo(sl){var v=sl.video;if(!v)return;sl.video=null;v.pause();v.removeAttribute('src');try{v.load()}catch(e){}v.remove()}
function startVideo(sl){if(!isVideo(sl.i)||sl.video)return;var v=document.createElement('video');
  v.controls=true;v.playsInline=true;v.setAttribute('playsinline','');v.preload='auto';v.poster=url('t',sl.i);v.src=url('v',sl.i);
  sl.f.appendChild(v);sl.video=v;var p=v.play();if(p&&p.catch)p.catch(function(){})}
function place(){for(var k=0;k<3;k++)xf(slots[k].el,(k-1)*(W+GAP),0,1,0)}
function trackX(){var t=getComputedStyle(track).transform;if(!t||t==='none')return 0;try{return new DOMMatrixReadOnly(t).m41}catch(e){return 0}}
function bar(){var it=items[cur];
  if(it.taken!=null){var d=new Date(it.taken*1000);vDay.textContent=dayFmt.format(d);vSub.textContent=timeFmt.format(d)+'  ·  '+(cur+1)+' of '+n}
  else{vDay.textContent=it.name;vSub.textContent=(cur+1)+' of '+n}
  if(dl){dl.href=url('o',cur);dl.setAttribute('aria-label','Download '+it.name+' ('+size(it.bytes)+')');dl.title='Download original · '+size(it.bytes)}
  prevB.disabled=cur===0;nextB.disabled=cur===n-1}
function render(i){cur=i;fill(slots[0],i-1);fill(slots[1],i);fill(slots[2],i+1);place();
  for(var k=0;k<3;k++)if(k!==1)stopVideo(slots[k]);startVideo(slots[1]);bar();
  preload(i+1);preload(i-1);preload(i+2);preload(i-2)}
/* moves to cur+dir now; the track keeps its on-screen position and glides to 0 */
function step(dir,from,ms){var x=from+dir*(W+GAP);
  if(dir===1)slots.push(slots.shift());else slots.unshift(slots.pop());
  render(cur+dir);xf(track,x,0,1,0);void track.offsetWidth;xf(track,0,0,1,ms)}
function go(dir){var j=cur+dir;if(!isOpen||closing||j<0||j>=n)return;var sl=slots[1];
  if(sl.s!==1){sl.s=1;sl.tx=sl.ty=0;apply(sl,0)}step(dir,trackX(),reduce?0:300)}
function setTheme(c){metas.forEach(function(m,k){m.content=c||themes[k]})}
function cellRect(i){var c=cells[i];var r=c.getBoundingClientRect();
  if(r.bottom<=0||r.top>=window.innerHeight){window.scrollBy(0,r.top-(window.innerHeight-r.height)/2);r=c.getBoundingClientRect()}return r}
/* frame transform that lays the item over its tile */
function toCell(sl,r){var k=Math.max(r.width/sl.fw,r.height/sl.fh);
  return {x:r.left+(r.width-sl.fw*k)/2-sl.fx,y:r.top+(r.height-sl.fh*k)/2-sl.fy,s:k}}
function show(i){
  lastFocus=document.activeElement;isOpen=true;closing=false;lb.hidden=false;root.classList.add('lb-open');setTheme('#000000');
  lb.classList.remove('bare');measure();xf(track,0,0,1,0);render(i);
  var sl=slots[1],r=cells[i].getBoundingClientRect();
  if(!reduce&&r.width&&r.bottom>0&&r.top<window.innerHeight){
    var t=toCell(sl,r);cells[i].classList.add('hero');lb.classList.add('busy');
    xf(sl.f,t.x,t.y,t.s,0);bg.style.transition='none';bg.style.opacity='0';void lb.offsetWidth;
    apply(sl,340);bg.style.transition='opacity 300ms ease';bg.style.opacity='1';
    setTimeout(function(){cells[i].classList.remove('hero');lb.classList.remove('busy')},340)}
  else bg.style.opacity='1';
  closeB.focus({preventScroll:true})}
function hide(){
  if(!isOpen||closing)return;closing=true;var sl=slots[1],i=cur;stopVideo(sl);
  var done=function(){isOpen=false;closing=false;lb.hidden=true;root.classList.remove('lb-open');lb.classList.remove('busy');
    cells[i].classList.remove('hero');setTheme(null);for(var k=0;k<3;k++)fill(slots[k],-1);
    if(lastFocus&&lastFocus.focus)lastFocus.focus({preventScroll:true})};
  if(reduce){done();return}
  var r=cellRect(i),t=toCell(sl,r);lb.classList.add('busy');
  xf(track,0,0,1,0);xf(sl.f,t.x,t.y,t.s,300);bg.style.transition='opacity 280ms ease';bg.style.opacity='0';
  setTimeout(function(){cells[i].classList.add('hero')},0);
  setTimeout(done,310)}
function open(i){show(i);try{history.pushState({lb:1},'')}catch(e){}}
function close(){if(history.state&&history.state.lb)history.back();else hide()}
window.addEventListener('popstate',hide);
cells.forEach(function(c){c.addEventListener('click',function(e){if(e.metaKey||e.ctrlKey||e.shiftKey||e.altKey)return;e.preventDefault();open(+c.getAttribute('data-i'))})});
closeB.addEventListener('click',close);
prevB.addEventListener('click',function(){go(-1)});
nextB.addEventListener('click',function(){go(1)});
document.addEventListener('keydown',function(e){if(!isOpen)return;
  if(e.key==='Escape'){e.preventDefault();close()}
  else if(e.key==='ArrowLeft'){e.preventDefault();go(-1)}
  else if(e.key==='ArrowRight'){e.preventDefault();go(1)}});
window.addEventListener('resize',function(){if(!isOpen||closing)return;measure();for(var k=0;k<3;k++)fit(slots[k]);place();xf(track,0,0,1,0)});

/* ---- gestures: swipe, dismiss, pinch, pan, double tap ---- */
function rubber(d,dim){var s=d<0?-1:1;d=Math.abs(d);return s*(1-1/(d*.55/dim+1))*dim}
function band(v,lo,hi,dim){return v>hi?hi+rubber(v-hi,dim):v<lo?lo+rubber(v-lo,dim):v}
function bounds(sl){var sw=sl.fw*sl.s,sh=sl.fh*sl.s,b={};
  if(sw<=W){b.x0=b.x1=(W-sw)/2-sl.fx}else{b.x0=W-sw-sl.fx;b.x1=-sl.fx}
  if(sh<=H){b.y0=b.y1=(H-sh)/2-sl.fy}else{b.y0=H-sh-sl.fy;b.y1=-sl.fy}return b}
function clampPan(sl){var b=bounds(sl);sl.tx=Math.min(b.x1,Math.max(b.x0,sl.tx));sl.ty=Math.min(b.y1,Math.max(b.y0,sl.ty))}
function zoomAt(sl,s1,px,py,ms){var cx=(px-sl.fx-sl.tx)/sl.s,cy=(py-sl.fy-sl.ty)/sl.s;
  sl.s=s1;sl.tx=px-sl.fx-cx*s1;sl.ty=py-sl.fy-cy*s1;clampPan(sl);apply(sl,ms);lb.classList.toggle('bare',s1>1.01)}
var ptrs={},np=0,g=null,pend=null,tapT=0,lastTap=null;
function later(f){if(!pend)requestAnimationFrame(function(){var h=pend;pend=null;if(h)h()});pend=f}
function now(){return performance.now()}
function sample(e){var q=g.q;q.push([now(),e.clientX,e.clientY]);while(q.length>2&&q[q.length-1][0]-q[0][0]>100)q.shift()}
function vel(){var q=g.q,a=q[0],b=q[q.length-1],dt=b[0]-a[0];if(q.length<2||dt<=0||now()-b[0]>80)return [0,0];return [(b[1]-a[1])/dt,(b[2]-a[2])/dt]}
function two(){var a=[];for(var k in ptrs)a.push(ptrs[k]);return a}
function startPinch(){var p=two(),sl=slots[1];if(sl.i<0||isVideo(sl.i))return;
  if(g&&g.mode==='x')xf(track,0,0,1,200);
  var mx=(p[0].x+p[1].x)/2,my=(p[0].y+p[1].y)/2;
  g={mode:'pinch',d0:Math.hypot(p[0].x-p[1].x,p[0].y-p[1].y)||1,s0:sl.s,cx:(mx-sl.fx-sl.tx)/sl.s,cy:(my-sl.fy-sl.ty)/sl.s,q:[]};
  clearTimeout(tapT);lb.classList.add('bare')}
lb.addEventListener('pointerdown',function(e){
  if(!isOpen||closing)return;
  // the bar's buttons, and the arrows for a mouse; a finger may swipe from anywhere
  if(e.target.closest('.bar')||(e.pointerType!=='touch'&&e.target.closest('.vnav')))return;
  if(e.pointerType==='mouse'&&e.button!==0)return;
  var vid=e.target.tagName==='VIDEO';
  if(vid){var vr=e.target.getBoundingClientRect();if(e.clientY>vr.bottom-80)return}
  if(e.isPrimary){ptrs={};np=0}
  ptrs[e.pointerId]={x:e.clientX,y:e.clientY};np++;
  if(np===2){startPinch();return}
  if(np>2)return;
  var sl=slots[1],x=trackX();xf(track,x,0,1,0);
  if(x!==0&&!(sl.s>1.01)){g={mode:'x',x0:e.clientX-x,y0:e.clientY,q:[],vid:vid,id:e.pointerId,moved:true};try{lb.setPointerCapture(e.pointerId)}catch(_){}}
  else g={mode:null,x0:e.clientX,y0:e.clientY,tx0:sl.tx,ty0:sl.ty,q:[],vid:vid,id:e.pointerId,moved:false};
  sample(e)});
lb.addEventListener('pointermove',function(e){
  var p=ptrs[e.pointerId];if(!p||!g)return;p.x=e.clientX;p.y=e.clientY;
  var sl=slots[1];
  if(g.mode==='pinch'){var q=two();if(q.length<2)return;
    var d=Math.hypot(q[0].x-q[1].x,q[0].y-q[1].y),mx=(q[0].x+q[1].x)/2,my=(q[0].y+q[1].y)/2;
    var s=g.s0*d/g.d0;if(s<1)s=1-rubber(1-s,2);if(s>5)s=5+rubber(s-5,10);
    sl.s=s;sl.tx=mx-sl.fx-g.cx*s;sl.ty=my-sl.fy-g.cy*s;later(function(){apply(sl,0)});return}
  if(e.pointerId!==g.id)return;
  sample(e);var dx=e.clientX-g.x0,dy=e.clientY-g.y0;
  if(!g.mode){if(Math.abs(dx)<8&&Math.abs(dy)<8)return;
    g.moved=true;clearTimeout(tapT);
    g.mode=sl.s>1.01?'pan':Math.abs(dx)>Math.abs(dy)?'x':'y';
    try{lb.setPointerCapture(e.pointerId)}catch(_){}
    if(g.mode==='y')lb.classList.add('busy')}
  if(g.mode==='x'){var x=dx;if((cur===0&&dx>0)||(cur===n-1&&dx<0))x=rubber(dx,W);g.dx=x;later(function(){xf(track,x,0,1,0)})}
  else if(g.mode==='y'){var yy=dy>0?dy:rubber(dy,H)*.5,k=1-Math.min(1,Math.max(0,yy)/H)*.4;g.dy=dy;
    later(function(){xf(sl.f,dx*.9+(1-k)*sl.fw/2,yy+(1-k)*sl.fh/2,k,0);bg.style.transition='none';bg.style.opacity=String(1-Math.min(1,Math.max(0,yy)/(H*.45)))})}
  else if(g.mode==='pan'){var b=bounds(sl);sl.tx=band(g.tx0+dx,b.x0,b.x1,W);sl.ty=band(g.ty0+dy,b.y0,b.y1,H);later(function(){apply(sl,0)})}
},{passive:true});
function end(e){
  if(!ptrs[e.pointerId])return;delete ptrs[e.pointerId];np--;
  if(!g)return;var sl=slots[1];
  if(g.mode==='pinch'){if(np>0)return;g=null;pend=null;
    var s=Math.min(4,Math.max(1,sl.s));
    if(s<=1.01){sl.s=1;sl.tx=sl.ty=0;apply(sl,260);lb.classList.remove('bare')}
    else{if(s!==sl.s){var cx=(W/2-sl.fx-sl.tx)/sl.s,cy=(H/2-sl.fy-sl.ty)/sl.s;sl.s=s;sl.tx=W/2-sl.fx-cx*s;sl.ty=H/2-sl.fy-cy*s}
      clampPan(sl);apply(sl,260)}return}
  if(e.pointerId!==g.id||np>0)return;
  var v=vel(),m=g.mode,gg=g;g=null;pend=null;
  if(!m){if(e.type==='pointerup')tap(e,gg);return}
  if(m==='x'){var dx=gg.dx||0,dir=0;
    if(v[0]<-.3||(dx<-W/2&&v[0]<=.3))dir=1;else if(v[0]>.3||(dx>W/2&&v[0]>=-.3))dir=-1;
    if((dir===1&&cur>=n-1)||(dir===-1&&cur<=0))dir=0;
    if(!dir){xf(track,0,0,1,reduce?0:280);return}
    var rest=W+GAP-Math.abs(dx),ms=reduce?0:Math.round(Math.max(170,Math.min(340,rest/Math.max(Math.abs(v[0]),1.2))));
    step(dir,dx,ms);return}
  if(m==='y'){lb.classList.remove('busy');
    if((gg.dy||0)>110||v[1]>.55){close();return}
    apply(sl,260);bg.style.transition='opacity 260ms ease';bg.style.opacity='1';return}
  if(m==='pan'){sl.tx+=v[0]*160;sl.ty+=v[1]*160;clampPan(sl);xf(sl.f,sl.tx,sl.ty,sl.s,420,'cubic-bezier(.15,.85,.3,1)')}}
lb.addEventListener('pointerup',end);
lb.addEventListener('pointercancel',end);
function tap(e,gg){
  if(gg.vid||e.target.closest('.vnav'))return;
  var t=now(),sl=slots[1];
  if(lastTap&&t-lastTap.t<320&&Math.hypot(e.clientX-lastTap.x,e.clientY-lastTap.y)<40){
    clearTimeout(tapT);lastTap=null;if(sl.i<0||isVideo(sl.i))return;
    if(sl.s>1.01){sl.s=1;sl.tx=sl.ty=0;apply(sl,300);lb.classList.remove('bare')}
    else zoomAt(sl,Math.max(2.5,Math.min(4,Math.max(W/sl.fw,H/sl.fh))),e.clientX,e.clientY,300);
    return}
  lastTap={t:t,x:e.clientX,y:e.clientY};
  if(e.pointerType==='mouse')return;
  clearTimeout(tapT);tapT=setTimeout(function(){lb.classList.toggle('bare')},260)}
lb.addEventListener('dblclick',function(e){e.preventDefault()});
lb.addEventListener('wheel',function(e){if(!isOpen)return;var sl=slots[1];if(sl.i<0||isVideo(sl.i))return;e.preventDefault();
  if(e.ctrlKey){zoomAt(sl,Math.max(1,Math.min(4,sl.s*Math.exp(-e.deltaY*.01))),e.clientX,e.clientY,0)}
  else if(sl.s>1.01){sl.tx-=e.deltaX;sl.ty-=e.deltaY;clampPan(sl);apply(sl,0)}},{passive:false});
document.addEventListener('gesturestart',function(e){if(isOpen)e.preventDefault()});
})();
`;

const ICON_PLAY = `<svg width="10" height="10" viewBox="0 0 10 10" aria-hidden="true"><path d="M2 1.2v7.6a.5.5 0 0 0 .76.43l6.2-3.8a.5.5 0 0 0 0-.86l-6.2-3.8A.5.5 0 0 0 2 1.2z" fill="currentColor"/></svg>`;
const ICON_CLOSE = `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18"/></svg>`;
const ICON_DOWNLOAD = `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 4v11M7 10.5l5 5 5-5M5 20h14"/></svg>`;
const ICON_PREV = `<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M15 5l-7 7 7 7"/></svg>`;
const ICON_NEXT = `<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M9 5l7 7-7 7"/></svg>`;

export interface GalleryOptions {
  nonce: string;
  id: string;
  manifest: Manifest;
  /** Absolute origin, for link-preview tags; omitted for password shares. */
  previewOrigin?: string;
}

export function galleryPage(o: GalleryOptions): string {
  const m = o.manifest;
  const base = `/s/${o.id}/f/`;
  const title = m.title || "Shared photos";
  const count = formatCount(m.items);
  const range = dateRange(m.items);
  const meta = range ? `${count} · ${range}` : count;
  const totalBytes = m.items.reduce((n, it) => n + (it.bytes || 0), 0);

  const cells = m.items
    .map((it, i) => {
      const dur =
        it.kind === "video"
          ? `<span class="dur">${ICON_PLAY}${it.duration !== null ? formatDuration(it.duration) : ""}</span>`
          : "";
      const label = `${it.kind === "video" ? "Video" : "Photo"} ${i + 1} of ${m.items.length}`;
      return `<a class="cell" href="${base}v/${it.id}" data-i="${i}" aria-label="${label}"><img alt="" decoding="async" draggable="false">${dur}</a>`;
    })
    .join("");

  const data = {
    base,
    items: m.items.map((it) => ({
      id: it.id,
      kind: it.kind,
      w: it.w,
      h: it.h,
      taken: it.taken,
      name: it.name,
      bytes: it.bytes,
    })),
  };

  let head = `\n<meta property="og:title" content="${escapeHtml(title)}">\n<meta property="og:description" content="${escapeHtml(meta)}">`;
  if (o.previewOrigin && m.items[0])
    head += `\n<meta property="og:image" content="${escapeHtml(`${o.previewOrigin}${base}t/${m.items[0].id}`)}">`;

  const sep = ` <span class="sep" aria-hidden="true">·</span> `;
  const sub =
    `<span>${escapeHtml(count)}</span>` +
    (range ? `${sep}<span>${escapeHtml(range)}</span>` : "") +
    `<span class="sep until-sep" aria-hidden="true">·</span> <span class="until" id="until" data-t="${m.expires_at}">${escapeHtml(`Available until ${formatDay(m.expires_at)}`)}</span>`;

  const zipAll = m.allow_download
    ? `<a class="pill" id="zip" href="/s/${o.id}/zip" download aria-label="Download all as ZIP, ${escapeHtml(formatBytes(totalBytes))}">${ICON_DOWNLOAD}<span>Download all</span><small>${escapeHtml(formatBytes(totalBytes))}</small></a>`
    : "";
  const dl = m.allow_download
    ? `<a class="vb r" id="dl" href="#" download aria-label="Download">${ICON_DOWNLOAD}</a>`
    : `<span class="r"></span>`;

  return shell({
    title,
    nonce: o.nonce,
    css: GALLERY_CSS,
    head,
    body: `<header class="hd">
<a class="brand" href="${ATLAS_URL}" rel="noopener noreferrer">${atlasMark(22, "am-h")}Atlas</a>
<div class="hrow"><div>
<h1>${escapeHtml(title)}</h1>
<p class="sub">${sub}</p>
</div>${zipAll}</div>
</header>
<div class="lb" id="lb" hidden role="dialog" aria-modal="true" aria-label="${escapeHtml(title)}">
<div class="lb-bg" id="lb-bg"></div>
<div class="track" id="track"></div>
<div class="bar">
<button class="vb l" id="close" type="button" aria-label="Close">${ICON_CLOSE}</button>
<div class="vt" aria-live="polite"><b id="v-day"></b><span id="v-sub"></span></div>
${dl}
</div>
<button class="vnav prev" id="prev" type="button" aria-label="Previous">${ICON_PREV}</button>
<button class="vnav next" id="next" type="button" aria-label="Next">${ICON_NEXT}</button>
</div>
<main class="grid" id="grid">${cells}</main>
<noscript><p class="nojs">Turn on JavaScript to see these photos.</p></noscript>
<script type="application/json" id="data">${scriptJson(data)}</script>
<script nonce="${o.nonce}">${GALLERY_JS.replace("__JUSTIFY__", () => justify.toString())}</script>
${FOOTER}`,
  });
}

// Server-rendered pages: the gallery, the password gate and the one-line
// notices (404, 410, 500). Every manifest string is user data and is escaped.

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
:root{color-scheme:light dark;--bg:#fff;--fg:#1d1d1f;--muted:#6e6e73;--cell:#f0f0f3;--card:#fff;--field:#f5f5f7;--line:rgba(0,0,0,.1);--accent:#0071e3;--accent-fg:#fff;--err:#d70015;--bar:rgba(255,255,255,.78)}
@media (prefers-color-scheme:dark){:root{--bg:#000;--fg:#f5f5f7;--muted:#98989d;--cell:#1c1c1e;--card:#1c1c1e;--field:#2c2c2e;--line:rgba(255,255,255,.14);--accent:#2997ff;--accent-fg:#fff;--err:#ff6961;--bar:rgba(22,22,24,.78)}}
*,*::before,*::after{box-sizing:border-box}
html{-webkit-text-size-adjust:100%;text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--fg);font-family:${FONT};font-size:17px;line-height:1.4;-webkit-font-smoothing:antialiased;overflow-x:hidden}
a{color:var(--accent);text-decoration:none}
button{font:inherit;color:inherit}
.foot{padding:28px max(16px,env(safe-area-inset-right)) max(28px,env(safe-area-inset-bottom)) max(16px,env(safe-area-inset-left));text-align:center;font-size:13px;color:var(--muted)}
.foot a{color:var(--muted);font-weight:600}
.foot a:hover{color:var(--fg)}
.center{min-height:100vh;min-height:100dvh;display:flex;flex-direction:column}
.center main{flex:1;display:flex;align-items:center;justify-content:center;padding:24px max(16px,env(safe-area-inset-right)) 0 max(16px,env(safe-area-inset-left))}
.notice{margin:0;font-size:20px;font-weight:600;letter-spacing:-.01em;text-align:center;max-width:28em}
`;

const FOOTER = `<footer class="foot">Shared with <a href="${ATLAS_URL}" rel="noopener noreferrer">Atlas</a></footer>`;

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

export function noticePage(nonce: string, title: string, line: string): string {
  return shell({
    title,
    nonce,
    css: "",
    body: `<div class="center"><main><p class="notice">${escapeHtml(line)}</p></main>${FOOTER}</div>`,
  });
}

// ---------------------------------------------------------------- gate

const GATE_CSS = `
.card{width:100%;max-width:360px;background:var(--card);border-radius:20px;padding:32px 24px 26px;text-align:center;box-shadow:0 1px 2px rgba(0,0,0,.04),0 8px 30px rgba(0,0,0,.08)}
@media (prefers-color-scheme:dark){.card{box-shadow:none;border:1px solid var(--line)}}
.lock{width:44px;height:44px;margin:0 auto 14px;border-radius:50%;background:var(--field);display:flex;align-items:center;justify-content:center;color:var(--muted)}
.card h1{margin:0 0 6px;font-size:22px;font-weight:700;letter-spacing:-.02em;overflow-wrap:anywhere}
.card p{margin:0 0 22px;font-size:15px;color:var(--muted)}
.card input{display:block;width:100%;height:46px;padding:0 14px;border:1px solid transparent;border-radius:12px;background:var(--field);color:var(--fg);font:inherit;font-size:17px;outline:none;-webkit-appearance:none;appearance:none}
.card input:focus{border-color:var(--accent);box-shadow:0 0 0 3px color-mix(in srgb,var(--accent) 25%,transparent)}
.card button{display:block;width:100%;height:46px;margin-top:12px;border:0;border-radius:12px;background:var(--accent);color:var(--accent-fg);font-size:17px;font-weight:600;cursor:pointer}
.card button:active{opacity:.85}
.err{margin:14px 0 0!important;color:var(--err)!important;font-size:14px!important}
`;

export function gatePage(nonce: string, id: string, title: string, wrong: boolean): string {
  const t = title || "Shared photos";
  return shell({
    title: t,
    nonce,
    css: GATE_CSS,
    body: `<div class="center"><main>
<form class="card" method="post" action="/s/${id}/unlock">
<div class="lock" aria-hidden="true"><svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="11" width="16" height="10" rx="2.5"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/></svg></div>
<h1>${escapeHtml(t)}</h1>
<p>Enter the password to view.</p>
<input type="password" name="password" placeholder="Password" aria-label="Password" autocomplete="current-password" required autofocus>
<button type="submit">View</button>${wrong ? `\n<p class="err" role="alert">Wrong password. Try again.</p>` : ""}
</form>
</main>${FOOTER}</div>`,
  });
}

// ---------------------------------------------------------------- gallery

const GALLERY_CSS = `
.hd{padding:max(32px,calc(env(safe-area-inset-top) + 20px)) max(16px,env(safe-area-inset-right)) 18px max(16px,env(safe-area-inset-left))}
.hd h1{margin:0;font-size:32px;line-height:1.12;font-weight:700;letter-spacing:-.025em;overflow-wrap:anywhere}
.meta{margin:6px 0 0;font-size:15px;color:var(--muted)}
.until{margin:2px 0 0;font-size:13px;color:var(--muted)}
@media (min-width:700px){.hd{padding-top:48px;padding-bottom:22px}.hd h1{font-size:40px}.meta{font-size:17px}}
.grid{display:grid;grid-template-columns:repeat(3,1fr);gap:2px;padding:0 env(safe-area-inset-right) 0 env(safe-area-inset-left)}
@media (min-width:600px){.grid{grid-template-columns:repeat(4,1fr)}}
@media (min-width:900px){.grid{grid-template-columns:repeat(5,1fr)}}
@media (min-width:1200px){.grid{grid-template-columns:repeat(6,1fr)}}
@media (min-width:1600px){.grid{grid-template-columns:repeat(8,1fr)}}
.cell{position:relative;display:block;aspect-ratio:1;overflow:hidden;background:var(--cell);-webkit-tap-highlight-color:transparent}
.cell img{display:block;width:100%;height:100%;object-fit:cover;opacity:0;transition:opacity .25s}
.cell img.in{opacity:1}
.cell:focus-visible{outline:3px solid var(--accent);outline-offset:-3px}
@media (hover:hover){.cell:hover img{filter:brightness(.92)}}
.dur{position:absolute;right:6px;bottom:5px;display:flex;align-items:center;gap:3px;color:#fff;font-size:12px;font-weight:600;font-variant-numeric:tabular-nums;text-shadow:0 0 3px rgba(0,0,0,.6);pointer-events:none}
.dur svg{filter:drop-shadow(0 0 2px rgba(0,0,0,.5))}
html.lb-open,html.lb-open body{overflow:hidden}
.lb{position:fixed;inset:0;z-index:10;background:var(--bg);display:flex;flex-direction:column;touch-action:pinch-zoom}
.lb[hidden]{display:none}
.bar{position:absolute;left:0;right:0;top:0;z-index:2;display:grid;grid-template-columns:1fr auto 1fr;align-items:center;gap:8px;padding:calc(env(safe-area-inset-top) + 6px) max(8px,env(safe-area-inset-right)) 6px max(8px,env(safe-area-inset-left));background:var(--bar);-webkit-backdrop-filter:saturate(180%) blur(20px);backdrop-filter:saturate(180%) blur(20px);transition:opacity .2s}
.bar .l{justify-self:start}.bar .r{justify-self:end}
.ttl{text-align:center;min-width:0;line-height:1.2}
.ttl b{display:block;font-size:15px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.ttl span{display:block;font-size:12px;color:var(--muted);font-variant-numeric:tabular-nums}
.ib{display:inline-flex;align-items:center;justify-content:center;gap:6px;min-width:44px;height:44px;padding:0 10px;border:0;border-radius:22px;background:transparent;color:var(--accent);cursor:pointer;font-size:15px;font-weight:500;white-space:nowrap;-webkit-tap-highlight-color:transparent}
.ib:hover{background:color-mix(in srgb,var(--fg) 7%,transparent)}
.ib[hidden]{display:none}
.ib small{font-size:13px;color:var(--muted);font-weight:400}
@media (max-width:420px){.ib .lbl{display:none}}
.stage{position:relative;flex:1;overflow:hidden}
.slide{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;padding:calc(env(safe-area-inset-top) + 56px) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left);will-change:transform}
.slide img,.slide video{display:block;max-width:100%;max-height:100%;width:auto;height:auto;object-fit:contain;-webkit-user-select:none;user-select:none;-webkit-touch-callout:none}
.slide img{width:100%;height:100%}
.slide video{width:100%;height:100%;background:transparent}
.lb.bare .bar,.lb.bare .nav{opacity:0;pointer-events:none}
.lb.bare .slide{padding-top:env(safe-area-inset-top)}
.nav{position:absolute;top:50%;z-index:2;width:44px;height:44px;margin-top:-22px;border:0;border-radius:50%;background:var(--bar);-webkit-backdrop-filter:blur(20px);backdrop-filter:blur(20px);color:var(--fg);display:flex;align-items:center;justify-content:center;cursor:pointer;transition:opacity .2s}
.nav.prev{left:max(12px,env(safe-area-inset-left))}.nav.next{right:max(12px,env(safe-area-inset-right))}
.nav:disabled{opacity:0;pointer-events:none}
@media (hover:none){.nav{display:none}}
@media (prefers-reduced-motion:reduce){.cell img{transition:none}}
`;

// The viewer. Plain DOM, no dependencies. Data comes from the JSON block.
const GALLERY_JS = `
(function(){
var D=JSON.parse(document.getElementById('data').textContent);
var items=D.items,base=D.base,n=items.length;
var lb=document.getElementById('lb'),stage=document.getElementById('stage'),slide=document.getElementById('slide');
var ttl=document.getElementById('ttl-main'),sub=document.getElementById('ttl-sub');
var dl=document.getElementById('dl'),dlSize=document.getElementById('dl-size');
var prevB=document.getElementById('prev'),nextB=document.getElementById('next');
var cells=document.querySelectorAll('.cell');
var cur=-1,lastFocus=null,busy=false;
var reduce=window.matchMedia('(prefers-reduced-motion: reduce)').matches;
function url(k,it){return base+k+'/'+it.id}
function bytes(b){var u=['bytes','KB','MB','GB'],i=0;while(b>=1000&&i<3){b/=1000;i++}return (i?b.toFixed(b<10?1:0):b)+' '+u[i]}
var dayFmt=new Intl.DateTimeFormat('en-US',{timeZone:'UTC',month:'short',day:'numeric',year:'numeric'});
var timeFmt=new Intl.DateTimeFormat('en-US',{timeZone:'UTC',hour:'numeric',minute:'2-digit'});
document.querySelectorAll('.cell img').forEach(function(img){
  if(img.complete&&img.naturalWidth)img.classList.add('in');
  else{img.addEventListener('load',function(){img.classList.add('in')});img.addEventListener('error',function(){img.classList.add('in')})}
});
var until=document.getElementById('until');
if(until){var t=new Date(+until.getAttribute('data-t')*1000);
  until.textContent='Available until '+t.toLocaleString('en-US',{month:'short',day:'numeric',year:'numeric',hour:'numeric',minute:'2-digit'});}
function render(i){
  var it=items[i];cur=i;slide.textContent='';
  if(it.kind==='video'){
    var v=document.createElement('video');
    v.controls=true;v.playsInline=true;v.setAttribute('playsinline','');v.preload='metadata';
    v.poster=url('t',it);v.src=url('v',it);slide.appendChild(v);
  }else{
    var img=document.createElement('img');img.alt=it.name;img.draggable=false;img.src=url('t',it);slide.appendChild(img);
    var hi=new Image();hi.src=url('v',it);
    var swap=function(){if(cur===i&&img.isConnected)img.src=hi.src};
    if(hi.decode)hi.decode().then(swap,function(){});else hi.onload=swap;
  }
  if(it.taken!=null){var d=new Date(it.taken*1000);ttl.textContent=dayFmt.format(d);sub.textContent=timeFmt.format(d)+'  ·  '+(i+1)+' of '+n}
  else{ttl.textContent=it.name;sub.textContent=(i+1)+' of '+n}
  if(dl){dl.href=url('o',it);dlSize.textContent=bytes(it.bytes);dl.setAttribute('aria-label','Download '+it.name+', '+bytes(it.bytes))}
  prevB.disabled=i===0;nextB.disabled=i===n-1;
  [i-1,i+1].forEach(function(j){if(j>=0&&j<n&&items[j].kind==='photo'){new Image().src=url('v',items[j])}});
}
function stopMedia(){var v=slide.querySelector('video');if(v){v.pause();v.removeAttribute('src');v.load()}}
function show(i){
  lastFocus=document.activeElement;lb.hidden=false;lb.classList.remove('bare');
  document.documentElement.classList.add('lb-open');
  slide.style.transition='none';slide.style.transform='';slide.style.opacity='';
  render(i);document.getElementById('close').focus({preventScroll:true});
}
function hide(){
  if(lb.hidden)return;stopMedia();slide.textContent='';lb.hidden=true;cur=-1;
  document.documentElement.classList.remove('lb-open');
  if(lastFocus&&lastFocus.focus)lastFocus.focus({preventScroll:true});
}
function open(i){show(i);try{history.pushState({lb:1},'')}catch(e){}}
function close(){if(history.state&&history.state.lb)history.back();else hide()}
window.addEventListener('popstate',function(){hide()});
function go(dir){
  var j=cur+dir;if(busy||j<0||j>=n)return;
  if(reduce){stopMedia();render(j);return}
  busy=true;slide.style.transition='transform .22s cubic-bezier(.2,.7,.3,1)';
  slide.style.transform='translate3d('+(-dir*100)+'%,0,0)';
  setTimeout(function(){
    stopMedia();slide.style.transition='none';slide.style.transform='translate3d('+(dir*100)+'%,0,0)';
    render(j);void slide.offsetWidth;
    slide.style.transition='transform .26s cubic-bezier(.2,.7,.3,1)';slide.style.transform='translate3d(0,0,0)';
    setTimeout(function(){busy=false},260);
  },220);
}
function snap(){slide.style.transition='transform .22s ease, opacity .22s ease';slide.style.transform='translate3d(0,0,0)';slide.style.opacity=''}
cells.forEach(function(c){c.addEventListener('click',function(e){if(e.metaKey||e.ctrlKey||e.shiftKey)return;e.preventDefault();open(+c.getAttribute('data-i'))})});
document.getElementById('close').addEventListener('click',close);
prevB.addEventListener('click',function(){go(-1)});
nextB.addEventListener('click',function(){go(1)});
document.addEventListener('keydown',function(e){
  if(lb.hidden)return;
  if(e.key==='Escape'){e.preventDefault();close()}
  else if(e.key==='ArrowLeft'){e.preventDefault();go(-1)}
  else if(e.key==='ArrowRight'){e.preventDefault();go(1)}
});
stage.addEventListener('click',function(e){if(e.target.tagName!=='VIDEO')lb.classList.toggle('bare')});
var x0=null,y0=0,dx=0,dy=0,t0=0,axis=null;
function zoomed(){return window.visualViewport&&window.visualViewport.scale>1.01}
stage.addEventListener('touchstart',function(e){
  if(e.touches.length!==1||busy||zoomed()){x0=null;return}
  x0=e.touches[0].clientX;y0=e.touches[0].clientY;dx=dy=0;axis=null;t0=Date.now();slide.style.transition='none';
},{passive:true});
stage.addEventListener('touchmove',function(e){
  if(x0===null)return;
  if(e.touches.length!==1){x0=null;snap();return}
  dx=e.touches[0].clientX-x0;dy=e.touches[0].clientY-y0;
  if(!axis){if(Math.abs(dx)<8&&Math.abs(dy)<8)return;axis=Math.abs(dx)>Math.abs(dy)?'x':'y'}
  if(axis==='x'){e.preventDefault();var edge=(cur===0&&dx>0)||(cur===n-1&&dx<0);slide.style.transform='translate3d('+(edge?dx/3:dx)+'px,0,0)'}
  else if(dy>0){e.preventDefault();slide.style.transform='translate3d(0,'+dy+'px,0)';slide.style.opacity=String(Math.max(.4,1-dy/400))}
},{passive:false});
stage.addEventListener('touchend',function(){
  if(x0===null)return;x0=null;
  var dt=Math.max(1,Date.now()-t0);
  if(axis==='x'){
    var v=dx/dt;
    if((dx<-60||v<-.5)&&cur<n-1){slide.style.transition='none';go(1)}
    else if((dx>60||v>.5)&&cur>0){slide.style.transition='none';go(-1)}
    else snap();
  }else if(axis==='y'){if(dy>110||dy/dt>.6)close();else snap()}
});
stage.addEventListener('touchcancel',function(){x0=null;snap()});
})();
`;

const ICON_PLAY = `<svg width="10" height="10" viewBox="0 0 10 10" aria-hidden="true"><path d="M2 1.2v7.6a.5.5 0 0 0 .76.43l6.2-3.8a.5.5 0 0 0 0-.86l-6.2-3.8A.5.5 0 0 0 2 1.2z" fill="currentColor"/></svg>`;
const ICON_CLOSE = `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18"/></svg>`;
const ICON_DOWNLOAD = `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 4v11M7 10.5l5 5 5-5M5 20h14"/></svg>`;
const ICON_PREV = `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M15 5l-7 7 7 7"/></svg>`;
const ICON_NEXT = `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M9 5l7 7-7 7"/></svg>`;

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
  const untilFallback = `Available until ${formatDay(m.expires_at)}`;

  const cells = m.items
    .map((it, i) => {
      const dur =
        it.kind === "video"
          ? `<span class="dur">${ICON_PLAY}${it.duration !== null ? formatDuration(it.duration) : ""}</span>`
          : "";
      const label = `${it.kind === "video" ? "Video" : "Photo"} ${i + 1} of ${m.items.length}`;
      return `<a class="cell" href="${base}v/${it.id}" data-i="${i}" aria-label="${label}"><img src="${base}t/${it.id}" alt="" loading="lazy" decoding="async">${dur}</a>`;
    })
    .join("");

  const data = {
    base,
    items: m.items.map((it) => ({
      id: it.id,
      kind: it.kind,
      taken: it.taken,
      name: it.name,
      bytes: it.bytes,
    })),
  };

  let head = `\n<meta property="og:title" content="${escapeHtml(title)}">\n<meta property="og:description" content="${escapeHtml(meta)}">`;
  if (o.previewOrigin && m.items[0])
    head += `\n<meta property="og:image" content="${escapeHtml(`${o.previewOrigin}${base}t/${m.items[0].id}`)}">`;

  const download = m.allow_download
    ? `<a class="ib r" id="dl" href="#" download>${ICON_DOWNLOAD}<span class="lbl">Download</span><small id="dl-size"></small></a>`
    : `<span class="r"></span>`;

  return shell({
    title,
    nonce: o.nonce,
    css: GALLERY_CSS,
    head,
    body: `<header class="hd">
<h1>${escapeHtml(title)}</h1>
<p class="meta">${escapeHtml(meta)}</p>
<p class="until" id="until" data-t="${m.expires_at}">${escapeHtml(untilFallback)}</p>
</header>
<main class="grid">${cells}</main>
${FOOTER}
<div class="lb" id="lb" hidden role="dialog" aria-modal="true" aria-label="${escapeHtml(title)}">
<div class="bar">
<button class="ib l" id="close" type="button" aria-label="Close">${ICON_CLOSE}</button>
<div class="ttl" aria-live="polite"><b id="ttl-main"></b><span id="ttl-sub"></span></div>
${download}
</div>
<div class="stage" id="stage"><div class="slide" id="slide"></div></div>
<button class="nav prev" id="prev" type="button" aria-label="Previous">${ICON_PREV}</button>
<button class="nav next" id="next" type="button" aria-label="Next">${ICON_NEXT}</button>
</div>
<script type="application/json" id="data">${scriptJson(data)}</script>
<script nonce="${o.nonce}">${GALLERY_JS}</script>`,
  });
}

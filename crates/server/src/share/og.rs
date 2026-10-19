//! The link preview of a share: the 1200×630 image chats and social apps
//! show for its link (`og:image`). The first photo fills it, and the title
//! sits on a panel of clear liquid glass over the photo's lower edge. A
//! password share shows the Atlas colours instead of a photo, since anyone
//! who has the link sees its preview.
//!
//! The card is an SVG rendered with resvg. The glass is web-glass's own
//! filter (displacement map, tone curve, rim highlight), baked for the two
//! panel heights by `assets/glass/bake.mjs`. Titles are set in Inter
//! (bundled, SIL OFL, `assets/fonts`); the system's fonts cover what Inter
//! lacks (emoji, CJK). Everything here is CPU-bound and runs on the blocking
//! pool.

use std::sync::{Arc, OnceLock};

use anyhow::{Context, Result};
use base64::Engine;
use image::codecs::jpeg::JpegEncoder;
use image::{ExtendedColorType, ImageEncoder, RgbImage};
use resvg::{tiny_skia, usvg};

use crate::imaging::{self, Decoded};

pub const W: u32 = 1200;
pub const H: u32 = 630;

pub struct Card<'a> {
    pub title: &'a str,
    /// Shown under the title, joined with " · " ("48 photos", "Oct 1 – 3, 2026").
    pub meta: &'a [String],
    /// The first photo; None shows the Atlas colours (password shares).
    pub photo: Option<&'a Decoded>,
}

// The panel, as baked (bake.mjs): 40 px from the left, right and bottom
// edges, one height for a title on one line and one for two.
const PANEL_X: f32 = 40.0;
const PANEL_W: f32 = 1120.0;
const PANEL_BOTTOM: f32 = 40.0;
const PANEL_ONE: f32 = 189.0;
const PANEL_TWO: f32 = 258.0;

/// The baked glass of each panel height, ready for resvg.
fn glass() -> &'static [String; 2] {
    static GLASS: OnceLock<[String; 2]> = OnceLock::new();
    GLASS.get_or_init(|| {
        [include_str!("../../assets/glass/panel-189.svg"), include_str!("../../assets/glass/panel-258.svg")]
            .map(for_resvg)
    })
}

/// resvg 0.48 multiplies a displacement by feDisplacementMap's `scale`
/// twice (`scale_coordinates` already includes it), so its square root
/// gives the browser's displacement at our 1:1 scale.
fn for_resvg(baked: &str) -> String {
    let re = regex::Regex::new(r#"(<feDisplacementMap[^>]*?\sscale=")([0-9.]+)""#).expect("pattern");
    re.replace_all(baked, |c: &regex::Captures| {
        format!(r#"{}{}""#, &c[1], c[2].parse::<f32>().unwrap_or(0.0).sqrt())
    })
    .into_owned()
}

// Inside the panel: padding, the text column, the icon on the right.
const PAD_TOP: f32 = 36.0;
const PAD_BOTTOM: f32 = 38.0;
const PAD_X: f32 = 44.0;
const ICON: f32 = 76.0;
const GAP: f32 = 32.0;
const COLUMN: f32 = PANEL_W - 2.0 * PAD_X - GAP - ICON;

const TITLE_SIZE: f32 = 64.0;
const TITLE_MIN: f32 = 48.0;
const TITLE_LEADING: f32 = 1.08;
const META_SIZE: f32 = 28.0;
const META_LEADING: f32 = 1.2;
const META_GAP: f32 = 12.0;

/// The card as a JPEG, with the photo's colour profile (iPhone photos are
/// Display P3).
pub fn render(card: &Card) -> Result<Vec<u8>> {
    let tree = usvg::Tree::from_str(&svg(card)?, &options()).context("preview: bad svg")?;
    let mut pixmap = tiny_skia::Pixmap::new(W, H).context("preview: pixmap")?;
    pixmap.fill(tiny_skia::Color::BLACK);
    resvg::render(&tree, tiny_skia::Transform::default(), &mut pixmap.as_mut());
    // opaque, so the premultiplied pixels are the plain ones
    let rgb: Vec<u8> = pixmap.data().as_chunks::<4>().0.iter().flat_map(|p| [p[0], p[1], p[2]]).collect();
    let mut out = Vec::new();
    let mut jpeg = JpegEncoder::new_with_quality(&mut out, 86);
    if let Some(icc) = card.photo.and_then(|p| p.icc.clone()) {
        let _ = jpeg.set_icc_profile(icc);
    }
    jpeg.write_image(&rgb, W, H, ExtendedColorType::Rgb8)?;
    Ok(out)
}

fn svg(card: &Card) -> Result<String> {
    let title = set(card.title, TITLE, TITLE_SIZE, TITLE_MIN, COLUMN, 2);
    let (height, glass) = if title.lines.len() == 1 && title.size == TITLE_SIZE {
        (PANEL_ONE, &glass()[0])
    } else {
        (PANEL_TWO, &glass()[1])
    };
    let top = H as f32 - PANEL_BOTTOM - height;
    let title_lead = title.size * TITLE_LEADING;
    let meta_lead = META_SIZE * META_LEADING;
    // the title and the meta line, centred in the panel's padding box (a
    // title that had to shrink leaves some room)
    let block = title.lines.len() as f32 * title_lead + META_GAP + meta_lead;
    let y = top + PAD_TOP + (height - PAD_TOP - PAD_BOTTOM - block) / 2.0;
    let first = y + baseline(title.size, title_lead);
    let meta_y = y + title.lines.len() as f32 * title_lead + META_GAP + baseline(META_SIZE, meta_lead);
    let x = PANEL_X + PAD_X;

    let backdrop = match card.photo {
        Some(p) => format!(r#"<image width="{W}" height="{H}" href="{}"/>"#, jpeg_uri(&cover(&p.rgb, W, H)?)?),
        None => brand(),
    };
    let lines: String = title
        .lines
        .iter()
        .enumerate()
        .map(|(i, line)| {
            format!(
                r##"<text x="{x}" y="{:.2}" {} fill="#fff" filter="url(#title-shadow)">{}</text>"##,
                first + i as f32 * title_lead,
                TITLE.attrs(title.size),
                esc(line)
            )
        })
        .collect();
    Ok(format!(
        r##"<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}"><defs>
<linearGradient id="ocean" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#4DD0E1"/><stop offset="1" stop-color="#1565C0"/></linearGradient>
<linearGradient id="dim" x1="0" y1="0" x2="0" y2="1"><stop offset=".45" stop-color="#000" stop-opacity="0"/><stop offset="1" stop-color="#000" stop-opacity=".35"/></linearGradient>
<filter id="title-shadow" x="-10%" y="-50%" width="120%" height="200%"><feDropShadow dx="0" dy="1" stdDeviation="7" flood-color="#000" flood-opacity=".35"/></filter>
<filter id="meta-shadow" x="-10%" y="-50%" width="120%" height="200%"><feDropShadow dx="0" dy="1" stdDeviation="5" flood-color="#000" flood-opacity=".4"/></filter>
{glass}<g id="scene">{backdrop}<rect width="{W}" height="{H}" fill="url(#dim)"/></g>
</defs>
<use href="#scene"/>
<g transform="translate({PANEL_X} {top})"><g clip-path="url(#glass-shape)"><g filter="url(#glass)"><use href="#scene" x="{}" y="{}"/></g></g></g>
{lines}<text x="{x}" y="{meta_y:.2}" {} fill="#fff" fill-opacity=".9" filter="url(#meta-shadow)">{}</text>
{}</svg>"##,
        -PANEL_X,
        -top,
        META.attrs(META_SIZE),
        esc(&card.meta.join(" · ")),
        mark(PANEL_X + PANEL_W - PAD_X - ICON, top + (height - ICON) / 2.0, ICON),
    ))
}

// MARK: - Type

const DISPLAY: &str = "Inter Display";
const TEXT: &str = "Inter";
/// Inter's ascender and descender, in em: where CSS puts the baseline.
const ASCENT: f32 = 1984.0 / 2048.0;
const DESCENT: f32 = 494.0 / 2048.0;

fn fonts() -> Arc<usvg::fontdb::Database> {
    static DB: OnceLock<Arc<usvg::fontdb::Database>> = OnceLock::new();
    DB.get_or_init(|| {
        let mut db = usvg::fontdb::Database::new();
        db.load_font_data(include_bytes!("../../assets/fonts/InterDisplay-Bold.ttf").to_vec());
        db.load_font_data(include_bytes!("../../assets/fonts/Inter-Medium.ttf").to_vec());
        // what Inter has no glyph for (emoji, CJK, …) falls back to these
        db.load_system_fonts();
        Arc::new(db)
    })
    .clone()
}

fn options() -> usvg::Options<'static> {
    usvg::Options { fontdb: fonts(), font_family: TEXT.into(), ..Default::default() }
}

/// The baseline in a line box `leading` tall, as a browser sets it.
fn baseline(size: f32, leading: f32) -> f32 {
    (leading - size * (ASCENT + DESCENT)) / 2.0 + size * ASCENT
}

#[derive(Clone, Copy)]
struct Font {
    family: &'static str,
    weight: u16,
    /// letter spacing, in em
    tracking: f32,
}

const TITLE: Font = Font { family: DISPLAY, weight: 700, tracking: -0.022 };
const META: Font = Font { family: TEXT, weight: 500, tracking: 0.0 };

impl Font {
    fn attrs(self, size: f32) -> String {
        format!(
            r#"font-family="{}" font-weight="{}" font-size="{size}" letter-spacing="{:.2}""#,
            self.family,
            self.weight,
            self.tracking * size
        )
    }

    /// How wide `text` is drawn (its ink, not its advance).
    fn width(self, text: &str, size: f32) -> f32 {
        let svg = format!(
            r#"<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"><text {}>{}</text></svg>"#,
            self.attrs(size),
            esc(text)
        );
        usvg::Tree::from_str(&svg, &options()).map(|t| t.root().abs_bounding_box().width()).unwrap_or(0.0)
    }
}

/// A title broken into lines, and the size it is set at.
struct Lines {
    size: f32,
    lines: Vec<String>,
}

/// `text` in at most `max_lines` lines no wider than `width`, at the largest
/// size from `max` down to `min` that fits; at `min`, a title that is still
/// too long ends in "…".
fn set(text: &str, font: Font, max: f32, min: f32, width: f32, max_lines: usize) -> Lines {
    let mut size = max;
    loop {
        let mut lines = wrap(text, font, size, width);
        if lines.len() <= max_lines {
            return Lines { size, lines };
        }
        if size <= min {
            lines.truncate(max_lines);
            let mut last = lines.pop().unwrap_or_default();
            loop {
                let cut = format!("{}…", last.trim_end());
                if last.is_empty() || font.width(&cut, size) <= width {
                    lines.push(cut);
                    return Lines { size, lines };
                }
                last.pop();
            }
        }
        size = (size - 4.0).max(min);
    }
}

/// Greedy line breaking at spaces; a word wider than a line is broken where
/// it has to be.
fn wrap(text: &str, font: Font, size: f32, width: f32) -> Vec<String> {
    let mut lines = Vec::new();
    let mut line = String::new();
    for word in text.split_whitespace() {
        let joined = if line.is_empty() { word.to_string() } else { format!("{line} {word}") };
        if font.width(&joined, size) <= width {
            line = joined;
            continue;
        }
        if !line.is_empty() {
            lines.push(std::mem::take(&mut line));
        }
        for c in word.chars() {
            line.push(c);
            if line.chars().count() > 1 && font.width(&line, size) > width {
                line.pop();
                lines.push(std::mem::replace(&mut line, c.to_string()));
            }
        }
    }
    if !line.is_empty() {
        lines.push(line);
    }
    lines
}

/// Text for SVG: escaped, without the control characters XML refuses.
fn esc(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            c if c.is_control() || c == '\u{fffe}' || c == '\u{ffff}' => {}
            c => out.push(c),
        }
    }
    out
}

// MARK: - Pictures

fn jpeg_uri(img: &RgbImage) -> Result<String> {
    let mut out = Vec::new();
    JpegEncoder::new_with_quality(&mut out, 92).write_image(img.as_raw(), img.width(), img.height(), ExtendedColorType::Rgb8)?;
    Ok(format!("data:image/jpeg;base64,{}", base64::engine::general_purpose::STANDARD.encode(out)))
}

/// `photo` cropped to the shape of w×h around its middle and scaled to it.
fn cover(photo: &RgbImage, w: u32, h: u32) -> Result<RgbImage> {
    let (pw, ph) = photo.dimensions();
    let scale = (f64::from(w) / f64::from(pw)).max(f64::from(h) / f64::from(ph));
    let cw = ((f64::from(w) / scale).round() as u32).clamp(1, pw);
    let ch = ((f64::from(h) / scale).round() as u32).clamp(1, ph);
    let crop = image::imageops::crop_imm(photo, (pw - cw) / 2, (ph - ch) / 2, cw, ch).to_image();
    imaging::resize(&crop, w, h)
}

/// The Atlas colours with the app icon's two diamonds, large and faint.
fn brand() -> String {
    let (w, h) = (W as f32, H as f32);
    let d = h * 0.9;
    let (cx, cy) = (w * 0.78, h * 0.5);
    format!(
        r##"<rect width="{w}" height="{h}" fill="url(#ocean)"/><rect x="{}" y="{}" width="{d}" height="{d}" rx="{}" transform="rotate(45 {cx} {cy})" fill="#B2EBF2" fill-opacity=".22"/><rect x="{}" y="{}" width="{}" height="{}" rx="{}" transform="rotate(45 {cx} {cy})" fill="#fff" fill-opacity=".35"/>"##,
        cx - d / 2.0,
        cy - d / 2.0,
        d * 0.23,
        cx - d * 0.22,
        cy - d * 0.22,
        d * 0.44,
        d * 0.44,
        d * 0.1,
    )
}

/// The Atlas app icon, as on the share page.
fn mark(x: f32, y: f32, size: f32) -> String {
    format!(
        r##"<g transform="translate({x} {y}) scale({})"><rect width="64" height="64" rx="15" fill="url(#ocean)"/><rect x="17" y="17" width="30" height="30" rx="7" transform="rotate(45 32 32)" fill="#B2EBF2"/><rect x="25.5" y="25.5" width="13" height="13" rx="3.2" transform="rotate(45 32 32)" fill="#fff"/></g>"##,
        size / 64.0
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn photo(w: u32, h: u32) -> Decoded {
        Decoded { rgb: RgbImage::from_fn(w, h, |x, y| image::Rgb([(x % 256) as u8, (y % 256) as u8, 180])), icc: None }
    }

    #[test]
    fn renders_a_1200_by_630_jpeg_with_and_without_a_photo() {
        let p = photo(2048, 1536);
        let meta = ["48 photos".to_string(), "Oct 1 – 3, 2026".to_string()];
        for title in ["Lake Weekend", "Winter Camp in the Dolomites with Friends and Family"] {
            for photo in [Some(&p), None] {
                let jpeg = render(&Card { title, meta: &meta, photo }).unwrap();
                let img = image::load_from_memory(&jpeg).unwrap();
                assert_eq!((img.width(), img.height()), (W, H));
            }
        }
    }

    /// The card's pixels over a photo black left of `edge` and white right of it.
    fn over_an_edge(edge: u32) -> tiny_skia::Pixmap {
        let rgb = RgbImage::from_fn(W, H, |x, _| if x < edge { image::Rgb([0, 0, 0]) } else { image::Rgb([255, 255, 255]) });
        let p = Decoded { rgb, icc: None };
        let meta = ["1 photo".to_string()];
        let mut svg = svg(&Card { title: "Lake Weekend", meta: &meta, photo: Some(&p) }).unwrap();
        // the glass alone: no type, no icon over it
        svg.truncate(svg.find("\n<text").unwrap());
        svg.push_str("</svg>");
        let tree = usvg::Tree::from_str(&svg, &options()).unwrap();
        let mut pixmap = tiny_skia::Pixmap::new(W, H).unwrap();
        resvg::render(&tree, tiny_skia::Transform::default(), &mut pixmap.as_mut());
        pixmap
    }

    /// Where a row turns light, from the left.
    fn turns_light(pixmap: &tiny_skia::Pixmap, y: u32, from: u32) -> u32 {
        (from..W).find(|&x| pixmap.pixel(x, y).unwrap().red() > 128).unwrap()
    }

    #[test]
    fn each_baked_glass_has_its_panel_size() {
        let re = regex::Regex::new(r#"<filter[^>]*\swidth="([0-9.]+)" height="([0-9.]+)""#).unwrap();
        for (glass, height) in glass().iter().zip([PANEL_ONE, PANEL_TWO]) {
            let c = re.captures(glass).unwrap();
            // the filter region reaches 2 px past the panel on every side
            assert_eq!(c[1].parse::<f32>().unwrap().round(), PANEL_W + 4.0);
            assert_eq!(c[2].parse::<f32>().unwrap().round(), height + 4.0);
        }
    }

    #[test]
    fn the_glass_bends_the_photo_at_its_rim_only() {
        let middle = H - PANEL_BOTTOM as u32 - PANEL_ONE as u32 / 2;
        // the flat middle of the panel shows the photo where it is (an
        // uncorrected resvg moves all of it by about 28 px)
        let centre = over_an_edge(600);
        assert_eq!(turns_light(&centre, 200, 0), 600);
        let at = turns_light(&centre, middle, 0);
        assert!(at.abs_diff(600) <= 1, "middle of the panel: edge at {at}");
        // near the rim the glass refracts: the edge moves
        let rim = over_an_edge(60);
        let at = turns_light(&rim, middle, 41);
        eprintln!("rim: edge at {at}");
        assert!(at.abs_diff(60) >= 8, "rim: edge at {at}");
    }

    #[test]
    fn titles_take_one_or_two_lines_and_end_in_an_ellipsis() {
        let short = set("Lake Weekend", TITLE, TITLE_SIZE, TITLE_MIN, COLUMN, 2);
        assert_eq!((short.size, short.lines.len()), (TITLE_SIZE, 1));
        let long = set(&"Summer with friends at the lake ".repeat(6), TITLE, TITLE_SIZE, TITLE_MIN, COLUMN, 2);
        assert_eq!((long.size, long.lines.len()), (TITLE_MIN, 2));
        assert!(long.lines[1].ends_with('…'));
        for line in &long.lines {
            assert!(TITLE.width(line, long.size) <= COLUMN);
        }
        // one word longer than a line is broken, not lost
        let word = set(&"x".repeat(120), TITLE, TITLE_SIZE, TITLE_MIN, 500.0, 3);
        assert!(word.lines.iter().all(|l| TITLE.width(l, word.size) <= 500.0));
    }

    #[test]
    fn titles_are_escaped_and_control_characters_dropped() {
        assert_eq!(esc("<Tom & \"Jerry\">\u{0}\u{7}"), "&lt;Tom &amp; &quot;Jerry&quot;&gt;");
        let meta = ["1 photo".to_string()];
        render(&Card { title: "a\u{1}b </text><script>", meta: &meta, photo: None }).unwrap();
    }

    /// Renders the card for the photos in $ATLAS_OG_SAMPLES into $ATLAS_OG_OUT,
    /// to look at: `cargo test -p atlas-server og_samples -- --ignored`
    #[test]
    #[ignore]
    fn og_samples() {
        let (Ok(dir), Ok(out)) = (std::env::var("ATLAS_OG_SAMPLES"), std::env::var("ATLAS_OG_OUT")) else { return };
        let titles = ["Lake Weekend", "Winter Camp in the Dolomites with Friends and Family"];
        let meta = [
            vec!["48 photos".to_string(), "Oct 1 – 3, 2026".to_string()],
            vec!["126 photos, 9 videos".to_string(), "Dec 28, 2025 – Jan 3, 2026".to_string()],
        ];
        let mut files: Vec<_> = std::fs::read_dir(&dir).unwrap().map(|e| e.unwrap().path()).collect();
        files.sort();
        for (i, path) in files.iter().enumerate() {
            let decoded = imaging::decode(path).unwrap();
            let card = Card { title: titles[i % 2], meta: &meta[i % 2], photo: Some(&decoded) };
            let t = std::time::Instant::now();
            let jpeg = render(&card).unwrap();
            eprintln!("{}: {:?}, {} KB", path.display(), t.elapsed(), jpeg.len() / 1024);
            std::fs::write(format!("{out}/og-{i}.jpg"), jpeg).unwrap();
        }
        let locked = ["Password protected".to_string()];
        let card = Card { title: titles[0], meta: &locked, photo: None };
        std::fs::write(format!("{out}/og-locked.jpg"), render(&card).unwrap()).unwrap();
    }
}

//! The files a share sends: browser-ready video (copied as it is where a
//! browser plays it, else made H.264), never with where it was taken, and
//! the originals' types and checksums for "Download all".

use std::path::Path;
use std::process::Command;
use std::time::Duration;

use anyhow::{Context, Result, bail};

use crate::jobs::{preview, video};

pub(super) fn crc32_of(path: &Path) -> Result<u32> {
    let mut file = std::fs::File::open(path)?;
    let mut hasher = crc32fast::Hasher::new();
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = std::io::Read::read(&mut file, &mut buf)?;
        if n == 0 {
            return Ok(hasher.finalize());
        }
        hasher.update(&buf[..n]);
    }
}

/// H.264 in MP4/MOV, 8 bit, at most 1080p and a sane bitrate plays in every
/// browser as it is.
pub(super) fn browser_plays(p: &video::Probe) -> bool {
    p.codec == "h264"
        && !p.pixel_format.contains("10")
        && p.coded_width.min(p.coded_height) <= 1080
        && p.bitrate.is_none_or(|b| b <= 12_000_000)
        && (p.container.contains("mp4") || p.container.contains("mov"))
}

/// The video and first audio stream as they are, in a new MP4 with no
/// metadata: no location, no camera, no Apple metadata tracks. Audio is made
/// AAC, which every browser plays and costs next to nothing.
pub(super) fn remux_clean(source: &Path, dest: &Path) -> Result<()> {
    if dest.is_file() {
        return Ok(());
    }
    std::fs::create_dir_all(dest.parent().context("no parent directory")?)?;
    let tmp = dest.with_extension("part.mp4");
    let mut ffmpeg = Command::new("ffmpeg");
    ffmpeg
        .args(["-v", "error", "-y", "-i"])
        .arg(source)
        .args([
            "-map", "0:v:0", "-map", "0:a:0?", "-c:v", "copy", "-c:a", "aac", "-b:a", "160k",
            "-ac", "2",
        ])
        .args([
            "-map_metadata",
            "-1",
            "-map_chapters",
            "-1",
            "-movflags",
            "+faststart",
        ]);
    match video::ffmpeg_into(&mut ffmpeg, &tmp, Duration::from_secs(3600))? {
        Ok(()) => Ok(std::fs::rename(&tmp, dest)?),
        Err(last) => bail!("ffmpeg could not copy the video: {last}"),
    }
}

/// A 1080p H.264 rendition for browsers, which mostly cannot play HEVC. GPU
/// first, then software, as for the app's own previews.
pub(super) fn transcode_h264(source: &Path, dest: &Path) -> Result<()> {
    if dest.is_file() {
        return Ok(());
    }
    let probe = video::probe(source)?;
    let (w, h) = preview::target_size(&probe);
    let nvenc = [
        "-c:v",
        "h264_nvenc",
        "-preset",
        "p5",
        "-rc",
        "vbr",
        "-cq",
        "24",
        "-b:v",
        "0",
        "-maxrate",
        "8M",
        "-bufsize",
        "16M",
    ];
    let gpu_scale = format!("scale_cuda={w}:{h}:format=nv12");
    let cpu_scale = format!("scale={w}:{h}:flags=bicubic,format=yuv420p");
    let attempts: [(&[&str], &str, &[&str]); 3] = [
        (
            &["-hwaccel", "cuda", "-hwaccel_output_format", "cuda"],
            &gpu_scale,
            &nvenc,
        ),
        (&[], &cpu_scale, &nvenc),
        (
            &[],
            &cpu_scale,
            &["-c:v", "libx264", "-preset", "veryfast", "-crf", "23"],
        ),
    ];
    // no location or camera data in what leaves the house
    let output = [
        "-profile:v",
        "high",
        "-c:a",
        "aac",
        "-b:a",
        "160k",
        "-ac",
        "2",
        "-map_metadata",
        "-1",
        "-movflags",
        "+faststart",
    ];
    preview::encode(source, dest, &attempts, &output)
}

pub(super) fn mime_of(name: &str) -> &'static str {
    match name
        .rsplit('.')
        .next()
        .map(str::to_ascii_lowercase)
        .as_deref()
    {
        Some("jpg" | "jpeg") => "image/jpeg",
        Some("png") => "image/png",
        Some("heic" | "heif") => "image/heic",
        Some("webp") => "image/webp",
        Some("gif") => "image/gif",
        Some("dng") => "image/x-adobe-dng",
        Some("mov") => "video/quicktime",
        Some("mp4" | "m4v") => "video/mp4",
        _ => "application/octet-stream",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::util;

    #[test]
    fn browsers_get_h264_up_to_1080p_as_is() {
        let p = |codec: &str, w, h, pix: &str| video::Probe {
            codec: codec.into(),
            coded_width: w,
            coded_height: h,
            pixel_format: pix.into(),
            bitrate: Some(8_000_000),
            container: "mov,mp4,m4a,3gp,3g2,mj2".into(),
            ..video::Probe::default()
        };
        assert!(browser_plays(&p("h264", 1920, 1080, "yuv420p")));
        assert!(!browser_plays(&p("hevc", 1920, 1080, "yuv420p")));
        assert!(!browser_plays(&p("h264", 3840, 2160, "yuv420p")));
        assert!(!browser_plays(&p("h264", 1920, 1080, "yuv420p10le")));
    }

    #[test]
    fn shared_videos_lose_where_they_were_taken() {
        let ffmpeg = |args: &[&str]| std::process::Command::new("ffmpeg").args(args).output();
        if ffmpeg(&["-version"]).is_err() {
            eprintln!("no ffmpeg here, skipped");
            return;
        }
        let dir = std::env::temp_dir().join(util::temp_name("share-remux"));
        std::fs::create_dir_all(&dir).unwrap();
        let (src, out) = (dir.join("in.mov"), dir.join("out.mp4"));
        let made = ffmpeg(&[
            "-v",
            "error",
            "-f",
            "lavfi",
            "-i",
            "testsrc=size=320x240:rate=10:duration=1",
            "-c:v",
            "libx264",
            "-metadata",
            "location=+45.1234+015.6789/",
            "-metadata",
            "com.apple.quicktime.make=Apple",
            "-movflags",
            "use_metadata_tags",
            src.to_str().unwrap(),
        ])
        .unwrap();
        if !made.status.success() {
            eprintln!("this ffmpeg cannot make the sample, skipped");
            return;
        }
        let tags = |p: &Path| {
            let o = std::process::Command::new("ffprobe")
                .args(["-v", "error", "-show_entries", "format_tags", "-of", "json"])
                .arg(p)
                .output()
                .unwrap();
            String::from_utf8_lossy(&o.stdout).into_owned()
        };
        assert!(
            tags(&src).contains("+45.1234"),
            "the sample carries a location"
        );
        remux_clean(&src, &out).unwrap();
        let after = tags(&out);
        assert!(
            !after.contains("45.1234") && !after.contains("Apple"),
            "{after}"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn original_types() {
        assert_eq!(mime_of("IMG_1.HEIC"), "image/heic");
        assert_eq!(mime_of("clip.mov"), "video/quicktime");
        assert_eq!(mime_of("noext"), "application/octet-stream");
    }
}

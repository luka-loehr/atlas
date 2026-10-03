//! Bulk imports from Google Takeout archives, read in place: nothing is
//! unpacked to disk except the originals themselves.

pub mod drive;
pub mod photos;

use std::fs::File;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

use anyhow::Result;
use sha2::{Digest, Sha256};

/// Stream one archive entry into `dir` under a temporary name, hashing on the
/// way. Returns the temp path, the SHA-256 and the byte count.
fn extract_hashed(entry: &mut impl Read, dir: &Path) -> Result<(PathBuf, String, u64)> {
    std::fs::create_dir_all(dir)?;
    let tmp = dir.join(crate::util::temp_name("import"));
    let mut out = File::create(&tmp)?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 1 << 20];
    let mut size = 0u64;
    loop {
        let n = entry.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
        out.write_all(&buf[..n])?;
        size += n as u64;
    }
    out.sync_all()?;
    Ok((tmp, crate::util::hex(&hasher.finalize()), size))
}

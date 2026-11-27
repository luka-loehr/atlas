//! Cryptographic helpers: hashing, constant-time comparison, AEAD secret
//! sealing for S3 secret keys at rest, and CSPRNG credential generation.

use anyhow::{Result, anyhow, bail};
use base64::Engine;
use md5::Md5;
use ring::aead::{AES_256_GCM, Aad, LessSafeKey, Nonce, UnboundKey};
use ring::hkdf::{HKDF_SHA256, KeyType, Salt};
use ring::hmac;
use ring::rand::{SecureRandom, SystemRandom};
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;

const HEX: &[u8; 16] = b"0123456789abcdef";
const KEY_ID_ALPHABET: &[u8; 32] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const SEAL_SALT: &[u8] = b"atlas-s3-key-seal-v1";
const SEAL_INFO: &[&[u8]] = &[b"atlas-aes-256-gcm-v1"];
const NONCE_LEN: usize = 12;

pub fn hex_encode(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for &b in bytes {
        out.push(HEX[(b >> 4) as usize] as char);
        out.push(HEX[(b & 0x0f) as usize] as char);
    }
    out
}

pub fn hex_decode(s: &str) -> Option<Vec<u8>> {
    if !s.len().is_multiple_of(2) {
        return None;
    }
    let mut out = Vec::with_capacity(s.len() / 2);
    for pair in s.as_bytes().as_chunks::<2>().0 {
        let hi = (pair[0] as char).to_digit(16)?;
        let lo = (pair[1] as char).to_digit(16)?;
        out.push(((hi << 4) | lo) as u8);
    }
    Some(out)
}

pub fn sha256_bytes(data: &[u8]) -> [u8; 32] {
    Sha256::digest(data).into()
}

pub fn sha256_hex(data: &[u8]) -> String {
    hex_encode(&sha256_bytes(data))
}

pub fn md5_bytes(data: &[u8]) -> [u8; 16] {
    Md5::digest(data).into()
}

pub fn md5_hex(data: &[u8]) -> String {
    hex_encode(&md5_bytes(data))
}

pub fn hmac_sha256(key: &[u8], data: &[u8]) -> [u8; 32] {
    let signing_key = hmac::Key::new(hmac::HMAC_SHA256, key);
    let tag = hmac::sign(&signing_key, data);
    let mut out = [0u8; 32];
    out.copy_from_slice(tag.as_ref());
    out
}

/// Constant-time slice comparison across both length and bytes.
pub fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && bool::from(a.ct_eq(b))
}

struct Key256;
impl KeyType for Key256 {
    fn len(&self) -> usize {
        32
    }
}

fn derive_seal_key(master_secret: &str) -> Result<LessSafeKey> {
    if master_secret.len() < 16 {
        bail!("master secret must be at least 16 bytes");
    }
    let salt = Salt::new(HKDF_SHA256, SEAL_SALT);
    let prk = salt.extract(master_secret.as_bytes());
    let okm = prk
        .expand(SEAL_INFO, Key256)
        .map_err(|_| anyhow!("hkdf expand failed"))?;
    let mut key_bytes = [0u8; 32];
    okm.fill(&mut key_bytes)
        .map_err(|_| anyhow!("hkdf fill failed"))?;
    let unbound =
        UnboundKey::new(&AES_256_GCM, &key_bytes).map_err(|_| anyhow!("invalid aead key"))?;
    Ok(LessSafeKey::new(unbound))
}

/// Encrypts a secret with AES-256-GCM bound to `aad` (e.g. `access_key_id`),
/// returning `nonce (12B) || ciphertext || tag (16B)`.
pub fn seal_secret(master_secret: &str, aad: &[u8], plaintext: &[u8]) -> Result<Vec<u8>> {
    let key = derive_seal_key(master_secret)?;
    let rng = SystemRandom::new();
    let mut nonce_bytes = [0u8; NONCE_LEN];
    rng.fill(&mut nonce_bytes)
        .map_err(|_| anyhow!("csprng failure"))?;
    let nonce = Nonce::assume_unique_for_key(nonce_bytes);

    let mut in_out = plaintext.to_vec();
    key.seal_in_place_append_tag(nonce, Aad::from(aad), &mut in_out)
        .map_err(|_| anyhow!("aead seal failure"))?;

    let mut out = Vec::with_capacity(NONCE_LEN + in_out.len());
    out.extend_from_slice(&nonce_bytes);
    out.extend_from_slice(&in_out);
    Ok(out)
}

/// Decrypts a secret previously sealed by [`seal_secret`], verifying `aad`.
pub fn open_secret(master_secret: &str, aad: &[u8], sealed: &[u8]) -> Result<Vec<u8>> {
    if sealed.len() < NONCE_LEN + AES_256_GCM.tag_len() {
        bail!("sealed secret truncated");
    }
    let key = derive_seal_key(master_secret)?;
    let mut nonce_bytes = [0u8; NONCE_LEN];
    nonce_bytes.copy_from_slice(&sealed[..NONCE_LEN]);
    let nonce = Nonce::assume_unique_for_key(nonce_bytes);

    let mut buf = sealed[NONCE_LEN..].to_vec();
    let plain = key
        .open_in_place(nonce, Aad::from(aad), &mut buf)
        .map_err(|_| anyhow!("aead open failed (wrong master key or tampered row)"))?;
    Ok(plain.to_vec())
}

/// Generates a 24-character S3-compatible Access Key ID (`ATLK` + 20 Crockford/unambiguous chars).
pub fn generate_access_key_id() -> Result<String> {
    let rng = SystemRandom::new();
    let mut raw = [0u8; 20];
    rng.fill(&mut raw).map_err(|_| anyhow!("csprng failure"))?;
    let mut out = String::with_capacity(24);
    out.push_str("ATLK");
    for b in raw {
        out.push(KEY_ID_ALPHABET[(b & 0x1f) as usize] as char);
    }
    Ok(out)
}

/// Generates a 256-bit CSPRNG secret key (`atls_` + 43 URL-safe base64 chars).
pub fn generate_secret_key() -> Result<String> {
    let rng = SystemRandom::new();
    let mut raw = [0u8; 32];
    rng.fill(&mut raw).map_err(|_| anyhow!("csprng failure"))?;
    Ok(format!(
        "atls_{}",
        base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(raw)
    ))
}

/// Generates a random hex identifier with the given prefix (e.g. `acct_...`, `mpu_...`).
pub fn generate_prefixed_id(prefix: &str, random_bytes: usize) -> Result<String> {
    let rng = SystemRandom::new();
    let mut raw = vec![0u8; random_bytes];
    rng.fill(&mut raw).map_err(|_| anyhow!("csprng failure"))?;
    Ok(format!("{prefix}_{}", hex_encode(&raw)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn seal_and_open_roundtrip_and_bind_aad() {
        let master = "0123456789abcdef0123456789abcdef";
        let secret = b"atls_super_secret_key_material";
        let sealed = seal_secret(master, b"ATLK23456789ABCDEFGHJKLM", secret).unwrap();
        assert_ne!(&sealed[12..], secret);
        let opened = open_secret(master, b"ATLK23456789ABCDEFGHJKLM", &sealed).unwrap();
        assert_eq!(opened, secret);

        // Swapping AAD (another access key id) must fail authentication
        assert!(open_secret(master, b"ATLK99999999999999999999", &sealed).is_err());
        // Wrong master secret must fail authentication
        assert!(
            open_secret(
                "fedcba9876543210fedcba9876543210",
                b"ATLK23456789ABCDEFGHJKLM",
                &sealed
            )
            .is_err()
        );
    }

    #[test]
    fn generated_keys_have_expected_shape() {
        let ak = generate_access_key_id().unwrap();
        let sk = generate_secret_key().unwrap();
        assert_eq!(ak.len(), 24);
        assert!(ak.starts_with("ATLK"));
        assert!(sk.starts_with("atls_"));
        assert!(sk.len() >= 48);
    }

    #[test]
    fn hashes_match_standard_vectors() {
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert_eq!(md5_hex(b"abc"), "900150983cd24fb0d6963f7d28e17f72");
    }
}

//! Pure-Rust primitives shared by `atlas-server`, `atlas-core`, and `atlas-cli`:
//!
//! - [`crypto`]: SHA-256, MD5 (for S3 multipart ETags), HMAC-SHA256, HKDF-SHA256,
//!   AES-256-GCM secret sealing, constant-time equality, and key generation.
//! - [`validate`]: S3 bucket name rules, canonical object key normalization,
//!   content-ID checks, and RFC 3986 percent-encoding.
//! - [`s3`]: AWS Signature V4 header signing/verification, presigned URL
//!   generation/verification, and `aws-chunked` payload decoding.
//! - [`models`]: Strongly-typed REST/JSON wire contracts shared by the server,
//!   OpenAPI 3.1 generator, and CLI.

pub mod crypto;
pub mod models;
pub mod s3;
pub mod validate;

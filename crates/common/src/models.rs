//! Strongly-typed JSON wire models shared across `atlas-server`, OpenAPI 3.1,
//! and `atlas-cli`.

use std::collections::BTreeMap;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AccountRole {
    Owner,
    Admin,
    Member,
    Service,
}

impl AccountRole {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Owner => "owner",
            Self::Admin => "admin",
            Self::Member => "member",
            Self::Service => "service",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "owner" => Some(Self::Owner),
            "admin" => Some(Self::Admin),
            "member" => Some(Self::Member),
            "service" => Some(Self::Service),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AccountStatus {
    Active,
    Suspended,
}

impl AccountStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Active => "active",
            Self::Suspended => "suspended",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "active" => Some(Self::Active),
            "suspended" => Some(Self::Suspended),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AccountInfo {
    pub id: String,
    pub name: String,
    pub display_name: Option<String>,
    pub role: AccountRole,
    pub status: AccountStatus,
    pub rate_limit_rps: Option<i32>,
    pub rate_limit_burst: Option<i32>,
    pub quota_bytes: Option<i64>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateAccountRequest {
    pub name: String,
    #[serde(default)]
    pub display_name: Option<String>,
    #[serde(default = "default_service_role")]
    pub role: AccountRole,
    #[serde(default)]
    pub rate_limit_rps: Option<i32>,
    #[serde(default)]
    pub rate_limit_burst: Option<i32>,
    #[serde(default)]
    pub quota_bytes: Option<i64>,
}

fn default_service_role() -> AccountRole {
    AccountRole::Service
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct UpdateAccountRequest {
    pub display_name: Option<String>,
    pub role: Option<AccountRole>,
    pub status: Option<AccountStatus>,
    pub rate_limit_rps: Option<i32>,
    pub rate_limit_burst: Option<i32>,
    pub quota_bytes: Option<i64>,
}

/// Valid permission scopes on an API/S3 key.
pub const VALID_SCOPES: &[&str] = &["read", "write", "delete", "media:search", "admin"];

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ApiKeyInfo {
    pub id: String,
    pub access_key_id: String,
    pub name: String,
    pub account_id: String,
    pub scopes: Vec<String>,
    /// Empty or `["*"]` means access to all buckets permitted by scopes; otherwise explicit bucket names.
    pub buckets: Vec<String>,
    pub rate_limit_rps: Option<i32>,
    pub rate_limit_burst: Option<i32>,
    pub expires_at: Option<DateTime<Utc>>,
    pub revoked_at: Option<DateTime<Utc>>,
    pub last_used_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateKeyRequest {
    pub name: String,
    #[serde(default)]
    pub account_id: Option<String>,
    #[serde(default = "default_rw_scopes")]
    pub scopes: Vec<String>,
    #[serde(default)]
    pub buckets: Vec<String>,
    #[serde(default)]
    pub rate_limit_rps: Option<i32>,
    #[serde(default)]
    pub rate_limit_burst: Option<i32>,
    /// Optional lifetime in seconds from creation.
    #[serde(default)]
    pub expires_in_secs: Option<i64>,
}

fn default_rw_scopes() -> Vec<String> {
    vec![
        "read".into(),
        "write".into(),
        "delete".into(),
        "media:search".into(),
    ]
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateKeyResponse {
    pub key: ApiKeyInfo,
    /// Returned ONCE at creation time. Works both as S3 Secret Access Key (SigV4)
    /// and with `Authorization: Bearer <access_key_id>:<secret_access_key>`.
    pub secret_access_key: String,
    /// Ready-to-use `Authorization: Bearer ...` token (`<access_key_id>:<secret_access_key>`).
    pub bearer_token: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BucketKind {
    Media,
    Files,
    General,
}

impl BucketKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Media => "media",
            Self::Files => "files",
            Self::General => "general",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "media" => Some(Self::Media),
            "files" => Some(Self::Files),
            "general" => Some(Self::General),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BucketInfo {
    pub name: String,
    pub kind: BucketKind,
    pub owner_account_id: String,
    pub object_count: i64,
    pub total_bytes: i64,
    pub quota_bytes: Option<i64>,
    pub public_read: bool,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateBucketRequest {
    pub name: String,
    #[serde(default = "default_general_kind")]
    pub kind: BucketKind,
    #[serde(default)]
    pub quota_bytes: Option<i64>,
}

fn default_general_kind() -> BucketKind {
    BucketKind::General
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ObjectInfo {
    pub bucket: String,
    pub key: String,
    pub size: i64,
    pub etag: String,
    pub sha256: String,
    pub content_type: String,
    pub metadata: BTreeMap<String, String>,
    pub asset_id: Option<String>,
    pub drive_file_id: Option<i64>,
    pub snippet: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ListObjectsResponse {
    pub bucket: String,
    pub prefix: String,
    pub delimiter: Option<String>,
    pub common_prefixes: Vec<String>,
    pub objects: Vec<ObjectInfo>,
    pub is_truncated: bool,
    pub next_cursor: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PutObjectResponse {
    pub bucket: String,
    pub key: String,
    pub size: i64,
    pub etag: String,
    pub sha256: String,
    pub content_type: String,
    pub asset_id: Option<String>,
    pub drive_file_id: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CopyObjectRequest {
    pub src_bucket: String,
    pub src_key: String,
    pub dst_key: String,
    #[serde(default)]
    pub metadata: Option<BTreeMap<String, String>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BatchDeleteRequest {
    pub keys: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BatchDeleteResponse {
    pub deleted: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PresignRequest {
    pub key: String,
    #[serde(default = "default_get_method")]
    pub method: String,
    #[serde(default = "default_presign_ttl")]
    pub expires_in_secs: u64,
}

fn default_get_method() -> String {
    "GET".into()
}

fn default_presign_ttl() -> u64 {
    3600
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PresignResponse {
    pub url: String,
    pub method: String,
    pub bucket: String,
    pub key: String,
    pub expires_in_secs: u64,
    pub expires_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaUrls {
    pub original: String,
    pub thumb_512: String,
    pub thumb_2048: String,
    pub tile: String,
    pub s3: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaPersonRef {
    pub id: i64,
    pub name: Option<String>,
    pub kind: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaSearchItem {
    pub id: String,
    pub bucket: String,
    pub key: String,
    pub media_type: String,
    pub taken_at: Option<DateTime<Utc>>,
    pub width: Option<i32>,
    pub height: Option<i32>,
    pub duration_s: Option<f64>,
    pub size_bytes: Option<i64>,
    pub favorite: bool,
    pub camera: Option<String>,
    pub place: Option<String>,
    pub people: Vec<MediaPersonRef>,
    pub ocr_text: Option<String>,
    pub score: Option<f32>,
    pub urls: MediaUrls,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaSearchResponse {
    pub query: String,
    pub semantic: String,
    pub total: usize,
    pub items: Vec<MediaSearchItem>,
}

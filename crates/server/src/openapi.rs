//! Canonical OpenAPI 3.1 specification generator for the entire Atlas API
//! (`/health`, `/openapi.json`, `/v1/*`, and `/s3/*`).
//!
//! `atlas-server openapi` writes this specification to `openapi/openapi.json`,
//! and `GET /openapi.json` (plus `GET /v1/openapi.json`) serves it live.
//! Automated contract tests verify byte-for-byte parity with `openapi/openapi.json`
//! and complete coverage of every registered server route.

use axum::Json;
use serde_json::{Value, json};

/// Canonical list of `(path, &[methods])` registered in [`crate::build_router`].
/// Enforced by integration contract tests so router changes can never drift from OpenAPI.
pub const REGISTERED_OPERATIONS: &[(&str, &[&str])] = &[
    ("/health", &["get"]),
    ("/openapi.json", &["get"]),
    ("/v1/openapi.json", &["get"]),
    // Auth & IAM
    ("/v1/auth/whoami", &["get"]),
    ("/v1/accounts", &["get", "post"]),
    ("/v1/accounts/{id}", &["get", "patch", "delete"]),
    ("/v1/keys", &["get", "post"]),
    ("/v1/keys/{id}", &["get", "delete"]),
    ("/v1/keys/{id}/revoke", &["post"]),
    // Unified Buckets & Native Object Storage
    ("/v1/buckets", &["get", "post"]),
    ("/v1/buckets/{bucket}", &["get", "delete"]),
    ("/v1/buckets/{bucket}/objects", &["get"]),
    (
        "/v1/buckets/{bucket}/objects/{key}",
        &["get", "put", "head", "delete"],
    ),
    ("/v1/buckets/{bucket}/stat/{key}", &["get"]),
    ("/v1/buckets/{bucket}/copy", &["post"]),
    ("/v1/buckets/{bucket}/delete", &["post"]),
    ("/v1/buckets/{bucket}/presign", &["post"]),
    // S3-Compatible Wire Protocol
    ("/s3", &["get"]),
    ("/s3/{bucket}", &["get", "put", "delete", "head", "post"]),
    (
        "/s3/{bucket}/{key}",
        &["get", "put", "head", "post", "delete"],
    ),
    // Structured Developer Media & AI Search
    ("/v1/media/search", &["get"]),
    ("/v1/media/similar/{id}", &["get"]),
    ("/v1/media/assets/{id}", &["get"]),
    // Photo Library, Timeline, People, Places & Search
    ("/v1/server", &["get"]),
    ("/v1/work", &["get"]),
    ("/v1/stats", &["get"]),
    ("/v1/heatmap", &["get"]),
    ("/v1/timeline", &["get"]),
    ("/v1/timeline/{bucket}", &["get"]),
    ("/v1/assets", &["put"]),
    ("/v1/assets/exists", &["post"]),
    ("/v1/assets/favorite", &["post"]),
    ("/v1/assets/archive", &["post"]),
    ("/v1/assets/lock", &["post"]),
    ("/v1/assets/trash", &["post"]),
    ("/v1/assets/restore", &["post"]),
    ("/v1/assets/delete", &["post"]),
    ("/v1/assets/{id}", &["get"]),
    ("/v1/assets/{id}/thumb/{size}", &["get"]),
    ("/v1/assets/{id}/tile", &["get"]),
    ("/v1/assets/{id}/original", &["get"]),
    ("/v1/assets/{id}/video", &["get"]),
    ("/v1/library/trash/empty", &["post"]),
    ("/v1/library/{view}", &["get"]),
    ("/v1/albums", &["get", "post"]),
    ("/v1/albums/{id}", &["get", "patch", "delete"]),
    ("/v1/albums/{id}/assets", &["post", "delete"]),
    ("/v1/people", &["get"]),
    ("/v1/people/{id}", &["get", "patch"]),
    ("/v1/people/{id}/merge", &["post"]),
    ("/v1/faces/{id}/crop", &["get"]),
    ("/v1/faces/hide", &["post"]),
    ("/v1/faces/unassign", &["post"]),
    ("/v1/places", &["get"]),
    ("/v1/places/{id}", &["get"]),
    ("/v1/covers", &["get"]),
    ("/v1/search", &["get"]),
    ("/v1/search/warm", &["post"]),
    // Drive (hierarchical view over the `files` bucket)
    ("/v1/drive/folders", &["post"]),
    ("/v1/drive/folders/{id}", &["get", "patch", "delete"]),
    ("/v1/drive/files", &["put"]),
    ("/v1/drive/files/{id}", &["patch"]),
    ("/v1/drive/files/{id}/thumb", &["get"]),
    ("/v1/drive/blobs/{hash}/{name}", &["get"]),
    ("/v1/drive/recent", &["get"]),
    ("/v1/drive/search", &["get"]),
    ("/v1/drive/move", &["post"]),
    ("/v1/drive/trash", &["get", "post"]),
    ("/v1/drive/trash/empty", &["post"]),
    ("/v1/drive/restore", &["post"]),
    ("/v1/drive/delete", &["post"]),
    // Link Sharing
    ("/v1/shares", &["get", "post"]),
    ("/v1/shares/{id}", &["get", "delete"]),
    // System & Machine Telemetry (Owner/Admin only)
    ("/v1/system", &["get"]),
    ("/v1/system/live", &["get"]),
    ("/v1/system/services", &["get"]),
    ("/v1/system/drives", &["get"]),
    ("/v1/system/containers", &["get"]),
    ("/v1/system/containers/{name}", &["get"]),
    ("/v1/system/network", &["get"]),
    ("/v1/system/activity", &["get"]),
    ("/v1/system/terminal", &["get"]),
    ("/v1/system/power/{action}", &["post"]),
];

fn op(tag: &str, operation_id: &str, summary: &str, ok_desc: &str) -> Value {
    json!({
        "tags": [tag],
        "operationId": operation_id,
        "summary": summary,
        "responses": {
            "200": { "description": ok_desc },
            "401": { "$ref": "#/components/responses/Unauthorized" },
            "403": { "$ref": "#/components/responses/Forbidden" },
            "429": { "$ref": "#/components/responses/RateLimited" }
        }
    })
}

pub fn spec() -> Value {
    json!({
        "openapi": "3.1.0",
        "info": {
            "title": "Atlas Storage, Media & AI Search API",
            "version": env!("CARGO_PKG_VERSION"),
            "description": "Self-hosted S3-compatible object storage, photo & video library, local GPU semantic/face/pet/OCR search, and homelab system API.",
            "license": {
                "name": "MIT",
                "url": "https://opensource.org/licenses/MIT"
            }
        },
        "servers": [
            { "url": "http://127.0.0.1:8787", "description": "Local or Tailscale Atlas server" }
        ],
        "security": [
            { "BearerAuth": [] },
            { "AtlasApiKey": [] },
            { "AwsSigV4": [] }
        ],
        "tags": [
            { "name": "Health", "description": "Liveness and OpenAPI discovery" },
            { "name": "IAM", "description": "Accounts, scoped S3/API keys, revocation, and per-key rate limits" },
            { "name": "Buckets", "description": "Unified native JSON & streaming object storage API" },
            { "name": "S3", "description": "AWS S3 wire-compatible XML & streaming object storage protocol (SigV4 + Presigned URLs)" },
            { "name": "MediaSearch", "description": "Structured developer API for semantic embeddings, people, pets, places, OCR, and visual similarity" },
            { "name": "Photos", "description": "Timeline, assets, albums, people, faces, and places" },
            { "name": "Drive", "description": "Folder-tree Finder/Files interface backed by the `files` bucket" },
            { "name": "Shares", "description": "Expiring album and photo share links" },
            { "name": "System", "description": "Host telemetry, GPU/SMART metrics, containers, PTY terminal, and power" }
        ],
        "paths": {
            "/health": {
                "get": {
                    "tags": ["Health"],
                    "operationId": "healthCheck",
                    "summary": "Unauthenticated liveness probe",
                    "security": [],
                    "responses": { "200": { "description": "Server is up (`ok`)" } }
                }
            },
            "/openapi.json": {
                "get": {
                    "tags": ["Health"],
                    "operationId": "getOpenApiSpec",
                    "summary": "Canonical OpenAPI 3.1 specification",
                    "security": [],
                    "responses": { "200": { "description": "OpenAPI 3.1 JSON document" } }
                }
            },
            "/v1/openapi.json": {
                "get": {
                    "tags": ["Health"],
                    "operationId": "getOpenApiSpecV1",
                    "summary": "Authenticated alias for OpenAPI 3.1 specification",
                    "responses": { "200": { "description": "OpenAPI 3.1 JSON document" } }
                }
            },
            // IAM
            "/v1/auth/whoami": {
                "get": op("IAM", "authWhoami", "Inspect active account, key, scopes, and bucket allowlist", "Caller principal details")
            },
            "/v1/accounts": {
                "get": op("IAM", "listAccounts", "List all accounts", "Account list"),
                "post": op("IAM", "createAccount", "Create a service, member, or admin account with optional quota & rate limits", "Created account")
            },
            "/v1/accounts/{id}": {
                "get": op("IAM", "getAccount", "Get account by ID or name", "Account details"),
                "patch": op("IAM", "updateAccount", "Update account role, status, quota, or rate limits", "Updated account"),
                "delete": op("IAM", "deleteAccount", "Delete non-owner account and cascade its keys", "Deletion count")
            },
            "/v1/keys": {
                "get": op("IAM", "listKeys", "List S3/API keys (never returns secrets)", "API key list"),
                "post": op("IAM", "createKey", "Mint a new scoped S3/API keypair with optional bucket allowlist, RPS limit, and expiry", "Created key and one-time secret")
            },
            "/v1/keys/{id}": {
                "get": op("IAM", "getKey", "Inspect one key by ID or access_key_id", "Key metadata"),
                "delete": op("IAM", "deleteKey", "Permanently delete an API key", "Deletion confirmation")
            },
            "/v1/keys/{id}/revoke": {
                "post": op("IAM", "revokeKey", "Immediately revoke an S3/API key and evict it from the auth cache", "Revoked key metadata")
            },
            // Buckets & Objects
            "/v1/buckets": {
                "get": op("Buckets", "listBuckets", "List accessible buckets (`media`, `files`, and custom buckets) with totals", "Bucket list"),
                "post": op("Buckets", "createBucket", "Create a new bucket with optional byte quota", "Bucket info")
            },
            "/v1/buckets/{bucket}": {
                "get": op("Buckets", "getBucket", "Get bucket usage and metadata", "Bucket info"),
                "delete": op("Buckets", "deleteBucket", "Delete an empty non-system bucket", "Deleted status")
            },
            "/v1/buckets/{bucket}/objects": {
                "get": op("Buckets", "listBucketObjects", "List or full-text search objects in a bucket (prefix, delimiter, cursor, q)", "Paginated object listing")
            },
            "/v1/buckets/{bucket}/objects/{key}": {
                "get": op("Buckets", "getBucketObject", "Stream object bytes with HTTP Range (206) and ETag support", "Object byte stream"),
                "put": op("Buckets", "putBucketObject", "Stream upload an object (auto-ingests media in `media` and syncs drive in `files`)", "Stored object metadata"),
                "head": op("Buckets", "headBucketObject", "Fetch object headers (ETag, Content-Length, x-amz-meta-*) without body", "Object headers"),
                "delete": op("Buckets", "deleteBucketObject", "Delete a single object key", "Deleted keys")
            },
            "/v1/buckets/{bucket}/stat/{key}": {
                "get": op("Buckets", "statBucketObject", "Fetch structured JSON metadata for an object", "ObjectInfo JSON")
            },
            "/v1/buckets/{bucket}/copy": {
                "post": op("Buckets", "copyBucketObject", "Server-side zero-reupload copy within or across buckets", "Copied object metadata")
            },
            "/v1/buckets/{bucket}/delete": {
                "post": op("Buckets", "batchDeleteBucketObjects", "Batch delete up to 1,000 keys in a bucket", "Deleted key list")
            },
            "/v1/buckets/{bucket}/presign": {
                "post": op("Buckets", "presignBucketObject", "Generate an AWS SigV4 presigned URL (GET, HEAD, PUT, DELETE)", "Signed URL and expiration")
            },
            // S3 Wire Protocol
            "/s3": {
                "get": op("S3", "s3ListBuckets", "S3 ListBuckets (XML)", "ListAllMyBucketsResult XML")
            },
            "/s3/{bucket}": {
                "get": op("S3", "s3GetBucket", "S3 ListObjectsV2, ListObjects, GetBucketLocation, GetBucketVersioning, or ListMultipartUploads", "S3 XML response"),
                "put": op("S3", "s3CreateBucket", "S3 CreateBucket", "Bucket created"),
                "delete": op("S3", "s3DeleteBucket", "S3 DeleteBucket (204)", "Bucket deleted"),
                "head": op("S3", "s3HeadBucket", "S3 HeadBucket", "Bucket exists"),
                "post": op("S3", "s3DeleteObjects", "S3 batch DeleteObjects (`?delete`)", "DeleteResult XML")
            },
            "/s3/{bucket}/{key}": {
                "get": op("S3", "s3GetObject", "S3 GetObject (streaming Range 206) or ListParts (`?uploadId=`)", "Object stream or ListPartsResult XML"),
                "put": op("S3", "s3PutObject", "S3 PutObject, CopyObject (`x-amz-copy-source`), or UploadPart (`?partNumber=&uploadId=`)", "ETag header or CopyObjectResult XML"),
                "head": op("S3", "s3HeadObject", "S3 HeadObject", "Object metadata headers"),
                "post": op("S3", "s3PostObject", "S3 CreateMultipartUpload (`?uploads`) or CompleteMultipartUpload (`?uploadId=`)", "Multipart XML result"),
                "delete": op("S3", "s3DeleteObject", "S3 DeleteObject or AbortMultipartUpload (`?uploadId=`)", "204 No Content")
            },
            // Developer Media Search
            "/v1/media/search": {
                "get": op("MediaSearch", "searchMedia", "Hybrid GPU semantic embedding (`wemm2b`), face/person, pet, place, and OCR search returning structured JSON items", "MediaSearchResponse")
            },
            "/v1/media/similar/{id}": {
                "get": op("MediaSearch", "findSimilarMedia", "Exact cosine visual similarity search against the in-memory 2048-d embedding matrix", "MediaSearchResponse")
            },
            "/v1/media/assets/{id}": {
                "get": op("MediaSearch", "getMediaAsset", "Fetch structured developer metadata and S3/thumbnail URLs for one media asset", "MediaSearchItem")
            },
            // Photos & Library
            "/v1/server": { "get": op("Photos", "getServerInfo", "Server version and capability summary", "Server metadata") },
            "/v1/work": { "get": op("Photos", "getIngestWork", "Active and queued background ML/ingest job counts", "Work summary") },
            "/v1/stats": { "get": op("Photos", "getLibraryStats", "Photo, video, and storage totals", "Stats JSON") },
            "/v1/heatmap": { "get": op("Photos", "getPhotoHeatmap", "Photos taken per day over the past year", "Heatmap counts") },
            "/v1/timeline": { "get": op("Photos", "getTimelineIndex", "Monthly timeline index with counts and validators", "Timeline index") },
            "/v1/timeline/{bucket}": { "get": op("Photos", "getTimelineMonth", "Columnar asset list for a month (`YYYY-MM` or `undated`)", "Columnar assets") },
            "/v1/assets": { "put": op("Photos", "uploadAsset", "Streaming content-addressed photo/video upload (synced into `media` bucket)", "Upload result") },
            "/v1/assets/exists": { "post": op("Photos", "checkAssetsExist", "Check which SHA-256 content hashes already exist (max 10,000)", "Existing hash subset") },
            "/v1/assets/favorite": { "post": op("Photos", "setAssetsFavorite", "Mark or unmark assets as favorites", "Updated count") },
            "/v1/assets/archive": { "post": op("Photos", "setAssetsArchived", "Archive or unarchive assets", "Updated count") },
            "/v1/assets/lock": { "post": op("Photos", "setAssetsLocked", "Move assets into or out of the locked view", "Updated count") },
            "/v1/assets/trash": { "post": op("Photos", "trashAssets", "Move assets to 30-day trash", "Updated count") },
            "/v1/assets/restore": { "post": op("Photos", "restoreAssets", "Restore assets from trash/archive/locked", "Updated count") },
            "/v1/assets/delete": { "post": op("Photos", "deleteAssets", "Permanently purge assets and derived files", "Deleted count") },
            "/v1/assets/{id}": { "get": op("Photos", "getAssetInfo", "Detailed EXIF, people, place, OCR text, and album info for one asset", "Asset info") },
            "/v1/assets/{id}/thumb/{size}": { "get": op("Photos", "getAssetThumb", "Immutable WebP thumbnail (`512` or `2048`)", "WebP image") },
            "/v1/assets/{id}/tile": { "get": op("Photos", "getAssetTile", "Square JPEG grid tile", "JPEG image") },
            "/v1/assets/{id}/original": { "get": op("Photos", "getAssetOriginal", "Exact original photo/video bytes (Range-capable)", "Original media stream") },
            "/v1/assets/{id}/video": { "get": op("Photos", "getAssetVideo", "Streaming 1080p rendition when available, else original", "Video stream") },
            "/v1/library/trash/empty": { "post": op("Photos", "emptyLibraryTrash", "Permanently purge all trashed photos/videos", "Deleted count") },
            "/v1/library/{view}": { "get": op("Photos", "getLibraryView", "Browse `favorites`, `videos`, `archive`, `locked`, or `trash`", "Columnar assets") },
            "/v1/albums": {
                "get": op("Photos", "listAlbums", "List albums with cover and count", "Album list"),
                "post": op("Photos", "createAlbum", "Create an album", "Album info")
            },
            "/v1/albums/{id}": {
                "get": op("Photos", "getAlbumAssets", "Get album metadata and columnar assets", "Album payload"),
                "patch": op("Photos", "renameAlbum", "Rename an album", "Updated album"),
                "delete": op("Photos", "deleteAlbum", "Delete an album (keeps photos)", "Deleted count")
            },
            "/v1/albums/{id}/assets": {
                "post": op("Photos", "addAlbumAssets", "Add assets to an album", "Added count"),
                "delete": op("Photos", "removeAlbumAssets", "Remove assets from an album", "Removed count")
            },
            "/v1/people": { "get": op("Photos", "listPeople", "List recognized people and pets", "People & pets list") },
            "/v1/people/{id}": {
                "get": op("Photos", "getPersonAssets", "Get person/pet details and assets", "Person assets"),
                "patch": op("Photos", "updatePerson", "Name, hide/unhide, or set cover face for a person/pet", "Updated person")
            },
            "/v1/people/{id}/merge": { "post": op("Photos", "mergePerson", "Merge another face cluster into this person", "Merge result") },
            "/v1/faces/{id}/crop": { "get": op("Photos", "getFaceCrop", "WebP face/pet crop thumbnail", "WebP image") },
            "/v1/faces/hide": { "post": op("Photos", "hideFaces", "Hide stranger face clusters", "Hidden count") },
            "/v1/faces/unassign": { "post": op("Photos", "unassignFaces", "Detach misassigned faces and record person veto", "Unassigned count") },
            "/v1/places": { "get": op("Photos", "listPlaces", "List geocoded places with photo counts", "Places list") },
            "/v1/places/{id}": { "get": op("Photos", "getPlaceAssets", "Get assets taken at a place", "Place assets") },
            "/v1/covers": { "get": op("Photos", "getCategoryCovers", "Cover thumbnails for library categories", "Covers JSON") },
            "/v1/search": { "get": op("Photos", "searchLibrary", "Columnar hybrid search used by native iOS & macOS apps", "Search payload") },
            "/v1/search/warm": { "post": op("Photos", "warmSearchModel", "Preload GPU embedding model and refresh vector matrix", "Warm status") },
            // Drive
            "/v1/drive/folders": { "post": op("Drive", "createDriveFolder", "Create folder in Drive (`files` bucket)", "Folder ID and name") },
            "/v1/drive/folders/{id}": {
                "get": op("Drive", "listDriveFolder", "List breadcrumbs, subfolders, and files for `root` or folder ID", "Folder listing"),
                "patch": op("Drive", "renameDriveFolder", "Rename folder and sync `files` bucket keys", "Updated count"),
                "delete": op("Drive", "deleteDriveFolder", "Permanently delete folder subtree", "Deleted count")
            },
            "/v1/drive/files": { "put": op("Drive", "uploadDriveFile", "Streaming Drive file upload (synced to `files` bucket)", "Uploaded file ID and hash") },
            "/v1/drive/files/{id}": { "patch": op("Drive", "renameDriveFile", "Rename Drive file and sync `files` bucket key", "Updated count") },
            "/v1/drive/files/{id}/thumb": { "get": op("Drive", "getDriveFileThumb", "512px WebP preview of image or PDF first page", "WebP preview") },
            "/v1/drive/blobs/{hash}/{name}": { "get": op("Drive", "getDriveBlob", "Content-addressed Range-capable file download with safe Content-Disposition", "File bytes") },
            "/v1/drive/recent": { "get": op("Drive", "getRecentDriveFiles", "40 most recently modified files", "File list") },
            "/v1/drive/search": { "get": op("Drive", "searchDrive", "Search Drive folders, filenames, and extracted PDF/Office text", "Matching files with context snippets") },
            "/v1/drive/move": { "post": op("Drive", "moveDriveItems", "Move files and folders (preventing cycles) and sync `files` bucket keys", "Moved count") },
            "/v1/drive/trash": {
                "get": op("Drive", "listDriveTrash", "List trashed Drive files", "Trashed files"),
                "post": op("Drive", "trashDriveFiles", "Move Drive files to trash", "Updated count")
            },
            "/v1/drive/trash/empty": { "post": op("Drive", "emptyDriveTrash", "Permanently purge all trashed Drive files", "Deleted count") },
            "/v1/drive/restore": { "post": op("Drive", "restoreDriveFiles", "Restore trashed Drive files", "Updated count") },
            "/v1/drive/delete": { "post": op("Drive", "deleteDriveFiles", "Permanently delete specified Drive files", "Deleted count") },
            // Shares
            "/v1/shares": {
                "get": op("Shares", "listShares", "List active expiring share links", "Share list"),
                "post": op("Shares", "createShare", "Create an expiring share link via atlas-share Worker", "Created share")
            },
            "/v1/shares/{id}": {
                "get": op("Shares", "getShare", "Get share upload progress and status", "Share details"),
                "delete": op("Shares", "deleteShare", "Revoke share link and delete remote R2 objects", "Deleted status")
            },
            // System
            "/v1/system": { "get": op("System", "getSystemSnapshot", "CPU, RAM, GPU, disk, network, and power snapshot", "System snapshot") },
            "/v1/system/live": { "get": op("System", "streamSystemLive", "WebSocket 2 Hz live telemetry stream (Origin-verified)", "WebSocket upgrade") },
            "/v1/system/services": { "get": op("System", "getSystemServices", "Systemd unit health, Postgres size, ML health, and queue counts", "Service health") },
            "/v1/system/drives": { "get": op("System", "getSystemDrives", "Physical disks, mounts, and SMART health", "Drive list") },
            "/v1/system/containers": { "get": op("System", "listSystemContainers", "Docker containers running on host", "Container list") },
            "/v1/system/containers/{name}": { "get": op("System", "getSystemContainer", "Inspect container state and recent logs", "Container details") },
            "/v1/system/network": { "get": op("System", "getSystemNetwork", "Tailscale node and peer status", "Network status") },
            "/v1/system/activity": { "get": op("System", "getSystemActivity", "154-day uptime, boot, and git commit heatmap", "Activity history") },
            "/v1/system/terminal": { "get": op("System", "openSystemTerminal", "Owner/Admin PTY login shell over WebSocket (Origin-verified, header auth only)", "WebSocket upgrade") },
            "/v1/system/power/{action}": { "post": op("System", "systemPowerAction", "Shutdown or restart the server (`shutdown` | `restart`)", "Action scheduled") }
        },
        "components": {
            "securitySchemes": {
                "BearerAuth": {
                    "type": "http",
                    "scheme": "bearer",
                    "description": "Master `ATLAS_TOKEN` or scoped API key `ATLK...:atls_...`"
                },
                "AtlasApiKey": {
                    "type": "apiKey",
                    "in": "header",
                    "name": "X-Atlas-Key",
                    "description": "Scoped API key `ATLK...:atls_...`"
                },
                "AwsSigV4": {
                    "type": "apiKey",
                    "in": "header",
                    "name": "Authorization",
                    "description": "AWS Signature Version 4 (`AWS4-HMAC-SHA256 Credential=ATLK...`)"
                }
            },
            "responses": {
                "Unauthorized": {
                    "description": "Missing, expired, revoked, or invalid credentials",
                    "content": { "application/json": { "schema": { "$ref": "#/components/schemas/ApiError" } } }
                },
                "Forbidden": {
                    "description": "Credentials valid, but missing required scope or bucket permission",
                    "content": { "application/json": { "schema": { "$ref": "#/components/schemas/ApiError" } } }
                },
                "RateLimited": {
                    "description": "Per-key or per-account token bucket exhausted (`Retry-After` header included)",
                    "content": { "application/json": { "schema": { "$ref": "#/components/schemas/ApiError" } } }
                }
            },
            "schemas": {
                "ApiError": {
                    "type": "object",
                    "required": ["error"],
                    "properties": { "error": { "type": "string" } }
                },
                "AccountInfo": {
                    "type": "object",
                    "required": ["id", "name", "role", "status", "created_at", "updated_at"],
                    "properties": {
                        "id": { "type": "string" },
                        "name": { "type": "string" },
                        "display_name": { "type": ["string", "null"] },
                        "role": { "type": "string", "enum": ["owner", "admin", "member", "service"] },
                        "status": { "type": "string", "enum": ["active", "suspended"] },
                        "rate_limit_rps": { "type": ["integer", "null"] },
                        "rate_limit_burst": { "type": ["integer", "null"] },
                        "quota_bytes": { "type": ["integer", "null"] },
                        "created_at": { "type": "string", "format": "date-time" },
                        "updated_at": { "type": "string", "format": "date-time" }
                    }
                },
                "ApiKeyInfo": {
                    "type": "object",
                    "required": ["id", "access_key_id", "name", "account_id", "scopes", "buckets", "created_at"],
                    "properties": {
                        "id": { "type": "string" },
                        "access_key_id": { "type": "string" },
                        "name": { "type": "string" },
                        "account_id": { "type": "string" },
                        "scopes": { "type": "array", "items": { "type": "string" } },
                        "buckets": { "type": "array", "items": { "type": "string" } },
                        "rate_limit_rps": { "type": ["integer", "null"] },
                        "rate_limit_burst": { "type": ["integer", "null"] },
                        "expires_at": { "type": ["string", "null"], "format": "date-time" },
                        "revoked_at": { "type": ["string", "null"], "format": "date-time" },
                        "last_used_at": { "type": ["string", "null"], "format": "date-time" },
                        "created_at": { "type": "string", "format": "date-time" }
                    }
                },
                "CreateKeyResponse": {
                    "type": "object",
                    "required": ["key", "secret_access_key", "bearer_token"],
                    "properties": {
                        "key": { "$ref": "#/components/schemas/ApiKeyInfo" },
                        "secret_access_key": { "type": "string" },
                        "bearer_token": { "type": "string" }
                    }
                },
                "BucketInfo": {
                    "type": "object",
                    "required": ["name", "kind", "owner_account_id", "object_count", "total_bytes", "public_read", "created_at"],
                    "properties": {
                        "name": { "type": "string" },
                        "kind": { "type": "string", "enum": ["media", "files", "general"] },
                        "owner_account_id": { "type": "string" },
                        "object_count": { "type": "integer" },
                        "total_bytes": { "type": "integer" },
                        "quota_bytes": { "type": ["integer", "null"] },
                        "public_read": { "type": "boolean" },
                        "created_at": { "type": "string", "format": "date-time" }
                    }
                },
                "ObjectInfo": {
                    "type": "object",
                    "required": ["bucket", "key", "size", "etag", "sha256", "content_type", "metadata", "created_at", "updated_at"],
                    "properties": {
                        "bucket": { "type": "string" },
                        "key": { "type": "string" },
                        "size": { "type": "integer" },
                        "etag": { "type": "string" },
                        "sha256": { "type": "string" },
                        "content_type": { "type": "string" },
                        "metadata": { "type": "object", "additionalProperties": { "type": "string" } },
                        "asset_id": { "type": ["string", "null"] },
                        "drive_file_id": { "type": ["integer", "null"] },
                        "snippet": { "type": ["string", "null"] },
                        "created_at": { "type": "string", "format": "date-time" },
                        "updated_at": { "type": "string", "format": "date-time" }
                    }
                },
                "MediaSearchItem": {
                    "type": "object",
                    "required": ["id", "bucket", "key", "media_type", "favorite", "people", "urls"],
                    "properties": {
                        "id": { "type": "string" },
                        "bucket": { "type": "string" },
                        "key": { "type": "string" },
                        "media_type": { "type": "string", "enum": ["photo", "video"] },
                        "taken_at": { "type": ["string", "null"], "format": "date-time" },
                        "width": { "type": ["integer", "null"] },
                        "height": { "type": ["integer", "null"] },
                        "duration_s": { "type": ["number", "null"] },
                        "size_bytes": { "type": ["integer", "null"] },
                        "favorite": { "type": "boolean" },
                        "camera": { "type": ["string", "null"] },
                        "place": { "type": ["string", "null"] },
                        "people": { "type": "array", "items": { "type": "object" } },
                        "ocr_text": { "type": ["string", "null"] },
                        "score": { "type": ["number", "null"] },
                        "urls": { "type": "object" }
                    }
                }
            }
        }
    })
}

pub async fn serve_openapi() -> Json<Value> {
    Json(spec())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_registered_operation_exists_in_openapi_spec() {
        let doc = spec();
        assert_eq!(doc["openapi"], "3.1.0");
        let paths = doc["paths"].as_object().expect("paths object");
        for (path, methods) in REGISTERED_OPERATIONS {
            let item = paths
                .get(*path)
                .unwrap_or_else(|| panic!("missing OpenAPI path: {path}"));
            for method in *methods {
                assert!(
                    item.get(*method).is_some(),
                    "missing OpenAPI method {method} on {path}"
                );
            }
        }
        assert_eq!(
            paths.len(),
            REGISTERED_OPERATIONS.len(),
            "OpenAPI paths count must match REGISTERED_OPERATIONS"
        );
    }
}

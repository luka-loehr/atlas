# Track: Architecture (`luka-loehr/atlas`)

Reviews trust boundaries, privilege separation, and component isolation across:

- `crates/server`: Axum HTTP/WebSocket API, S3/IAM compatibility layer, system/host management (`/v1/system/*`), terminal WebSocket, container/power endpoints, Drive & Photos routes.
- `crates/common`: Shared models, validation, S3 helpers, and secret sealing.
- `crates/core`: PostgreSQL + pgvector access, job queue, media decoding/video processing.
- `crates/ml`: GPU ML worker (embeddings, faces, OCR, animal/vision classification).
- `share/`: Cloudflare Share Worker (public share pages, R2/bucket proxy, admin API).
- `crates/cli`: Operator CLI (`atlas`) with SSH, deploy, secrets, and share commands.
- `app/`: SwiftUI iOS/macOS client (`API.swift`, auth/token storage, URL handling).

## Key questions

1. Are authentication and authorization enforced uniformly across HTTP, WebSocket, and S3/IAM routes without bypassable middleware gaps?
2. Are high-privilege system routes (terminal, live metrics, power, containers, drives) strictly isolated behind admin credentials and Origin checks?
3. Are secrets sealed at rest with proper key separation and migration safety?
4. Do trust boundaries between `atlas-server`, Postgres, `atlas-ml`, the Share Worker, CLI, and Swift app prevent lateral privilege escalation?

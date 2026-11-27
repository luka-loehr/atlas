# Track: Quality & Maintainability (`luka-loehr/atlas`)

Audits performance, memory efficiency, concurrency, error handling, and panic safety across `crates/server`, `crates/core`, `crates/ml`, `crates/cli`, and `share/`.

## Key questions

1. Are there quadratic or excessive heap allocations on large inputs (for example `Vec<char>` on large extracted PDF text in Drive search snippets, or full-file buffering in memory)?
2. Are independent database queries executed sequentially where they could be batched or run concurrently, or are N+1 query patterns present?
3. Are there reachable `.unwrap()`, `.expect()`, or unchecked slice/index panics on untrusted or external input in server/ML request paths?
4. Are errors propagated cleanly without swallowing failures or leaking internal state to clients?

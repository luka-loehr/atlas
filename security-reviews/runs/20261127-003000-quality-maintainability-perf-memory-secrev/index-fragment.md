# Index fragment: 20261127-003000-quality-maintainability-perf-memory-secrev

- Queue: `SECQ-20261127-003` (`done`)
- Findings:
- [AUD-20261127-QUALITY-001](../../findings/AUD-20261127-QUALITY-001.md) (medium): drive/browse.rs snippet() allocates two full Vec<char> copies of extracted PDF text per search result
- [AUD-20261127-QUALITY-002](../../findings/AUD-20261127-QUALITY-002.md) (low): Sequential DB queries and host subprocess calls in drive/browse.rs and system/host.rs
- [AUD-20261127-QUALITY-003](../../findings/AUD-20261127-QUALITY-003.md) (low): Unchecked Mutex and RwLock unwrap() calls in server request and worker paths
- PASS statements:
- None.

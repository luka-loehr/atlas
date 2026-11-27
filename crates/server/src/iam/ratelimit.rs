//! Sharded, zero-DB-overhead token-bucket rate limiter per API key / account.

use std::collections::HashMap;
use std::hash::{Hash, Hasher};
use std::sync::Mutex;
use std::time::Instant;

const SHARDS: usize = 64;

struct Bucket {
    tokens: f64,
    last_refill: Instant,
}

#[derive(Debug, Clone, Copy)]
pub struct RateDecision {
    pub allowed: bool,
    pub limit: u32,
    pub remaining: u32,
    pub retry_after_secs: u64,
}

pub struct RateLimiter {
    shards: [Mutex<HashMap<String, Bucket>>; SHARDS],
}

impl Default for RateLimiter {
    fn default() -> Self {
        Self::new()
    }
}

impl RateLimiter {
    pub fn new() -> Self {
        Self {
            shards: std::array::from_fn(|_| Mutex::new(HashMap::new())),
        }
    }

    fn shard_index(subject: &str) -> usize {
        let mut h = std::collections::hash_map::DefaultHasher::new();
        subject.hash(&mut h);
        (h.finish() as usize) & (SHARDS - 1)
    }

    /// Consumes `cost` tokens (typically 1) for `subject` at `rps` / `burst`.
    pub fn check(&self, subject: &str, rps: u32, burst: u32) -> RateDecision {
        let rps = rps.max(1);
        let burst = burst.max(rps);
        let capacity = f64::from(burst);
        let rate = f64::from(rps);
        let now = Instant::now();

        let shard = &self.shards[Self::shard_index(subject)];
        let mut map = shard.lock().unwrap_or_else(|e| e.into_inner());
        // Bound per-shard map growth if ephemeral subjects ever accumulate
        if map.len() > 4096 {
            map.retain(|_, b| now.duration_since(b.last_refill).as_secs() < 600);
        }
        let entry = map.entry(subject.to_string()).or_insert(Bucket {
            tokens: capacity,
            last_refill: now,
        });
        let elapsed = now.duration_since(entry.last_refill).as_secs_f64();
        if elapsed > 0.0 {
            entry.tokens = (entry.tokens + elapsed * rate).min(capacity);
            entry.last_refill = now;
        }
        if entry.tokens >= 1.0 {
            entry.tokens -= 1.0;
            RateDecision {
                allowed: true,
                limit: rps,
                remaining: entry.tokens.floor() as u32,
                retry_after_secs: 0,
            }
        } else {
            let deficit = 1.0 - entry.tokens;
            let wait = (deficit / rate).ceil().max(1.0) as u64;
            RateDecision {
                allowed: false,
                limit: rps,
                remaining: 0,
                retry_after_secs: wait,
            }
        }
    }

    pub fn evict(&self, subject: &str) {
        let shard = &self.shards[Self::shard_index(subject)];
        let mut map = shard.lock().unwrap_or_else(|e| e.into_inner());
        map.remove(subject);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn enforces_burst_and_recovers_over_time() {
        let rl = RateLimiter::new();
        for _ in 0..5 {
            assert!(rl.check("k1", 2, 5).allowed);
        }
        let denied = rl.check("k1", 2, 5);
        assert!(!denied.allowed);
        assert!(denied.retry_after_secs >= 1);
    }
}

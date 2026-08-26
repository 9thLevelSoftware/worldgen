//! Deterministic RNG streams.
//!
//! Every random decision in the generator draws from a `Pcg64` stream derived
//! from `(master_seed, stage_tag, sub)`. Stages therefore cannot perturb each
//! other's rolls, and per-entity streams (e.g. one per loot container) are
//! independent of iteration order.
//!
//! Rules (see plan §Determinism): no process-global RNG, no OS-entropy
//! seeding, no float-driven decisions. Weighted choices use integer
//! cumulative weights.

use rand::{Rng, SeedableRng};
use rand_pcg::Pcg64;
use std::hash::Hasher;
use xxhash_rust::xxh3::Xxh3;

/// Derive a deterministic RNG stream for a generation stage / sub-entity.
pub fn stream(master_seed: u64, tag: &str, sub: u64) -> Pcg64 {
    Pcg64::seed_from_u64(key(master_seed, tag, sub))
}

/// Derive a deterministic u64 key (also used for site-seed derivation).
pub fn key(master_seed: u64, tag: &str, sub: u64) -> u64 {
    let mut h = Xxh3::new();
    h.write_u64(master_seed);
    h.write(tag.as_bytes());
    h.write_u64(sub);
    h.finish()
}

/// Inclusive integer range roll.
pub fn roll_range(rng: &mut Pcg64, min: i64, max: i64) -> i64 {
    if min >= max {
        return min;
    }
    rng.random_range(min..=max)
}

/// Roll against a probability expressed in basis points (10000 = certain).
pub fn roll_bp(rng: &mut Pcg64, bp: u32) -> bool {
    rng.random_range(0u32..10_000) < bp
}

/// Weighted index choice over integer weights. Returns None for empty/zero
/// input. Deterministic: cumulative scan in slice order.
pub fn weighted_choice(rng: &mut Pcg64, weights: &[u32]) -> Option<usize> {
    let total: u64 = weights.iter().map(|w| *w as u64).sum();
    if total == 0 {
        return None;
    }
    let mut roll = rng.random_range(0..total);
    for (i, w) in weights.iter().enumerate() {
        let w = *w as u64;
        if roll < w {
            return Some(i);
        }
        roll -= w;
    }
    None
}

/// Fisher-Yates shuffle (deterministic given the stream).
pub fn shuffle<T>(rng: &mut Pcg64, items: &mut [T]) {
    for i in (1..items.len()).rev() {
        let j = rng.random_range(0..=i);
        items.swap(i, j);
    }
}

/// Integer lerp on basis points: value between `at_zero` and `at_full` as
/// `t` (0..=10000) goes from 0 to 10000.
pub fn lerp_bp(at_zero: i64, at_full: i64, t: u16) -> i64 {
    at_zero + (at_full - at_zero) * t as i64 / 10_000
}

/// Integer square root (for radius/distance math without floats).
pub fn isqrt(v: i64) -> i64 {
    if v <= 0 {
        return 0;
    }
    let mut x = v;
    let mut y = (x + 1) / 2;
    while y < x {
        x = y;
        y = (x + v / x) / 2;
    }
    x
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn streams_are_deterministic_and_independent() {
        let mut a1 = stream(42, "hull", 0);
        let mut a2 = stream(42, "hull", 0);
        let mut b = stream(42, "rooms", 0);
        let x1: u64 = a1.random();
        let x2: u64 = a2.random();
        let y: u64 = b.random();
        assert_eq!(x1, x2);
        assert_ne!(x1, y);
    }

    #[test]
    fn isqrt_works() {
        assert_eq!(isqrt(0), 0);
        assert_eq!(isqrt(1), 1);
        assert_eq!(isqrt(15), 3);
        assert_eq!(isqrt(16), 4);
        assert_eq!(isqrt(1_000_000), 1000);
    }
}

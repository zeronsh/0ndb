//! Phase timers for profiling large mounts, enabled with `ONDB_TIMING=1`
//! (otherwise every call is a no-op).
use std::collections::BTreeMap;
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

static T: Mutex<BTreeMap<&'static str, Duration>> = Mutex::new(BTreeMap::new());

fn on() -> bool {
    static ON: OnceLock<bool> = OnceLock::new();
    *ON.get_or_init(|| std::env::var_os("ONDB_TIMING").is_some())
}

pub fn add(k: &'static str, d: Duration) {
    if on() {
        *T.lock().unwrap_or_else(|p| p.into_inner()).entry(k).or_default() += d;
    }
}

/// Accumulated totals, `name=duration` separated by spaces.
pub fn dump() -> String {
    T.lock().unwrap_or_else(|p| p.into_inner()).iter().map(|(k, v)| format!("{k}={v:.2?} ")).collect()
}

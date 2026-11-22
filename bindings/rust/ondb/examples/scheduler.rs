use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use ondb::{hex, unhex, CancelToken, HostBuilder, HostState, PlacementDecision, PlacementRequest, PlugResult, Scheduler};

struct Pick {
    runner: Option<[u8; 16]>,
    asked: Arc<AtomicU64>,
}

impl Scheduler for Pick {
    fn place(&self, req: &PlacementRequest, _cancel: &CancelToken) -> PlugResult<PlacementDecision> {
        let n = self.asked.fetch_add(1, Ordering::Relaxed) + 1;
        let decision = match self.runner {
            Some(id) => PlacementDecision::Runner(id),
            None => PlacementDecision::Reference,
        };
        println!(
            "place #{n} {:?} object {} msg {} prefer {} exclude {} provider {:?} -> {:?}",
            req.kind,
            hex(&req.object),
            req.msg.map(|m| format!("{}:{}", hex(&m.0), m.1)).unwrap_or_default(),
            req.prefer.map(|p| hex(&p)).unwrap_or_default(),
            req.exclude.map(|p| hex(&p)).unwrap_or_default(),
            req.provider,
            decision.clone_runner_hex(),
        );
        Ok(decision)
    }
}

trait RunnerHex {
    fn clone_runner_hex(&self) -> String;
}

impl RunnerHex for PlacementDecision {
    fn clone_runner_hex(&self) -> String {
        match self {
            PlacementDecision::Runner(id) => hex(id),
            PlacementDecision::Wait => "wait".into(),
            PlacementDecision::Reference => "reference".into(),
        }
    }
}

fn main() -> ondb::Result<()> {
    let mut args = std::env::args().skip(1);
    let sock = PathBuf::from(args.next().expect("usage: scheduler SOCKET [RUNNER_HEX] [SECONDS]"));
    let runner = args.next().filter(|s| s != "reference").map(|s| {
        let b = unhex(&s).expect("RUNNER_HEX is 32 hex characters");
        let mut id = [0u8; 16];
        id.copy_from_slice(&b);
        id
    });
    let secs: u64 = args.next().and_then(|s| s.parse().ok()).unwrap_or(60);
    let asked = Arc::new(AtomicU64::new(0));
    let host = HostBuilder::new().socket(&sock).scheduler(Pick { runner, asked: asked.clone() }).spawn()?;
    println!("registered for {:?}", host.wait_registered(Duration::from_secs(10))?);
    let deadline = std::time::Instant::now() + Duration::from_secs(secs);
    while std::time::Instant::now() < deadline {
        if let Some(HostState::Refused(st)) = host.next_state(Some(Duration::from_millis(200))) {
            println!("refused: {st:?}");
            break;
        }
    }
    println!("answered {} placement requests", asked.load(Ordering::Relaxed));
    host.stop();
    Ok(())
}

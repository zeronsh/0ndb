//! Randomized multi-replica test: replicas edit concurrently (including
//! edits authored against stale parents, renames, moves, removals), batches
//! are delivered in random causal order, and every replica must end up
//! byte-identical.

use std::collections::{HashMap, HashSet};

use strand_core::codec::{decode_snapshot, encode_snapshot};
use strand_core::{ActorId, Batch, Content, FileMode, History, HistoryId, InodeId, LineEnding, NodeKind, Op, Splice, Version};
use uuid::Uuid;

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    fn below(&mut self, n: u64) -> u64 {
        if n == 0 { 0 } else { self.next() % n }
    }
    fn chance(&mut self, pct: u64) -> bool {
        self.below(100) < pct
    }
    fn word(&mut self) -> Vec<u8> {
        let n = 1 + self.below(6);
        let mut w: Vec<u8> = (0..n).map(|_| b'a' + self.below(26) as u8).collect();
        if self.chance(30) {
            w.push(b'\n');
        }
        w
    }
}

struct Replica {
    actor: ActorId,
    h: History,
    seen: HashSet<strand_core::BatchId>,
    versions: Vec<Version>,
}

fn snapshot(h: &History) -> Vec<(String, Option<Vec<u8>>)> {
    h.walk().into_iter().map(|(p, id)| (p, h.text(&id))).collect()
}

fn entries_at(h: &History, v: &Version) -> (Vec<InodeId>, Vec<InodeId>) {
    let ex = h.exclusions_for(v);
    let view = h.excluding(&ex);
    let walk = h.tree().walk(&view);
    let files = walk.iter().filter(|(_, id)| matches!(h.inode(id).unwrap().kind, NodeKind::File(_))).map(|(_, id)| *id).collect();
    let mut dirs: Vec<InodeId> = walk.iter().filter(|(_, id)| h.inode(id).unwrap().is_dir()).map(|(_, id)| *id).collect();
    dirs.push(InodeId::ROOT);
    (files, dirs)
}

fn random_batch(rng: &mut Rng, r: &mut Replica) -> Option<Batch> {
    // Sometimes author against a stale parent, as a disk mount does when it
    // ingests edits made while remote changes were arriving.
    let parents = if r.versions.len() > 1 && rng.chance(25) {
        Some(r.versions[rng.below(r.versions.len() as u64) as usize].clone())
    } else {
        None
    };
    let (files_now, dirs_now) = entries_at(&r.h, parents.as_ref().unwrap_or(r.h.heads()));
    let n_ops = 1 + rng.below(3);
    let (batch, _) =
        r.h.transact(r.actor, parents, |txn| -> Result<(), ()> {
            for _ in 0..n_ops {
                let roll = rng.below(100);
                if roll < 12 || files_now.is_empty() {
                    let parent = dirs_now[rng.below(dirs_now.len() as u64) as usize];
                    let name = format!("f{}", rng.below(6));
                    let content = Content::Text(rng.word());
                    let _ =
                        txn.push(Op::CreateFile { parent, name, mode: FileMode::Regular, line_ending: LineEnding::Lf, content });
                } else if roll < 17 {
                    let parent = dirs_now[rng.below(dirs_now.len() as u64) as usize];
                    let _ = txn.push(Op::CreateDir { parent, name: format!("d{}", rng.below(4)) });
                } else if roll < 25 {
                    let pick = files_now[rng.below(files_now.len() as u64) as usize];
                    let parent = dirs_now[rng.below(dirs_now.len() as u64) as usize];
                    let _ = txn.push(Op::Rename { inode: pick, parent, name: format!("r{}", rng.below(5)) });
                } else if roll < 29 {
                    let all: Vec<InodeId> = dirs_now.iter().chain(files_now.iter()).filter(|i| !i.is_root()).copied().collect();
                    if !all.is_empty() {
                        let pick = all[rng.below(all.len() as u64) as usize];
                        let parent = dirs_now[rng.below(dirs_now.len() as u64) as usize];
                        let _ = txn.push(Op::Rename { inode: pick, parent, name: format!("m{}", rng.below(3)) });
                    }
                } else if roll < 32 {
                    let pick = files_now[rng.below(files_now.len() as u64) as usize];
                    let _ = txn.push(Op::Remove { inode: pick });
                } else if roll < 34 {
                    let pick = files_now[rng.below(files_now.len() as u64) as usize];
                    let _ = txn.push(Op::Restore { inode: pick });
                } else if roll < 36 {
                    let _ = txn.push(Op::Meta { key: format!("k{}", rng.below(3)), value: Some(rng.word()) });
                } else {
                    let pick = files_now[rng.below(files_now.len() as u64) as usize];
                    let len = {
                        let view = txn.view();
                        txn.history().text_in(&view, &pick).map(|t| t.len() as u64).unwrap_or(0)
                    };
                    let mut splices = Vec::new();
                    let mut text = Vec::new();
                    let mut floor = 0;
                    for _ in 0..1 + rng.below(3) {
                        if floor > len {
                            break;
                        }
                        let at = floor + rng.below(len - floor + 1);
                        let del = if rng.chance(50) { rng.below(len - at + 1).min(8) } else { 0 };
                        let ins = if rng.chance(70) { rng.word() } else { Vec::new() };
                        if del == 0 && ins.is_empty() {
                            continue;
                        }
                        splices.push(Splice { at, del, ins: ins.len() as u64 });
                        text.extend(ins);
                        floor = at + del + 1;
                    }
                    if !splices.is_empty() {
                        txn.push(Op::EditText { inode: pick, text, splices }).expect("valid edit");
                    }
                }
            }
            Ok(())
        })
        .expect("transact");
    if let Some(b) = &batch {
        r.seen.insert(b.id());
        r.versions.push(r.h.heads().clone());
    }
    batch
}

fn run(seed: u64, replicas: usize, rounds: usize) {
    let mut rng = Rng(seed);
    let hid = HistoryId(Uuid::from_u128(7));
    let mut reps: Vec<Replica> = (0..replicas)
        .map(|i| Replica {
            actor: ActorId(Uuid::from_u128(100 + i as u128)),
            h: History::new(hid),
            seen: HashSet::new(),
            versions: vec![Version::root()],
        })
        .collect();
    let mut log: Vec<Batch> = Vec::new();
    for _ in 0..rounds {
        let i = rng.below(replicas as u64) as usize;
        if rng.chance(55) {
            if let Some(b) = random_batch(&mut rng, &mut reps[i]) {
                log.push(b);
            }
        } else {
            // Deliver a few random batches whose parents are present.
            for _ in 0..1 + rng.below(4) {
                let candidates: Vec<&Batch> = log
                    .iter()
                    .filter(|b| !reps[i].seen.contains(&b.id()) && reps[i].h.dag().missing_parents(&b.header.parents).is_empty())
                    .collect();
                if candidates.is_empty() {
                    break;
                }
                let b = candidates[rng.below(candidates.len() as u64) as usize].clone();
                reps[i].h.integrate(&b).unwrap_or_else(|e| panic!("seed {seed}: integrate {:?}: {e}", b.id()));
                reps[i].seen.insert(b.id());
                let v = reps[i].h.heads().clone();
                reps[i].versions.push(v);
            }
        }
    }
    let mut ordered = log.clone();
    ordered.sort_by_key(|b| (b.header.start, b.header.actor));
    for r in reps.iter_mut() {
        for b in &ordered {
            if r.seen.insert(b.id()) {
                r.h.integrate(b).unwrap_or_else(|e| panic!("seed {seed}: final integrate: {e}"));
            }
        }
    }
    let reference = snapshot(&reps[0].h);
    let meta0: HashMap<String, Vec<u8>> = reps[0].h.meta_with_prefix("k").map(|(k, v)| (k.to_string(), v.to_vec())).collect();
    for (i, r) in reps.iter().enumerate() {
        assert_eq!(r.h.heads(), reps[0].h.heads(), "seed {seed}: heads differ on replica {i}");
        assert_eq!(snapshot(&r.h), reference, "seed {seed}: replica {i} diverged");
        let meta: HashMap<String, Vec<u8>> = r.h.meta_with_prefix("k").map(|(k, v)| (k.to_string(), v.to_vec())).collect();
        assert_eq!(meta, meta0, "seed {seed}: meta diverged");
    }
    let restored = decode_snapshot(&encode_snapshot(&reps[0].h)).unwrap();
    assert_eq!(snapshot(&restored), reference);
}

#[test]
fn replicas_converge_under_random_concurrency() {
    for seed in 1..=300u64 {
        run(seed.wrapping_mul(0x9E3779B97F4A7C15) | 1, 3, 120);
    }
}

#[test]
fn many_replicas_long_runs() {
    for seed in 1..=20u64 {
        run(seed.wrapping_mul(0xD1B54A32D192ED03) | 1, 5, 600);
    }
}

#[test]
fn historical_reads_match_what_was_seen() {
    // Every version a replica passed through must be reconstructable later.
    let mut rng = Rng(0xABCDEF);
    let hid = HistoryId(Uuid::from_u128(9));
    let mut r = Replica {
        actor: ActorId(Uuid::from_u128(1)),
        h: History::new(hid),
        seen: HashSet::new(),
        versions: vec![Version::root()],
    };
    let mut seen_states = Vec::new();
    for _ in 0..200 {
        if random_batch(&mut rng, &mut r).is_some() {
            seen_states.push((r.h.heads().clone(), snapshot(&r.h)));
        }
    }
    for (v, state) in seen_states {
        let ex = r.h.exclusions_for(&v);
        let view = r.h.excluding(&ex);
        let then: Vec<(String, Option<Vec<u8>>)> =
            r.h.tree().walk(&view).into_iter().map(|(p, id)| (p, r.h.text_in(&view, &id))).collect();
        assert_eq!(then, state, "state at {v:?} not reconstructable");
    }
}

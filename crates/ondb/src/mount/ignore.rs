use std::path::{Path, PathBuf};

use ignore::gitignore::{Gitignore, GitignoreBuilder};
use ignore::{Match, WalkBuilder};

use super::disk::{self, STATE_DIR};
use super::git::GitDirs;

/// Gitignore rules for a root: every `.gitignore` (deeper files win) plus
/// git's `info/exclude`. Entries already tracked stay tracked even if a rule
/// later ignores them, matching git's behavior.
pub struct Ignore {
    root: PathBuf,
    /// (directory relative to root, rules), deepest first.
    rules: Vec<(String, Gitignore)>,
}

impl Ignore {
    pub fn load(root: &Path, git: Option<&GitDirs>) -> Ignore {
        let mut rules = Vec::new();
        if let Some(exclude) = git.map(GitDirs::exclude)
            && exclude.is_file()
        {
            let mut b = GitignoreBuilder::new(root);
            b.add(exclude);
            if let Ok(g) = b.build() {
                rules.push((String::new(), g));
            }
        }
        for entry in walker(root).build().flatten() {
            if entry.file_name() != ".gitignore" || !entry.file_type().is_some_and(|t| t.is_file()) {
                continue;
            }
            let dir = entry.path().parent().unwrap_or(root);
            let mut b = GitignoreBuilder::new(dir);
            b.add(entry.path());
            if let Ok(g) = b.build() {
                let rel = dir.strip_prefix(root).map(|p| p.to_string_lossy().into_owned()).unwrap_or_default();
                rules.push((rel, g));
            }
        }
        rules.sort_by_key(|(dir, _)| std::cmp::Reverse(if dir.is_empty() { 0 } else { dir.matches('/').count() + 1 }));
        Ignore { root: root.to_path_buf(), rules }
    }

    pub fn is_ignored(&self, rel: &str, is_dir: bool) -> bool {
        if disk::is_internal(rel) {
            return true;
        }
        let abs = self.root.join(rel);
        for (dir, rules) in &self.rules {
            if !dir.is_empty() && !disk::is_under(rel, dir) {
                continue;
            }
            match rules.matched_path_or_any_parents(&abs, is_dir) {
                Match::Ignore(_) => return true,
                Match::Whitelist(_) => return false,
                Match::None => {}
            }
        }
        false
    }
}

/// A walker over `dir` honoring ignore files found inside it, skipping
/// internal directories. Callers re-check results against [`Ignore`] for
/// rules that live above `dir`.
pub fn walker(dir: &Path) -> WalkBuilder {
    let mut w = WalkBuilder::new(dir);
    w.hidden(false)
        .git_ignore(true)
        .git_exclude(true)
        .git_global(false)
        .require_git(false)
        .parents(false)
        .follow_links(false)
        .filter_entry(|e| {
            let name = e.file_name().to_string_lossy();
            name != ".git" && name != STATE_DIR && !name.starts_with(disk::TEMP_PREFIX)
        });
    w
}

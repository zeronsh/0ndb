use std::path::{Path, PathBuf};

use ignore::gitignore::{Gitignore, GitignoreBuilder};
use ignore::{Match, WalkBuilder};

use super::disk::{self, STATE_DIR};
use super::git::GitDirs;

/// Directories (and files) nobody wants tracked in a folder that isn't a git
/// checkout: dependency trees, caches, OS litter. Only unambiguous names, so
/// a plain folder's own content (`build/`, `dist/` may be someone's
/// documents) is never skipped; its `.gitignore`, if any, can whitelist
/// these back.
pub const PLAIN_DEFAULTS: &[&str] = &[
    "node_modules/",
    ".venv/",
    "__pycache__/",
    "*.pyc",
    ".pytest_cache/",
    ".mypy_cache/",
    ".ruff_cache/",
    ".tox/",
    ".next/",
    ".nuxt/",
    ".turbo/",
    ".parcel-cache/",
    ".gradle/",
    ".Trash/",
    ".DS_Store",
];

/// Gitignore rules for a root: every `.gitignore` (deeper files win) plus
/// git's `info/exclude`, and outside git, [`PLAIN_DEFAULTS`] below them all.
/// Entries already tracked stay tracked even if a rule later ignores them,
/// matching git's behavior.
pub struct Ignore {
    root: PathBuf,
    /// (directory relative to root, rules), deepest first.
    rules: Vec<(String, Gitignore)>,
    /// Not a git checkout: the defaults apply.
    plain: bool,
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
        for entry in walker(root, git.is_none()).build().flatten() {
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
        let plain = git.is_none();
        if plain {
            let mut b = GitignoreBuilder::new(root);
            for line in PLAIN_DEFAULTS {
                let _ = b.add_line(None, line);
            }
            if let Ok(g) = b.build() {
                rules.push((String::new(), g));
            }
        }
        Ignore { root: root.to_path_buf(), rules, plain }
    }

    /// Whether this root isn't a git checkout (so the defaults apply).
    pub fn plain(&self) -> bool {
        self.plain
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
/// internal directories (and, in a `plain` folder, the default-ignored
/// ones). Callers re-check results against [`Ignore`] for rules that live
/// above `dir`.
pub fn walker(dir: &Path, plain: bool) -> WalkBuilder {
    let mut w = WalkBuilder::new(dir);
    w.hidden(false)
        .git_ignore(true)
        .git_exclude(true)
        .git_global(false)
        .require_git(false)
        .parents(false)
        .follow_links(false)
        .filter_entry(move |e| {
            let name = e.file_name().to_string_lossy();
            let skipped = plain
                && e.file_type().is_some_and(|t| t.is_dir())
                && PLAIN_DEFAULTS.iter().any(|d| d.strip_suffix('/') == Some(&*name));
            name != ".git" && name != STATE_DIR && !name.starts_with(disk::TEMP_PREFIX) && !skipped
        });
    w
}

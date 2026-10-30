//! Remote URLs, normalized across spellings so one repository has one
//! identity whatever protocol or form a clone used.

use serde::{Deserialize, Serialize};

/// A hosted repository named by a remote URL: `host/namespace.../name`.
/// `namespace` has several segments on hosts with nested groups.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct RemoteUrl {
    /// Lowercased host, without port or user.
    pub host: String,
    pub namespace: Vec<String>,
    pub name: String,
}

impl RemoteUrl {
    /// Parses https, http, ssh (`ssh://` and scp-like `user@host:path`) and
    /// git URLs. Local paths and `file://` URLs have no host and give `None`.
    pub fn parse(url: &str) -> Option<RemoteUrl> {
        let url = url.trim();
        let (host, path) = if let Some((scheme, rest)) = url.split_once("://") {
            if !matches!(scheme, "https" | "http" | "ssh" | "git" | "git+ssh" | "ssh+git") {
                return None;
            }
            let (authority, path) = rest.split_once('/')?;
            let host = authority.rsplit('@').next()?;
            let host =
                if host.starts_with('[') { host.split(']').next()?.trim_start_matches('[') } else { host.split(':').next()? };
            (host.to_string(), path.to_string())
        } else {
            // scp-like: [user@]host:path, where host has no slash.
            let (authority, path) = url.split_once(':')?;
            if authority.contains('/') || authority.is_empty() || path.starts_with("//") {
                return None;
            }
            let host = authority.rsplit('@').next()?;
            if host.len() == 1 {
                return None; // a Windows drive letter
            }
            (host.to_string(), path.to_string())
        };
        let mut segments: Vec<String> = path.trim_matches('/').split('/').filter(|s| !s.is_empty()).map(str::to_string).collect();
        let last = segments.pop()?;
        let name = last.strip_suffix(".git").unwrap_or(&last).to_string();
        if host.is_empty() || name.is_empty() || segments.is_empty() {
            return None;
        }
        Some(RemoteUrl { host: host.to_ascii_lowercase(), namespace: segments, name })
    }

    /// `namespace/name`, as hosts spell it in URLs.
    pub fn slug(&self) -> String {
        format!("{}/{}", self.namespace.join("/"), self.name)
    }

    /// Spelling-insensitive identity: `host/slug`, lowercased.
    pub fn key(&self) -> String {
        format!("{}/{}", self.host, self.slug()).to_ascii_lowercase()
    }

    pub fn web_url(&self) -> String {
        format!("https://{}/{}", self.host, self.slug())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(u: &str) -> Option<(String, String)> {
        RemoteUrl::parse(u).map(|r| (r.host.clone(), r.slug()))
    }

    #[test]
    fn spellings_of_one_repository_agree() {
        let want = Some(("github.com".to_string(), "zeronsh/0ndb".to_string()));
        for u in [
            "https://github.com/zeronsh/0ndb.git",
            "https://github.com/zeronsh/0ndb",
            "https://user:token@github.com/zeronsh/0ndb/",
            "git@github.com:zeronsh/0ndb.git",
            "ssh://git@github.com/zeronsh/0ndb.git",
            "ssh://git@github.com:22/zeronsh/0ndb",
            "git://github.com/zeronsh/0ndb.git",
            "GitHub.com:zeronsh/0ndb",
        ] {
            assert_eq!(p(u), want, "{u}");
        }
    }

    #[test]
    fn nested_namespaces_and_rejections() {
        assert_eq!(p("https://gitlab.com/group/sub/repo.git"), Some(("gitlab.com".into(), "group/sub/repo".into())));
        assert_eq!(p("git@git.example.org:a/b/c/d.git"), Some(("git.example.org".into(), "a/b/c/d".into())));
        assert_eq!(p("/srv/git/repo.git"), None);
        assert_eq!(p("file:///srv/git/repo.git"), None);
        assert_eq!(p("C:\\repos\\x"), None);
        assert_eq!(p("https://github.com/onlyname"), None);
        assert_eq!(p("../relative/repo"), None);
    }
}

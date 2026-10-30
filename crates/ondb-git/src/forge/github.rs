//! GitHub (and GitHub Enterprise) through the `gh` CLI, so the user's own
//! sign-in and host configuration apply and no token passes through 0ndb.

use std::time::Duration;

use serde_json::Value;

use super::{ChangeRequest, ChangeState, ChecksState, Forge, ForgeError, ForgeRepo, NewChangeRequest, ReviewState};
use crate::Error;
use crate::cmd::Cmd;
use crate::remote::RemoteUrl;

const TIMEOUT: Duration = Duration::from_secs(20);

const FIELDS: &str = "number title url state isDraft headRefName baseRefName headRefOid \
    headRepositoryOwner { login } author { login } mergeable reviewDecision updatedAt \
    commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }";

#[derive(Clone, Debug)]
pub struct GitHub {
    program: String,
}

impl Default for GitHub {
    fn default() -> Self {
        GitHub { program: "gh".into() }
    }
}

impl GitHub {
    /// Uses a specific `gh` executable.
    pub fn with_program(program: impl Into<String>) -> Self {
        GitHub { program: program.into() }
    }

    fn gh(&self, host: &str) -> Cmd {
        Cmd::new(&self.program)
            .env("GH_PROMPT_DISABLED", "1")
            .env("GH_NO_UPDATE_NOTIFIER", "1")
            .env("NO_COLOR", "1")
            .env("GH_HOST", host)
            .timeout(TIMEOUT)
            .limit(4 << 20)
    }

    fn api(&self, host: &str, args: &[String]) -> Result<Value, ForgeError> {
        let out = self.gh(host).arg("api").args(args.iter().cloned()).output().map_err(map_err)?;
        if !out.success() {
            return Err(classify(&out.stderr, &out.text()));
        }
        serde_json::from_slice(&out.stdout).map_err(|e| ForgeError::Decode(e.to_string()))
    }

    fn graphql(&self, remote: &RemoteUrl, query: &str, vars: &[(&str, &str)]) -> Result<Value, ForgeError> {
        let mut args = vec!["graphql".to_string(), "-f".into(), format!("query={query}")];
        for (k, v) in vars {
            args.push("-f".into());
            args.push(format!("{k}={v}"));
        }
        let v = self.api(&remote.host, &args)?;
        if let Some(errs) = v.get("errors").and_then(Value::as_array).filter(|e| !e.is_empty()) {
            let msg = errs.iter().filter_map(|e| e["message"].as_str()).collect::<Vec<_>>().join("; ");
            return Err(if msg.contains("Could not resolve to a Repository") {
                ForgeError::NotFound
            } else {
                ForgeError::Failed(msg)
            });
        }
        Ok(v)
    }

    fn owner_name(remote: &RemoteUrl) -> (String, String) {
        (remote.namespace.join("/"), remote.name.clone())
    }
}

impl Forge for GitHub {
    fn id(&self) -> &'static str {
        "github"
    }

    fn signed_in(&self, host: &str) -> Result<bool, ForgeError> {
        let out = self.gh(host).args(["auth", "status", "--hostname", host]).output().map_err(map_err)?;
        Ok(out.success())
    }

    fn repository(&self, remote: &RemoteUrl) -> Result<ForgeRepo, ForgeError> {
        let v = self.api(&remote.host, &[format!("repos/{}", remote.slug())])?;
        Ok(ForgeRepo {
            slug: str_of(&v["full_name"]).ok_or_else(|| ForgeError::Decode("full_name".into()))?,
            default_branch: str_of(&v["default_branch"]),
            web_url: str_of(&v["html_url"]).unwrap_or_else(|| remote.web_url()),
            private: v["private"].as_bool().unwrap_or(false),
        })
    }

    fn change_request_for_branch(
        &self,
        remote: &RemoteUrl,
        branch: &str,
        head_owner: Option<&str>,
    ) -> Result<Option<ChangeRequest>, ForgeError> {
        let (owner, name) = Self::owner_name(remote);
        let q = format!(
            "query($owner: String!, $name: String!, $branch: String!) {{ repository(owner: $owner, name: $name) {{ \
             pullRequests(headRefName: $branch, first: 20, orderBy: {{field: UPDATED_AT, direction: DESC}}) {{ nodes {{ {FIELDS} }} }} }} }}"
        );
        let v = self.graphql(remote, &q, &[("owner", &owner), ("name", &name), ("branch", branch)])?;
        let mut prs = parse_nodes(&v["data"]["repository"]["pullRequests"]["nodes"])?;
        if let Some(o) = head_owner {
            prs.retain(|p| p.head_owner.as_deref().is_none_or(|h| h.eq_ignore_ascii_case(o)));
        }
        let open = prs.iter().position(|p| p.state == ChangeState::Open);
        Ok(match open {
            Some(i) => Some(prs.swap_remove(i)),
            None => prs.into_iter().next(),
        })
    }

    fn open_change_requests(&self, remote: &RemoteUrl, limit: usize) -> Result<Vec<ChangeRequest>, ForgeError> {
        let (owner, name) = Self::owner_name(remote);
        let q = format!(
            "query($owner: String!, $name: String!) {{ repository(owner: $owner, name: $name) {{ \
             pullRequests(states: OPEN, first: {}, orderBy: {{field: UPDATED_AT, direction: DESC}}) {{ nodes {{ {FIELDS} }} }} }} }}",
            limit.clamp(1, 100)
        );
        let v = self.graphql(remote, &q, &[("owner", &owner), ("name", &name)])?;
        parse_nodes(&v["data"]["repository"]["pullRequests"]["nodes"])
    }

    fn create_change_request(&self, remote: &RemoteUrl, req: &NewChangeRequest) -> Result<ChangeRequest, ForgeError> {
        let v = self.api(
            &remote.host,
            &[
                "-X".into(),
                "POST".into(),
                format!("repos/{}/pulls", remote.slug()),
                "-f".into(),
                format!("title={}", req.title),
                "-f".into(),
                format!("body={}", req.body),
                "-f".into(),
                format!("head={}", req.head),
                "-f".into(),
                format!("base={}", req.base),
                "-F".into(),
                format!("draft={}", req.draft),
            ],
        )?;
        Ok(ChangeRequest {
            number: v["number"].as_u64().ok_or_else(|| ForgeError::Decode("number".into()))?,
            title: str_of(&v["title"]).unwrap_or_default(),
            url: str_of(&v["html_url"]).unwrap_or_default(),
            state: ChangeState::Open,
            draft: v["draft"].as_bool().unwrap_or(req.draft),
            head_branch: str_of(&v["head"]["ref"]).unwrap_or_else(|| req.head.clone()),
            head_owner: str_of(&v["head"]["repo"]["owner"]["login"]),
            base_branch: str_of(&v["base"]["ref"]).unwrap_or_else(|| req.base.clone()),
            head_oid: str_of(&v["head"]["sha"]),
            author: str_of(&v["user"]["login"]),
            checks: ChecksState::None,
            review: None,
            mergeable: None,
            updated_at: str_of(&v["updated_at"]),
        })
    }
}

fn str_of(v: &Value) -> Option<String> {
    v.as_str().map(str::to_string)
}

fn parse_nodes(nodes: &Value) -> Result<Vec<ChangeRequest>, ForgeError> {
    let Some(nodes) = nodes.as_array() else {
        return Err(ForgeError::Decode("pullRequests.nodes".into()));
    };
    nodes.iter().filter(|n| !n.is_null()).map(parse_pr).collect()
}

fn parse_pr(n: &Value) -> Result<ChangeRequest, ForgeError> {
    let state = match n["state"].as_str() {
        Some("OPEN") => ChangeState::Open,
        Some("MERGED") => ChangeState::Merged,
        Some("CLOSED") => ChangeState::Closed,
        other => return Err(ForgeError::Decode(format!("state {other:?}"))),
    };
    let rollup = n["commits"]["nodes"].get(0).map(|c| &c["commit"]["statusCheckRollup"]["state"]);
    Ok(ChangeRequest {
        number: n["number"].as_u64().ok_or_else(|| ForgeError::Decode("number".into()))?,
        title: str_of(&n["title"]).unwrap_or_default(),
        url: str_of(&n["url"]).unwrap_or_default(),
        state,
        draft: n["isDraft"].as_bool().unwrap_or(false),
        head_branch: str_of(&n["headRefName"]).unwrap_or_default(),
        head_owner: str_of(&n["headRepositoryOwner"]["login"]),
        base_branch: str_of(&n["baseRefName"]).unwrap_or_default(),
        head_oid: str_of(&n["headRefOid"]),
        author: str_of(&n["author"]["login"]),
        checks: match rollup.and_then(Value::as_str) {
            Some("SUCCESS") => ChecksState::Passing,
            Some("FAILURE" | "ERROR") => ChecksState::Failing,
            Some("PENDING" | "EXPECTED") => ChecksState::Pending,
            _ => ChecksState::None,
        },
        review: match n["reviewDecision"].as_str() {
            Some("APPROVED") => Some(ReviewState::Approved),
            Some("CHANGES_REQUESTED") => Some(ReviewState::ChangesRequested),
            Some("REVIEW_REQUIRED") => Some(ReviewState::ReviewRequired),
            _ => None,
        },
        mergeable: match n["mergeable"].as_str() {
            Some("MERGEABLE") => Some(true),
            Some("CONFLICTING") => Some(false),
            _ => None,
        },
        updated_at: str_of(&n["updatedAt"]),
    })
}

fn map_err(e: Error) -> ForgeError {
    match e {
        Error::Missing(_) => ForgeError::CliMissing("gh"),
        Error::Timeout(_) => ForgeError::Timeout,
        other => ForgeError::Failed(other.to_string()),
    }
}

/// Maps `gh` failures to error kinds without echoing output (which may
/// contain repository or account details) beyond a short first line.
fn classify(stderr: &str, stdout: &str) -> ForgeError {
    let all = format!("{stderr}\n{stdout}").to_ascii_lowercase();
    if all.contains("gh auth login") || all.contains("authentication") || all.contains("http 401") {
        ForgeError::Auth("github".into())
    } else if all.contains("rate limit") {
        ForgeError::RateLimited
    } else if all.contains("http 404") || all.contains("not found") {
        ForgeError::NotFound
    } else {
        ForgeError::Failed(stderr.lines().next().unwrap_or("gh failed").chars().take(200).collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_graphql_pull_requests() {
        let v: Value = serde_json::from_str(
            r#"{"data":{"repository":{"pullRequests":{"nodes":[
              {"number":7,"title":"Closed one","url":"u7","state":"CLOSED","isDraft":false,"headRefName":"feat","baseRefName":"main",
               "headRefOid":"a","headRepositoryOwner":{"login":"fork"},"author":{"login":"x"},"mergeable":"UNKNOWN","reviewDecision":null,
               "updatedAt":"2026-01-02","commits":{"nodes":[]}},
              {"number":9,"title":"Open one","url":"u9","state":"OPEN","isDraft":true,"headRefName":"feat","baseRefName":"main",
               "headRefOid":"b","headRepositoryOwner":{"login":"zeronsh"},"author":{"login":"y"},"mergeable":"CONFLICTING",
               "reviewDecision":"CHANGES_REQUESTED","updatedAt":"2026-01-01",
               "commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"FAILURE"}}}]}}
            ]}}}}"#,
        )
        .unwrap();
        let prs = parse_nodes(&v["data"]["repository"]["pullRequests"]["nodes"]).unwrap();
        assert_eq!(prs.len(), 2);
        assert_eq!(prs[1].state, ChangeState::Open);
        assert!(prs[1].draft);
        assert_eq!(prs[1].checks, ChecksState::Failing);
        assert_eq!(prs[1].review, Some(ReviewState::ChangesRequested));
        assert_eq!(prs[1].mergeable, Some(false));
        assert_eq!(prs[0].head_owner.as_deref(), Some("fork"));
    }

    #[test]
    fn classifies_failures() {
        assert!(matches!(classify("To get started with GitHub CLI, please run:  gh auth login", ""), ForgeError::Auth(_)));
        assert!(matches!(classify("HTTP 404: Not Found", ""), ForgeError::NotFound));
        assert!(matches!(classify("API rate limit exceeded", ""), ForgeError::RateLimited));
    }
}

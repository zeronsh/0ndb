#!/bin/bash
# End-to-end: 0ndb against a real GitHub clone and its linked worktrees.
# Build first (cargo build --release). Needs push access to PLAYGROUND_URL.
set -u
B="${ONDB:-$(cd "$(dirname "$0")/.." && pwd)/target/release/0ndb}"
E="${E2E_DIR:-/tmp/ondb-e2e}"; mkdir -p "$E"
export GIT_AUTHOR_NAME=e2e GIT_AUTHOR_EMAIL=e2e@example.com GIT_COMMITTER_NAME=e2e GIT_COMMITTER_EMAIL=e2e@example.com
export GH_TOKEN="${GH_TOKEN:-$(gh auth token)}"
GITC=(-c credential.helper= -c 'credential.helper=!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f')
URL="${PLAYGROUND_URL:-https://github.com/zeronsh/0ndb-git-playground.git}"
FAIL=0
step() { printf '\n=== %s\n' "$*"; }
settle() { sleep 1.5; }
verify() {
  for d in "$@"; do
    out=$($B verify -C "$E/$d" 2>&1); rc=$?
    if [ $rc -eq 0 ]; then echo "  [$d] $out"; else echo "  [$d] FAIL"; echo "$out" | sed 's/^/      /'; FAIL=1; fi
  done
}
last() { $B log -C "$E/$1" -n "${2:-1}" 2>&1 | sed "s/^/  [$1] /"; }

rm -rf $E/a $E/a-feature $E/a-hotfix $E/a-new $E/b $E/*.log
git "${GITC[@]}" clone -q $URL $E/a && git "${GITC[@]}" clone -q $URL $E/b || { echo "can't clone $URL (set GH_TOKEN for an account with access)"; exit 2; }
cd $E/a
git worktree add -q ../a-feature feature
git worktree add -q -b hotfix ../a-hotfix main
for d in a a-feature a-hotfix; do $B init -C $E/$d | sed "s/^/  /"; done

step "phase 1: live watchers on clone + 2 linked worktrees"
for d in a a-feature a-hotfix; do $B watch -C $E/$d > $E/$d.log 2>&1 & done
sleep 1

step "1. edit in main checkout (ordinary edit)"
echo "// touched" >> $E/a/src/lib.rs; settle; last a

step "2. git switch -c topic, then switch release (dirty lib.rs carries over)"
git -C $E/a switch -qc topic && git -C $E/a switch -q release; settle; last a 2; verify a

step "3. linked worktree: branch switch (HEAD lives outside the mount)"
git -C $E/a-feature switch -qc feature2 && git -C $E/a-feature switch -q --detach main; settle; last a-feature; verify a-feature

step "4. linked worktree: switch + immediate edit of a file git just wrote; then commit"
git -C $E/a-feature switch -q feature2 && echo "more notes" >> $E/a-feature/docs/feature.md; settle; last a-feature 2
git -C $E/a-feature commit -qam "notes"; settle; last a-feature 2; verify a-feature

step "5. remote push, then git pull --ff in main checkout"
git -C $E/b switch -q release
echo "pub const BUILD: &str = \"$(date +%s%N)\";" > $E/b/src/build_id.rs
git -C $E/b add -A && git -C $E/b commit -qm "build id" && git -C $E/b "${GITC[@]}" push -q origin release
git -C $E/a "${GITC[@]}" pull -q --ff-only; settle; last a; verify a

step "6. hotfix worktree: commit, rebase onto feature, reset --hard"
echo "hotfix" > $E/a-hotfix/HOTFIX.md && git -C $E/a-hotfix add -A && git -C $E/a-hotfix commit -qm hotfix; settle
git -C $E/a-hotfix rebase -q feature; settle; last a-hotfix
git -C $E/a-hotfix reset -q --hard HEAD~1; settle; last a-hotfix; verify a-hotfix

step "7. stash / pop in hotfix (HEAD doesn't move: these ARE edits)"
echo "wip" >> $E/a-hotfix/README.md; settle
git -C $E/a-hotfix stash -q; settle; git -C $E/a-hotfix stash pop -q; settle; last a-hotfix 3; verify a-hotfix

step "8. merge with conflict in a-feature, resolve, commit"
git -C $E/a-feature switch -q -c conflict main
printf 'pub fn add(a: i32, b: i32) -> i32 {\n    b + a\n}\n' > $E/a-feature/src/lib.rs && git -C $E/a-feature commit -qam swap; settle
git -C $E/a-feature merge -q feature >/dev/null 2>&1; settle; last a-feature; verify a-feature
git -C $E/a-feature checkout -q --theirs src/lib.rs && git -C $E/a-feature add -A && git -C $E/a-feature commit -qm merge --no-edit; settle; last a-feature; verify a-feature

step "9. add/remove another worktree while main is watched"
git -C $E/a worktree add -q -b tmp ../a-new main && sleep 1 && git -C $E/a worktree remove ../a-new; settle; last a; verify a

step "10. rapid switches"
for br in main feature2 release topic release; do git -C $E/a switch -q $br 2>/dev/null || git -C $E/a switch -q --discard-changes $br; done; settle; verify a

step "stopping watchers"
kill %1 %2 %3 2>/dev/null; wait 2>/dev/null

step "phase 2: attributed agent commands (0ndb run)"
cd $E/a
step "11. agent scope: real edit + branch switch in one command"
git -C $E/a switch -q release
$B run --agent claude --label "edit+switch" -- sh -c 'echo "# agent" >> scripts/build.sh && git switch -q feature2' 2>&1 | sed 's/^/  /'
verify a
$B changes --agent claude 2>&1 | sed 's/^/  [claude sees] /'

step "12. git while nothing watches, then remount"
git switch -q main; echo "offline" >> README.md
$B log -n 2 2>&1 | sed 's/^/  [a] /'; verify a

step "13. agent edits + commits in one command (commit is not a checkout)"
$B run --agent claude --label "edit+commit" -- sh -c 'echo "agent line" >> README.md && git commit -qam agent-commit' 2>&1 | sed 's/^/  /'
verify a

step "14. agent hits a merge conflict, then resolves it"
git switch -qc clash main && printf 'pub fn add(a: i32, b: i32) -> i32 {\n    b + a\n}\n' > src/lib.rs && git commit -qam clash
$B run --agent claude --label "merge" -- sh -c 'git merge -q feature >/dev/null 2>&1; true' 2>&1 | sed 's/^/  /'
$B run --agent claude --label "resolve" -- sh -c 'printf "pub fn add(a: i32, b: i32) -> i32 {\n    a + b\n}\n" > src/lib.rs && git add -A && git commit -qm merged' 2>&1 | sed 's/^/  /'
verify a

$B log -n 3 2>&1 | sed 's/^/  [a] /'

step "15. agent edits + switches; revert undoes only the edit"
git checkout -q -- . && git switch -q release
$B run --agent claude --label "edit+switch 2" -- sh -c 'echo "# agent2" >> scripts/build.sh && git switch -q feature2' 2>&1 | sed 's/^/  /'
SCOPE=$($B scopes 2>&1 | awk '/edit\+switch 2/ {print $1; exit}')
$B revert --agent claude "$SCOPE" 2>&1 | sed 's/^/  /'
grep -q "# agent2" scripts/build.sh && { echo "  FAIL: agent line still present"; FAIL=1; } || echo "  agent line removed from scripts/build.sh"
[ "$(git rev-parse --abbrev-ref HEAD)" = feature2 ] && [ -f docs/feature.md ] && echo "  still on feature2 with its files (switch kept)" || { echo "  FAIL: switch undone"; FAIL=1; }
[ -z "$(git status --porcelain)" ] && echo "  git status clean" || { echo "  FAIL: git status dirty"; git status --short; FAIL=1; }
verify a

echo; [ $FAIL -eq 0 ] && echo "ALL VERIFIED" || echo "SOME CHECKS FAILED"

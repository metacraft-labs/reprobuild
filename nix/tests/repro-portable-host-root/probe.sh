#!/bin/sh
# `check <name> $?` deliberately reads the status of the test before it.
# shellcheck disable=SC2319
# Runs INSIDE the host-shaped root (see run.sh), as an ordinary user with no
# /nix anywhere. `repro` and `git` resolve from PATH, exactly as a runner job
# or a managed git hook resolves them.
#
# usage: probe.sh <scratch-dir>
# Prints one `PASS <name>` / `FAIL <name>` line per property and exits non-zero
# when any of them failed. run.sh asserts the lines, not just the status, so a
# control that fails for some unrelated reason cannot pass for the right one.
set -u
base=$1
fail=0
note() { printf '%s\n' "$*"; }
check() {
  if [ "$2" = 0 ]; then note "PASS $1"; else note "FAIL $1"; fail=1; fi
}
show() { sed "s/^/  $1| /"; }

export GIT_AUTHOR_NAME=probe GIT_AUTHOR_EMAIL=probe@example.invalid
export GIT_COMMITTER_NAME=probe GIT_COMMITTER_EMAIL=probe@example.invalid
export GIT_PAGER=cat

# ---- fixture: a one-repo workspace with a git-backed origin ----------------
mkdir -p "$base" && cd "$base" || exit 2
git init -q --bare -b main origin.git || exit 2
git init -q -b main seed || exit 2
(cd seed && echo seed > README && git add README && git commit -q -m seed &&
  git push -q "file://$base/origin.git" main) || exit 2
mkdir -p ws/projects ws/repos ws/.repro
git clone -q "file://$base/origin.git" ws/app || exit 2
cat > ws/projects/wsroot.toml <<EOF
schema = "reprobuild.workspace.project.v1"

[project]
name = "wsroot"

[[remote]]
name = "app-origin"
fetch = "file://$base/origin.git"

includes = [
  "repos/app.toml",
]
EOF
cat > ws/repos/app.toml <<'EOF'
schema = "reprobuild.workspace.repo.v2"

[repo]
name = "app"
path = "app"
remote = "app-origin"
mainline = "main"
EOF
cat > ws/.repro/workspace-state.toml <<'EOF'
schema = "reprobuild.workspace.state.v1"

[workspace]
project = "wsroot"
projects = ["wsroot"]
EOF
cd ws/app || exit 2
caller=$(pwd)

# The first run of the bundle extracts the whole closure (minutes on a loaded
# builder). Do it here, outside the per-property timeouts, the way the runner
# image pre-warms it at bake time; `--version` needs neither /bin/sh nor cwd.
out=$(timeout 3600 repro --version 2>&1)
note "$out" | tail -n 1 | show warm

# ---- (1) repro spawns a shell ----------------------------------------------
# `repro ws forall` starts `sh` through PATH; the command then runs the
# absolute `/bin/sh` Nim's execCmd* and the hook bodies use.
out=$(timeout 900 repro ws forall --workspace-root="$base/ws" \
  -c '/bin/sh -c true && echo SPAWNED_BIN_SH_OK' 2>&1)
rc=$?
note "$out" | show forall
[ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q 'SPAWNED_BIN_SH_OK'
check "repro-spawns-bin-sh" $?

# ---- (2) repro starts in the caller's directory ----------------------------
# With no selector, `repro exec` looks for the dev-env module in the current
# directory and names the path it looked at: that path is repro's cwd.
out=$(timeout 900 repro exec -- true 2>&1)
note "$out" | head -n 3 | show exec
printf '%s\n' "$out" | grep -q "not found: $caller/reprobuild.nim"
check "repro-cwd-is-caller-cwd" $?

# ---- (3) a real hooks ensure + git checkout round trip ---------------------
# No path argument: ensure resolves the repo from its cwd, as `.envrc` and the
# workspace docs run it.
out=$(timeout 900 repro hooks ensure --vcs 2>&1)
rc=$?
note "$out" | tail -n 3 | show ensure
[ "$rc" = 0 ] && [ -f .git/hooks/post-checkout.repro-managed ] &&
  [ -f "$caller/.git/hooks/post-checkout" ]
check "hooks-ensure-installs-post-checkout" $?

# A checkout that leaves HEAD where it was is skipped by the hook before it
# does any work, so move HEAD between two different commits. The managed
# post-checkout body hands over to `repro hooks dispatch post-checkout`, which
# appends to the manifest-refresh log: a new line there is the evidence that
# the dispatch ran to completion, not merely that git exited 0.
git checkout -q -b feature 2>/dev/null
echo feature > F && git add F && git commit -q -m feature 2>/dev/null
log="${XDG_CACHE_HOME:-$HOME/.cache}/repro/manifest-refresh.log"
before=$(grep -c 'post-checkout' "$log" 2>/dev/null || true)
out=$(timeout 900 git checkout main 2>&1)
rc=$?
note "$out" | show checkout
after=$(grep -c 'post-checkout' "$log" 2>/dev/null || true)
[ "$rc" = 0 ] &&
  ! printf '%s\n' "$out" | grep -qi 'no such file\|could not be evaluated\|refus' &&
  [ "${after:-0}" -gt "${before:-0}" ]
check "git-checkout-dispatches-post-checkout" $?

exit "$fail"

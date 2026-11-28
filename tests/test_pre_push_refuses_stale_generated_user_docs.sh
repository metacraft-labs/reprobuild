#!/usr/bin/env bash
# A push of a commit that changes the CLI description without regenerating the
# user docs rendered from it is refused at the push, and the refusal names the
# stale page and the command that regenerates it.
#
# The defect this guards: reprobuild `c709357a70` (2026-11-25) added two verbs
# to `repro nimble` without regenerating
# docs/users/content/reference/commands/index.md. `agents` has no CI, and the
# push-time gate (scripts/pre_push_suite_checks.sh) did not run
# `scripts/render_user_docs_generated.py --check`, so the commit landed, and
# from then on `just lint` refused every later commit at its docs step,
# whatever that commit changed.
#
# Works on a scratch clone of a snapshot of this working tree (tracked and
# untracked, ignored files left out), so it exercises the gate being edited.
# It runs the gate script the installed pre-push hook runs, with the commit
# being pushed in PRE_COMMIT_TO_REF as pre-commit passes it. That the dev
# shell installs a pre-push hook which runs this script is asserted by
# tests/test_pre_push_refuses_stale_suite_artifacts.sh; going through the
# installed hook here as well would only repeat that. The gate runs with a
# PATH that holds git, nix and coreutils-class tools but no python3, so a gate
# that ran the docs check on the ambient PATH fails for a missing tool.
#
# No mocks: the real generator, the real CLI description and the real dev
# shell.
#
# Asserted:
#   - red: a commit that renames a `repro nimble` verb in the CLI description
#     and leaves the command index alone is refused, naming
#     docs/users/content/reference/commands/index.md and
#     scripts/render_user_docs_generated.py;
#   - green: the commit that regenerates the page is accepted;
#   - red again: with that clean commit checked out, the stale commit pushed
#     by name is still refused -- the pushed commit is judged, not the
#     checkout.
#
# Each push runs the two-minute source scans, so this takes several minutes.
#
#   bash tests/test_pre_push_refuses_stale_generated_user_docs.sh
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'chmod -R u+w "$SCRATCH" 2>/dev/null; rm -rf "$SCRATCH"' EXIT
fail() {
	echo "FAIL: $*" >&2
	exit 1
}

CLI_DESC=libs/repro_cli_support/src/repro_cli_support/cli_description.nim
COMMANDS_PAGE=docs/users/content/reference/commands/index.md

# Snapshot the working tree into an unreferenced commit, without touching the
# repository's index or refs.
GIT_INDEX_FILE="$SCRATCH/index" git -C "$REPO" read-tree HEAD
GIT_INDEX_FILE="$SCRATCH/index" git -C "$REPO" add -A
tree="$(GIT_INDEX_FILE="$SCRATCH/index" git -C "$REPO" write-tree)"
snapshot="$(git -C "$REPO" -c user.name=t -c user.email=t@t commit-tree "$tree" -p HEAD -m snapshot)"
clone="$SCRATCH/reprobuild"
mkdir -p "$SCRATCH/no-hooks"
git clone -q --shared --no-checkout "$REPO" "$clone"
# Hooks off for everything the test itself does in the clone: the commits are
# the ones a bypassed commit-time lint lets through, and the gate under test
# is invoked directly below.
git -C "$clone" config core.hooksPath "$SCRATCH/no-hooks"
git -C "$clone" checkout -q -b hook-test "$snapshot"
git -C "$clone" config user.name t
git -C "$clone" config user.email t@t

# The push-time PATH: no python3 on it.
minbin="$SCRATCH/bin"
mkdir -p "$minbin"
for tool in git nix bash sh env cat dirname basename grep sed awk mktemp rm \
	mkdir ls head tail tr date readlink realpath uname id chmod cp mv find sort \
	wc cut stat touch tee xargs; do
	if path="$(command -v "$tool" 2>/dev/null)" && [[ $path == /* ]]; then
		ln -s "$path" "$minbin/$tool"
	fi
done
[ ! -e "$minbin/python3" ] || fail "the restricted PATH carries python3"
push() {
	(cd "$clone" && env PATH="$minbin" PRE_COMMIT_TO_REF="$1" \
		bash scripts/pre_push_suite_checks.sh 2>&1)
}
no_ambient_tool() {
	if grep -qE 'python3: (command )?not found' <<<"$1"; then
		fail "the push gate reached for python3 on the ambient PATH: $(grep -E 'not found' <<<"$1" | head -3)"
	fi
}
regenerate() {
	(cd "$clone/scripts" && nix develop "$clone" --no-write-lock-file -c bash -euo pipefail -c '
		cd ..
		python3 scripts/render_user_docs_generated.py
	') >"$SCRATCH/regen.log" 2>&1 || fail "regenerating the user docs failed: $(tail -20 "$SCRATCH/regen.log")"
}

# Red: a verb renamed in the CLI description, the command index not
# regenerated -- the shape of `c709357a70`.
grep -qF 'subcmd "gitlink-audit",' "$clone/$CLI_DESC" ||
	fail "the CLI description no longer declares the nimble 'gitlink-audit' verb this test renames; pick another verb"
grep -qF "\`gitlink-audit\`" "$clone/$COMMANDS_PAGE" ||
	fail "$COMMANDS_PAGE does not list 'gitlink-audit', so renaming it would not make the page stale"
sed -i 's/subcmd "gitlink-audit",/subcmd "gitlink-report",/' "$clone/$CLI_DESC"
git -C "$clone" commit -q -am "red: a CLI verb renamed without regenerating the docs"
stale="$(git -C "$clone" rev-parse HEAD)"
if red_output="$(push "$stale")"; then
	fail "a push of a commit that changes the CLI description without regenerating $COMMANDS_PAGE was accepted: $(tail -20 <<<"$red_output")"
fi
no_ambient_tool "$red_output"
grep -qF "$COMMANDS_PAGE is stale" <<<"$red_output" ||
	fail "the refusal does not name $COMMANDS_PAGE as stale: $(tail -30 <<<"$red_output")"
grep -qF 'python3 scripts/render_user_docs_generated.py' <<<"$red_output" ||
	fail "the refusal does not name the regeneration command: $(tail -30 <<<"$red_output")"

# Green: the regeneration, committed.
regenerate
git -C "$clone" diff --quiet -- "$COMMANDS_PAGE" &&
	fail "regenerating did not change $COMMANDS_PAGE, so the red commit was not stale for the reason this test states"
grep -qF "\`gitlink-report\`" "$clone/$COMMANDS_PAGE" ||
	fail "the regenerated $COMMANDS_PAGE does not list the renamed verb"
git -C "$clone" commit -q -am "green: the regeneration"
clean="$(git -C "$clone" rev-parse HEAD)"
green_output="$(push "$clean")" ||
	fail "a push of the regenerated commit was refused: $(tail -40 <<<"$green_output")"
no_ambient_tool "$green_output"

# Red again: the checkout is clean and current, the pushed commit is not.
if again_output="$(push "$stale")"; then
	fail "with the regenerated commit checked out, a push of the stale commit by name was accepted"
fi
no_ambient_tool "$again_output"
grep -qF "$COMMANDS_PAGE is stale" <<<"$again_output" ||
	fail "the second refusal does not name $COMMANDS_PAGE: $(tail -30 <<<"$again_output")"

[ "$(git -C "$clone" worktree list --porcelain | grep -c '^worktree ')" = 1 ] ||
	fail "the gate left a temporary worktree registered: $(git -C "$clone" worktree list)"

echo "PASS: a push of a CLI change without the regenerated user docs is refused naming the page and the generator; the pushed commit, not the checkout, is judged"

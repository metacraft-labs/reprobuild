#!/usr/bin/env bash
# A push of a commit whose tree-derived suite artifacts are stale is refused
# at the push, and the refusal names `just regen-suite-artifacts`.
#
# The defect this guards: commits that added test cases without regenerating
# the case-count baseline reached `agents` twice in two days (2026-11-26,
# 2026-11-27), because `agents` has no CI and no
# checkout ran the suite checks at the push. They were declared at the
# `pre-push` stage only in flake.nix's git-hooks.nix set, which is never
# installed; the hooks a checkout gets are the committed
# .pre-commit-config.yaml's, and that asked for no pre-push hook type.
#
# Works on a scratch clone of a snapshot of this working tree (tracked and
# untracked, ignored files left out), so it exercises the hook configuration
# being edited. The hooks are installed the way a contributor gets them: by
# entering the dev shell from the checkout.
#
# The installed pre-push hook is invoked directly, with git's pre-push
# arguments and ref lines, rather than through `git push`: a real push would
# go on to run Reprobuild's managed publication gate, which writes to the
# shared lock store. The dispatcher runs `pre-push.repro-local` first and
# stops the push when it fails (the dispatcher in .git/hooks/pre-push), so the
# hook's exit status is the push's verdict. Every invocation runs with a PATH
# that holds git, nix and coreutils-class tools but no python3, so a hook that
# ran the checks on the ambient PATH fails for a missing tool.
#
# The commits are made with --no-verify: the commit-time `just lint` is the
# hook that gets bypassed, and the push gate has to hold regardless.
#
# Asserted:
#   - entering the dev shell installs a pre-push hook that runs the
#     committed config at the pre-push stage;
#   - red: pushing a commit that adds a test case without regenerating is
#     refused, and the refusal names the source whose count moved and
#     `just regen-suite-artifacts`;
#   - green: pushing the commit that regenerates the artifacts is accepted,
#     although the working tree holds an untracked, unenrolled test source
#     that the inventory's tree walk refuses in place (a control shows it
#     does) -- the pushed commit is judged, not the checkout;
#   - red again: with that clean commit checked out, pushing the stale commit
#     by name is still refused.
#
# Each push runs the two-minute source scans, so this takes several minutes.
#
#   bash tests/test_pre_push_refuses_stale_suite_artifacts.sh
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'chmod -R u+w "$SCRATCH" 2>/dev/null; rm -rf "$SCRATCH"' EXIT
fail() {
	echo "FAIL: $*" >&2
	exit 1
}

# Snapshot the working tree into an unreferenced commit, without touching the
# repository's index or refs.
GIT_INDEX_FILE="$SCRATCH/index" git -C "$REPO" read-tree HEAD
GIT_INDEX_FILE="$SCRATCH/index" git -C "$REPO" add -A
tree="$(GIT_INDEX_FILE="$SCRATCH/index" git -C "$REPO" write-tree)"
snapshot="$(git -C "$REPO" -c user.name=t -c user.email=t@t commit-tree "$tree" -p HEAD -m snapshot)"
clone="$SCRATCH/reprobuild"
git clone -q --shared --no-checkout "$REPO" "$clone"
git -C "$clone" checkout -q -b hook-test "$snapshot"
git -C "$clone" config user.name t
git -C "$clone" config user.email t@t

(cd "$clone" && nix develop "$clone" --no-write-lock-file -c true) >/dev/null 2>&1 ||
	fail "the dev shell did not start from the scratch clone"
hooks_dir="$(git -C "$clone" rev-parse --path-format=absolute --git-path hooks)"
hook=""
for candidate in "$hooks_dir/pre-push.repro-local" "$hooks_dir/pre-push"; do
	if grep -qs -- '--config .pre-commit-config.yaml --hook-type pre-push' "$candidate"; then
		hook="$candidate"
		break
	fi
done
[ -n "$hook" ] ||
	fail "entering the dev shell installed no pre-push hook that runs the committed config (looked at $hooks_dir/pre-push and pre-push.repro-local)"

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
# push SHA: invoke the installed hook as git would for
# `git push origin <SHA>:refs/heads/agents` over a remote that holds the
# snapshot.
push() {
	(cd "$clone" && printf 'refs/heads/hook-test %s refs/heads/agents %s\n' "$1" "$snapshot" |
		env PATH="$minbin" "$hook" origin "$REPO" 2>&1)
}
no_ambient_tool() {
	if grep -qE '(python3|pre-commit): (command )?not found' <<<"$1"; then
		fail "the push hook reached for a tool on the ambient PATH: $(grep -E 'not found' <<<"$1" | head -3)"
	fi
}

# Red: a test case added, the artifacts not regenerated.
# A source whose cases the baseline counts: the first recorded Nim source
# that has a top-level suite case to insert ahead of.
target=""
while IFS=$'\t' read -r source language count; do
	[ "$language" = nim ] && [ "$count" -gt 0 ] 2>/dev/null || continue
	if grep -qE '^  test "' "$clone/$source" 2>/dev/null; then
		target="$source"
		break
	fi
done < <(grep -v '^#' "$clone/scripts/reprobuild-suite-static-case-counts.tsv")
[ -n "$target" ] || fail "no recorded test source with a top-level suite case to modify"
awk '!done && /^  test "/ {
		print "  test \"a case added without regenerating the suite artifacts\":"
		print "    check 1 + 1 == 2"
		print ""
		done = 1
	}
	{ print }' "$clone/$target" >"$SCRATCH/red.nim"
mv "$SCRATCH/red.nim" "$clone/$target"
git -C "$clone" add -- "$target"
git -C "$clone" commit -q --no-verify -m "red: a case without the regeneration"
stale="$(git -C "$clone" rev-parse HEAD)"
if red_output="$(push "$stale")"; then
	fail "a push of a commit that adds a case to $target without regenerating was accepted: $(tail -20 <<<"$red_output")"
fi
no_ambient_tool "$red_output"
grep -qF "$target" <<<"$red_output" ||
	fail "the refusal does not name $target, whose case count moved: $(tail -30 <<<"$red_output")"
grep -qF 'just regen-suite-artifacts' <<<"$red_output" ||
	fail "the refusal does not name just regen-suite-artifacts: $(tail -30 <<<"$red_output")"

# Green: the regeneration, committed. The writers run in the dev shell, as a
# contributor runs them.
(cd "$clone/scripts" && nix develop "$clone" --no-write-lock-file -c bash -euo pipefail -c '
	cd ..
	python3 scripts/reprobuild_suite_inventory.py --write-static-case-counts
	python3 scripts/reprobuild_suite_inventory.py --write-inventory-sources
') >"$SCRATCH/regen.log" 2>&1 || fail "regenerating the artifacts failed: $(tail -20 "$SCRATCH/regen.log")"
git -C "$clone" add -A
git -C "$clone" commit -q --no-verify -m "green: the regeneration"
clean="$(git -C "$clone" rev-parse HEAD)"
# Untracked and unenrolled: judged in place, the tree walk would refuse it.
mkdir -p "$clone/tests/unit"
printf 'import unittest\n\nsuite "untracked":\n  test "not enrolled":\n    check 1 + 1 == 2\n' \
	>"$clone/tests/unit/t_untracked_scratch_source.nim"
green_output="$(push "$clean")" ||
	fail "a push of the regenerated commit was refused: $(tail -40 <<<"$green_output")"
no_ambient_tool "$green_output"
grep -q 'suite description and generated docs match the pushed tree' <<<"$green_output" ||
	fail "the push did not run the suite-description hook: $green_output"
# Control: judged in place, the checkout IS refused, so the pass above came
# from checking the pushed commit apart from the untracked source.
if (cd "$clone/scripts" && nix develop "$clone" --no-write-lock-file -c bash -euo pipefail -c '
	cd ..
	python3 scripts/reprobuild_suite_inventory.py --check-declared-sources
') >"$SCRATCH/control.log" 2>&1; then
	fail "control: the untracked source is not refused in place, so the green push proves nothing about which tree was judged"
fi
grep -qF 't_untracked_scratch_source.nim' "$SCRATCH/control.log" ||
	fail "control: the in-place refusal does not name the untracked source: $(tail -10 "$SCRATCH/control.log")"
rm -f "$clone/tests/unit/t_untracked_scratch_source.nim"

# Red again: the checkout is clean and current, the pushed commit is not.
if again_output="$(push "$stale")"; then
	fail "with the regenerated commit checked out, a push of the stale commit by name was accepted"
fi
no_ambient_tool "$again_output"
grep -qF "$target" <<<"$again_output" ||
	fail "the second refusal does not name $target: $(tail -30 <<<"$again_output")"

[ "$(git -C "$clone" worktree list --porcelain | grep -c '^worktree ')" = 1 ] ||
	fail "the hook left a temporary worktree registered: $(git -C "$clone" worktree list)"

echo "PASS: a push of stale suite artifacts is refused naming just regen-suite-artifacts; the pushed commit, not the checkout, is judged"

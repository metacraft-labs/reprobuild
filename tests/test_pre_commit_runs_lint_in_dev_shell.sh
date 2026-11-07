#!/usr/bin/env bash
# A commit runs `just lint` inside this repository's dev shell, and a commit
# that `just lint` refuses does not land.
#
# Works on a scratch clone of a snapshot of this working tree (tracked and
# untracked, ignored files left out), so it exercises the hook configuration
# being edited rather than the last committed one. The hooks are installed the
# way a contributor gets them: by entering the dev shell from the checkout.
#
# Every commit runs with a PATH that holds git, nix, the git credential tools
# (`just lint` asks GitHub whether .github/sibling-repos' refs exist) and
# coreutils-class tools, but none of the lint toolchain (just, nim, python3,
# actionlint, shellcheck).
# A hook that ran the lint on the ambient PATH fails there for a missing tool;
# one that runs it in the dev shell takes every tool from the pinned shell.
#
# Asserted:
#   - red: a commit adding an unconditional bare `skip()` to an existing test
#     case is refused, HEAD does not move, and the refusal names the bare-skip
#     check;
#   - green: a commit that changes nothing `just lint` objects to lands;
#   - the commit does not reinstall the git hooks (the hook enters the shell
#     outside the checkout's top level, where the shell installs nothing).
#
# Each commit runs the full lint, so this takes minutes.
#
#   bash tests/test_pre_commit_runs_lint_in_dev_shell.sh
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
grep -qs -- '--config .pre-commit-config.yaml' "$hooks_dir/pre-commit" "$hooks_dir/pre-commit.repro-local" ||
	fail "entering the dev shell installed no pre-commit hook that runs the committed config"
hooks_before="$(cd "$hooks_dir" && stat -c '%n %Y %s' -- * | sort)"

# The commit-time PATH: no lint tool on it.
minbin="$SCRATCH/bin"
mkdir -p "$minbin"
for tool in git nix bash sh env cat dirname basename grep sed awk mktemp rm \
	mkdir ls head tail tr date readlink realpath uname id chmod cp mv find sort \
	wc cut stat touch tee xargs repro gh ssh; do
	if path="$(command -v "$tool" 2>/dev/null)" && [[ $path == /* ]]; then
		ln -s "$path" "$minbin/$tool"
	fi
done
for tool in just nim python3 actionlint shellcheck; do
	[ ! -e "$minbin/$tool" ] || fail "the restricted PATH carries $tool"
done
commit() { (cd "$clone" && env PATH="$minbin" git commit -q -m "$1" 2>&1); }

# Red: a bare skip() in an existing test case.
target="$(cd "$clone" && git grep -lE '^  test "' -- 'tests/*.nim' | awk 'NR == 1')"
[ -n "$target" ] || fail "no test source with a top-level suite case to modify"
awk '!done && /^  test "/ { print; print "    skip()"; done = 1; next } { print }' \
	"$clone/$target" >"$SCRATCH/red.nim"
mv "$SCRATCH/red.nim" "$clone/$target"
git -C "$clone" add -- "$target"
head_before="$(git -C "$clone" rev-parse HEAD)"
if red_output="$(commit "red: bare skip")"; then
	fail "a commit adding a bare skip() to $target was accepted"
fi
[ "$(git -C "$clone" rev-parse HEAD)" = "$head_before" ] ||
	fail "the refused commit moved HEAD"
grep -q 'bare' <<<"$red_output" ||
	fail "the refusal does not come from the bare-skip check: $(tail -20 <<<"$red_output")"
if grep -qE '(just|nim|python3|actionlint|shellcheck): (command )?not found' <<<"$red_output"; then
	fail "the lint reached for a tool on the ambient PATH: $(grep -E 'not found' <<<"$red_output" | head -3)"
fi
git -C "$clone" reset -q --hard HEAD

# Green: a change the lint has nothing to say about.
printf '\n' >>"$clone/README.md"
git -C "$clone" add README.md
green_output="$(commit "green: clean change")" ||
	fail "a clean commit was refused: $(tail -30 <<<"$green_output")"
[ "$(git -C "$clone" rev-parse HEAD^)" = "$head_before" ] ||
	fail "the clean commit did not land on top of the previous HEAD"
grep -q 'just lint' <<<"$green_output" ||
	fail "the clean commit did not run the lint hook: $green_output"

[ "$(cd "$hooks_dir" && stat -c '%n %Y %s' -- * | sort)" = "$hooks_before" ] ||
	fail "a commit rewrote the git hooks"

echo "PASS: a commit runs just lint in the dev shell; a bare skip() is refused, a clean change lands"

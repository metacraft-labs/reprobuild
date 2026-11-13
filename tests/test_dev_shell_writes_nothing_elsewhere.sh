#!/usr/bin/env bash
# The dev shell installs this repository's committed .pre-commit-config.yaml
# as its pre-commit hook, and writes nothing into any other repository.
#
# The shell's hook (flake.nix, guarded by scripts/is_reprobuild_checkout.sh)
# installs git hooks into `git rev-parse --show-toplevel` of the CURRENT
# DIRECTORY. `nix develop /path/to/this-repo` is also how other projects borrow
# this toolchain, so entered from anywhere but this checkout it must write
# nothing.
#
# Asserted, from a scratch git repository and from a subdirectory of it: no
# file or directory appears, no hook is installed and `core.hooksPath` is
# untouched. As the positive control, entered from this repository the
# committed `.pre-commit-config.yaml` is left byte-identical and a pre-commit
# hook (the slot itself, or its `.repro-local` chain under a Reprobuild
# dispatcher) runs it.
#
#   bash tests/test_dev_shell_writes_nothing_elsewhere.sh
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
fail() {
	echo "FAIL: $*" >&2
	exit 1
}

git -C "$SCRATCH" init -q
git -C "$SCRATCH" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
mkdir -p "$SCRATCH/sub"
hooks_before="$(ls "$SCRATCH/.git/hooks")"

for dir in "$SCRATCH" "$SCRATCH/sub"; do
	(cd "$dir" && nix develop "$REPO" --no-write-lock-file -c true) >/dev/null 2>&1 ||
		fail "the dev shell did not start from $dir"
	[ -z "$(git -C "$SCRATCH" status --porcelain --ignored)" ] ||
		fail "entered from $dir: files were written into the other repository: $(git -C "$SCRATCH" status --porcelain --ignored | tr '\n' ' ')"
	# git status does not list empty directories.
	extra="$(cd "$SCRATCH" && find . -mindepth 1 -path ./.git -prune -o ! -path ./sub -print)"
	[ -z "$extra" ] || fail "entered from $dir: entries were created in the other repository: ${extra//$'\n'/ }"
	[ "$(ls "$SCRATCH/.git/hooks")" = "$hooks_before" ] ||
		fail "entered from $dir: git hooks were installed into the other repository"
	[ -z "$(git -C "$SCRATCH" config --local --get core.hooksPath || true)" ] ||
		fail "entered from $dir: the other repository's core.hooksPath was changed"
done

# Positive control: the guard must not stop the hook in this repository.
config_before="$(git -C "$REPO" hash-object .pre-commit-config.yaml)"
hooks_dir="$(git -C "$REPO" rev-parse --path-format=absolute --git-path hooks)"
output="$(cd "$REPO" && nix develop "$REPO" --no-write-lock-file -c true 2>&1)" ||
	fail "the dev shell did not start from this repository"
[ -f "$REPO/.pre-commit-config.yaml" ] && [ ! -L "$REPO/.pre-commit-config.yaml" ] &&
	[ "$(git -C "$REPO" hash-object .pre-commit-config.yaml)" = "$config_before" ] ||
	fail "control: the committed .pre-commit-config.yaml was replaced or changed"
if grep -q 'Refusing to install' <<<"$output"; then
	fail "control: an installer refused the committed config: $(grep 'Refusing to install' <<<"$output")"
fi
grep -qs -- '--config .pre-commit-config.yaml' "$hooks_dir/pre-commit" "$hooks_dir/pre-commit.repro-local" ||
	fail "control: entered from this repository, no pre-commit hook runs the committed config"

echo "PASS: entered from another repository the dev shell writes nothing there; from this one it installs the committed config as the pre-commit hook"

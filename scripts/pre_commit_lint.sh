#!/usr/bin/env bash
# The commit-time `just lint`, run inside this repository's dev shell.
#
# `.pre-commit-config.yaml` runs this on every commit. The lint's verdict
# depends on its tools (nim, python3, actionlint, shellcheck, just itself), so
# they must come from the shell `flake.nix` pins, never from whatever PATH the
# contributor commits from: the same tree would otherwise pass in one terminal
# and fail in another.
#
# The shell is entered from `scripts/`, not from the top level. Entered from
# the top level, the shell hook installs the git hooks and runs `repro hooks
# ensure` (guarded by scripts/is_reprobuild_checkout.sh); a commit must not
# rewrite the hooks that are running it. Everything else about the shell is
# the same from a subdirectory: the sibling-checkout rebinding keys on `git
# rev-parse --show-toplevel`, which a subdirectory answers identically. `just`
# runs the recipe in the Justfile's directory, so the lint sees the whole tree.
#
# pre-commit stashes unstaged changes before running hooks, so the tree this
# lints is the tree being committed.
#
# THE REGENERATION-ONLY COMMIT. The generated suite artifacts (the `-merge`
# paths in .gitattributes) are pure functions of the tree, and nearly every
# commit on `agents` rewrites them, so catching a branch up with `agents`
# always conflicts on them and needs a commit of its own. When that commit's
# only authored content is those artifacts, the full lint (~1.5 h) has
# nothing to grade that the commits it joins were not already graded on, and
# a branch could not land at all while `agents` moved faster than one lint
# (2026-11-20: four catch-up rounds lost that race). Such a commit runs the
# gates that grade the artifacts instead:
#   * a non-merge commit whose staged change touches only those paths, or
#   * a merge whose conflicts were only in those paths and whose staged tree
#     differs from git's own merge result only in those paths.
# Anything else -- one authored line anywhere else -- runs the full lint.
#
# The shell is entered through a profile in the checkout's git directory
# (scripts/lib/rooted_dev_shell.sh), so its whole closure -- the MinGW
# compiler of the Windows C stage among it -- holds a permanent GC root while
# the lint runs. A plain `nix develop --command` leaves only a temporary root
# that is dropped when nix execs the command, and on a host below Nix's
# `min-free` the automatic GC then collects the lint's own tools under it.
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

generated_paths=(
	repro_tests.nim
	scripts/reprobuild-test-shape-parity.tsv
	scripts/reprobuild-suite-static-case-counts.tsv
	benchmarks/reports/reprobuild-suite-m0-inventory-sources.json
)

only_generated() {
	# Reads paths on stdin; true when every one is a generated path and there
	# is at least one.
	local seen=0 path g ok
	while IFS= read -r path; do
		[ -n "$path" ] || continue
		ok=0
		for g in "${generated_paths[@]}"; do
			[ "$path" = "$g" ] && ok=1
		done
		[ "$ok" = 1 ] || return 1
		seen=1
	done
	[ "$seen" = 1 ]
}

lock_taken_from_a_parent() {
	# Passes paths through, except repro.lock when the staged copy is one
	# parent's copy byte for byte: taking a side of the lock authors nothing,
	# and the pre-push gate refreshes the lock against the merged tree. A
	# hand-edited lock stays in the list and so takes the full lint.
	local path staged
	while IFS= read -r path; do
		if [ "$path" = repro.lock ]; then
			staged="$(git rev-parse :repro.lock 2>/dev/null || true)"
			if [ -n "$staged" ] && { [ "$staged" = "$(git rev-parse HEAD:repro.lock)" ] ||
				[ "$staged" = "$(git rev-parse MERGE_HEAD:repro.lock)" ]; }; then
				continue
			fi
		fi
		printf '%s\n' "$path"
	done
}

regeneration_only() {
	cd "$repo_root"
	local git_dir
	git_dir="$(git rev-parse --git-dir)"
	if [ -f "$git_dir/MERGE_HEAD" ]; then
		local merged conflicts
		# `merge-tree` exits 1 when there are conflicts and prints the tree
		# first, then the conflicted paths.
		merged="$(git merge-tree --write-tree --name-only HEAD MERGE_HEAD)" || true
		conflicts="$(printf '%s\n' "$merged" | sed -n '2,/^$/p' | lock_taken_from_a_parent)"
		printf '%s\n' "$conflicts" | only_generated || return 1
		# The staged tree must be git's own merge everywhere else.
		local base_tree staged_tree
		base_tree="$(printf '%s\n' "$merged" | head -n 1)"
		staged_tree="$(git write-tree)"
		git diff --name-only "$base_tree" "$staged_tree" | lock_taken_from_a_parent | only_generated
	else
		git rev-parse -q --verify HEAD >/dev/null || return 1
		git diff --cached --name-only HEAD | only_generated
	fi
}

# shellcheck source=scripts/lib/rooted_dev_shell.sh
source "$repo_root/scripts/lib/rooted_dev_shell.sh"
profile="$(rooted_dev_shell_profile "$repo_root")"
cd "$repo_root/scripts"
if (regeneration_only); then
	echo "pre_commit_lint: only generated suite artifacts are authored here; running the gates that grade them, not the full lint"
	# The generator rewrites repro_tests.nim in place; pre-commit fails the
	# commit if that changes the tree, which is the check that the committed
	# edge table is the generator's.
	# shellcheck disable=SC2016 # expanded by the inner bash, from "$1"
	rooted_dev_shell_exec "$profile" "$repo_root" --no-write-lock-file --command bash -euo pipefail -c '
		cd "$1"
		nim r --hints:off scripts/generate_test_edges.nim
		python3 ./scripts/reprobuild_suite_inventory.py --check-static-case-counts
		python3 ./scripts/reprobuild_suite_inventory.py --check-inventory
		python3 ./scripts/reprobuild_suite_inventory.py --check-declared-sources
		python3 ./scripts/reprobuild_suite_inventory.py --check-shape-parity
	' _ "$repo_root"
fi
rooted_dev_shell_exec "$profile" "$repo_root" --no-write-lock-file --command \
	just --justfile "$repo_root/Justfile" lint

#!/usr/bin/env bash
# The push-time gates over checked-in generated files, run on the PUSHED
# commit inside this repository's dev shell.
#
# `.pre-commit-config.yaml` runs this at the `pre-push` stage. It runs the
# build-free source scans that judge files derived from other files in the
# tree, and refuses the push when any finds drift:
#
#   * scripts/check_suite_case_counts.sh -- the static case-count baseline,
#     the source half of the inventory, the declared-source walk, the
#     edge-generator shape parity and the `ct test` addressability ledger;
#   * scripts/check_vacuous_test_cases.py -- no case that asserts only
#     `check true`;
#   * scripts/render_user_docs_generated.py --check -- the generated regions
#     of the user docs (the command tables rendered from the CLI description,
#     the `repro health` table, the installer help) and llms.txt match the
#     sources they are rendered from. A CLI change that skipped the
#     regeneration reached `agents` (reprobuild `c709357a70`, 2026-11-25),
#     and from then on `just lint` refused every later commit at its docs
#     step, whatever the commit changed.
#
# WHY AT THE PUSH. `agents` has no CI, so its gates are the ones run on the
# pushing machine (metacraft-dev-guidelines branching-policy.md, "Product
# repos with an `agents` branch"). The commit-time `just lint` runs the same
# checks, but it takes over an hour and is the hook that gets bypassed; twice
# in two days (reprobuild `3452e1bc4`, `24b330f23`) a commit that added test
# cases without `just regen-suite-artifacts` reached `agents`, and every later
# pusher inherited the red check.
# These scans cost about two minutes and no build (the docs check is Python
# over source files and takes seconds), which is what makes them affordable at
# every push.
#
# Both hooks were declared at the `pre-push` stage in flake.nix's
# git-hooks.nix set from the start, but that set is never installed: the dev
# shell installs THIS repository's committed `.pre-commit-config.yaml`
# (scripts/install-git-hooks.sh), which carried no pre-push hook and asked for
# no pre-push hook type. So no checkout ever ran them at the push.
#
# WHAT IS CHECKED IS THE PUSHED COMMIT. pre-commit hands a pre-push hook the
# commit being pushed in $PRE_COMMIT_TO_REF. When that is HEAD and the working
# tree has nothing git would report (no tracked edit, no untracked file), the
# working tree IS the pushed tree and the checks run in place. Otherwise --
# `git push origin other:agents`, or an untracked scratch test the inventory's
# tree walk would count -- the pushed commit is checked out into a temporary
# worktree and the checks run there, so a push is judged by what it
# publishes, never by what happens to be lying in the checkout. The
# temporary worktree is created with hooks switched off: it must not run this
# repository's post-checkout hooks, which repair hook installations.
#
# Which commit that is, is pre-commit's choice (`hook-impl`, `_pre_push_ns`):
# the FIRST ref line that is not a deletion and carries commits the remote
# lacks. A deletion, or a branch or tag whose commits the remote already has,
# runs nothing. An annotated tag arrives as the tag object and is peeled to
# its commit below. A push of several refs at once is judged by its first
# such ref alone, so push `agents` on its own.
#
# The checks come from the pushed tree too: a commit that edits a check is
# judged by its own version of it, as CI would judge it.
#
# TOOLS. The checks' verdicts depend on python3 and git, so they run in the
# dev shell flake.nix pins, never on the PATH the push happens to come from.
# The shell is entered from `scripts/` for the reason scripts/pre_commit_lint.sh
# gives (entered from the top level it reinstalls the hooks that are running
# it), through a GC-rooted profile (scripts/lib/rooted_dev_shell.sh).
#
#   scripts/pre_push_suite_checks.sh            # from a pre-push hook
#   PRE_COMMIT_TO_REF=<rev> scripts/pre_push_suite_checks.sh
#
# Exit codes: 0 -- the pushed commit's suite description and generated user
# docs match its tree; non-zero -- they do not (the checks name what moved and
# how to regenerate), or the pushed commit could not be checked out.
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# Run by hand, with no pre-push context, it checks HEAD.
pushed="${PRE_COMMIT_TO_REF:-HEAD}"
if ! pushed_sha="$(git rev-parse --verify --quiet "${pushed}^{commit}")"; then
	echo "pre_push_suite_checks: '${pushed}' (the commit being pushed) is not a commit in ${repo_root}" >&2
	exit 1
fi

check_root="$repo_root"
scratch=""
cleanup() {
	[ -n "$scratch" ] || return 0
	git -C "$repo_root" worktree remove --force "$scratch/tree" >/dev/null 2>&1 || true
	rm -rf -- "$scratch"
	git -C "$repo_root" worktree prune >/dev/null 2>&1 || true
}
# A signal ends the script (with the conventional 128+N status) instead of
# returning into it, so an interrupted push never goes on to run the checks
# against a worktree the handler has just removed; EXIT then cleans up.
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
if [ "$pushed_sha" != "$(git rev-parse HEAD)" ] ||
	[ -n "$(git status --porcelain --untracked-files=normal)" ]; then
	scratch="$(mktemp -d "${TMPDIR:-/tmp}/reprobuild-pre-push-checks.XXXXXX")"
	mkdir -p "$scratch/no-hooks"
	echo "pre_push_suite_checks: the working tree is not the pushed commit; checking $(git rev-parse --short "$pushed_sha") in a temporary worktree"
	git -c core.hooksPath="$scratch/no-hooks" worktree add --quiet --detach \
		"$scratch/tree" "$pushed_sha"
	check_root="$scratch/tree"
fi

# shellcheck source=scripts/lib/rooted_dev_shell.sh
source "$repo_root/scripts/lib/rooted_dev_shell.sh"
profile="$(rooted_dev_shell_profile "$repo_root")"
cd "$repo_root/scripts"
# A subshell, because rooted_dev_shell_exec execs: the temporary worktree must
# still be removed when the checks return.
# shellcheck disable=SC2016 # expanded by the inner bash, from "$1"
(rooted_dev_shell_exec "$profile" "$repo_root" --no-write-lock-file --command bash -euo pipefail -c '
	cd "$1"
	status=0
	bash scripts/check_suite_case_counts.sh "$1" || status=1
	python3 scripts/check_vacuous_test_cases.py --root "$1" || status=1
	# The generator resolves every path from its own location, so the copy in
	# the checked tree judges that tree.
	if ! python3 scripts/render_user_docs_generated.py --check; then
		echo "pre_push_suite_checks: the generated user docs do not match their sources in the pushed commit. Run python3 scripts/render_user_docs_generated.py and commit the result in the commit that changed the source (the CLI description, the health checks, the installers or the docs front matter); when the drift was inherited, regenerate in a chore(docs) commit of its own." >&2
		status=1
	fi
	exit "$status"
' _ "$check_root")

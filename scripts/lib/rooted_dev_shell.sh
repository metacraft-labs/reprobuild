# shellcheck shell=bash
#
# scripts/lib/rooted_dev_shell.sh -- enter a Nix dev shell whose closure
# holds a PERSISTENT garbage-collector root for as long as the command runs,
# and after it.
#
# WHY. A plain `nix develop --command CMD` roots the shell's environment only
# with a temporary root, and the temporary root belongs to the `nix` process.
# That process execs CMD, so the root is gone before CMD has started (the GC
# then reports the roots file as stale). On Linux the collector still keeps
# the closure alive while any process's /proc environ names it, so the window
# is narrow there; on macOS nothing protects it. On a host whose free space is
# below Nix's `min-free`, every store operation starts an automatic GC, and the
# shared-build-host rule forbids turning that off. So a long-running gate
# inside the shell can find its own tools collected under it.
#
# THE INCIDENT. On m3 (macOS arm64, permanently below `min-free`), the
# pre-commit `just lint` refused a commit twice because the dev shell's MinGW
# cross compiler (`REPRO_WINDOWS_CC`, used by
# scripts/check_portable_engine_closure.sh) had been collected. Its only root
# was `{temp:PID} -> ...-nix-shell-env`. Recorded in reprobuild-pm as
# issues/2026-11-15-pre-commit-mingw-lint-gate-loses-its-compiler-to-nix-gc-mid-commit.md.
#
# HOW. `nix develop --profile P` records the shell environment as a generation
# of the profile P, and a generation is an indirect, permanent GC root
# (/nix/var/nix/gcroots/auto). The root is in place before CMD runs, and it
# survives CMD, so the next commit does not start from a collected toolchain
# either. It is NOT a reason to disable the free-space GC: it pins exactly one
# dev-shell closure per checkout.
#
# GENERATIONS. Every change to the shell's inputs adds a generation, and each
# generation pins its whole closure. Before entering, every generation OLDER
# than the current one is removed, so a checkout pins at most two closures (the
# previous one, until the next entry, and the new one). Newer ones are left
# alone: a second entry in the same worktree may have just created one and be
# running from it.
#
# CAVEAT (macOS). The root is a symlink in the checkout's git directory that
# the root-owned nix-daemon follows. A checkout in a folder macOS privacy
# protection guards (~/Documents, ~/Desktop, ~/Downloads) may be unreadable
# to the daemon; check that `nix-store -q --roots "$REPRO_WINDOWS_CC"` names
# the profile's generation there.
#
# Usage:
#   source scripts/lib/rooted_dev_shell.sh
#   rooted_dev_shell_exec PROFILE NIX-DEVELOP-ARGS...   # does not return

# The profile path for the checkout at $1: inside its git directory, so it is
# per worktree, never tracked, never stashed by pre-commit and never seen by a
# gate that walks the working tree.
rooted_dev_shell_profile() {
	local dir
	dir="$(git -C "$1" rev-parse --path-format=absolute --git-path repro-dev-shell)" || return 1
	printf '%s/profile\n' "${dir}"
}

# Remove every generation of profile $1 older than the one it currently names.
rooted_dev_shell_prune() {
	local profile="$1" target current n link
	[[ -L "${profile}" ]] || return 0
	target="$(readlink -- "${profile}")"
	current="${target%-link}"       # ".../profile-N-link" -> ".../profile-N"
	current="${current##*-}"        # -> "N"
	[[ "${current}" =~ ^[0-9]+$ ]] || return 0
	for link in "${profile}"-*-link; do
		[[ -L "${link}" ]] || continue
		n="${link#"${profile}"-}"
		n="${n%-link}"
		[[ "${n}" =~ ^[0-9]+$ ]] || continue
		((n < current)) && rm -f -- "${link}"
	done
	return 0
}

rooted_dev_shell_exec() {
	local profile="$1"
	shift
	mkdir -p -- "$(dirname -- "${profile}")"
	rooted_dev_shell_prune "${profile}"
	exec nix develop --profile "${profile}" "$@"
}

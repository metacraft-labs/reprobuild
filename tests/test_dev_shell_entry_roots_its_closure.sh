#!/usr/bin/env bash
# The pre-commit hook's dev shell holds a permanent GC root for its whole
# closure, so the automatic Nix garbage collector cannot remove the lint's
# tools while `just lint` runs or between two commits.
#
# Regression test for reprobuild-pm
# issues/2026-11-15-pre-commit-mingw-lint-gate-loses-its-compiler-to-nix-gc-mid-commit.md:
# on m3 (macOS, below Nix's `min-free`, so every store operation runs an
# auto-GC) the MinGW compiler the Windows C lint stage uses was collected
# under the hook, whose only root was a `nix develop` temporary root.
#
# It runs the production entry, scripts/lib/rooted_dev_shell.sh, which
# scripts/pre_commit_lint.sh uses, against a two-derivation probe shell built
# locally (no substituter, no network): the shell's environment names a
# `probe-tool` store path the way the real shell names REPRO_WINDOWS_CC. The
# real dev shell is not used because it takes minutes to evaluate and is not
# what is under test; the rooting is.
#
# Asserted:
#   - control: after a plain `nix develop --command` exits, its probe tool is
#     deletable (`nix-store --delete` succeeds), so the deletion check below
#     can see a missing root;
#   - while the command runs, the probe tool has a root that is neither a
#     temporary root nor a running process (`{temp:`, `/proc/`, `{lsof}`) --
#     the only roots there are on macOS-like collectors -- and it is the
#     profile's generation;
#   - after the command exits, the probe tool cannot be deleted;
#   - repeated entries keep at most two generations;
#   - scripts/pre_commit_lint.sh enters its shell through this library.
#
# Needs `nix` and a bash from the Nix store (the dev shell's bash), and runs
# several store operations, each of which starts an automatic GC on a host
# below `min-free`; so it is run by `just dev-shell-hooks`, not on every
# commit. `--wiring-only` runs just the last check, needs nothing, and is what
# `just lint` runs.
#
#   bash tests/test_dev_shell_entry_roots_its_closure.sh [--wiring-only]
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() {
	echo "FAIL: $*" >&2
	exit 1
}

check_wiring() {
	grep -qE '^rooted_dev_shell_exec ' "$REPO/scripts/pre_commit_lint.sh" ||
		fail "scripts/pre_commit_lint.sh does not enter its dev shell through rooted_dev_shell_exec"
	if grep -qE '^[[:space:]]*exec nix develop' "$REPO/scripts/pre_commit_lint.sh"; then
		fail "scripts/pre_commit_lint.sh still runs a plain \`exec nix develop\`"
	fi
	grep -qE '^[[:space:]]*exec nix develop --profile ' "$REPO/scripts/lib/rooted_dev_shell.sh" ||
		fail "scripts/lib/rooted_dev_shell.sh no longer enters the shell with --profile"
}
if [[ ${1:-} == --wiring-only ]]; then
	check_wiring
	echo "PASS: scripts/pre_commit_lint.sh enters a profile-rooted dev shell (wiring only)"
	exit 0
fi

command -v nix >/dev/null 2>&1 || fail "nix is not on PATH; run inside the dev shell"
bash_exe="$(readlink -f "$(command -v bash)")"
[[ $bash_exe == /nix/store/*/bin/bash ]] ||
	fail "bash resolves to '$bash_exe', not a Nix store bash; run inside the dev shell"
bash_store="${bash_exe%/bin/bash}"

SCRATCH="$(mktemp -d)"
probes=()
cleanup() {
	rm -rf "$SCRATCH"
	local p
	for p in "${probes[@]}"; do
		[[ -e $p ]] && { delete_probe "$p" || true; }
	done
}
trap cleanup EXIT

cat >"$SCRATCH/shell.nix" <<EOF
let
  system = builtins.currentSystem;
  bash = builtins.storePath "$bash_store";
  tool = derivation {
    name = "probe-tool-\${builtins.getEnv "PROBE_SALT"}";
    inherit system;
    builder = "\${bash}/bin/bash";
    args = [ "-c" "echo probe > \$out" ];
  };
in derivation {
  name = "probe-shell";
  inherit system;
  builder = "\${bash}/bin/bash";
  args = [ "-c" "echo > \$out" ];
  PROBE_TOOL = "\${tool}";
  # nix develop writes the environment to each name in \$outputs.
  outputs = [ "out" ];
}
EOF

# Each entry gets a fresh salt, hence a probe tool nothing else roots.
salt() { printf 'rdsr-%s-%s-%s' "$$" "$1" "$RANDOM"; }

# Try to delete a probe tool together with the shell environment that
# references it (its only referrer). `nix-store --delete` refuses any path
# that is still alive, i.e. reachable from a root, and a path with a valid
# referrer outside the deletion set, so this succeeds exactly when nothing
# roots the probe shell's closure. A path that is already gone counts as
# deleted: on a host below `min-free` the automatic GC may have collected an
# unrooted probe first, which shows the same thing.
delete_probe() {
	local refs
	[[ -e $1 ]] || return 0
	mapfile -t refs < <(nix-store -q --referrers "$1")
	nix-store --delete "${refs[@]}" "$1" >/dev/null 2>&1
}

# --- control: a plain `nix develop --command` leaves nothing behind --------
export PROBE_SALT
PROBE_SALT="$(salt plain)"
# shellcheck disable=SC2016 # expanded by the inner shell, inside the dev shell
plain_tool="$(cd "$SCRATCH" && nix develop --impure -f shell.nix \
	--command bash -c 'printf %s "$PROBE_TOOL"' 2>"$SCRATCH/nix.err")" || true
[[ $plain_tool == /nix/store/*-probe-tool-* ]] ||
	fail "the probe shell did not export PROBE_TOOL (got '$plain_tool'); nix said:
$(tail -20 "$SCRATCH/nix.err")"
probes+=("$plain_tool")
delete_probe "$plain_tool" ||
	fail "control: after a plain nix develop exited, $plain_tool could not be deleted, so this test cannot tell a rooted closure from an unrooted one"

# --- the rooted entry ------------------------------------------------------
# shellcheck source=scripts/lib/rooted_dev_shell.sh
source "$REPO/scripts/lib/rooted_dev_shell.sh"
profile="$SCRATCH/roots/profile"
enter() {
	# shellcheck disable=SC2016 # expanded by the inner shell, inside the dev shell
	(cd "$SCRATCH" && rooted_dev_shell_exec "$profile" --impure -f shell.nix \
		--command bash -c 'printf "%s\n" "$PROBE_TOOL"; nix-store -q --roots "$PROBE_TOOL"' \
		2>"$SCRATCH/nix.err")
}

PROBE_SALT="$(salt rooted)"
output="$(enter)" || fail "the rooted entry failed; nix said:
$(tail -20 "$SCRATCH/nix.err")"
tool="$(head -n 1 <<<"$output")"
[[ $tool == /nix/store/*-probe-tool-* ]] ||
	fail "the rooted shell did not export PROBE_TOOL (got '$tool')"
probes+=("$tool")
roots="$(tail -n +2 <<<"$output")"
persistent="$(grep -vE '^(\{temp:|\{lsof\}|/proc/)' <<<"$roots" || true)"
[[ -n $persistent ]] ||
	fail "while the command ran, $tool had no persistent GC root; its roots were:
${roots:-  (none)}"
grep -qF "$profile-" <<<"$persistent" ||
	fail "while the command ran, the persistent root of $tool was not the profile's generation:
$persistent"

if delete_probe "$tool"; then
	fail "after the rooted shell exited, $tool was deleted: nothing roots it"
fi
[[ -e $tool ]] || fail "$tool is gone after the rooted shell exited"

# --- generations stay bounded ------------------------------------------------
for i in 1 2 3; do
	PROBE_SALT="$(salt "gen$i")"
	output="$(enter)" || fail "rooted entry $i failed; nix said:
$(tail -20 "$SCRATCH/nix.err")"
	probes+=("$(head -n 1 <<<"$output")")
done
shopt -s nullglob
gens=("$profile"-*-link)
((${#gens[@]} <= 2)) ||
	fail "after four entries the profile keeps ${#gens[@]} generations, not at most two: ${gens[*]}"

# --- the hook uses it ----------------------------------------------------------
check_wiring

echo "PASS: the pre-commit dev shell's closure is rooted while and after the lint runs"

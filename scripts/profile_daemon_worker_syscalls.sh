#!/usr/bin/env bash
# profile_daemon_worker_syscalls.sh — CONF-3: DERIVE the worker unit's syscall
# filter by profiling instead of guessing it, and PROVE the derived filter
# (deployment-security-architecture.md §4.4 CONF-3).
#
# The workload (by default the Distributed-Execution M7 worker tests: a real
# worker daemon answering goals, and the execution-lease launcher in every
# layer configuration, including the subordinate-uid floor) runs as the
# invoking user inside a TRANSIENT SYSTEM unit — `sudo systemd-run --uid=…`,
# nothing installed under /etc/systemd, every unit stopped and reset
# afterwards. A system unit is required: a systemd *user* manager forces
# no_new_privs on any unit with SystemCallLog=/SystemCallFilter=, and under
# no_new_privs the floor's id-mapping helpers (newuidmap/newgidmap, which
# carry file capabilities or setuid) cannot gain their privilege, so the
# floor's calls would never be observed. The units carry the worker unit's
# own NoNewPrivileges=no and CapabilityBoundingSet=CAP_SETUID CAP_SETGID.
#
#   profile (default)  traces every system call the workload and all of its
#     descendants make (the daemon, git, compilers, the lease supervisor, the
#     id-mapping helpers, the confined lease) with strace, run as root with
#     `-u <invoking user>` so the setuid/file-capability helpers keep their
#     privilege. It is lossless, unlike SystemCallLog=: without auditd the
#     kernel prints seccomp LOG records through the rate-limited printk path
#     ("kauditd_printk_skb: N callbacks suppressed"), and a lease's lchown
#     storm drops the setgroups/setresuid records that follow it (measured on
#     arch, 2026-10-18). The observed names that the unit's base set
#     (@system-service minus @privileged @resources @obsolete, expanded with
#     `systemd-analyze syscall-filter`) does not allow are written to
#     recipes/repro-daemon-worker/syscalls — the list the unit re-allows.
#     systemd-units/repro-daemon-worker.profile.conf remains the in-service
#     observation for a provisioned host whose auditd makes it lossless.
#   --verify           runs the workload under the unit's own syscall settings
#     (SystemCallFilter= exactly as the unit file states them,
#     SystemCallErrorNumber=EPERM, SystemCallArchitectures=native,
#     RestrictNamespaces=, RestrictAddressFamilies=, NoNewPrivileges=no, the
#     bounding set) and fails unless every workload binary exits 0.
#
# Linux only; profiling requires the dev shell's REPRO_SYSTEMD_ANALYZE.
# Needs passwordless sudo, and strace for profiling ($STRACE or on
# PATH; e.g. STRACE=$(nix build --no-link --print-out-paths nixpkgs#strace)/bin/strace).
# Usage:
#   scripts/profile_daemon_worker_syscalls.sh [--verify] <workload-binary> ...
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)" == Linux ]] || { echo "CONF-3 profiling runs on Linux" >&2; exit 2; }
OUT=recipes/repro-daemon-worker/syscalls
UNIT=recipes/repro-daemon-worker/systemd-units/repro-daemon-worker.service
UAPI=${REPRO_LINUX_UAPI_INCLUDE:-/usr/include}
HDR=$UAPI/asm/unistd_64.h
[[ "$(uname -m)" == aarch64 ]] && HDR=$UAPI/asm-generic/unistd.h
mode=profile
if [[ "${1:-}" == --verify ]]; then mode=verify; shift; fi
workload=("$@")
if [[ ${#workload[@]} -eq 0 ]]; then
  echo "usage: $0 [--verify] <workload-binary> [...]  (e.g. the built M7 worker tests)" >&2
  exit 2
fi
sudo -n true 2>/dev/null || { echo "CONF-3 needs passwordless sudo for a transient system unit" >&2; exit 2; }

# The settings every transient unit shares with the worker unit.
common=(-p NoNewPrivileges=no -p "CapabilityBoundingSet=CAP_SETUID CAP_SETGID"
        --uid="$(id -u)" --gid="$(id -g)"
        -E PATH="$PATH" -E HOME="$HOME" -E TMPDIR=/tmp -E USER="$(id -un)"
        -E REPRO_NIM_COMPILER="${REPRO_NIM_COMPILER:-}"
        --working-directory="$PWD")

# run_unit <log-file> <extra systemd-run args...> -- <binary>
run_unit() {
  local log=$1; shift
  local unit="repro-m7-conf3-$$-$RANDOM"
  local rc=0
  sudo -n systemd-run --unit="$unit" --wait --pipe --collect --quiet \
    "${common[@]}" "$@" >"$log" 2>&1 || rc=$?
  sudo -n systemctl stop "$unit" >/dev/null 2>&1 || true
  sudo -n systemctl reset-failed "$unit" >/dev/null 2>&1 || true
  return $rc
}

logdir=$(mktemp -d)
trap 'rm -rf "$logdir"' EXIT

if [[ $mode == verify ]]; then
  filters=()
  while IFS= read -r line; do filters+=(-p "$line"); done < <(
    grep -E '^(SystemCallFilter|SystemCallErrorNumber|SystemCallArchitectures|RestrictNamespaces|RestrictAddressFamilies)=' "$UNIT")
  failed=0
  for bin in "${workload[@]}"; do
    if run_unit "$logdir/verify.log" "${filters[@]}" -- "$bin"; then
      echo "verify: ${bin##*/} ok under the unit's syscall filter"
    else
      echo "verify: ${bin##*/} FAILED under the unit's syscall filter" >&2
      tail -25 "$logdir/verify.log" >&2
      failed=1
    fi
  done
  exit $failed
fi

strace_bin=${STRACE:-$(command -v strace || true)}
[[ -x "$strace_bin" ]] || { echo "CONF-3 profiling needs strace (\$STRACE or on PATH)" >&2; exit 2; }

# expand <group-or-name>: every syscall name it stands for, recursively.
# Subtract exactly the pinned base set the lint derives the floor from.
# --verify uses the unit's filter directly and needs no group expansion.
systemd_analyze=${REPRO_SYSTEMD_ANALYZE:-}
[[ -n "$systemd_analyze" ]] || {
  echo "CONF-3 profiling requires REPRO_SYSTEMD_ANALYZE from the dev shell" >&2
  exit 2
}
[[ "$systemd_analyze" == */* && -f "$systemd_analyze" && -x "$systemd_analyze" ]] || {
  echo "CONF-3: REPRO_SYSTEMD_ANALYZE=$systemd_analyze must name an executable file; re-enter the dev shell" >&2
  exit 2
}
declare -A expanded=()
expand() {
  local item=$1 raw
  if [[ $item != @* ]]; then echo "$item"; return; fi
  if [[ -z "${expanded[$item]:-}" ]]; then
    if ! raw=$("$systemd_analyze" syscall-filter --no-pager "$item" 2>"$logdir/analyze.stderr"); then
      echo "CONF-3: $systemd_analyze failed to expand $item" >&2
      cat "$logdir/analyze.stderr" >&2
      return 1
    fi
    expanded[$item]=$(awk 'NR > 1 && $1 !~ /^#/ && NF == 1 {print $1}' <<< "$raw")
    if [[ -z "${expanded[$item]}" ]]; then
      echo "CONF-3: $systemd_analyze returned an empty expansion for $item" >&2
      cat "$logdir/analyze.stderr" >&2
      return 1
    fi
  fi
  local member
  for member in ${expanded[$item]}; do expand "$member" || return 1; done
}
declare -A allowed=()
# Capture and check before iterating: a failed command substitution in a for
# list does not fail the loop, even under set -e. Recursion must propagate its
# status explicitly too, since these checked substitutions disable errexit.
base_names=$(expand @system-service) || exit 1
for n in $base_names; do allowed[$n]=1; done
for g in @privileged @resources @obsolete; do
  group_names=$(expand "$g") || exit 1
  for n in $group_names; do unset "allowed[$n]"; done
done

declare -A seen=()
for bin in "${workload[@]}"; do
  sudo -n env PATH="$PATH" HOME="$HOME" TMPDIR=/tmp USER="$(id -un)" \
    REPRO_NIM_COMPILER="${REPRO_NIM_COMPILER:-}" \
    "$strace_bin" -f -qq -o "$logdir/trace" -u "$(id -un)" -- "$bin" \
    >"$logdir/profile.log" 2>&1 || {
      echo "CONF-3: workload ${bin##*/} failed while traced; a profile of a failing run is incomplete" >&2
      tail -20 "$logdir/profile.log" >&2
      exit 1
    }
  while read -r name; do seen[$name]=1; done < <(
    sudo -n cat "$logdir/trace" |
      sed -nE 's/^[0-9]+ +([a-z0-9_]+)\(.*/\1/p; s/^[0-9]+ +<\.\.\. ([a-z0-9_]+) resumed>.*/\1/p' |
      sort -u)
  sudo -n rm -f "$logdir/trace"
done
names=()
for name in "${!seen[@]}"; do
  [[ -n "${allowed[$name]:-}" ]] || names+=("$name")
done
{
  echo "# CONF-3 derived syscall additions for repro-daemon-worker.service."
  echo "# Generated by scripts/profile_daemon_worker_syscalls.sh on $(hostname) ($(uname -r), $(date -u +%Y-%m-%d))"
  echo "# by tracing (strace -f, as root, -u $(id -un)): ${workload[*]##*/}"
  echo "# Every name the workload used that @system-service minus @privileged @resources @obsolete does not allow."
  echo "# One name per line; the unit re-allows exactly these."
  printf '%s\n' "${names[@]}" | sort -u
} > "$OUT"
echo "observed ${#seen[@]} distinct syscalls; wrote $(grep -vc '^#' "$OUT") to $OUT"

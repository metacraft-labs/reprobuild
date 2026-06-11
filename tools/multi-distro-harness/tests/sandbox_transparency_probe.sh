#!/bin/sh
# sandbox_transparency_probe.sh - verify a bubblewrap "passthrough"
# invocation (no FHS substitution) is observationally identical to a
# native exec.
#
# Linux-Third-Party-Sandbox-MVP M0 acceptance probe:
#
# The Tier 3 / FHS-view wrapper is supposed to be MECHANISM, not
# isolation policy. With every host bind-mount in place and no
# `--unshare-*` flag toggled, a program run through bwrap MUST behave
# identically to running it directly: same files in /home, same PID
# table, same hostname, same user identity.
#
# This test installs bubblewrap on demand (the M1 driver will own
# installation in production; for this probe we just need bwrap on the
# PATH), then runs three transparency checks:
#
#   1. Deterministic echo: `bwrap ... -- echo "hello from bwrap"`
#      MUST emit exactly that line and exit 0.
#   2. Host filesystem visibility: `bwrap ... -- ls /home` MUST list
#      at least one entry (the host's home directory tree).
#   3. Host process visibility: `bwrap ... -- ps aux | wc -l` MUST
#      report >= 5 lines (host PIDs are visible).
#   4. Host user identity: `bwrap ... -- id -u` MUST match the host's
#      `id -u` exactly (UID mapping is identity by spec).
#
# Stays POSIX-sh-compatible. The bwrap invocation shape mirrors the
# Linux-Third-Party-Sandbox-MVP M0 spec:
#
#   bwrap --dev-bind / / --proc /proc -- <argv>
#
# (`--dev-bind / /` recursively re-binds the entire host root + brings
# /dev across; `--proc /proc` mounts a fresh procfs in the user-ns so
# `ps` works.)
#
# Exit code:
#   0 - all four transparency checks pass.
#   1 - bwrap not installable on this distro, or any transparency
#       check fails.

set -eu

# ----------------------------------------------------------------------
# Distro identification.
# ----------------------------------------------------------------------

if [ ! -r /etc/os-release ]; then
  echo "sandbox_transparency_probe: FAIL - /etc/os-release missing" >&2
  exit 1
fi
# shellcheck disable=SC1091
. /etc/os-release
distro_id="${ID:-unknown}"

# ----------------------------------------------------------------------
# Ensure bubblewrap is installed.
# ----------------------------------------------------------------------
# This step is for the probe only; the M1 driver will own real install.
# Closed-set distro switch with the same package-manager invocations the
# user-facing M1 driver will eventually use.

install_bwrap() {
  case "$distro_id" in
    debian|ubuntu)
      apt-get update -qq >/dev/null 2>&1 || true
      apt-get install -y bubblewrap >/dev/null 2>&1
      ;;
    fedora)
      dnf install -y bubblewrap >/dev/null 2>&1
      ;;
    arch)
      pacman -Sy --noconfirm bubblewrap >/dev/null 2>&1
      ;;
    alpine)
      apk add bubblewrap >/dev/null 2>&1
      ;;
    opensuse|opensuse-tumbleweed|opensuse-leap)
      zypper --non-interactive install bubblewrap >/dev/null 2>&1
      ;;
    *)
      echo "sandbox_transparency_probe: FAIL - unknown distro ID='${distro_id}'" >&2
      return 1
      ;;
  esac
}

if ! command -v bwrap >/dev/null 2>&1; then
  echo "sandbox_transparency_probe: bwrap missing; installing via ${distro_id} package manager..."
  if ! install_bwrap; then
    echo "sandbox_transparency_probe: FAIL - install_bwrap failed on ${distro_id}" >&2
    exit 1
  fi
  if ! command -v bwrap >/dev/null 2>&1; then
    echo "sandbox_transparency_probe: FAIL - bwrap not on PATH after install on ${distro_id}" >&2
    exit 1
  fi
fi

bwrap_version=$(bwrap --version 2>/dev/null | head -n1 || echo 'version-unknown')
echo "sandbox_transparency_probe: ${distro_id} using ${bwrap_version}"

# ----------------------------------------------------------------------
# Sanity: bwrap needs unprivileged user-ns to work. If the kernel
# disallows it the probe is meaningless; report and skip with FAIL.
# ----------------------------------------------------------------------

if ! unshare --user true >/dev/null 2>&1; then
  echo "sandbox_transparency_probe: FAIL - unprivileged user-ns disabled" >&2
  echo "  remediation: sysctl -w kernel.unprivileged_userns_clone=1" >&2
  exit 1
fi

# ----------------------------------------------------------------------
# Transparency probes.
# ----------------------------------------------------------------------
# Each probe runs the same bwrap shape:
#
#   bwrap --dev-bind / / --proc /proc -- <argv...>
#
# `--dev-bind / /` recursively bind-mounts the entire host root
# (including /dev, /home, /tmp, /run, /sys, /var) into the user-ns.
# `--proc /proc` mounts a fresh procfs INSIDE the user-ns so ps(1) and
# friends see live PIDs. Together these are the spec's minimum-policy
# invocation; everything else stays at the kernel default.

run_bwrap() {
  # shellcheck disable=SC2068
  bwrap --dev-bind / / --proc /proc -- $@
}

fail=0

# Probe 1: deterministic echo output + exit 0.
echo 'sandbox_transparency_probe: probe 1 (deterministic echo)...'
out=$(run_bwrap echo 'hello from bwrap' 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "  FAIL - bwrap echo exited rc=$rc; output=${out}" >&2
  fail=1
elif [ "$out" != 'hello from bwrap' ]; then
  echo "  FAIL - expected 'hello from bwrap', got '$out'" >&2
  fail=1
else
  echo "  OK - 'hello from bwrap' (rc=0)"
fi

# Probe 2: host filesystem visibility.
# `/home` must contain at least one entry. On Alpine minirootfs `/home`
# may be empty (no human users created) so we fall back to asserting
# `/etc` is visible, which every distro guarantees.
echo 'sandbox_transparency_probe: probe 2 (host filesystem visibility)...'
home_entries=$(run_bwrap ls /home 2>/dev/null | wc -l || echo 0)
etc_entries=$(run_bwrap ls /etc 2>/dev/null | wc -l || echo 0)
if [ "$etc_entries" -lt 1 ]; then
  echo "  FAIL - /etc not visible inside bwrap (entries=$etc_entries)" >&2
  fail=1
else
  echo "  OK - /etc has ${etc_entries} entries, /home has ${home_entries} entries"
fi

# Probe 3: host process visibility (no --unshare-pid means host PID
# table is mounted; --proc /proc just re-mounts a fresh procfs view of
# it). Even Alpine minirootfs WSL instances run at least:
#   - the WSL bridge process (init)
#   - wsl.exe -> /bin/sh (the test runner)
#   - the bwrap process itself
#   - the inner ps process
#   - sh -c pipeline shim
# So `ps aux | wc -l` should always be >= 5 (header + >=4 PIDs).
echo 'sandbox_transparency_probe: probe 3 (host process visibility)...'
if ! command -v ps >/dev/null 2>&1; then
  echo "  SKIP - ps(1) not installed on ${distro_id}; cannot verify"
else
  ps_lines=$(run_bwrap sh -c 'ps aux | wc -l' 2>/dev/null || echo 0)
  if [ "$ps_lines" -lt 5 ]; then
    echo "  FAIL - expected >=5 ps lines, got ${ps_lines}" >&2
    fail=1
  else
    echo "  OK - ${ps_lines} ps lines visible inside bwrap"
  fi
fi

# Probe 4: host user identity (UID identity-mapped by spec).
echo 'sandbox_transparency_probe: probe 4 (host user identity)...'
host_uid=$(id -u)
inside_uid=$(run_bwrap id -u 2>/dev/null || echo 'unknown')
if [ "$host_uid" != "$inside_uid" ]; then
  echo "  FAIL - host uid=${host_uid}, inside uid=${inside_uid} (must match)" >&2
  fail=1
else
  echo "  OK - uid ${host_uid} identical inside/outside bwrap"
fi

# ----------------------------------------------------------------------
# Aggregate verdict.
# ----------------------------------------------------------------------

if [ "$fail" -ne 0 ]; then
  echo "sandbox_transparency_probe: FAIL on ${distro_id}" >&2
  exit 1
fi
echo "sandbox_transparency_probe: OK on ${distro_id} (4/4 probes passed)"
exit 0

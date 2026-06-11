#!/bin/sh
# sandbox_m2_apt_mvp.sh - Linux-Third-Party-Sandbox-MVP M2 integration
# acceptance test: realize a Debian .deb (the GNU `hello` package) +
# its first-level Depends closure from snapshot.debian.org, compose the
# realized prefixes into an FHS tree, and exec /usr/bin/hello through
# bubblewrap using the M1 driver's M0-locked transparency-posture argv
# shape.
#
# Pinned fixtures (snapshot.debian.org bookworm/main/binary-amd64,
# verified 2026-06-11 by the impl sub-agent):
#
#   snapshot:   20260101T000000Z
#   codename:   bookworm
#   arch:       amd64
#   root:       hello 2.10-3 amd64
#                 Filename: pool/main/h/hello/hello_2.10-3_amd64.deb
#                 SHA256:   2e6e2f1a0007dc43bc91c273fd36e91e40a4f1c2765a03eca68b70a42103878a
#                 Depends:  libc6 (>= 2.34)
#   level-1:    libc6 2.36-9+deb12u13 amd64
#                 Filename: pool/main/g/glibc/libc6_2.36-9+deb12u13_amd64.deb
#                 SHA256:   3d8072c73b017e907bbf44b7db870687888a991961d74f1ecbba6b9458f32a2c
#   index:      dists/bookworm/main/binary-amd64/Packages.gz
#                 SHA256:   ae5b8a6b9b82eae394f078256ea05c5aed322e04efa435f47ad116349dec0fa9
#
# `hello` is the GNU Hello clone: the only program (per its Debian
# changelog) whose entire purpose is to print "Hello, world!". On
# this version it prints exactly that line + exit 0.
#
# Expected runtime: ~10-30s cold (Packages.gz is ~12 MiB; hello.deb +
# libc6.deb are ~3 MiB total + decompression); <2s warm via the
# script's per-prefix cache hit.
#
# Distros: debian, ubuntu (both ship apt + dpkg-deb + bubblewrap).
# The test refuses non-apt distros — M3 (dnf) and M4 (pacman) will
# author their own equivalents.

set -eu

# ----------------------------------------------------------------------
# Sanity: this test must run inside repro-debian or repro-ubuntu.
# ----------------------------------------------------------------------

if [ ! -r /etc/os-release ]; then
  echo "sandbox_m2_apt_mvp: FAIL - /etc/os-release missing" >&2
  exit 1
fi
# shellcheck disable=SC1091
. /etc/os-release
distro_id="${ID:-unknown}"
case "$distro_id" in
  debian|ubuntu) ;;
  *)
    echo "sandbox_m2_apt_mvp: FAIL - expected debian|ubuntu, got ID=${distro_id}" >&2
    echo "  (M3 will mirror this on fedora; M4 on arch; M2 is apt-only)" >&2
    exit 1
    ;;
esac

REPO_ROOT="${REPRO_REPO_ROOT:-/mnt/d/metacraft/reprobuild}"
APT_MVP="${REPO_ROOT}/tools/sandbox-harness/apt_mvp.sh"

if [ ! -f "$APT_MVP" ]; then
  echo "sandbox_m2_apt_mvp: FAIL - apt_mvp.sh missing at ${APT_MVP}" >&2
  exit 1
fi

# ----------------------------------------------------------------------
# Step 1: install bubblewrap if missing. (dpkg-deb + curl + sha256sum
# + gunzip + awk + sed ship by default on debian/ubuntu base images;
# bubblewrap usually does not. Use the same closed-set install switch
# as the M0 transparency probe.)
# ----------------------------------------------------------------------

echo "sandbox_m2_apt_mvp: step 1 - install bubblewrap if needed"
if ! command -v bwrap >/dev/null 2>&1; then
  apt-get update -qq >/dev/null 2>&1 || true
  apt-get install -y bubblewrap >/dev/null 2>&1
  if ! command -v bwrap >/dev/null 2>&1; then
    echo "sandbox_m2_apt_mvp: FAIL - bwrap missing after apt-get install" >&2
    exit 1
  fi
fi
echo "sandbox_m2_apt_mvp:   bwrap version: $(bwrap --version 2>/dev/null | head -n1)"

# ----------------------------------------------------------------------
# Step 2: sanity-check the M0 user-ns precondition.
# ----------------------------------------------------------------------

if ! unshare --user true >/dev/null 2>&1; then
  echo "sandbox_m2_apt_mvp: FAIL - unprivileged user-ns disabled" >&2
  echo "  remediation: sysctl -w kernel.unprivileged_userns_clone=1" >&2
  exit 1
fi

# ----------------------------------------------------------------------
# Step 3: invoke apt_mvp.sh under a clean per-test store root so the
# test is hermetic. Capture stdout for the assertion.
# ----------------------------------------------------------------------

STORE_ROOT="/tmp/sandbox_m2_apt_mvp_store_$$"
rm -rf "$STORE_ROOT"
mkdir -p "$STORE_ROOT"
trap 'rm -rf "$STORE_ROOT"' EXIT INT TERM

echo "sandbox_m2_apt_mvp: step 3 - apt_mvp.sh (cold)"
out_file=$(mktemp)
set +e
sh "$APT_MVP" \
  --snapshot=20260101T000000Z \
  --codename=bookworm \
  --package=hello \
  --store-root="$STORE_ROOT" \
  -- /usr/bin/hello \
  > "$out_file" 2>&1
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
  echo "sandbox_m2_apt_mvp: FAIL - apt_mvp.sh exited rc=$rc; tail:" >&2
  tail -n 40 "$out_file" >&2
  rm -f "$out_file"
  exit 1
fi

# ----------------------------------------------------------------------
# Step 4: assert the wrapped binary's output.
# ----------------------------------------------------------------------
#
# GNU Hello 2.10 on Debian prints exactly:
#
#   Hello, world!
#
# Plus possibly leading apt_mvp progress lines (script stdout is
# intermixed because we don't separate stdout/stderr in the harness).
# Search for the canonical line; the binary's output must contain it.

expected='Hello, world!'

if ! grep -Fq "$expected" "$out_file"; then
  echo "sandbox_m2_apt_mvp: FAIL - wrapped binary did not print '${expected}'" >&2
  echo "  full output:" >&2
  cat "$out_file" >&2
  rm -f "$out_file"
  exit 1
fi

echo "sandbox_m2_apt_mvp:   wrapped binary printed: '${expected}' (matched)"

# ----------------------------------------------------------------------
# Step 5: warm cache assertion - second invocation must short-circuit
# the fetch loop (per-prefix cache hit message). The composed FHS tree
# is also cached.
# ----------------------------------------------------------------------

echo "sandbox_m2_apt_mvp: step 5 - apt_mvp.sh (warm)"
warm_file=$(mktemp)
set +e
sh "$APT_MVP" \
  --snapshot=20260101T000000Z \
  --codename=bookworm \
  --package=hello \
  --store-root="$STORE_ROOT" \
  -- /usr/bin/hello \
  > "$warm_file" 2>&1
warm_rc=$?
set -e

if [ "$warm_rc" -ne 0 ]; then
  echo "sandbox_m2_apt_mvp: FAIL - warm apt_mvp.sh exited rc=$warm_rc" >&2
  tail -n 40 "$warm_file" >&2
  rm -f "$out_file" "$warm_file"
  exit 1
fi

if ! grep -Fq 'cache hit' "$warm_file"; then
  echo "sandbox_m2_apt_mvp: FAIL - warm run did not hit any cache path" >&2
  cat "$warm_file" >&2
  rm -f "$out_file" "$warm_file"
  exit 1
fi
if ! grep -Fq "$expected" "$warm_file"; then
  echo "sandbox_m2_apt_mvp: FAIL - warm run lost '${expected}' output" >&2
  cat "$warm_file" >&2
  rm -f "$out_file" "$warm_file"
  exit 1
fi
echo "sandbox_m2_apt_mvp:   warm run cache-hit + still prints '${expected}'"

rm -f "$out_file" "$warm_file"

echo ''
echo "sandbox_m2_apt_mvp: OK on ${distro_id}"
echo "  pipeline:  snapshot.debian.org -> sha256-verify -> dpkg-deb -x -> bwrap"
echo "  closure:   hello + libc6 (1 root + 1 first-level Depends)"
echo "  output:    ${expected}"
exit 0

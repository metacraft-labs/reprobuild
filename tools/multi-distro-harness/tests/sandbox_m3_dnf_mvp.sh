#!/bin/sh
# sandbox_m3_dnf_mvp.sh - Linux-Third-Party-Sandbox-MVP M3 integration
# acceptance test: realize a Fedora .rpm (the GNU `hello` package) +
# its first-level <rpm:requires> closure from the Fedora archive
# mirror, compose the realized prefixes into an FHS tree, and exec
# /usr/bin/hello through bubblewrap using the M1 driver's M0-locked
# transparency-posture argv shape.
#
# Pinned fixtures (Fedora 39 Everything/x86_64 from the archive
# mirror, verified 2026-06-11 by the M3 impl sub-agent):
#
#   release:      39
#   arch:         x86_64
#   mirror_base:  https://archives.fedoraproject.org/pub/archive/fedora/linux/releases/39/Everything/x86_64/os/
#                 (Fedora 39 is EOL — Fedora's archive mirror keeps
#                 every EOL release indefinitely. This is the Fedora
#                 analogue of snapshot.debian.org for reproducibility.)
#
#   root:         hello 2.12.1-2.fc39 x86_64
#                   <location href>: Packages/h/hello-2.12.1-2.fc39.x86_64.rpm
#                   SHA256:          10f9944f95ca54f224133cffab1cfab0c40e3adb64e4190d3d9e8f9dbed680f9
#                   <rpm:requires>:  rtld(GNU_HASH), libc.so.6(GLIBC_2.34)(64bit)
#
#   level-1 dep:  glibc 2.38-7.fc39 x86_64
#                   <location href>: Packages/g/glibc-2.38-7.fc39.x86_64.rpm
#                   SHA256:          5d65286b8cf58d62d6b41b3eb828d3367c725b1b22e690500a4d8aa6bdf572a2
#                   provides:        rtld(GNU_HASH), libc.so.6(...), glibc, ...
#                   (Both requires of hello resolve to glibc; the
#                   closure resolver dedupes glibc to a single entry.)
#
#   primary.xml.gz: repodata/e681f4dcf1aa9814a1393a685d70b94210232b8997d2bc8a02c080e0ba8e51e3-primary.xml.gz
#                   SHA256: e681f4dcf1aa9814a1393a685d70b94210232b8997d2bc8a02c080e0ba8e51e3
#                   (~18 MiB compressed, ~170 MiB uncompressed; the
#                   sha is also embedded in the filename per Fedora's
#                   content-addressed repodata convention.)
#
# `hello` is the GNU Hello clone: the only program whose entire
# purpose is to print "Hello, world!". On Fedora 39 this version
# prints exactly that single line + exit 0.
#
# Expected runtime: ~30-90 s cold (primary.xml.gz is ~18 MiB; hello.rpm
# is ~88 KiB; glibc.rpm is ~2.2 MiB + decompression); <5 s warm via
# the script's per-prefix + per-primary cache hit.
#
# Distros: fedora (ships rpm + dnf + python3 + rpm2cpio + cpio).
# Other RPM distros (opensuse, rhel-derivatives) would work in
# principle but are NOT exercised by M3 — the test refuses non-Fedora
# distros by /etc/os-release `ID=` check.

set -eu

# ----------------------------------------------------------------------
# Sanity: this test must run inside repro-fedora.
# ----------------------------------------------------------------------

if [ ! -r /etc/os-release ]; then
  echo "sandbox_m3_dnf_mvp: FAIL - /etc/os-release missing" >&2
  exit 1
fi
# shellcheck disable=SC1091
. /etc/os-release
distro_id="${ID:-unknown}"
case "$distro_id" in
  fedora) ;;
  *)
    echo "sandbox_m3_dnf_mvp: FAIL - expected fedora, got ID=${distro_id}" >&2
    echo "  (M2 covers debian|ubuntu; M4 will cover arch; M3 is fedora-only)" >&2
    exit 1
    ;;
esac

REPO_ROOT="${REPRO_REPO_ROOT:-/mnt/d/metacraft/reprobuild}"
DNF_MVP="${REPO_ROOT}/tools/sandbox-harness/dnf_mvp.sh"

if [ ! -f "$DNF_MVP" ]; then
  echo "sandbox_m3_dnf_mvp: FAIL - dnf_mvp.sh missing at ${DNF_MVP}" >&2
  exit 1
fi

# ----------------------------------------------------------------------
# Step 1: install bubblewrap if missing.
# ----------------------------------------------------------------------
#
# Fedora 39+ ships bubblewrap in the main repo; `dnf install bubblewrap`
# pulls it in. rpm2cpio + cpio + python3 + curl + sha256sum + gunzip +
# awk + sed are all on the Fedora base image already.

echo "sandbox_m3_dnf_mvp: step 1 - install bubblewrap if needed"
if ! command -v bwrap >/dev/null 2>&1; then
  dnf install -y --setopt=install_weak_deps=False bubblewrap \
    >/dev/null 2>&1
  if ! command -v bwrap >/dev/null 2>&1; then
    echo "sandbox_m3_dnf_mvp: FAIL - bwrap missing after dnf install" >&2
    exit 1
  fi
fi
echo "sandbox_m3_dnf_mvp:   bwrap version: $(bwrap --version 2>/dev/null | head -n1)"

# ----------------------------------------------------------------------
# Step 2: sanity-check the M0 user-ns precondition.
# ----------------------------------------------------------------------

if ! unshare --user true >/dev/null 2>&1; then
  echo "sandbox_m3_dnf_mvp: FAIL - unprivileged user-ns disabled" >&2
  echo "  remediation: sysctl -w kernel.unprivileged_userns_clone=1" >&2
  exit 1
fi

# ----------------------------------------------------------------------
# Step 3: dnf_mvp.sh dependency probe.
# ----------------------------------------------------------------------
#
# rpm2cpio + cpio + python3 must all be present. The dnf_mvp.sh script
# probes these itself; pre-check here so the failure is more focused
# than the orchestrator's generic "FAIL - required command".

for tool in rpm2cpio cpio python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "sandbox_m3_dnf_mvp: FAIL - required tool '$tool' missing" >&2
    echo "  (dnf install rpm cpio python3)" >&2
    exit 1
  fi
done

# ----------------------------------------------------------------------
# Step 4: invoke dnf_mvp.sh under a clean per-test store root.
# ----------------------------------------------------------------------

STORE_ROOT="/tmp/sandbox_m3_dnf_mvp_store_$$"
rm -rf "$STORE_ROOT"
mkdir -p "$STORE_ROOT"
trap 'rm -rf "$STORE_ROOT"' EXIT INT TERM

echo "sandbox_m3_dnf_mvp: step 4 - dnf_mvp.sh (cold)"
out_file=$(mktemp)
set +e
sh "$DNF_MVP" \
  --release=39 \
  --arch=x86_64 \
  --package=hello \
  --store-root="$STORE_ROOT" \
  -- /usr/bin/hello \
  > "$out_file" 2>&1
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
  echo "sandbox_m3_dnf_mvp: FAIL - dnf_mvp.sh exited rc=$rc; tail:" >&2
  tail -n 40 "$out_file" >&2
  rm -f "$out_file"
  exit 1
fi

# ----------------------------------------------------------------------
# Step 5: assert the wrapped binary's output.
# ----------------------------------------------------------------------
#
# GNU Hello 2.12.1 on Fedora 39 prints exactly:
#
#   Hello, world!
#
# Plus dnf_mvp progress lines (script stdout is intermixed). Search for
# the canonical line; the binary's output must contain it.

expected='Hello, world!'

if ! grep -Fq "$expected" "$out_file"; then
  echo "sandbox_m3_dnf_mvp: FAIL - wrapped binary did not print '${expected}'" >&2
  echo "  full output:" >&2
  cat "$out_file" >&2
  rm -f "$out_file"
  exit 1
fi

echo "sandbox_m3_dnf_mvp:   wrapped binary printed: '${expected}' (matched)"

# ----------------------------------------------------------------------
# Step 6: warm cache assertion.
# ----------------------------------------------------------------------
#
# Second invocation must short-circuit the fetch loop (per-prefix cache
# hit message). The composed FHS tree is also cached. primary.xml.gz
# is also cached.

echo "sandbox_m3_dnf_mvp: step 6 - dnf_mvp.sh (warm)"
warm_file=$(mktemp)
set +e
sh "$DNF_MVP" \
  --release=39 \
  --arch=x86_64 \
  --package=hello \
  --store-root="$STORE_ROOT" \
  -- /usr/bin/hello \
  > "$warm_file" 2>&1
warm_rc=$?
set -e

if [ "$warm_rc" -ne 0 ]; then
  echo "sandbox_m3_dnf_mvp: FAIL - warm dnf_mvp.sh exited rc=$warm_rc" >&2
  tail -n 40 "$warm_file" >&2
  rm -f "$out_file" "$warm_file"
  exit 1
fi

if ! grep -Fq 'cache hit' "$warm_file"; then
  echo "sandbox_m3_dnf_mvp: FAIL - warm run did not hit any cache path" >&2
  cat "$warm_file" >&2
  rm -f "$out_file" "$warm_file"
  exit 1
fi
if ! grep -Fq "$expected" "$warm_file"; then
  echo "sandbox_m3_dnf_mvp: FAIL - warm run lost '${expected}' output" >&2
  cat "$warm_file" >&2
  rm -f "$out_file" "$warm_file"
  exit 1
fi
echo "sandbox_m3_dnf_mvp:   warm run cache-hit + still prints '${expected}'"

rm -f "$out_file" "$warm_file"

echo ''
echo "sandbox_m3_dnf_mvp: OK on ${distro_id}"
echo "  pipeline:  archives.fedoraproject.org -> sha256-verify -> rpm2cpio|cpio -> bwrap"
echo "  closure:   hello + glibc (1 root + 1 first-level requires after dedup)"
echo "  output:    ${expected}"
exit 0

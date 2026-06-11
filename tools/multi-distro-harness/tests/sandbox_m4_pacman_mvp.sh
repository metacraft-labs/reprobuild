#!/bin/sh
# sandbox_m4_pacman_mvp.sh - Linux-Third-Party-Sandbox-MVP M4 integration
# acceptance test: realize an Arch .pkg.tar.zst (the `bash` package) +
# its first-level %DEPENDS% closure from the Arch Linux Archive (ALA),
# compose the realized prefixes into an FHS tree, and exec a small
# hello-world bash script (written to host /tmp, which is bind-passthrough
# under the M0 posture) through bubblewrap using the M1 driver's M0-locked
# transparency-posture argv shape.
#
# Why a /tmp script instead of `bash -c '...'`:
#
#   The orchestrator's `-- <argv>` tail is word-split before being passed
#   to `exec bwrap` — there is no quoting layer that survives `-- arg arg`
#   re-assembly into a single string. `bash -c "echo Hello, world!"`
#   would therefore run as `bash -c echo Hello, world!` (bash treats
#   `Hello,` as $0 and `world!` as $1, printing nothing useful). M2/M3
#   sidestep this because their inner argv is just `/usr/bin/hello`
#   (one token, no embedded spaces). M4 sidesteps it by writing the
#   hello-world payload to a host /tmp file (visible inside the sandbox
#   via the /tmp bind-passthrough from the M0 posture) and exec'ing
#   `/usr/bin/bash <script-path>` — one token per argv slot.
#
# Why `bash` instead of `hello` (which M2/M3 use):
#
#   Arch's official repos (core + extra) do NOT ship a GNU `hello`
#   package. The closest equivalents are either AUR (not in the M4
#   verification scope — ALA only mirrors core/extra/multilib) or
#   running a coreutils binary that produces no canonical fixed string
#   on its own.
#
#   `bash` is the smallest core package that ALSO exercises every
#   capability the M4 closure resolver must handle:
#
#     - first-level %DEPENDS% with multiple entries
#     - %DEPENDS% entries that are version-constrained CAPABILITIES
#       (`libreadline.so=8-64`) which the resolver must match against
#       another package's %PROVIDES% block, NOT against a %NAME%
#     - dedup: bash's `readline` and `libreadline.so=8-64` deps both
#       resolve to the SAME provider package (`readline`) so the
#       resolver must emit `readline` once
#
#   `bash -c 'echo Hello, world!'` is the smallest invocation that
#   produces the same canonical "Hello, world!" output line that the
#   M2/M3 fixtures assert against. The assertion text is therefore the
#   same across M2/M3/M4 even though the package is different.
#
# Pinned fixtures (ALA core/x86_64 snapshot 2025/01/01, verified
# 2026-06-11 by the M4 impl sub-agent):
#
#   date:         2025/01/01
#   repo:         core
#   arch:         x86_64
#   mirror_base:  https://archive.archlinux.org/repos/2025/01/01/core/os/x86_64/
#                 (ALA preserves every published version indefinitely.
#                 This is the Arch analogue of snapshot.debian.org /
#                 archives.fedoraproject.org for reproducibility.)
#
#   core.db:      120673 B (sha256 fe3bc989b85be6ea5122dc37885b93ade8a3418352c84a63198de12368432e87)
#                 (NOT sha-verified by pacman_mvp.sh — Arch ships no
#                 InRelease/repomd equivalent; HTTPS is the .db
#                 verification floor + per-pkg %SHA256SUM% is the
#                 .pkg.tar.zst verification floor. GPG verification of
#                 .db.sig is deferred to M5.)
#
#   root:         bash 5.2.037-1
#                   %FILENAME%:  bash-5.2.037-1-x86_64.pkg.tar.zst
#                   %SHA256SUM%: 1a09e213442f9f8200d7ebb082f712272a4bee64d1fc02a2feb519e5ba7ebf24
#                   %DEPENDS%:   readline, libreadline.so=8-64, glibc, ncurses
#                   (four deps; readline+libreadline.so both resolve to
#                   the `readline` package via %NAME% + %PROVIDES%; the
#                   resolver dedupes to (readline, glibc, ncurses).)
#
#   level-1 dep:  readline 8.2.013-1
#                   %FILENAME%:  readline-8.2.013-1-x86_64.pkg.tar.zst
#                   %SHA256SUM%: 832fc6ddb39f189a15bdbabbd2bfd59bf42a178a098206a537ace4ff3fd2311b
#                   %PROVIDES%:  libhistory.so=8-64, libreadline.so=8-64
#
#   level-1 dep:  glibc 2.40+r16+gaa533d58ff-2
#                   %FILENAME%:  glibc-2.40+r16+gaa533d58ff-2-x86_64.pkg.tar.zst
#                   %SHA256SUM%: c87c0e71fd03472918dc052b5833d5568ab62866e8259d28ab453ffc4bcf8291
#
#   level-1 dep:  ncurses 6.5-3
#                   %FILENAME%:  ncurses-6.5-3-x86_64.pkg.tar.zst
#                   %SHA256SUM%: 26a71def5164cf2e26aff8fb43457a373e1b9c9657880143700bdb6bad616b85
#
# Expected runtime: ~30-90 s cold (core.db is ~120 KiB; bash + glibc +
# readline + ncurses payloads sum to ~13 MiB); <5 s warm via the
# script's per-prefix + per-db cache hit.
#
# Distros: arch (ships pacman + tar 1.31+ with --zstd + bubblewrap).
# Other pacman distros (manjaro, endeavouros) would work in principle
# but are NOT exercised by M4 — the test refuses non-arch distros by
# /etc/os-release `ID=` check.

set -eu

# ----------------------------------------------------------------------
# Sanity: this test must run inside repro-arch.
# ----------------------------------------------------------------------

if [ ! -r /etc/os-release ]; then
  echo "sandbox_m4_pacman_mvp: FAIL - /etc/os-release missing" >&2
  exit 1
fi
# shellcheck disable=SC1091
. /etc/os-release
distro_id="${ID:-unknown}"
case "$distro_id" in
  arch) ;;
  *)
    echo "sandbox_m4_pacman_mvp: FAIL - expected arch, got ID=${distro_id}" >&2
    echo "  (M2 covers debian|ubuntu; M3 covers fedora; M4 is arch-only)" >&2
    exit 1
    ;;
esac

REPO_ROOT="${REPRO_REPO_ROOT:-/mnt/d/metacraft/reprobuild}"
PACMAN_MVP="${REPO_ROOT}/tools/sandbox-harness/pacman_mvp.sh"

if [ ! -f "$PACMAN_MVP" ]; then
  echo "sandbox_m4_pacman_mvp: FAIL - pacman_mvp.sh missing at ${PACMAN_MVP}" >&2
  exit 1
fi

# ----------------------------------------------------------------------
# Step 1: install bubblewrap if missing.
# ----------------------------------------------------------------------
#
# Arch ships bubblewrap in the `extra` repo; `pacman -S --noconfirm
# bubblewrap` pulls it in. tar + gzip + curl + sha256sum + awk + sed +
# zstd are all on the Arch base image already (tar 1.35 has --zstd
# built-in so the script never falls back to the separate zstd CLI on
# Arch — but zstd is present too).

echo "sandbox_m4_pacman_mvp: step 1 - install bubblewrap if needed"
if ! command -v bwrap >/dev/null 2>&1; then
  pacman -Sy --noconfirm --needed bubblewrap >/dev/null 2>&1 || true
  if ! command -v bwrap >/dev/null 2>&1; then
    echo "sandbox_m4_pacman_mvp: FAIL - bwrap missing after pacman -S" >&2
    exit 1
  fi
fi
echo "sandbox_m4_pacman_mvp:   bwrap version: $(bwrap --version 2>/dev/null | head -n1)"

# ----------------------------------------------------------------------
# Step 2: sanity-check the M0 user-ns precondition.
# ----------------------------------------------------------------------

if ! unshare --user true >/dev/null 2>&1; then
  echo "sandbox_m4_pacman_mvp: FAIL - unprivileged user-ns disabled" >&2
  echo "  remediation: sysctl -w kernel.unprivileged_userns_clone=1" >&2
  exit 1
fi

# ----------------------------------------------------------------------
# Step 3: pacman_mvp.sh dependency probe.
# ----------------------------------------------------------------------
#
# tar must have --zstd OR zstd must be on PATH for .pkg.tar.zst
# extraction. The pacman_mvp.sh script probes this itself; pre-check
# here so the failure is more focused than the orchestrator's generic
# "FAIL - need either 'tar --zstd' OR 'zstd' OR 'unzstd'".

if ! tar --zstd --help >/dev/null 2>&1; then
  if ! command -v zstd >/dev/null 2>&1 && ! command -v unzstd >/dev/null 2>&1; then
    echo "sandbox_m4_pacman_mvp: FAIL - no zstd-capable extractor" >&2
    echo "  (need tar 1.31+ with --zstd OR pacman -S zstd)" >&2
    exit 1
  fi
fi

# ----------------------------------------------------------------------
# Step 4: invoke pacman_mvp.sh under a clean per-test store root.
# ----------------------------------------------------------------------
#
# Hello-world payload is written to /tmp/sandbox_m4_pacman_mvp_hello_$$.sh
# on the host. /tmp is bind-passthrough under the M0 transparency posture,
# so the same path is reachable inside the sandbox; bash sees the script
# bytes via the kernel /tmp mount that bwrap passes through.

STORE_ROOT="/tmp/sandbox_m4_pacman_mvp_store_$$"
HELLO_SCRIPT="/tmp/sandbox_m4_pacman_mvp_hello_$$.sh"
rm -rf "$STORE_ROOT"
rm -f "$HELLO_SCRIPT"
mkdir -p "$STORE_ROOT"
printf '#!/usr/bin/env bash\necho "Hello, world!"\n' > "$HELLO_SCRIPT"
chmod +x "$HELLO_SCRIPT"
trap 'rm -rf "$STORE_ROOT" "$HELLO_SCRIPT"' EXIT INT TERM

echo "sandbox_m4_pacman_mvp: step 4 - pacman_mvp.sh (cold)"
out_file=$(mktemp)
set +e
sh "$PACMAN_MVP" \
  --date=2025/01/01 \
  --repo=core \
  --arch=x86_64 \
  --package=bash \
  --store-root="$STORE_ROOT" \
  -- /usr/bin/bash "$HELLO_SCRIPT" \
  > "$out_file" 2>&1
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
  echo "sandbox_m4_pacman_mvp: FAIL - pacman_mvp.sh exited rc=$rc; tail:" >&2
  tail -n 40 "$out_file" >&2
  rm -f "$out_file"
  exit 1
fi

# ----------------------------------------------------------------------
# Step 5: assert the wrapped binary's output.
# ----------------------------------------------------------------------
#
# `bash -c 'echo Hello, world!'` inside the FHS sandbox prints exactly:
#
#   Hello, world!
#
# Plus pacman_mvp progress lines (script stdout is intermixed). Search
# for the canonical line; the binary's output must contain it.

expected='Hello, world!'

if ! grep -Fq "$expected" "$out_file"; then
  echo "sandbox_m4_pacman_mvp: FAIL - wrapped binary did not print '${expected}'" >&2
  echo "  full output:" >&2
  cat "$out_file" >&2
  rm -f "$out_file"
  exit 1
fi

echo "sandbox_m4_pacman_mvp:   wrapped binary printed: '${expected}' (matched)"

# ----------------------------------------------------------------------
# Step 6: warm cache assertion.
# ----------------------------------------------------------------------
#
# Second invocation must short-circuit the fetch loop (per-prefix cache
# hit message). The composed FHS tree is also cached. The extracted
# desc dir (keyed by .db sha256) is also cached.

echo "sandbox_m4_pacman_mvp: step 6 - pacman_mvp.sh (warm)"
warm_file=$(mktemp)
set +e
sh "$PACMAN_MVP" \
  --date=2025/01/01 \
  --repo=core \
  --arch=x86_64 \
  --package=bash \
  --store-root="$STORE_ROOT" \
  -- /usr/bin/bash "$HELLO_SCRIPT" \
  > "$warm_file" 2>&1
warm_rc=$?
set -e

if [ "$warm_rc" -ne 0 ]; then
  echo "sandbox_m4_pacman_mvp: FAIL - warm pacman_mvp.sh exited rc=$warm_rc" >&2
  tail -n 40 "$warm_file" >&2
  rm -f "$out_file" "$warm_file"
  exit 1
fi

if ! grep -Fq 'cache hit' "$warm_file"; then
  echo "sandbox_m4_pacman_mvp: FAIL - warm run did not hit any cache path" >&2
  cat "$warm_file" >&2
  rm -f "$out_file" "$warm_file"
  exit 1
fi
if ! grep -Fq "$expected" "$warm_file"; then
  echo "sandbox_m4_pacman_mvp: FAIL - warm run lost '${expected}' output" >&2
  cat "$warm_file" >&2
  rm -f "$out_file" "$warm_file"
  exit 1
fi
echo "sandbox_m4_pacman_mvp:   warm run cache-hit + still prints '${expected}'"

rm -f "$out_file" "$warm_file"

echo ''
echo "sandbox_m4_pacman_mvp: OK on ${distro_id}"
echo "  pipeline:  archive.archlinux.org -> sha256-verify -> tar --zstd -> bwrap"
echo "  closure:   bash + readline + glibc + ncurses (1 root + 3 first-level %DEPENDS% after dedup)"
echo "  payload:   ${HELLO_SCRIPT} (host /tmp; bind-passthrough into the sandbox)"
echo "  output:    ${expected}"
exit 0

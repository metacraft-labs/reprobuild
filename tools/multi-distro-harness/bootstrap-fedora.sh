#!/bin/sh
# bootstrap-fedora.sh — reprobuild self-bootstrap on Fedora 44.
#
# Runs inside an already-provisioned `repro-fedora` WSL2 instance (M0
# provisioning is `pwsh tools/multi-distro-harness/provision-fedora.ps1`).
# Produces a working `repro` + `repro-standard-provider` pair at
# /tmp/reprobuild-bootstrap-fedora/bin/.
#
# Why no `nix develop`?
#   M3 of the Linux-Distro-Recipe-Validation campaign establishes the
#   Tier 1 build path on Fedora using only dnf + the source tree. The
#   nix dev shell is the canonical NixOS-only path; Fedora users need a
#   dnf-driven alternative.
#
# Dnf vs upstream sources:
#
#   Unlike M1 (Arch) and M2 (Debian/Ubuntu) where libclingo + libblake3
#   were NOT in the distro repos and had to be built from upstream
#   tarballs, Fedora 44 ships ALL THREE hash/solver dependencies in its
#   main repo:
#
#     - clingo-devel 5.8.0  (matches the upstream tag M1/M2 build)
#     - blake3-devel 1.8.3  (newer than M1/M2's upstream 1.5.0)
#     - xxhash-devel 0.8.3  (same as M2's apt xxhash)
#
#   This eliminates Steps 2 and 3 from the M2 bootstrap shape — the
#   only out-of-band install required is the choosenim-driven Nim 2.2.x
#   (Fedora 44's main repo has no `nim` package at all as of 2026-06).
#
# Dnf prerequisites:
#
#   gcc make            C toolchain (Fedora ships gcc 16.x; no meta-pkg
#                       like apt's `build-essential` — list each binary).
#   git curl ca-certificates xz
#                       repo + tarball + TLS roots + xz (compression).
#   pkgconf-pkg-config  pkg-config binary (Fedora renamed the package
#                       from `pkgconfig` to `pkgconf-pkg-config` —
#                       installs the `pkg-config` cli).
#   openssl-devel       reprobuild's nim-bearssl + a few stdlib paths.
#   sqlite-devel        reprobuild links libsqlite3 directly (config.nims).
#   cmake bison re2c    historically needed for clingo + blake3 upstream
#                       builds; harmless on Fedora since dnf provides
#                       both, but kept in the set so the script remains
#                       compatible with a future Fedora release where
#                       clingo gets pulled from the main repo.
#   unzip               tarball/zip extraction utility for recipes.
#   clingo-devel        libclingo.so + clingo.h (in /usr/lib64 + /usr/include).
#   blake3-devel        libblake3.so + blake3.h (in /usr/lib64 + /usr/include).
#   xxhash-devel        libxxhash.so + xxhash.h (in /usr/lib64 + /usr/include).
#
# Nim source:
#   Fedora 44's main + updates repos do NOT ship a `nim` package; we use
#   M0's choosenim install at /root/.nimble/bin/nim (Nim 2.2.10), same
#   strategy as M2's Debian/Ubuntu bootstraps.
#
# Fedora /usr/lib64 layout:
#   Fedora installs shared libraries to /usr/lib64/ (not /usr/lib/ — the
#   latter is reserved for 32-bit libs). Reprobuild's `config.nims`
#   `firstExistingPrefix` only probes `<prefix>/lib/<dylib>` (NOT
#   `<prefix>/lib64/`), so setting `BLAKE3_PREFIX=/usr` would fail
#   resolution. Mirror M2's apt-multiarch workaround: symlink the
#   dnf-shipped headers + libraries into `/usr/local/{include,lib}/`
#   and export `BLAKE3_PREFIX=/usr/local` + `XXHASH_PREFIX=/usr/local`.
#   A cleaner fix would be a `config.nims` patch teaching the helper
#   about /usr/lib64; that's a source change and out of M3 scope.
#
# Why does this script stage the workspace from /mnt/d/metacraft (the
# Windows-side checkout) instead of cloning from github.com?
#   Same rationale as M1/M2: the Windows-side workspace already has
#   every sibling repo + the workspace lock applied, and building off
#   the 9P-mounted Windows filesystem is 10-100x slower for Nim's many
#   small-file writes. The build redirects nimcache to a Linux-native
#   /tmp tree but reads sources directly from /mnt/d/.
#
# Exit codes (compatible with M1/M2's contract):
#   0  success — repro + repro-standard-provider built, --version works.
#   1  generic failure (dnf / nim / network).
#   2  reprobuild repo source tree not visible at /mnt/d/metacraft/reprobuild.
#   3  reserved (was clingo build failure on M1/M2 — N/A on Fedora).
#   4  reserved (was blake3 build failure on M1/M2 — N/A on Fedora).
#   5  reprobuild Nim build failure.
#   6  produced binary does not run.

set -eu

WORK_ROOT="${REPRO_BOOTSTRAP_ROOT:-/tmp/reprobuild-bootstrap-fedora}"
SRC_MOUNT="${REPRO_BOOTSTRAP_SRC:-/mnt/d/metacraft}"
NIM_BIN="${REPRO_BOOTSTRAP_NIM:-}"
BUILD_LOG="${WORK_ROOT}/bootstrap.log"

log() {
  printf '[bootstrap-fedora] %s\n' "$*"
}

err() {
  printf '[bootstrap-fedora] ERROR: %s\n' "$*" >&2
}

# ----------------------------------------------------------------------
# Step 0 — environment sanity.
# ----------------------------------------------------------------------

if ! grep -q '^ID=fedora' /etc/os-release 2>/dev/null; then
  err "this script must run inside a Fedora instance (repro-fedora)"
  exit 1
fi

if [ ! -d "${SRC_MOUNT}/reprobuild" ]; then
  err "reprobuild source tree not found at ${SRC_MOUNT}/reprobuild"
  err "expected the Windows-side checkout to be mounted at /mnt/d/metacraft"
  err "(see provision-fedora.ps1 for how repro-fedora is set up)"
  exit 2
fi

mkdir -p "${WORK_ROOT}/bin"
mkdir -p "${WORK_ROOT}/nimcache"

# ----------------------------------------------------------------------
# Step 1 — dnf prerequisites.
# ----------------------------------------------------------------------
#
# Minimum dnf package set required to build reprobuild from source on
# Fedora 44. Unlike M1 (Arch) + M2 (Debian/Ubuntu), Fedora ships clingo,
# blake3, and xxhash in its main repo — so the upstream clingo + BLAKE3
# tarball builds from M1/M2 are NOT needed here.
#
#   gcc make            C toolchain (no meta-pkg on Fedora).
#   git curl ca-certificates xz
#                       repo + tarball + TLS roots + xz.
#   pkgconf-pkg-config  provides the `pkg-config` binary (Fedora package
#                       renamed from `pkgconfig` in F32+).
#   openssl-devel       nim-bearssl + a few stdlib paths.
#   sqlite-devel        config.nims links libsqlite3 directly.
#   cmake bison re2c    held over from M1/M2 in case a future Fedora
#                       release drops one of clingo/blake3 from the main
#                       repo and this script falls back to an upstream
#                       build (defensive — harmless if unused).
#   unzip               tarball/zip extraction utility for recipes.
#   clingo-devel        libclingo.so + clingo.h.
#   blake3-devel        libblake3.so + blake3.h.
#   xxhash-devel        libxxhash.so + xxhash.h.

log "Step 1: dnf prerequisites"
dnf install -y --setopt=install_weak_deps=False \
  gcc make git curl ca-certificates xz \
  pkgconf-pkg-config openssl-devel sqlite-devel \
  cmake bison re2c unzip \
  clingo-devel blake3-devel xxhash-devel \
  >>"${BUILD_LOG}" 2>&1

# Symlink Fedora's /usr/lib64 + /usr/include headers into /usr/local so
# `config.nims`' `firstExistingPrefix(<prefix>/lib/<dylib>)` resolves
# cleanly (the helper does NOT probe lib64). This mirrors M2's apt
# multiarch workaround at /usr/local/lib + /usr/local/include.
mkdir -p /usr/local/lib /usr/local/include

# blake3
if [ ! -f /usr/local/lib/libblake3.so ] && \
   [ -f /usr/lib64/libblake3.so ]; then
  ln -sf /usr/lib64/libblake3.so      /usr/local/lib/libblake3.so
  if [ -f /usr/lib64/libblake3.so.0 ]; then
    ln -sf /usr/lib64/libblake3.so.0  /usr/local/lib/libblake3.so.0
  fi
  if [ -f /usr/include/blake3.h ]; then
    ln -sf /usr/include/blake3.h      /usr/local/include/blake3.h
  fi
  log "  blake3: symlinked dnf install into /usr/local for config.nims"
fi

# xxhash
if [ ! -f /usr/local/lib/libxxhash.so ] && \
   [ -f /usr/lib64/libxxhash.so ]; then
  ln -sf /usr/lib64/libxxhash.so      /usr/local/lib/libxxhash.so
  if [ -f /usr/lib64/libxxhash.so.0 ]; then
    ln -sf /usr/lib64/libxxhash.so.0  /usr/local/lib/libxxhash.so.0
  fi
  if [ -f /usr/include/xxhash.h ]; then
    ln -sf /usr/include/xxhash.h      /usr/local/include/xxhash.h
  fi
  if [ -f /usr/include/xxh3.h ]; then
    ln -sf /usr/include/xxh3.h        /usr/local/include/xxh3.h
  fi
  log "  xxhash: symlinked dnf install into /usr/local for config.nims"
fi

# clingo (loaded via dlopen at runtime; `repro_solver` doesn't link it
# at build time, so config.nims doesn't probe a prefix — we wire it via
# the system loader instead).
if [ ! -f /etc/ld.so.conf.d/local.conf ]; then
  echo '/usr/local/lib' > /etc/ld.so.conf.d/local.conf
fi
ldconfig

if [ -z "${NIM_BIN}" ]; then
  if command -v nim >/dev/null 2>&1; then
    NIM_BIN="$(command -v nim)"
  elif [ -x /root/.nimble/bin/nim ]; then
    # M0's choosenim install (provision-fedora.ps1 step 2).
    NIM_BIN=/root/.nimble/bin/nim
  else
    err "no nim binary found"
    err "expected M0's provision-fedora.ps1 to have installed choosenim"
    err "at /root/.nimble/bin/nim; re-provision or set REPRO_BOOTSTRAP_NIM"
    exit 1
  fi
fi

nim_version="$("${NIM_BIN}" --version 2>/dev/null | head -1)"
log "  nim: ${NIM_BIN} — ${nim_version}"

# Sanity-check Nim version >= 2.2.0.
case "$nim_version" in
  *'Version 2.2'*|*'Version 2.3'*|*'Version 2.4'*|*'Version 3.'*)
    : ;;
  *)
    err "nim version below the reprobuild minimum (2.2.0): ${nim_version}"
    exit 1 ;;
esac

# ----------------------------------------------------------------------
# Step 2 — clingo (from dnf; nothing to do beyond the install in Step 1).
# ----------------------------------------------------------------------
#
# Fedora 44 ships `clingo` 5.8.0 + `clingo-devel` in the main repo;
# libclingo.so lands at /usr/lib64/libclingo.so. M1's upstream-tarball
# build of clingo (and M1's re2c-4.3 compat patch from the AUR) are NOT
# needed here. The /usr/local/lib symlink for libblake3 + libxxhash
# from Step 1 doesn't need a parallel libclingo symlink because
# config.nims doesn't probe for clingo — `repro_solver` dlopens it via
# the system loader, which finds /usr/lib64/libclingo.so without
# any /usr/local indirection.

log "Step 2: clingo provided by dnf clingo-devel (no upstream build)"

# ----------------------------------------------------------------------
# Step 3 — BLAKE3 (from dnf; nothing to do beyond the install in Step 1).
# ----------------------------------------------------------------------
#
# Fedora 44 ships `blake3` 1.8.3 + `blake3-devel` in the main repo;
# libblake3.so lands at /usr/lib64/libblake3.so + the header at
# /usr/include/blake3.h. M1/M2's upstream BLAKE3 cmake build is NOT
# needed here. Step 1's symlink wired the dnf install into /usr/local
# for config.nims.

log "Step 3: BLAKE3 provided by dnf blake3-devel (no upstream build)"

# ----------------------------------------------------------------------
# Step 4 — build the `repro` + `repro-standard-provider` binaries.
# ----------------------------------------------------------------------
#
# Same shape as M1's bootstrap-arch.sh Step 4 + M2's bootstrap-debian.sh
# Step 4 — build from /mnt/d/metacraft/reprobuild with nimcache on a
# Linux-native /tmp tree.

log "Step 4: build repro + repro-standard-provider"
export REPROBUILD_USE_SYSTEM_HASH_LIBS=1
export BLAKE3_PREFIX=/usr/local
export XXHASH_PREFIX=/usr/local
export REPROBUILD_REPO_ROOT="${SRC_MOUNT}/reprobuild"

cd "${SRC_MOUNT}/reprobuild"
if ! "${NIM_BIN}" c -d:release \
    --hints:off --warnings:off \
    --nimcache:"${WORK_ROOT}/nimcache/repro" \
    --out:"${WORK_ROOT}/bin/repro" \
    apps/repro/repro.nim >>"${BUILD_LOG}" 2>&1; then
  err "nim build of apps/repro/repro.nim failed; see ${BUILD_LOG}"
  exit 5
fi
log "  built: ${WORK_ROOT}/bin/repro"

if ! "${NIM_BIN}" c -d:release -d:reproProviderMode \
    --hints:off --warnings:off \
    --nimcache:"${WORK_ROOT}/nimcache/repro-standard-provider" \
    --out:"${WORK_ROOT}/bin/repro-standard-provider" \
    apps/repro-standard-provider/repro_standard_provider.nim \
    >>"${BUILD_LOG}" 2>&1; then
  err "nim build of repro-standard-provider failed; see ${BUILD_LOG}"
  exit 5
fi
log "  built: ${WORK_ROOT}/bin/repro-standard-provider"

# ----------------------------------------------------------------------
# Step 5 — verify the binary runs.
# ----------------------------------------------------------------------

log "Step 5: verify"
got_version="$("${WORK_ROOT}/bin/repro" --version 2>&1 || true)"
log "  repro --version: ${got_version}"
case "$got_version" in
  'repro '*)
    log "  OK"
    ;;
  *)
    err "repro --version did not produce the expected 'repro <version>' line"
    err "got: ${got_version}"
    exit 6
    ;;
esac

log "bootstrap-fedora: OK"
log "  binaries: ${WORK_ROOT}/bin/{repro, repro-standard-provider}"
log "  log:      ${BUILD_LOG}"
log ""
log "To use the binary in subsequent shells, export:"
log "  export PATH=${WORK_ROOT}/bin:/root/.nimble/bin:/usr/local/bin:/usr/bin:\$PATH"
log "  export REPROBUILD_REPO_ROOT=${SRC_MOUNT}/reprobuild"
log "  export BLAKE3_PREFIX=/usr/local"
log "  export XXHASH_PREFIX=/usr/local"
log ""
log "Note: /root/.nimble/bin carries the choosenim-installed Nim 2.2.10"
log "that 'repro' invokes to compile recipe project files. Fedora 44's"
log "main repo has no 'nim' package at all, so this is the only Nim"
log "available."

#!/bin/sh
# bootstrap-debian.sh — reprobuild self-bootstrap on Debian 12 (Bookworm).
#
# Runs inside an already-provisioned `repro-debian` WSL2 instance (M0
# provisioning is `pwsh tools/multi-distro-harness/provision-debian.ps1`).
# Produces a working `repro` + `repro-standard-provider` pair at
# /tmp/reprobuild-bootstrap-debian/bin/.
#
# Why no `nix develop`?
#   M2 of the Linux-Distro-Recipe-Validation campaign establishes the
#   Tier 1 build path on Debian using only apt + the source tree. The
#   nix dev shell is the canonical NixOS-only path; Debian users need an
#   apt-driven alternative.
#
# Apt vs upstream sources:
#
#   - Apt ships:  gcc/make/binutils (build-essential), git, curl,
#                 ca-certificates, xz-utils, pkg-config, libssl-dev,
#                 libsqlite3-dev, libxxhash-dev, cmake, bison, re2c,
#                 unzip.
#   - NOT in Debian bookworm's apt repos:
#                 * libclingo-dev / clingo runtime
#                 * libblake3-dev
#                 * Nim 2.2.x  (apt's nim is 1.6.10 — too old for
#                   reprobuild's 2.2.0+ minimum)
#     For these, we mirror M1's upstream-build path: build clingo
#     5.8.0 and BLAKE3 1.5.0 from source via cmake to /usr/local, and
#     use the choosenim-installed Nim 2.2.10 at /root/.nimble/bin/nim
#     (already provisioned by M0's provision-debian.ps1).
#
# Re2c divergence from M1:
#   Arch ships re2c 4.5+ which removed the legacy `condition` block
#   syntax clingo 5.8.0's vendored grammar files use, requiring the
#   AUR's re2c-4.3 compat patch. Debian bookworm ships re2c 3.0 (older)
#   which still accepts the legacy syntax — the patch is unnecessary
#   and is NOT applied here.
#
# xxhash apt layout:
#   Debian's libxxhash-dev installs the shared library at
#   /usr/lib/x86_64-linux-gnu/libxxhash.so (the Debian multiarch path)
#   but reprobuild's config.nims `firstExistingPrefix` only checks
#   `<prefix>/lib/<dylibName>`. To make the resolution work without
#   modifying config.nims, this script symlinks the apt-shipped header
#   and lib into /usr/local/include + /usr/local/lib alongside BLAKE3,
#   and exports `XXHASH_PREFIX=/usr/local`.
#
# Why does this script stage the workspace from /mnt/d/metacraft (the
# Windows-side checkout) instead of cloning from github.com?
#   Same rationale as M1's bootstrap-arch.sh: the Windows-side workspace
#   already has every sibling repo + the workspace lock applied, and
#   building off the 9P-mounted Windows filesystem is 10-100x slower for
#   Nim's many small-file writes. The build redirects nimcache to a
#   Linux-native /tmp tree but reads sources directly from /mnt/d/.
#
# Exit codes:
#   0  success — repro + repro-standard-provider built, --version works.
#   1  generic failure (apt / nim / network).
#   2  reprobuild repo source tree not visible at /mnt/d/metacraft/reprobuild.
#   3  clingo build failure.
#   4  blake3 build failure.
#   5  reprobuild Nim build failure.
#   6  produced binary does not run.

set -eu

WORK_ROOT="${REPRO_BOOTSTRAP_ROOT:-/tmp/reprobuild-bootstrap-debian}"
SRC_MOUNT="${REPRO_BOOTSTRAP_SRC:-/mnt/d/metacraft}"
NIM_BIN="${REPRO_BOOTSTRAP_NIM:-}"
BUILD_LOG="${WORK_ROOT}/bootstrap.log"

log() {
  printf '[bootstrap-debian] %s\n' "$*"
}

err() {
  printf '[bootstrap-debian] ERROR: %s\n' "$*" >&2
}

# ----------------------------------------------------------------------
# Step 0 — environment sanity.
# ----------------------------------------------------------------------

if ! grep -q '^ID=debian' /etc/os-release 2>/dev/null; then
  err "this script must run inside a Debian instance (repro-debian)"
  exit 1
fi

if [ ! -d "${SRC_MOUNT}/reprobuild" ]; then
  err "reprobuild source tree not found at ${SRC_MOUNT}/reprobuild"
  err "expected the Windows-side checkout to be mounted at /mnt/d/metacraft"
  err "(see provision-debian.ps1 for how repro-debian is set up)"
  exit 2
fi

mkdir -p "${WORK_ROOT}/bin"
mkdir -p "${WORK_ROOT}/nimcache"

# ----------------------------------------------------------------------
# Step 1 — apt prerequisites.
# ----------------------------------------------------------------------
#
# Minimum apt package set required to build reprobuild from source on
# Debian bookworm:
#
#   build-essential     gcc + make + binutils + libc6-dev — the C toolchain.
#   git                 repo cloning + the bootstrap repo.
#   curl                downloading clingo / blake3 tarballs.
#   ca-certificates     TLS roots for github.com downloads.
#   xz-utils            tarball decompression for upstream sources.
#   pkg-config          link-flag resolution for libssl / libsqlite3 / etc.
#   libssl-dev          reprobuild's nim-bearssl + a few stdlib paths.
#   libsqlite3-dev      reprobuild links libsqlite3 directly (see config.nims).
#   libxxhash-dev       reprobuild_hash uses xxhash; symlinked into /usr/local
#                       below so config.nims `firstExistingPrefix` finds it.
#   cmake               required to build clingo + blake3 from upstream.
#   bison               clingo grammar generation.
#   re2c                clingo build-time tool. Debian's 3.0 is OLDER than
#                       Arch's 4.5 and accepts the legacy `condition` syntax
#                       clingo 5.8.0 uses — no compat patch needed here.
#   unzip               available for tarball/zip extraction in downstream
#                       recipes.
#
# What's intentionally NOT installed via apt:
#   libclingo-dev / clingo  — not in bookworm's apt repos as of 2026-06.
#                              Built from upstream below.
#   libblake3-dev            — not in bookworm's apt repos as of 2026-06.
#                              Built from upstream below.
#   nim                      — apt ships 1.6.10, below reprobuild's 2.2.0
#                              minimum. We use M0's choosenim install at
#                              /root/.nimble/bin/nim (Nim 2.2.10).

log "Step 1: apt prerequisites"
export DEBIAN_FRONTEND=noninteractive
apt-get update >>"${BUILD_LOG}" 2>&1 || true
apt-get install -y --no-install-recommends \
  build-essential git curl ca-certificates xz-utils \
  pkg-config libssl-dev libsqlite3-dev libxxhash-dev \
  cmake bison re2c unzip >>"${BUILD_LOG}" 2>&1

# Symlink Debian's multiarch xxhash into /usr/local so config.nims'
# `firstExistingPrefix(XXHASH_PREFIX/lib/libxxhash.so)` resolves cleanly.
if [ ! -f /usr/local/lib/libxxhash.so ] && \
   [ -f /usr/lib/x86_64-linux-gnu/libxxhash.so ]; then
  mkdir -p /usr/local/lib /usr/local/include
  ln -sf /usr/lib/x86_64-linux-gnu/libxxhash.so      /usr/local/lib/libxxhash.so
  ln -sf /usr/lib/x86_64-linux-gnu/libxxhash.so.0    /usr/local/lib/libxxhash.so.0
  ln -sf /usr/include/xxhash.h                       /usr/local/include/xxhash.h
  if [ -f /usr/include/xxh3.h ]; then
    ln -sf /usr/include/xxh3.h                       /usr/local/include/xxh3.h
  fi
  log "  xxhash: symlinked apt install into /usr/local for config.nims"
fi

if [ -z "${NIM_BIN}" ]; then
  if command -v nim >/dev/null 2>&1; then
    NIM_BIN="$(command -v nim)"
  elif [ -x /root/.nimble/bin/nim ]; then
    # M0's choosenim install (provision-debian.ps1 step 2).
    NIM_BIN=/root/.nimble/bin/nim
  else
    err "no nim binary found"
    err "expected M0's provision-debian.ps1 to have installed choosenim"
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
# Step 2 — build clingo from upstream.
# ----------------------------------------------------------------------
#
# reprobuild's repro_solver dlopens libclingo.so at runtime. Debian
# bookworm does not ship libclingo-dev / clingo in its apt repos as of
# 2026-06; build clingo 5.8.0 from the upstream tarball, install to
# /usr/local, and wire /usr/local/lib into ldconfig.
#
# Unlike M1 on Arch, the AUR's re2c-4.3 compat patch is NOT applied here:
# Debian bookworm ships re2c 3.0, which still accepts the legacy
# `condition` block syntax clingo's vendored grammar files use.

if [ ! -f /usr/local/lib/libclingo.so ]; then
  log "Step 2: build clingo from upstream"
  cd "${WORK_ROOT}"
  if [ ! -f clingo-5.8.0.tar.gz ]; then
    curl -fsSL -o clingo-5.8.0.tar.gz \
      https://github.com/potassco/clingo/archive/refs/tags/v5.8.0.tar.gz
  fi
  rm -rf clingo-5.8.0
  tar xzf clingo-5.8.0.tar.gz
  cd clingo-5.8.0
  if ! cmake -B build -S . -DCMAKE_BUILD_TYPE=Release \
      -DCLINGO_BUILD_TESTS=OFF -DCLINGO_BUILD_EXAMPLES=OFF \
      -DCLINGO_BUILD_APPS=OFF -DCLINGO_BUILD_SHARED=ON \
      -DCMAKE_INSTALL_PREFIX=/usr/local >>"${BUILD_LOG}" 2>&1; then
    err "clingo: cmake configure failed"
    exit 3
  fi
  if ! cmake --build build --parallel "$(nproc)" >>"${BUILD_LOG}" 2>&1; then
    err "clingo: build failed"
    exit 3
  fi
  if ! cmake --install build >>"${BUILD_LOG}" 2>&1; then
    err "clingo: install failed"
    exit 3
  fi
  echo '/usr/local/lib' > /etc/ld.so.conf.d/local.conf
  ldconfig
  log "  clingo: installed at /usr/local/lib/libclingo.so"
else
  log "Step 2: clingo already installed at /usr/local/lib/libclingo.so (skip)"
fi

# ----------------------------------------------------------------------
# Step 3 — build BLAKE3 from upstream.
# ----------------------------------------------------------------------
#
# Debian bookworm does not ship libblake3-dev in its apt repos as of
# 2026-06. (Debian trixie / Ubuntu 24.04 noble DO ship it; this script
# targets bookworm.) Mirror M1's path: build the upstream BLAKE3-team/
# BLAKE3 cmake project and install to /usr/local.

if [ ! -f /usr/local/lib/libblake3.so ]; then
  log "Step 3: build BLAKE3 from upstream"
  cd "${WORK_ROOT}"
  if [ ! -f BLAKE3-1.5.0.tar.gz ]; then
    curl -fsSL -o BLAKE3-1.5.0.tar.gz \
      https://github.com/BLAKE3-team/BLAKE3/archive/refs/tags/1.5.0.tar.gz
  fi
  rm -rf BLAKE3-1.5.0
  tar xzf BLAKE3-1.5.0.tar.gz
  cd BLAKE3-1.5.0/c
  if ! cmake -B build -S . -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_SHARED_LIBS=ON -DCMAKE_INSTALL_PREFIX=/usr/local \
      >>"${BUILD_LOG}" 2>&1; then
    err "blake3: cmake configure failed"
    exit 4
  fi
  if ! cmake --build build --parallel "$(nproc)" >>"${BUILD_LOG}" 2>&1; then
    err "blake3: build failed"
    exit 4
  fi
  if ! cmake --install build >>"${BUILD_LOG}" 2>&1; then
    err "blake3: install failed"
    exit 4
  fi
  ldconfig
  log "  blake3: installed at /usr/local/lib/libblake3.so"
else
  log "Step 3: BLAKE3 already installed at /usr/local/lib/libblake3.so (skip)"
fi

# ----------------------------------------------------------------------
# Step 4 — build the `repro` + `repro-standard-provider` binaries.
# ----------------------------------------------------------------------
#
# Same shape as M1's bootstrap-arch.sh Step 4 — build from
# /mnt/d/metacraft/reprobuild with nimcache on a Linux-native /tmp tree.

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

log "bootstrap-debian: OK"
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
log "that 'repro' invokes to compile recipe project files. Unlike Arch"
log "(pacman 'nim' in /usr/sbin), Debian's nim is not on the default PATH."

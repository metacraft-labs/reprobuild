#!/bin/sh
# bootstrap-ubuntu.sh — reprobuild self-bootstrap on Ubuntu 22.04 (Jammy).
#
# Runs inside an already-provisioned `repro-ubuntu` WSL2 instance (M0
# provisioning is `pwsh tools/multi-distro-harness/provision-ubuntu.ps1`).
# Produces a working `repro` + `repro-standard-provider` pair at
# /tmp/reprobuild-bootstrap-ubuntu/bin/.
#
# Relationship to bootstrap-debian.sh:
#   Ubuntu 22.04 jammy is Debian-derived; the apt package layout and
#   prereq set are nearly identical. We deliberately keep this as its
#   own script (rather than factoring out a shared helper) because:
#     1. Each milestone (M2 = Debian/Ubuntu, M3 = Fedora, M4 = Alpine)
#        is its own deliverable in the Linux-Distro-Recipe-Validation
#        campaign; refactoring across milestones is a separate concern.
#     2. Ubuntu-jammy-specific divergences from Debian-bookworm exist
#        (apt sources, libssl-dev version cadence, no nim apt package
#        at all in jammy's main repos vs Debian's 1.6.10) and are
#        documented inline below.
#
# Ubuntu-specific divergences from bootstrap-debian.sh:
#   - **Nim**: Ubuntu 22.04 jammy's main apt repos do NOT ship `nim` at
#     all (Debian bookworm ships 1.6.10). We rely on M0's choosenim
#     install at /root/.nimble/bin/nim (Nim 2.2.10), same as the
#     Debian script's fallback.
#   - **No PPA needed**: every other prereq (build-essential, cmake,
#     bison, re2c 3.0, libxxhash-dev, libssl-dev, libsqlite3-dev,
#     pkg-config, unzip) is in jammy's main + universe repos.
#   - **xxhash multiarch**: same Debian-style layout
#     (/usr/lib/x86_64-linux-gnu/libxxhash.so); same symlink workaround.
#   - **re2c version**: jammy ships re2c 3.0, same as Debian bookworm —
#     the AUR's re2c-4.3 compat patch from M1 is NOT applied.
#   - **clingo**: not in jammy's repos; built from upstream like Debian.
#   - **BLAKE3**: not in jammy's repos (Ubuntu 24.04 noble DOES ship
#     libblake3-dev; jammy does NOT); built from upstream like Debian.
#
# Exit codes (identical to bootstrap-debian.sh):
#   0  success — repro + repro-standard-provider built, --version works.
#   1  generic failure (apt / nim / network).
#   2  reprobuild repo source tree not visible at /mnt/d/metacraft/reprobuild.
#   3  clingo build failure.
#   4  blake3 build failure.
#   5  reprobuild Nim build failure.
#   6  produced binary does not run.

set -eu

WORK_ROOT="${REPRO_BOOTSTRAP_ROOT:-/tmp/reprobuild-bootstrap-ubuntu}"
SRC_MOUNT="${REPRO_BOOTSTRAP_SRC:-/mnt/d/metacraft}"
NIM_BIN="${REPRO_BOOTSTRAP_NIM:-}"
BUILD_LOG="${WORK_ROOT}/bootstrap.log"

log() {
  printf '[bootstrap-ubuntu] %s\n' "$*"
}

err() {
  printf '[bootstrap-ubuntu] ERROR: %s\n' "$*" >&2
}

# ----------------------------------------------------------------------
# Step 0 — environment sanity.
# ----------------------------------------------------------------------

if ! grep -q '^ID=ubuntu' /etc/os-release 2>/dev/null; then
  err "this script must run inside an Ubuntu instance (repro-ubuntu)"
  exit 1
fi

if [ ! -d "${SRC_MOUNT}/reprobuild" ]; then
  err "reprobuild source tree not found at ${SRC_MOUNT}/reprobuild"
  err "expected the Windows-side checkout to be mounted at /mnt/d/metacraft"
  err "(see provision-ubuntu.ps1 for how repro-ubuntu is set up)"
  exit 2
fi

mkdir -p "${WORK_ROOT}/bin"
mkdir -p "${WORK_ROOT}/nimcache"

# ----------------------------------------------------------------------
# Step 1 — apt prerequisites.
# ----------------------------------------------------------------------
#
# Minimum apt package set required to build reprobuild from source on
# Ubuntu jammy (22.04 LTS). Same set as Debian bookworm — the package
# names are identical in this region of the archive.
#
#   build-essential     gcc + make + binutils + libc6-dev — the C toolchain.
#   git                 repo cloning + the bootstrap repo.
#   curl                downloading clingo / blake3 tarballs.
#   ca-certificates     TLS roots for github.com downloads.
#   xz-utils            tarball decompression for upstream sources.
#   pkg-config          link-flag resolution.
#   libssl-dev          reprobuild's nim-bearssl + a few stdlib paths.
#   libsqlite3-dev      reprobuild links libsqlite3 directly (see config.nims).
#   libxxhash-dev       reprobuild_hash uses xxhash; symlinked into /usr/local
#                       below so config.nims `firstExistingPrefix` finds it.
#   cmake               required to build clingo + blake3 from upstream.
#   bison               clingo grammar generation.
#   re2c                clingo build-time tool (3.0 on jammy, same as bookworm).
#   unzip               tarball/zip extraction utility for recipes.
#
# What's intentionally NOT installed via apt:
#   libclingo-dev / clingo  — not in jammy's apt repos as of 2026-06.
#                              Built from upstream below.
#   libblake3-dev            — not in jammy's apt repos (it IS in noble's,
#                              i.e. Ubuntu 24.04). For jammy, built from
#                              upstream below.
#   nim                      — jammy's main + universe repos don't ship nim
#                              at all. We use M0's choosenim install at
#                              /root/.nimble/bin/nim (Nim 2.2.10).

log "Step 1: apt prerequisites"
export DEBIAN_FRONTEND=noninteractive
apt-get update >>"${BUILD_LOG}" 2>&1 || true
apt-get install -y --no-install-recommends \
  build-essential git curl ca-certificates xz-utils \
  pkg-config libssl-dev libsqlite3-dev libxxhash-dev \
  cmake bison re2c unzip >>"${BUILD_LOG}" 2>&1

# Symlink Ubuntu's multiarch xxhash into /usr/local so config.nims'
# `firstExistingPrefix(XXHASH_PREFIX/lib/libxxhash.so)` resolves cleanly
# (the apt install lays the .so under /usr/lib/x86_64-linux-gnu/, which
# the config.nims helper doesn't search).
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
    # M0's choosenim install (provision-ubuntu.ps1 step 2).
    NIM_BIN=/root/.nimble/bin/nim
  else
    err "no nim binary found"
    err "expected M0's provision-ubuntu.ps1 to have installed choosenim"
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
# Same shape as bootstrap-debian.sh Step 2. Ubuntu jammy ships re2c 3.0
# which accepts clingo 5.8.0's vendored grammar files; the AUR's
# re2c-4.3 compat patch from M1 is NOT applied here.

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
# Ubuntu jammy does not ship libblake3-dev (Ubuntu 24.04 noble does).
# Mirror M1's path: build the upstream BLAKE3-team/BLAKE3 cmake project
# and install to /usr/local.

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

log "bootstrap-ubuntu: OK"
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
log "that 'repro' invokes to compile recipe project files. Ubuntu jammy"
log "ships no 'nim' package at all in main+universe, so this is the only"
log "Nim available."

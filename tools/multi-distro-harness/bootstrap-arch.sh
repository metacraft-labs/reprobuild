#!/bin/sh
# bootstrap-arch.sh — reprobuild self-bootstrap on Arch Linux (no nix develop).
#
# Runs inside an already-provisioned `repro-arch` WSL2 instance (M0
# provisioning is `pwsh tools/multi-distro-harness/provision-arch.ps1`).
# Produces a working `repro` + `repro-standard-provider` pair at
# /tmp/reprobuild-bootstrap-arch/bin/.
#
# Why no `nix develop`?
#   M1 of the Linux-Distro-Recipe-Validation campaign establishes the
#   Tier 1 build path on Arch using only pacman + the source tree. The
#   nix dev shell is the canonical NixOS-only path; Arch users need a
#   pacman-driven alternative.
#
# Why does this script stage the workspace from /mnt/d/metacraft (the
# Windows-side checkout) instead of cloning from github.com?
#   1. The branch `dev` carries the M0 harness commit (08995ad) which is
#      already pushed, BUT the bootstrap also needs every workspace
#      sibling repo on `config.nims`'s --path search (runquota,
#      codetracer-native-recorder, nim-bearssl, ...). Cloning all of
#      them from individual remotes would multiply the bootstrap cost
#      and the network dependency surface.
#   2. The user's existing Windows-side workspace at /mnt/d/metacraft/
#      is the canonical reprobuild + sibling checkout. rsync-staging
#      from there into /tmp keeps the build off the slow 9P-mounted
#      Windows filesystem (10-100x slowdown observed on Nim's many
#      small-file writes).
#   3. The Windows-side checkout already has the workspace lock applied,
#      so sibling-pin drift is impossible.
#
# Exit codes:
#   0  success — repro + repro-standard-provider built, --version works.
#   1  generic failure (pacman / nim / network).
#   2  reprobuild repo source tree not visible at /mnt/d/metacraft/reprobuild.
#   3  clingo build failure.
#   4  blake3 build failure.
#   5  reprobuild Nim build failure.
#   6  produced binary does not run.

set -eu

WORK_ROOT="${REPRO_BOOTSTRAP_ROOT:-/tmp/reprobuild-bootstrap-arch}"
SRC_MOUNT="${REPRO_BOOTSTRAP_SRC:-/mnt/d/metacraft}"
NIM_BIN="${REPRO_BOOTSTRAP_NIM:-}"
BUILD_LOG="${WORK_ROOT}/bootstrap.log"

log() {
  printf '[bootstrap-arch] %s\n' "$*"
}

err() {
  printf '[bootstrap-arch] ERROR: %s\n' "$*" >&2
}

# ----------------------------------------------------------------------
# Step 0 — environment sanity.
# ----------------------------------------------------------------------

if ! grep -q '^ID=arch' /etc/os-release 2>/dev/null; then
  err "this script must run inside an Arch Linux instance (repro-arch)"
  exit 1
fi

if [ ! -d "${SRC_MOUNT}/reprobuild" ]; then
  err "reprobuild source tree not found at ${SRC_MOUNT}/reprobuild"
  err "expected the Windows-side checkout to be mounted at /mnt/d/metacraft"
  err "(see provision-arch.ps1 for how repro-arch is set up)"
  exit 2
fi

mkdir -p "${WORK_ROOT}/bin"
mkdir -p "${WORK_ROOT}/nimcache"

# ----------------------------------------------------------------------
# Step 1 — pacman prerequisites.
# ----------------------------------------------------------------------
#
# Minimum package set required to build reprobuild from source on Arch:
#
#   base-devel   gcc, make, binutils, fakeroot, patch — the C toolchain
#                and PKGBUILD-style build helpers.
#   git          repo cloning + the bootstrap repo + clingo patch fetch.
#   curl         downloading clingo / blake3 / patch tarballs.
#   ca-certificates  TLS roots for github.com downloads.
#   xz           tarball decompression for upstream sources.
#   nim          Arch ships current Nim (2.2.10 at time of writing).
#                Alternative: choosenim (already installed by M0's
#                provision-arch.ps1 at /root/.nimble/bin/nim). Either
#                works; this script prefers the pacman-shipped one for
#                predictability and skips the install when nim is
#                already on PATH.
#   sqlite       reprobuild links libsqlite3 directly (see config.nims).
#   openssl      transitive (nim-bearssl + a few stdlib paths).
#   cmake        required to build clingo + blake3 from upstream.
#   bison re2c   clingo build-time tools (re2c >= 4.3 needs the AUR
#                compat patch; this script applies it inline).
#
# Why not blake3 / xxh3 / gxhash?
#   - xxhash IS in extra/ (installed during M0 smoke probe).
#   - blake3 is NOT in Arch's official repos as of 2026-06; we build it
#     from the upstream BLAKE3-team/BLAKE3 cmake project below.
#   - gxhash is a Rust crate, not a system library; reprobuild's
#     libs/gxhash/ wraps the vendored Nim port — no system install
#     needed.
#
# Why not clingo from pacman?
#   - Not in core/extra. The AUR carries it (https://aur.archlinux.org/
#     packages/clingo) but pulling AUR packages requires either an AUR
#     helper (paru/yay) or a makepkg/PKGBUILD ceremony. Building clingo
#     directly from the upstream tarball is simpler and reproducible.
#     We apply the AUR's re2c-4.3 compat patch inline.

log "Step 1: pacman prerequisites"
pacman -Sy --noconfirm >>"${BUILD_LOG}" 2>&1 || true
pacman -S --noconfirm --needed --overwrite='*' \
  base-devel git curl ca-certificates xz nim sqlite openssl \
  cmake bison re2c >>"${BUILD_LOG}" 2>&1

if [ -z "${NIM_BIN}" ]; then
  if command -v nim >/dev/null 2>&1; then
    NIM_BIN="$(command -v nim)"
  elif [ -x /root/.nimble/bin/nim ]; then
    # M0's choosenim install (provision-arch.ps1 step 2).
    NIM_BIN=/root/.nimble/bin/nim
  else
    err "no nim binary found after pacman install"
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
# reprobuild's repro_solver dlopens libclingo.so at runtime (the dynlib
# pragma in libs/repro_solver/src/repro_solver/clingo_bindings.nim
# names the unsuffixed soname). We build clingo 5.8.0 from the upstream
# tarball, apply the AUR's re2c-4.3 compat patch (current Arch ships
# re2c 4.5+ which removed the legacy `condition` block syntax clingo's
# vendored grammar files used), install to /usr/local, and wire
# /usr/local/lib into ldconfig.

if [ ! -f /usr/local/lib/libclingo.so ]; then
  log "Step 2: build clingo from upstream"
  cd "${WORK_ROOT}"
  if [ ! -f clingo-5.8.0.tar.gz ]; then
    curl -fsSL -o clingo-5.8.0.tar.gz \
      https://github.com/potassco/clingo/archive/refs/tags/v5.8.0.tar.gz
  fi
  rm -rf clingo-5.8.0 aur-clingo
  tar xzf clingo-5.8.0.tar.gz
  # Apply the AUR's re2c-4.3 compat patch. We pull it via a depth-1 git
  # clone of the AUR PKGBUILD repo (the patch alone is not separately
  # hosted upstream).
  if ! git clone --depth 1 https://aur.archlinux.org/clingo.git aur-clingo \
       >>"${BUILD_LOG}" 2>&1; then
    err "clingo: could not fetch re2c compat patch from AUR"
    exit 3
  fi
  cd clingo-5.8.0
  if ! patch -Np1 -i ../aur-clingo/fix-re2c-4.3-compat.patch \
       >>"${BUILD_LOG}" 2>&1; then
    err "clingo: re2c compat patch did not apply"
    exit 3
  fi
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
# reprobuild's libs/blake3/ wraps either a vendored portable C source
# (under references/mold/third-party/blake3/c/, only wired on Windows
# via `when defined(windows) or defined(reproVendoredHash)`) OR a system
# libblake3. The Linux non-Nix path expects a system install at
# $BLAKE3_PREFIX/include/blake3.h + $BLAKE3_PREFIX/lib/libblake3.so.
# Arch's official repos don't ship blake3, so we build the upstream
# BLAKE3-team/BLAKE3 cmake project and install to /usr/local.
#
# (The vendored sources COULD also be wired by adjusting
# repro_interface_artifacts.nim's externalHashFlags() to fall back to
# the vendored copy on Linux when no system install is found, but that
# is a source change and out of scope for the bootstrap script.)

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
# We build directly from /mnt/d/metacraft/reprobuild — the Windows-side
# checkout that already has the workspace lock applied. The build uses
# /tmp/.../nimcache/ as the nimcache root (a Linux native filesystem)
# so Nim's heavy small-file write traffic doesn't hit the 9P-mounted
# Windows tree. The two output binaries land at
# ${WORK_ROOT}/bin/{repro, repro-standard-provider}.
#
# Required env exports:
#   REPROBUILD_USE_SYSTEM_HASH_LIBS=1
#       Switches config.nims away from the `reproVendoredHash` define
#       (which is the Windows-only path) and onto the system blake3 +
#       xxhash install we just produced.
#   BLAKE3_PREFIX=/usr/local
#       Tells config.nims AND externalHashFlags() where libblake3 is.
#   XXHASH_PREFIX=/usr
#       Tells the same where libxxhash is (pacman's xxhash ships under
#       /usr/include + /usr/lib).
#   REPROBUILD_REPO_ROOT=/mnt/d/metacraft/reprobuild
#       Runtime fallback for `reprobuildRepoRoot()` in
#       libs/repro_profile_compile/src/repro_profile_compile/sources.nim.
#       The compile-time anchor (`CompiledRepoRoot`) would resolve to a
#       /tmp/.../nimcache-derived path; the env override forces the
#       real on-disk source tree.

log "Step 4: build repro + repro-standard-provider"
export REPROBUILD_USE_SYSTEM_HASH_LIBS=1
export BLAKE3_PREFIX=/usr/local
export XXHASH_PREFIX=/usr
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

log "Bootstrap complete."
log "  binaries: ${WORK_ROOT}/bin/{repro, repro-standard-provider}"
log "  log:      ${BUILD_LOG}"
log ""
log "To use the binary in subsequent shells, export:"
log "  export PATH=${WORK_ROOT}/bin:/usr/local/bin:/usr/bin:\$PATH"
log "  export REPROBUILD_REPO_ROOT=${SRC_MOUNT}/reprobuild"
log "  export BLAKE3_PREFIX=/usr/local"
log "  export XXHASH_PREFIX=/usr"

#!/bin/sh
# bootstrap-alpine.sh — reprobuild self-bootstrap on Alpine 3.19 (musl).
#
# Runs inside an already-provisioned `repro-alpine` WSL2 instance (M0
# provisioning is `pwsh tools/multi-distro-harness/provision-alpine.ps1`).
# Produces a working `repro` + `repro-standard-provider` pair at
# /tmp/reprobuild-bootstrap-alpine/bin/.
#
# Why no `nix develop`?
#   M4 of the Linux-Distro-Recipe-Validation campaign establishes the
#   Tier 1 build path on Alpine using only apk + the source tree. The
#   nix dev shell is the canonical NixOS-only path; Alpine users need
#   an apk-driven alternative. Alpine matters disproportionately because
#   it is the campaign's only musl-libc baseline AND the ReproOS-MVP
#   bootstrap chain (hex0 -> tcc -> gcc -> musl) targets musl.
#
# Apk vs upstream sources:
#
#   Alpine 3.19's main + community repos ship clingo 5.6.2 + xxhash-dev
#   0.8.2 but NO blake3 package at all. The Alpine `edge` repos (the
#   rolling-release pre-3.20 channel) carry the missing dependencies:
#
#     - blake3-dev 1.8.5    (edge/community; matches Fedora 44's 1.8.3
#                            within back-compat C API)
#     - xxhash-dev 0.8.3    (edge/main; a minor bump over v3.19's 0.8.2,
#                            chosen for consistency with the other
#                            edge-sourced versions)
#     - clingo-dev 5.8.0    (edge/community; matches the M1/M2 upstream
#                            tarball build version)
#
#   Unlike M1 (Arch) + M2 (Debian/Ubuntu) where libclingo + libblake3
#   had to be built from upstream tarballs, Alpine edge ships ALL
#   THREE in apk — this eliminates the upstream Steps 2 and 3 from the
#   M1/M2 bootstrap shape and matches the M3 (Fedora) shape exactly.
#
# Nim source build:
#
#   Alpine edge/community ships nim 2.2.0, but Nim 2.2.0 has a known
#   codegen bug that mis-generates the eqdestroy hook signature for
#   sequence types — reprobuild's `apps/repro` build hits this at
#   `codec_u551`/`codec_u388` in `repro_dev_env_artifacts/codec.nim`
#   (the gcc error reads "expected 'tySequence__... *' but argument
#   is of type 'tySequence__...'"). Fixed in Nim 2.2.2+.
#
#   choosenim is NOT a fallback option: its pre-built Nim binaries are
#   glibc-linked and refuse to execute on musl ("ELF interpreter not
#   found" — the dynamic linker is `/lib64/ld-linux-x86-64.so.2`, which
#   doesn't exist on Alpine; musl's loader is `/lib/ld-musl-x86_64.so.1`).
#
#   Solution: bootstrap Nim 2.2.10 from the upstream source tarball.
#   Nim ships a frozen csources subtree (`c_code/`) inside its release
#   tarball which compiles via plain gcc — no pre-existing Nim required.
#   `./build.sh` builds a v1 nim from those csources (~30 s); then
#   `./koch boot -d:release` self-hosts up to 2.2.10 (~2 min). Total
#   wall time ~2 min added to the cold path. This matches M1-M3's
#   Nim 2.2.10 version exactly, so the only sha256 divergence from
#   M1-M3 will come from the libc + gcc deltas (which IS what M4 is
#   meant to surface for the ReproOS musl track).
#
# Apk prerequisites:
#
#   build-base          C toolchain (gcc + make + binutils + musl-dev,
#                       Alpine's equivalent of Debian's `build-essential`
#                       and Arch's `base-devel`). musl-dev replaces
#                       glibc-headers; everything below libc looks
#                       different from glibc-based distros.
#   git curl ca-certificates xz
#                       repo + tarball + TLS roots + xz (compression).
#                       `curl` already on the image; `xz` is needed to
#                       extract the Nim 2.2.10 tarball (.tar.xz).
#   pkgconf             pkg-config binary (Alpine's package name; provides
#                       a /usr/bin/pkg-config alias).
#   openssl-dev         reprobuild's nim-bearssl + a few stdlib paths.
#   sqlite-dev          reprobuild links libsqlite3 directly (config.nims).
#   cmake bison re2c    held over from M1/M2 in case a future bootstrap
#                       falls back to upstream clingo/blake3 builds
#                       (defensive — harmless if unused).
#   unzip               tarball/zip extraction utility for recipes.
#   blake3-dev          libblake3.so + blake3.h from edge/community.
#   xxhash-dev          libxxhash.so + xxhash.h from edge/main.
#   clingo-dev          libclingo.so + clingo.h from edge/community.
#
# Alpine /usr/lib layout:
#   Unlike Debian/Ubuntu (multiarch /usr/lib/x86_64-linux-gnu/) and
#   Fedora (/usr/lib64/ for 64-bit), Alpine installs all 64-bit shared
#   libraries directly to /usr/lib/ — the same flat layout reprobuild's
#   `config.nims` `firstExistingPrefix` helper probes natively
#   (<prefix>/lib/<dylib>). So unlike M2 + M3 we do NOT need to symlink
#   anything into /usr/local/{lib,include}/; setting BLAKE3_PREFIX=/usr
#   and XXHASH_PREFIX=/usr resolves directly. This is the cleanest M1-M4
#   prefix story to date.
#
# Why does this script stage the workspace from /mnt/d/metacraft (the
# Windows-side checkout) instead of cloning from github.com?
#   Same rationale as M1/M2/M3: the Windows-side workspace already has
#   every sibling repo + the workspace lock applied, and building off
#   the 9P-mounted Windows filesystem is 10-100x slower for Nim's many
#   small-file writes. The build redirects nimcache to a Linux-native
#   /tmp tree but reads sources directly from /mnt/d/.
#
# POSIX-sh compliance:
#   Alpine's /bin/sh is busybox ash (NOT bash). This script is strictly
#   POSIX sh — no `[[ ]]`, no `$'...'`, no arrays, no bash function
#   declarations. The `case` patterns use `|` alternation which IS
#   POSIX. The M1/M2/M3 scripts are already POSIX-clean; this script
#   maintains that contract more strictly because Alpine has no bash
#   fallback by default.
#
# Exit codes (compatible with M1/M2/M3's contract):
#   0  success — repro + repro-standard-provider built, --version works.
#   1  generic failure (apk / nim / network).
#   2  reprobuild repo source tree not visible at /mnt/d/metacraft/reprobuild.
#   3  reserved (was clingo build failure on M1/M2 — N/A on Alpine).
#   4  reserved (was blake3 build failure on M1/M2 — N/A on Alpine).
#   5  reprobuild Nim build failure.
#   6  produced binary does not run.
#   7  Nim 2.2.10 source build failure.

set -eu

WORK_ROOT="${REPRO_BOOTSTRAP_ROOT:-/tmp/reprobuild-bootstrap-alpine}"
SRC_MOUNT="${REPRO_BOOTSTRAP_SRC:-/mnt/d/metacraft}"
NIM_BIN="${REPRO_BOOTSTRAP_NIM:-}"
NIM_VERSION="${REPRO_BOOTSTRAP_NIM_VERSION:-2.2.10}"
NIM_SRC_ROOT="${WORK_ROOT}/nim-${NIM_VERSION}"
BUILD_LOG="${WORK_ROOT}/bootstrap.log"

log() {
  printf '[bootstrap-alpine] %s\n' "$*"
}

err() {
  printf '[bootstrap-alpine] ERROR: %s\n' "$*" >&2
}

# ----------------------------------------------------------------------
# Step 0 — environment sanity.
# ----------------------------------------------------------------------

if ! grep -q '^ID=alpine' /etc/os-release 2>/dev/null; then
  err "this script must run inside an Alpine instance (repro-alpine)"
  exit 1
fi

if [ ! -d "${SRC_MOUNT}/reprobuild" ]; then
  err "reprobuild source tree not found at ${SRC_MOUNT}/reprobuild"
  err "expected the Windows-side checkout to be mounted at /mnt/d/metacraft"
  err "(see provision-alpine.ps1 for how repro-alpine is set up)"
  exit 2
fi

mkdir -p "${WORK_ROOT}/bin"
mkdir -p "${WORK_ROOT}/nimcache"

# ----------------------------------------------------------------------
# Step 1 — apk prerequisites.
# ----------------------------------------------------------------------
#
# Minimum apk package set required to build reprobuild from source on
# Alpine 3.19. Like M3 (Fedora) and unlike M1/M2 (Arch / Debian /
# Ubuntu), Alpine edge ships clingo, blake3, and xxhash — so the
# upstream clingo + BLAKE3 tarball builds from M1/M2 are NOT needed.
#
# We enable edge/main + edge/community for the duration of this script
# because:
#   - v3.19/main has no blake3 package at all.
#   - edge/community has blake3-dev 1.8.5 + clingo-dev 5.8.0.
#   - edge/main has xxhash-dev 0.8.3.
#
# Note: we explicitly do NOT install nim from apk. Alpine edge/community
# has nim 2.2.0, but that version has a codegen bug that breaks the
# reprobuild build (see Step 2 for the Nim 2.2.10 source build).

log "Step 1: apk prerequisites"

# Add edge repos if not already configured. We append rather than
# replace v3.19 so the rootfs's v3.19 base remains the dominant source
# for everything except the three pinned-from-edge dev packages.
if ! grep -q '^https://dl-cdn.alpinelinux.org/alpine/edge/main$' /etc/apk/repositories; then
  printf 'https://dl-cdn.alpinelinux.org/alpine/edge/main\n' \
    >> /etc/apk/repositories
fi
if ! grep -q '^https://dl-cdn.alpinelinux.org/alpine/edge/community$' /etc/apk/repositories; then
  printf 'https://dl-cdn.alpinelinux.org/alpine/edge/community\n' \
    >> /etc/apk/repositories
fi

apk update >>"${BUILD_LOG}" 2>&1 || true

# Toolchain + build prereqs from v3.19/main (stable baseline). We pin
# these to v3.19 implicitly by NOT passing --repository — apk picks the
# higher-precedence repo for each name (v3.19 ranks above edge for
# packages present in both). musl-dev is included by build-base.
log "  installing toolchain + build prereqs..."
apk add --no-cache \
  build-base git curl ca-certificates xz \
  pkgconf openssl-dev sqlite-dev \
  cmake bison re2c unzip \
  >>"${BUILD_LOG}" 2>&1

# blake3-dev, xxhash-dev, clingo-dev from edge. We use --repository
# explicitly to override apk's repo-precedence pick so the edge versions
# are installed even when v3.19 lacks the package or has an older one.
log "  installing blake3-dev + xxhash-dev + clingo-dev from edge..."
apk add --no-cache \
  --repository=https://dl-cdn.alpinelinux.org/alpine/edge/main \
  --repository=https://dl-cdn.alpinelinux.org/alpine/edge/community \
  blake3-dev xxhash-dev clingo-dev \
  >>"${BUILD_LOG}" 2>&1

# Verify the three edge packages landed at the expected paths. Alpine's
# flat /usr/lib + /usr/include layout means this is purely a sanity
# check; no symlinking into /usr/local is needed (unlike M2/M3).
for f in /usr/include/blake3.h /usr/lib/libblake3.so \
         /usr/include/xxhash.h /usr/lib/libxxhash.so \
         /usr/include/clingo.h /usr/lib/libclingo.so; do
  if [ ! -e "$f" ]; then
    err "expected apk install to provide $f, but it is missing"
    err "see ${BUILD_LOG} for the apk install transcript"
    exit 1
  fi
done
log "  apk install OK: blake3 + xxhash + clingo in /usr/{include,lib}"

# ----------------------------------------------------------------------
# Step 2 — Nim 2.2.10 from source.
# ----------------------------------------------------------------------
#
# Background: Alpine edge/community's nim 2.2.0 has a codegen bug that
# mis-generates eqdestroy hook signatures for sequence types — `apps/
# repro` builds hit it at codec_u551 in repro_dev_env_artifacts (gcc:
# "expected 'tySequence__... *' but argument is of type 'tySequence__...'").
# Fixed in Nim 2.2.2+; we use Nim 2.2.10 to match M1/M2/M3 exactly.
# choosenim is NOT an option here — its pre-built Nim is glibc-linked
# and won't run on musl.
#
# Build path: download upstream nim-2.2.10.tar.xz, run the included
# `build.sh` (compiles a v1 nim from the frozen `c_code/` csources via
# plain gcc — no pre-existing Nim required), then `./koch boot
# -d:release` to self-host up to 2.2.10. Wall time ~2 min on a Ryzen-
# class WSL2 host.

# If an override binary was supplied AND it's the right version, honour
# the override and skip the source build entirely.
if [ -n "${NIM_BIN}" ]; then
  if [ -x "${NIM_BIN}" ]; then
    override_version="$("${NIM_BIN}" --version 2>/dev/null | head -1)"
    case "$override_version" in
      *'Version 2.2.1'*|*'Version 2.2.2'*|*'Version 2.2.3'*|*'Version 2.2.4'*| \
      *'Version 2.2.5'*|*'Version 2.2.6'*|*'Version 2.2.7'*|*'Version 2.2.8'*| \
      *'Version 2.2.9'*|*'Version 2.2.10'*|*'Version 2.3'*|*'Version 2.4'*| \
      *'Version 3.'*)
        log "Step 2: using REPRO_BOOTSTRAP_NIM override (${NIM_BIN}): ${override_version}" ;;
      *)
        err "REPRO_BOOTSTRAP_NIM override is at a buggy/old version: ${override_version}"
        err "Nim 2.2.0 has a codegen bug that breaks reprobuild; need 2.2.2+"
        exit 1 ;;
    esac
  else
    err "REPRO_BOOTSTRAP_NIM=${NIM_BIN} is not executable"
    exit 1
  fi
elif [ -x "${NIM_SRC_ROOT}/bin/nim" ]; then
  # Warm-run short-circuit: previously-built Nim 2.2.10 is reusable as-is.
  NIM_BIN="${NIM_SRC_ROOT}/bin/nim"
  log "Step 2: Nim ${NIM_VERSION} already built at ${NIM_BIN} (warm short-circuit)"
else
  log "Step 2: build Nim ${NIM_VERSION} from source"
  cd "${WORK_ROOT}"
  if [ ! -f "nim-${NIM_VERSION}.tar.xz" ]; then
    if ! curl -fsSL -o "nim-${NIM_VERSION}.tar.xz" \
         "https://nim-lang.org/download/nim-${NIM_VERSION}.tar.xz" \
         >>"${BUILD_LOG}" 2>&1; then
      err "failed to download nim-${NIM_VERSION}.tar.xz from nim-lang.org"
      exit 7
    fi
  fi
  rm -rf "${NIM_SRC_ROOT}"
  if ! tar xJf "nim-${NIM_VERSION}.tar.xz" >>"${BUILD_LOG}" 2>&1; then
    err "failed to extract nim-${NIM_VERSION}.tar.xz"
    exit 7
  fi
  cd "${NIM_SRC_ROOT}"
  # Step 2a: compile a v1 nim from the included csources via build.sh.
  # No pre-existing Nim is required; build.sh uses gcc on the frozen
  # `c_code/` subtree.
  if ! sh ./build.sh >>"${BUILD_LOG}" 2>&1; then
    err "Nim ${NIM_VERSION} build.sh failed; see ${BUILD_LOG}"
    exit 7
  fi
  # Step 2b: compile koch via the freshly-built v1 nim.
  if ! ./bin/nim c --hints:off --warnings:off koch \
       >>"${BUILD_LOG}" 2>&1; then
    err "Nim ${NIM_VERSION} koch compile failed; see ${BUILD_LOG}"
    exit 7
  fi
  # Step 2c: koch boot -d:release self-hosts up to 2.2.10. This is the
  # binary we use for the reprobuild build below.
  if ! ./koch boot -d:release >>"${BUILD_LOG}" 2>&1; then
    err "Nim ${NIM_VERSION} koch boot -d:release failed; see ${BUILD_LOG}"
    exit 7
  fi
  NIM_BIN="${NIM_SRC_ROOT}/bin/nim"
fi

nim_version="$("${NIM_BIN}" --version 2>/dev/null | head -1)"
log "  nim: ${NIM_BIN} — ${nim_version}"

# Sanity-check Nim version >= 2.2.1 (2.2.0 has the codegen bug we
# avoided; 2.2.10 is the source-built version we expect).
case "$nim_version" in
  *'Version 2.2.1'*|*'Version 2.2.2'*|*'Version 2.2.3'*|*'Version 2.2.4'*| \
  *'Version 2.2.5'*|*'Version 2.2.6'*|*'Version 2.2.7'*|*'Version 2.2.8'*| \
  *'Version 2.2.9'*|*'Version 2.2.10'*|*'Version 2.3'*|*'Version 2.4'*| \
  *'Version 3.'*)
    : ;;
  *)
    err "nim version below the reprobuild minimum (2.2.1): ${nim_version}"
    err "(Nim 2.2.0 has a known codegen bug for sequence destructor hooks)"
    exit 1 ;;
esac

# Verify nim is musl-linked (sanity check — a glibc nim would silently
# fail with "ELF interpreter not found" on first invocation).
nim_interp="$(head -c1024 "${NIM_BIN}" | strings 2>/dev/null | \
  grep -Eo '/lib/ld-musl-x86_64.so.1|/lib64/ld-linux-x86-64.so.2' | head -1 || true)"
case "$nim_interp" in
  /lib/ld-musl-x86_64.so.1)
    log "  nim: musl-linked (OK for Alpine)" ;;
  /lib64/ld-linux-x86-64.so.2)
    err "nim is glibc-linked; will not run on musl"
    err "this suggests the source build silently picked up a glibc compiler"
    exit 1 ;;
  *)
    log "  nim: interp probe inconclusive (${nim_interp:-none}); continuing" ;;
esac

# ----------------------------------------------------------------------
# Step 3 — clingo + BLAKE3 (from apk; nothing to do beyond Step 1).
# ----------------------------------------------------------------------
#
# Alpine edge ships both:
#   - clingo-dev 5.8.0 + clingo-libs 5.8.0 (libclingo.so at
#     /usr/lib/libclingo.so -> libclingo.so.4 -> libclingo.so.4.0).
#   - blake3-dev 1.8.5 + blake3-libs 1.8.5 (libblake3.so at
#     /usr/lib/libblake3.so -> libblake3.so.0 -> libblake3.so.1.8.5,
#     header at /usr/include/blake3.h).
# The default musl-ldconfig cache finds /usr/lib via its standard path
# so no extra ld.so.conf wiring is needed. M1's upstream-tarball
# build of clingo (and M1's re2c-4.3 compat patch from the AUR) and
# M1/M2's upstream BLAKE3 cmake build are NOT needed here.

log "Step 3: clingo + BLAKE3 provided by apk (no upstream build)"

# ----------------------------------------------------------------------
# Step 4 — build the `repro` + `repro-standard-provider` binaries.
# ----------------------------------------------------------------------
#
# Same shape as M1/M2/M3 — build from /mnt/d/metacraft/reprobuild with
# nimcache on a Linux-native /tmp tree. The key Alpine difference is
# that BLAKE3_PREFIX=/usr + XXHASH_PREFIX=/usr resolve directly via
# `config.nims` `firstExistingPrefix` because Alpine puts everything
# in flat /usr/lib (unlike M2's apt multiarch and M3's Fedora /usr/lib64
# layout, both of which require /usr/local symlinking).

log "Step 4: build repro + repro-standard-provider"
export REPROBUILD_USE_SYSTEM_HASH_LIBS=1
export BLAKE3_PREFIX=/usr
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

log "bootstrap-alpine: OK"
log "  binaries: ${WORK_ROOT}/bin/{repro, repro-standard-provider}"
log "  nim:      ${NIM_BIN}"
log "  log:      ${BUILD_LOG}"
log ""
log "To use the binary in subsequent shells, export:"
log "  export PATH=${WORK_ROOT}/bin:${NIM_SRC_ROOT}/bin:/usr/local/bin:/usr/bin:\$PATH"
log "  export REPROBUILD_REPO_ROOT=${SRC_MOUNT}/reprobuild"
log "  export BLAKE3_PREFIX=/usr"
log "  export XXHASH_PREFIX=/usr"
log ""
log "Note: \"repro build\" forks \"nim\" to compile recipe project files,"
log "so the source-built Nim's bin dir (${NIM_SRC_ROOT}/bin) MUST be on"
log "PATH for downstream recipe builds. Unlike M1 (Arch) which has nim"
log "on /usr/bin by default, and M2/M3 which use choosenim at"
log "/root/.nimble/bin, Alpine's source-built Nim lives under WORK_ROOT."
log "musl-libc binaries are produced; the resulting sha256 will differ"
log "from glibc-distro builds (M1 Arch / M2 Debian+Ubuntu / M3 Fedora)."

#!/usr/bin/env bash
# ============================================================================
# M9.R.14a — Linux validation bootstrap for the M9.R.13/14/15 recipe campaign
# ----------------------------------------------------------------------------
# Idempotent bootstrap of an eli-wsl-style NixOS distro into a state where
# ``./build/bin/repro build recipes/packages/source/<name> --tool-provisioning=from-source``
# can run end-to-end against the local ``repro-cache`` distro.
#
# This is the reusable knob the M9.R.14a sub-agent task brief describes
# ("Wrap all of the above in tools/bootstrap-linux-smoke.sh so the sequence
# is reproducible"). Re-running this script on an already-bootstrapped
# distro is a no-op for every step whose output is already present.
#
# Design notes:
#
#   * The host distro is NixOS 25.05 (eli-wsl is provisioned as a NixOS
#     WSL distro per the user-memory ``reference_nixos_wsl_eli`` note).
#     We therefore do NOT install gcc / nim / clingo via ``apt`` — those
#     come from the reprobuild flake's ``devShells.default`` via
#     ``nix develop``. Re-using the flake also means the toolchain matches
#     what CI uses, which is the whole point of a reproducible bootstrap.
#
#   * Both checkouts (``reprobuild`` + ``reprobuild-specs``) live under
#     ``/opt/repro/`` to avoid the ``/mnt/d/`` 9p reflector (slow + CRLF
#     hazards per ``project_windows_edit_crlf_hazard``).
#
#   * Cache connectivity: WSL2 distros share a single network namespace, so
#     the ``repro-cache`` distro's HTTP server on ``0.0.0.0:7878`` is
#     reachable from inside eli-wsl as ``http://127.0.0.1:7878/`` once the
#     repro-cache distro is running. The script verifies this with a GET
#     to ``/healthz``.
#
# Usage from the Windows host:
#
#   wsl.exe -d eli-wsl --user root -- bash \
#     /mnt/d/metacraft/reprobuild/tools/bootstrap-linux-smoke.sh
#
# Usage from inside eli-wsl (after checkout is in place):
#
#   bash /opt/repro/reprobuild/tools/bootstrap-linux-smoke.sh
#
# Steps map 1:1 to the M9.R.14a milestone slices:
#
#   1) bootstrap-linux-smoke.sh + eli-wsl prerequisites      (.1)
#   2) build apps/repro/repro on Linux                       (.2)
#   3) cache connectivity eli-wsl -> repro-cache             (.3)
#   4) smoke expat on Linux                                  (.4)
# ============================================================================
set -euo pipefail

# ----- Configuration -------------------------------------------------------

# Both checkouts live here. /opt is root-owned by default; the script runs as
# root inside eli-wsl. Using /opt/repro/ keeps everything off /mnt/d/.
REPRO_ROOT="${REPRO_ROOT:-/opt/repro}"
REPROBUILD_DIR="${REPRO_ROOT}/reprobuild"
REPROBUILD_SPECS_DIR="${REPRO_ROOT}/reprobuild-specs"

# Cache server URL — see "cache connectivity" note above. WSL2 distros share
# the network namespace, so 127.0.0.1:7878 reaches the repro-cache distro's
# repro-binary-cache.service when that distro is booted.
REPRO_BINARY_CACHE_URL="${REPRO_BINARY_CACHE_URL:-http://127.0.0.1:7878/}"

# Default smoke recipe; the brief's Part 3 targets expat. Override with
# REPRO_SMOKE_RECIPE=... to point at another from-source recipe.
REPRO_SMOKE_RECIPE="${REPRO_SMOKE_RECIPE:-recipes/packages/source/expat}"

# Git URLs (public). Override REPROBUILD_GIT_URL / REPROBUILD_SPECS_GIT_URL
# to lift from a local mirror or a fork.
REPROBUILD_GIT_URL="${REPROBUILD_GIT_URL:-https://github.com/metacraft-labs/reprobuild}"
REPROBUILD_SPECS_GIT_URL="${REPROBUILD_SPECS_GIT_URL:-https://github.com/metacraft-labs/reprobuild-specs}"
REPROBUILD_GIT_REF="${REPROBUILD_GIT_REF:-main}"

# Shallow clone depth. ``main`` carries hundreds of MB of vendored
# references/ + recipes/bootstrap/*/build trees that blow the default
# git-over-https side-band buffer ("fetch-pack: unexpected disconnect" in
# the cold-clone retry). Depth=1 keeps the bootstrap fast + reliable; the
# campaign smoke does not need history. Override REPRO_CLONE_DEPTH=0 to
# get a full clone if you need bisect.
REPRO_CLONE_DEPTH="${REPRO_CLONE_DEPTH:-1}"

# ----- Logging -------------------------------------------------------------

# Compact, prefixed log lines so a failed step is grep-friendly in the
# Windows-host wrapper output. Always emit to stderr so stdout stays clean
# for any caller that wants to parse it.
log() { echo "[bootstrap-linux-smoke] $*" >&2; }
die() { echo "[bootstrap-linux-smoke][FATAL] $*" >&2; exit 1; }

# ----- M9.R.15i.2 — strip /mnt/<drive>/ entries from PATH ------------------
#
# Inside WSL2 the host Windows PATH bleeds through as a sequence of
# /mnt/c/, /mnt/d/, etc. mounts (the WSL interop layer's appendWindowsPath
# default). These entries point at the Windows-mounted 9p reflector which
# is significantly slower than native Linux paths — cmake's ``find_program``
# walk visits every PATH entry probing for the program name + the
# CMAKE_EXECUTABLE_SUFFIX, and the Windows-mount probes can dominate the
# configure time for cmake-driven recipes (qt6-base, KF6, etc.) by ~4x.
#
# Additionally, having Windows MSVC + MSYS2 paths on PATH inside the nix-
# shell occasionally surfaces the wrong toolchain — cmake's gcc detection
# probe can pick up the Windows ``gcc.exe`` shim if the wrapper is hit
# before the nix-store one (unlikely but possible if scoop ships a
# ``gcc.exe`` alias).
#
# We strip them at the smoke-script level (vs. engine-level) per the
# task brief: scoping the change to the workflow keeps native Linux
# CI runs (where /mnt/* legitimately means real filesystems) untouched.
#
# Idempotent: re-running strip_wsl_mnt_paths leaves the PATH unchanged.
strip_wsl_mnt_paths() {
  # No-op on non-WSL hosts. /proc/sys/fs/binfmt_misc/WSLInterop is the
  # canonical marker for a WSL distro (the kernel module registers a
  # binfmt entry for ``.exe`` files on every WSL2 distro).
  if [ ! -e /proc/sys/fs/binfmt_misc/WSLInterop ] \
      && [ ! -e /proc/sys/fs/binfmt_misc/WSLInterop-late ]; then
    return 0
  fi
  local cleaned=""
  local IFS=":"
  for entry in $PATH; do
    case "${entry}" in
      /mnt/[a-zA-Z]/*) continue ;;
    esac
    if [ -z "${cleaned}" ]; then
      cleaned="${entry}"
    else
      cleaned="${cleaned}:${entry}"
    fi
  done
  export PATH="${cleaned}"
}

# ----- Step 1: NixOS sanity checks -----------------------------------------

step_1_nixos_prereqs() {
  log "step 1: NixOS prerequisites"

  command -v nix >/dev/null 2>&1 || die "nix not on PATH (this script expects a NixOS host)"
  command -v git >/dev/null 2>&1 || die "git not on PATH"
  command -v curl >/dev/null 2>&1 || die "curl not on PATH"

  # Flakes + nix-command are needed for ``nix develop`` against the
  # reprobuild flake. Test by asking nix for the feature list — failure
  # mode here is the operator dropped to a stock NixOS that omits flakes
  # from /etc/nix/nix.conf.
  if ! nix config show experimental-features 2>/dev/null \
      | grep -qE '\bflakes\b'; then
    die "nix flakes experimental feature is not enabled; add 'experimental-features = nix-command flakes' to /etc/nix/nix.conf"
  fi

  log "step 1: ok (nix $(nix --version | awk '{print $NF}'), git $(git --version | awk '{print $NF}'))"
}

# ----- Step 2: Checkouts ---------------------------------------------------

# Clone or update a single repo under REPRO_ROOT. Idempotent — runs ``git
# fetch`` + fast-forward on an existing checkout; clones fresh otherwise.
checkout_repo() {
  local url="$1" dest="$2" ref="$3"

  if [ -d "${dest}/.git" ]; then
    log "checkout: existing ${dest}, fetching"
    git -C "${dest}" fetch --quiet origin "${ref}"
    # Don't blindly reset — if the operator made local edits, preserve them.
    # Fast-forward only.
    if ! git -C "${dest}" merge --ff-only "origin/${ref}" >/dev/null 2>&1; then
      log "checkout: ${dest} has local changes; skipping ff (operator-managed checkout)"
    fi
  else
    log "checkout: cloning ${url} -> ${dest} (depth=${REPRO_CLONE_DEPTH})"
    mkdir -p "$(dirname "${dest}")"
    local depth_args=()
    if [ "${REPRO_CLONE_DEPTH}" -gt 0 ]; then
      depth_args+=(--depth "${REPRO_CLONE_DEPTH}" --single-branch)
    fi
    # ``http.postBuffer`` bump is belt-and-braces in case the
    # CRLF-converting Windows-side gitconfig leaks via the WSL bind:
    # large pack negotiations occasionally truncate without it.
    # Retry once on sideband disconnect (intermittent github.com glitch
    # on cold runs against the large reprobuild pack).
    local attempt
    for attempt in 1 2 3; do
      if git -c http.postBuffer=524288000 \
             clone --quiet --branch "${ref}" "${depth_args[@]}" \
                   "${url}" "${dest}"; then
        return 0
      fi
      log "checkout: clone attempt ${attempt}/3 failed for ${url}; retrying"
      rm -rf "${dest}"
    done
    die "checkout: clone of ${url} failed after 3 attempts"
  fi
}

step_2_checkouts() {
  log "step 2: checkouts under ${REPRO_ROOT}"
  mkdir -p "${REPRO_ROOT}"
  checkout_repo "${REPROBUILD_GIT_URL}" "${REPROBUILD_DIR}" "${REPROBUILD_GIT_REF}"

  # reprobuild-specs is a PRIVATE github repo. The reprobuild build does NOT
  # link against it (every reference in apps/ + libs/ + recipes/ is a doc
  # comment); we clone it opportunistically when credentials are available
  # so a sibling agent can browse the campaign milestone files, but a
  # credential failure is NOT fatal for the smoke build. The build still
  # produces ./build/bin/repro and the smoke step still runs.
  if [ "${REPRO_SKIP_SPECS:-0}" = "1" ]; then
    log "step 2: skipping reprobuild-specs (REPRO_SKIP_SPECS=1)"
  else
    log "step 2: attempting opportunistic reprobuild-specs clone (private repo; skips on auth failure)"
    if ! checkout_repo_optional "${REPROBUILD_SPECS_GIT_URL}" \
                                "${REPROBUILD_SPECS_DIR}" \
                                "${REPROBUILD_GIT_REF}"; then
      log "step 2: reprobuild-specs unavailable; continuing (specs only carries docs, the engine doesn't link them)"
    fi
  fi

  # ----- Source-only flake inputs config.nims looks up as siblings ------
  #
  # config.nims's addPackagePath() helper falls back to ``../<repo>`` when
  # the corresponding env var isn't set. The reprobuild flake's source-only
  # inputs (nimcrypto, nim-bearssl, runquota, ct-test-runner, test-adapters)
  # are normally fed via env vars; outside the flake we clone them as
  # siblings of ``${REPROBUILD_DIR}`` so config.nims resolves them.
  #
  # We do this OUTSIDE the flake because the flake's full closure pulls a
  # private codetracer-native-recorder input that 404s without auth and
  # blocks every Linux build (see step 4 comment). The Linux engine build
  # doesn't import any ct_interpose / stackable_hooks symbols, so the
  # five sibling sources below are sufficient.
  #
  # Revisions are pinned from ``flake.lock`` so the bootstrap matches what
  # CI sees byte-for-byte. Update both places when bumping any input.
  log "step 2: cloning source-only siblings at flake.lock-pinned revisions"

  # nim-bearssl carries submodules (bearssl/csources); --recurse-submodules
  # pulls the C tree the bindings link against. Revision lifted from
  # flake.lock's ``bearssl-src`` node.
  checkout_sibling_rev "https://github.com/status-im/nim-bearssl"  "nim-bearssl" \
                       "9a4eed052abbded2d94feaf3f5bbd95a30ec4671" 1

  # cheatfate/nimcrypto: rev from flake.lock's ``nimcrypto-src`` node.
  # The repo uses ``master`` as default-but-not-HEAD branch ordering; we
  # pin the rev directly.
  checkout_sibling_rev "https://github.com/cheatfate/nimcrypto"   "nimcrypto" \
                       "69eec0375dd146aede41f920c702c531bfe89c6b" 0

  # metacraft-labs/runquota: rev from flake.lock's ``runquota-src`` node.
  checkout_sibling_rev "https://github.com/metacraft-labs/runquota" "runquota" \
                       "87524764128109d433d0c3356d9b1edb5a60cbc6" 0

  # metacraft-labs/reprobuild-ct-test-runner: rev from flake.lock's
  # ``reprobuild-ct-test-runner-src`` node.
  checkout_sibling_rev "https://github.com/metacraft-labs/reprobuild-ct-test-runner" \
                       "reprobuild-ct-test-runner" \
                       "1a2fceae68cf7ac4f3352c8eb9897b2646dbcf08" 0

  # metacraft-labs/reprobuild-test-adapters: rev from flake.lock's
  # ``reprobuild-test-adapters-src`` node.
  checkout_sibling_rev "https://github.com/metacraft-labs/reprobuild-test-adapters" \
                       "reprobuild-test-adapters" \
                       "517a484b3781d0132698394f451a11f52363e719" 0

  log "step 2: ok"
}

# Clone a sibling repo and check out a specific revision. Used to mirror
# the flake.lock-pinned source-only inputs.
#
# A pinned rev clone requires a two-step dance (clone without --branch,
# then ``git fetch <rev>`` + ``git checkout <rev>``) because GitHub's
# smart-http server only serves named refs to ``git clone --branch``.
# With shallow fetch we ask for just the single commit (``--depth 1
# origin <rev>``) which all modern GitHubs support.
checkout_sibling_rev() {
  local url="$1" name="$2" rev="$3" recurse_submodules="$4"
  local dest="${REPRO_ROOT}/${name}"
  if [ -d "${dest}/.git" ]; then
    local current
    current=$(git -C "${dest}" rev-parse HEAD 2>/dev/null || echo unknown)
    if [ "${current}" = "${rev}" ]; then
      log "checkout: ${name} already at pinned rev ${rev}; leaving as-is"
      return 0
    fi
    log "checkout: ${name} at ${current}, pinned needs ${rev}; fetching"
    git -C "${dest}" fetch --depth 1 origin "${rev}" 2>/dev/null \
      && git -C "${dest}" checkout --quiet "${rev}" \
      && return 0 || true
    log "checkout: in-place pin failed; re-cloning"
    rm -rf "${dest}"
  fi

  log "checkout: cloning ${url} -> ${dest} @ ${rev:0:12} (recurse=${recurse_submodules})"
  mkdir -p "${dest}"
  pushd "${dest}" >/dev/null
  git init --quiet
  git remote add origin "${url}"
  local attempt
  for attempt in 1 2 3; do
    if git -c http.postBuffer=524288000 fetch --quiet --depth 1 origin "${rev}"; then
      git checkout --quiet FETCH_HEAD
      if [ "${recurse_submodules}" = "1" ]; then
        git submodule update --init --recursive --depth 1 --recommend-shallow
      fi
      popd >/dev/null
      return 0
    fi
    log "checkout: sibling fetch attempt ${attempt}/3 failed for ${url} @ ${rev:0:12}; retrying"
  done
  popd >/dev/null
  rm -rf "${dest}"
  die "checkout: clone of ${url} @ ${rev} failed after 3 attempts"
}

# Optional variant of checkout_repo: does NOT die on failure, returns
# non-zero so the caller can continue. Single attempt because credentials
# either work or they don't — retrying doesn't help.
checkout_repo_optional() {
  local url="$1" dest="$2" ref="$3"
  if [ -d "${dest}/.git" ]; then
    log "checkout: existing ${dest}; leaving as-is"
    return 0
  fi
  log "checkout: trying ${url} -> ${dest} (optional)"
  mkdir -p "$(dirname "${dest}")"
  local depth_args=()
  if [ "${REPRO_CLONE_DEPTH}" -gt 0 ]; then
    depth_args+=(--depth "${REPRO_CLONE_DEPTH}" --single-branch)
  fi
  if GIT_TERMINAL_PROMPT=0 git -c http.postBuffer=524288000 \
        clone --quiet --branch "${ref}" "${depth_args[@]}" \
              "${url}" "${dest}" 2>/dev/null; then
    return 0
  fi
  rm -rf "${dest}"
  return 1
}

# ----- Step 3: Cache connectivity verification -----------------------------

# The repro-cache distro is provisioned separately. From inside eli-wsl the
# cache server is reachable via 127.0.0.1:7878 because WSL2 distros share
# the host's eth0 namespace. If the cache server isn't running, the operator
# has to ``wsl.exe -d repro-cache -- systemctl status repro-binary-cache``
# from the Windows side (we can't reach into a sibling distro from here).
step_3_cache_connectivity() {
  log "step 3: cache connectivity probe (${REPRO_BINARY_CACHE_URL})"
  local code
  code=$(curl -s -m 5 -o /dev/null -w "%{http_code}" \
    "${REPRO_BINARY_CACHE_URL%/}/healthz" || true)
  if [ "${code}" = "200" ]; then
    log "step 3: ok (healthz=200)"
  else
    log "step 3: WARN cache /healthz returned ${code:-no-response}; smoke will skip publish"
    log "  -> start the cache distro from the Windows host:"
    log "     wsl.exe -d repro-cache --user root -- systemctl status repro-binary-cache"
  fi
}

# ----- Step 4: Build apps/repro/repro on Linux -----------------------------

# We delegate to ``just bootstrap`` inside ``nix develop`` so the build sees
# the flake-provisioned nim2 + gcc + clingo. The bootstrap recipe is
# idempotent — it skips the nim compile when ./build/bin/repro is up to date
# (see justfile line 19).
# Build toolchain provisioning: bypass ``nix develop`` against the
# reprobuild flake because the flake pulls a private GitHub input
# (``codetracer-native-recorder`` — 404 without auth). The Linux engine
# build does NOT use that input (every CT_INTERPOSE_SRC / STACKABLE_HOOKS_SRC
# importer is gated on Windows or macOS). We use ``nix-shell -p`` against
# nixpkgs to provision just the leaf toolchain reprobuild needs.
#
# The list mirrors the flake's ``devShells.default.packages`` block minus
# the Windows/macOS-only entries. Keep it in sync when adding new build
# inputs to the engine.
LINUX_TOOLCHAIN_PKGS=(
  nim2
  gcc
  pkg-config
  just
  clingo
  libblake3
  sqlite
  xxHash
  openssl
  zlib
  curl
  jq
  cacert
  # M9.R.14f.2 — patchelf is used by the install-mirror RPATH patcher
  # to embed transitive runtime lib dirs in every from-source ELF so
  # the resulting binaries are self-contained (no LD_LIBRARY_PATH
  # required at runtime).
  patchelf
)

# Env vars the flake sets that the Linux build also wants. We set
# REPROBUILD_USE_SYSTEM_HASH_LIBS=1 so the build links against the nix-shell
# libblake3 / xxHash rather than vendored sources, matching the flake's
# behaviour.
linux_build_env() {
  echo "REPROBUILD_USE_SYSTEM_HASH_LIBS=1"
  echo "BLAKE3_PREFIX=${BLAKE3_PREFIX:-}"
  echo "XXHASH_PREFIX=${XXHASH_PREFIX:-}"
  echo "SQLITE_PREFIX=${SQLITE_PREFIX:-}"
}

step_4_build_repro() {
  log "step 4: build apps/repro/repro via nix-shell -p + just bootstrap"

  pushd "${REPROBUILD_DIR}" >/dev/null

  # Skip-fast path: the just bootstrap recipe already does this, but we
  # short-circuit ahead of ``nix-shell -p`` (which warms the package set
  # for ~30s on a cold cache) when the binary is already current.
  if [ -x ./build/bin/repro ] \
      && ! find apps libs config.nims flake.nix repro.nim -type f \
            -newer ./build/bin/repro -print -quit 2>/dev/null | grep -q .; then
    log "step 4: ./build/bin/repro is current; skipping rebuild"
    popd >/dev/null
    return 0
  fi

  log "step 4: invoking nix-shell -p ${LINUX_TOOLCHAIN_PKGS[*]} --run 'just bootstrap'"

  # The flake's nixpkgs input pin is what CI uses, so prefer it over the
  # ambient channel. We extract the locked nixpkgs URL and route nix-shell
  # at it via NIX_PATH=nixpkgs=<url>. If the lock can't be parsed, fall
  # back to the ambient channel (operator may be on plain NixOS).
  local nixpkgs_arg=""
  if command -v jq >/dev/null 2>&1 \
      && [ -r flake.lock ]; then
    local pinned
    pinned=$(jq -r '
      .nodes
      | to_entries[]
      | select(.value.original.repo == "nixpkgs" and .value.original.owner == "NixOS")
      | "github:" + .value.locked.owner + "/" + .value.locked.repo + "/" + .value.locked.rev
    ' flake.lock 2>/dev/null | head -1 || true)
    if [ -n "${pinned}" ]; then
      nixpkgs_arg="nixpkgs=${pinned}"
      log "step 4: pinning nixpkgs from flake.lock -> ${pinned}"
    fi
  fi

  # ``nix-shell -p`` produces a shell whose PATH carries the requested
  # packages. We feed REPROBUILD_USE_SYSTEM_HASH_LIBS so config.nims wires
  # to the nix-shell-provided libblake3 + xxHash. ``--run`` makes the shell
  # exit after ``just bootstrap`` completes.
  if [ -n "${nixpkgs_arg}" ]; then
    NIX_PATH="${nixpkgs_arg}" \
    REPROBUILD_USE_SYSTEM_HASH_LIBS=1 \
      nix-shell -I "${nixpkgs_arg}" -p "${LINUX_TOOLCHAIN_PKGS[@]}" \
        --run "just bootstrap"
  else
    REPROBUILD_USE_SYSTEM_HASH_LIBS=1 \
      nix-shell -p "${LINUX_TOOLCHAIN_PKGS[@]}" \
        --run "just bootstrap"
  fi

  if [ ! -x ./build/bin/repro ]; then
    die "step 4: just bootstrap completed but ./build/bin/repro is missing"
  fi
  log "step 4: ok ($(./build/bin/repro --version 2>&1 | head -1 || echo 'version probe failed'))"

  popd >/dev/null
}

# ----- Step 5: Smoke a from-source recipe (default: expat) -----------------

step_5_smoke() {
  log "step 5: smoke ${REPRO_SMOKE_RECIPE} from-source on Linux"

  pushd "${REPROBUILD_DIR}" >/dev/null

  local log_path="/tmp/m9r14a-$(basename "${REPRO_SMOKE_RECIPE}").log"
  log "step 5: log -> ${log_path}"

  # REPRO_BINARY_CACHE_URL lets the engine publish realized artifacts. The
  # env var is read by libs/repro_engine_publisher/.
  #
  # We intentionally turn ``set -e`` off around the smoke invocation: the
  # smoke is data, not a hard gate. A from-source resolution failure is
  # interesting (e.g. ``runquotad`` has no provisioning channel) and we
  # want to report it as the M9.R.14a.4 result rather than crashing the
  # bootstrap. The caller decides what to do with the exit code.
  set +e
  REPRO_BINARY_CACHE_URL="${REPRO_BINARY_CACHE_URL}" \
    ./build/bin/repro build "${REPRO_SMOKE_RECIPE}" \
      --tool-provisioning=from-source \
      2>&1 | tee "${log_path}"
  local rc=${PIPESTATUS[0]}
  set -e

  log "step 5: exit=${rc} log=${log_path}"
  if [ "${rc}" -eq 0 ]; then
    log "step 5: ok"
  else
    log "step 5: smoke surfaced a campaign gap (non-zero exit ${rc}); see ${log_path}"
  fi

  popd >/dev/null
  return "${rc}"
}

# ----- Driver --------------------------------------------------------------

main() {
  # M9.R.15i.2 — strip /mnt/<drive>/ entries from PATH on WSL hosts so
  # the cmake configure probe walks don't traverse the Windows-mount
  # 9p reflector (~4x slowdown for cmake-driven recipes). No-op on
  # native Linux hosts.
  strip_wsl_mnt_paths
  step_1_nixos_prereqs
  step_2_checkouts
  step_3_cache_connectivity
  step_4_build_repro
  step_5_smoke
}

main "$@"

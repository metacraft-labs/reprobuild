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

  log "step 2: ok"
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
step_4_build_repro() {
  log "step 4: build apps/repro/repro via nix develop + just bootstrap"

  pushd "${REPROBUILD_DIR}" >/dev/null

  # Skip-fast path: the just bootstrap recipe already does this, but we
  # short-circuit ahead of ``nix develop`` (which warms the flake closure
  # for ~30s on a cold cache) when the binary is already current.
  if [ -x ./build/bin/repro ] \
      && ! find apps libs config.nims flake.nix repro.nim -type f \
            -newer ./build/bin/repro -print -quit 2>/dev/null | grep -q .; then
    log "step 4: ./build/bin/repro is current; skipping rebuild"
    popd >/dev/null
    return 0
  fi

  log "step 4: invoking nix develop --command just bootstrap (cold path: warms flake closure first)"
  # --accept-flake-config quiets the substituter-prompt that some flakes
  # raise on first contact.
  nix develop --accept-flake-config --command just bootstrap

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
  REPRO_BINARY_CACHE_URL="${REPRO_BINARY_CACHE_URL}" \
    ./build/bin/repro build "${REPRO_SMOKE_RECIPE}" \
      --tool-provisioning=from-source \
      2>&1 | tee "${log_path}"

  local rc=${PIPESTATUS[0]}
  log "step 5: exit=${rc} log=${log_path}"

  popd >/dev/null
  return "${rc}"
}

# ----- Driver --------------------------------------------------------------

main() {
  step_1_nixos_prereqs
  step_2_checkouts
  step_3_cache_connectivity
  step_4_build_repro
  step_5_smoke
}

main "$@"

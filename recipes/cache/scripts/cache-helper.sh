#!/usr/bin/env bash
# cache-helper.sh — ReproOS-Generations-And-Foreign-Packages A3 P2 shell glue.
#
# Sourced (NOT executed) by the R4-R9 build-*.sh scripts. Exposes:
#
#   cache_lookup_and_substitute <entry-key-hex> <out-prefix>
#       Returns 0 if the binary cache materialised the prefix at
#       <out-prefix> (no rebuild needed). Returns 1 on miss; the
#       caller proceeds with the actual build.
#
#   cache_publish <entry-key-hex> <prefix>
#       Packages + signs + uploads <prefix> as the entry's payload.
#       Failure here is logged but does NOT abort the build (the
#       output is already on disk; cache upload is best-effort).
#
#   cache_repro_binary_cache_client_bin
#       Echoes the absolute path to the CLI binary, building it on
#       first call if missing. Other scripts can rely on the binary
#       being present after one invocation.
#
# Environment variables (read on each call):
#   REPRO_BINARY_CACHE_URL        — default http://localhost:7878
#   REPRO_BINARY_CACHE_KEY_PATH   — required for cache_publish
#   REPRO_BINARY_CACHE_CERT_PATH  — required for cache_publish
#   REPRO_LOCAL_STORE             — default ~/.local/share/repro/local-store
#   REPRO_CACHE_DRY_RUN           — when "1", cache_lookup_and_substitute
#                                    exits after the lookup attempt and
#                                    propagates its result.
#   REPRO_CACHE_DISABLE           — when "1", lookups are forced to miss
#                                    and publishes are no-ops. Useful for
#                                    smoke-testing the build path.

# Resolve the repo root from the sourcing script's $BASH_SOURCE.
_cache_helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_cache_repo_root="$(cd "${_cache_helper_dir}/../../.." && pwd)"

cache_repro_binary_cache_client_bin() {
  local bin="${_cache_repo_root}/build/test-bin/repro_binary_cache_client_cli.exe"
  if [[ ! -x "$bin" && ! -f "$bin" ]]; then
    bin="${_cache_repo_root}/build/test-bin/repro_binary_cache_client_cli"
  fi
  if [[ ! -x "$bin" && ! -f "$bin" ]]; then
    printf 'cache-helper.sh: CLI binary missing; build it with:\n' >&2
    printf '  nim c -o:build/test-bin/repro_binary_cache_client_cli.exe \\\n' >&2
    printf '    apps/repro-binary-cache-client/repro_binary_cache_client_cli.nim\n' >&2
    return 1
  fi
  printf '%s\n' "$bin"
}

# --- internal: sha256 of a file path (for provider-revision derivation) ---
cache_helper_sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$path" | awk '{print $NF}'
  else
    printf 'cache-helper.sh: no sha256sum/shasum/openssl on PATH\n' >&2
    return 1
  fi
}
export -f cache_helper_sha256_file

cache_lookup_and_substitute() {
  local hex="$1" outPrefix="$2"
  if [[ "${REPRO_CACHE_DISABLE:-0}" == "1" ]]; then
    return 1
  fi
  local bin
  bin="$(cache_repro_binary_cache_client_bin)" || return 1
  if "$bin" substitute "$hex" "$outPrefix" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

cache_publish() {
  local hex="$1"; shift
  local prefix="$1"; shift
  if [[ "${REPRO_CACHE_DISABLE:-0}" == "1" ]]; then
    return 0
  fi
  if [[ -z "${REPRO_BINARY_CACHE_KEY_PATH:-}" ||
        -z "${REPRO_BINARY_CACHE_CERT_PATH:-}" ]]; then
    printf '[cache] publish skipped (key/cert env vars not set)\n' >&2
    return 0
  fi
  local bin
  bin="$(cache_repro_binary_cache_client_bin)" || return 1
  # Remaining args are forwarded as identity flags (--package-name=...,
  # --dep=..., --option=key=val, etc.); the caller threads in the same
  # values it used to compute <hex>.
  if "$bin" publish "$hex" "$prefix" "$@"; then
    return 0
  else
    printf '[cache] publish failed for %s\n' "$hex" >&2
    return 1
  fi
}

# Diagnostic: print "hit" / "miss" without touching the local store.
cache_lookup() {
  local hex="$1"
  local bin
  bin="$(cache_repro_binary_cache_client_bin)" || return 1
  "$bin" lookup "$hex"
}

# ---------------------------------------------------------------------------
# Higher-level helpers used by the R4-R9 build-*.sh scripts.
# ---------------------------------------------------------------------------

# cache_derive_key <identity-flag>...
#
# Echoes the derived 64-char entry-key hex to stdout. Returns the
# CLI's exit code so the caller can detect a malformed flag block.
cache_derive_key() {
  local bin
  bin="$(cache_repro_binary_cache_client_bin)" || return 1
  "$bin" derive-key "$@"
}

# cache_default_host_identity_flags <build-script-path>
#
# Populates an exported `CACHE_HOST_IDENTITY_FLAGS` bash array with the
# 4 host-detected toolchain-identity components every R4-R9 phase needs:
#   --toolchain-host-ldso=<...>
#   --toolchain-extra=host_gcc=<...>
#   --provider-revision=<sha256 of build-script-path>
#
# The caller appends its phase-specific identity (--package-name, etc.)
# before invoking ``cache_derive_key`` / ``cache_publish``.
cache_default_host_identity_flags() {
  local script_path="$1"
  local host_gcc_version="${REPRO_HOST_GCC_VERSION:-$(gcc --version 2>/dev/null | head -1 | awk '{print $NF}')}"
  local host_ldso_abi="${REPRO_HOST_LDSO_ABI:-glibc-host}"
  local prov_rev
  prov_rev="$(cache_helper_sha256_file "$script_path")"
  CACHE_HOST_IDENTITY_FLAGS=(
    --toolchain-host-ldso="${host_ldso_abi}"
    --toolchain-extra="host_gcc=${host_gcc_version:-unknown}"
    --provider-revision="${prov_rev}"
  )
  export CACHE_HOST_IDENTITY_FLAGS
}

# cache_default_platform_flags
#
# Populates exported `CACHE_PLATFORM_FLAGS` with the host-detected
# platform identity. R4-R9 are linux/x86_64/gnu under the bootstrap
# chain, but having the auto-detection means the same scripts work
# under sandbox testing on Windows / macOS.
cache_default_platform_flags() {
  local host_os host_abi
  case "$(uname -s)" in
    Linux*) host_os=linux ; host_abi=gnu ;;
    Darwin*) host_os=darwin ; host_abi="" ;;
    MINGW*|MSYS*|CYGWIN*) host_os=windows ; host_abi=msvc ;;
    *) host_os=linux ; host_abi=gnu ;;
  esac
  CACHE_PLATFORM_FLAGS=(
    --platform-cpu=x86_64
    --platform-os="${host_os}"
    --platform-abi="${host_abi}"
    --platform-libc=
  )
  export CACHE_PLATFORM_FLAGS
}

# cache_run_phase <script-path> <out-dir> <single-file|dir> [--package-name=NAME ...]
#
# Encodes the prelude/postlude pattern shared by every R4-R9 build-*.sh
# script. The caller passes:
#   - the build script's own path (used for provider-revision sha256)
#   - the output directory the build produces under
#   - "single-file": the prefix is one output file named like the package
#     (mode-bit + name preserved by the rbcarc-v1 archive shape).
#     "dir": the build writes a multi-file prefix under <out-dir>/prefix.
#   - the package-identity flags (--package-name=..., --package-version=...,
#     --dep=..., --option=..., etc.).
#
# Sets globals:
#   CACHE_KEY_HEX      the derived entry-key hex (64-char)
#   CACHE_HIT          1 if the cache hit + the prefix is on disk; 0 otherwise.
#
# The build-script body checks `[[ "$CACHE_HIT" == "1" ]]` and exits 0
# when set. Otherwise it builds, then calls `cache_phase_publish`.
cache_phase_prepare() {
  local script_path="$1"; shift
  local out_dir="$1"; shift
  # shellcheck disable=SC2034
  local pkg_flags=( "$@" )
  cache_default_host_identity_flags "$script_path"
  cache_default_platform_flags
  local all_flags=(
    "${CACHE_PLATFORM_FLAGS[@]}"
    "${CACHE_HOST_IDENTITY_FLAGS[@]}"
    "${pkg_flags[@]}"
  )
  CACHE_KEY_HEX="$(cache_derive_key "${all_flags[@]}")"
  CACHE_PHASE_FLAGS=( "${all_flags[@]}" )
  CACHE_HIT=0
  if [[ "${REPRO_CACHE_DRY_RUN:-0}" == "1" ]]; then
    cache_lookup "${CACHE_KEY_HEX}" || true
    CACHE_HIT=2          # special: "dry-run; lookup attempted but build skipped"
    return 0
  fi
  if cache_lookup_and_substitute "${CACHE_KEY_HEX}" "${out_dir}/prefix"; then
    CACHE_HIT=1
  fi
  export CACHE_KEY_HEX CACHE_HIT CACHE_PHASE_FLAGS
}

# cache_phase_publish <prefix-path>
#
# Publishes the build's realized prefix using the identity-flag block
# CACHE_PHASE_FLAGS captured by `cache_phase_prepare`. The publish is
# best-effort: a failure is logged but does NOT abort the build.
cache_phase_publish() {
  local prefix="$1"
  if [[ -z "${CACHE_KEY_HEX:-}" || -z "${CACHE_PHASE_FLAGS:-}" ]]; then
    echo "[cache] cache_phase_publish called without cache_phase_prepare" >&2
    return 1
  fi
  cache_publish "${CACHE_KEY_HEX}" "${prefix}" "${CACHE_PHASE_FLAGS[@]}" \
    || echo "[cache] cache publish skipped/failed for ${CACHE_KEY_HEX}" >&2
}

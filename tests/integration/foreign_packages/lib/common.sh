#!/usr/bin/env bash
# Shared bash helpers for the C2 foreign-package harvester integration
# tests. Each t_c2_harvest_*.sh test builds a deterministic fixture
# (see ``fixture_build.nim``), runs the harvester in ``--offline +
# fingerprint-allowlist`` mode against it, and asserts on the produced
# catalog files.
#
# The fixture lives under a per-test temp directory so two tests can
# run in parallel without interference.

set -euo pipefail

c2_repo_root() {
  local dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
  echo "$dir"
}

c2_harvester_binary() {
  local repo_root
  repo_root="$(c2_repo_root)"
  if [[ -n "${C2_HARVESTER_BIN:-}" ]]; then
    echo "$C2_HARVESTER_BIN"
    return
  fi
  # On Windows the compiled binary lands next to the source as
  # repro_harvest_apt.exe; on Linux/macOS, repro_harvest_apt.
  for candidate in \
      "$repo_root/apps/repro-harvest-apt/repro_harvest_apt.exe" \
      "$repo_root/apps/repro-harvest-apt/repro_harvest_apt" \
      "$repo_root/build/test-bin/repro_harvest_apt.exe" \
      "$repo_root/build/test-bin/repro_harvest_apt"
  do
    if [[ -x "$candidate" ]]; then
      echo "$candidate"
      return
    fi
  done
  echo "ERROR: cannot locate repro_harvest_apt binary; build it via:" >&2
  echo "  nim c -d:ssl --path:apps/repro-harvest-apt/src apps/repro-harvest-apt/repro_harvest_apt.nim" >&2
  exit 1
}

c2_fixture_builder() {
  local repo_root
  repo_root="$(c2_repo_root)"
  for candidate in \
      "$repo_root/tests/integration/foreign_packages/lib/fixture_build.exe" \
      "$repo_root/tests/integration/foreign_packages/lib/fixture_build"
  do
    if [[ -x "$candidate" ]]; then
      echo "$candidate"
      return
    fi
  done
  echo "ERROR: cannot locate fixture_build binary; build it via:" >&2
  echo "  nim c tests/integration/foreign_packages/lib/fixture_build.nim" >&2
  exit 1
}

c2_make_workdir() {
  local prefix="${1:-c2}"
  if command -v mktemp >/dev/null 2>&1; then
    mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX"
  else
    local dir="${TMPDIR:-/tmp}/${prefix}.$$"
    mkdir -p "$dir"
    echo "$dir"
  fi
}

c2_build_fixture() {
  local root="$1"
  "$(c2_fixture_builder)" "$root" >/dev/null
}

c2_run_harvester() {
  # Usage: c2_run_harvester <fixture_root> <output_dir> <source-spec>
  local fixture="$1"
  local out="$2"
  local source="$3"
  "$(c2_harvester_binary)" \
    --source "$source" \
    --output-dir "$out" \
    --cache-dir "$fixture/cache" \
    --gpg-keys "$fixture/keys" \
    --offline \
    --signature-backend fingerprint-allowlist \
    --rate-ms 0
}

c2_ok() {
  echo "OK: $*"
}

c2_fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# C3 helpers
# ---------------------------------------------------------------------------

c3_launcher_binary() {
  local repo_root
  repo_root="$(c2_repo_root)"
  if [[ -n "${C3_LAUNCHER_BIN:-}" ]]; then
    echo "$C3_LAUNCHER_BIN"; return
  fi
  for candidate in \
      "$repo_root/apps/reprobuild-sandbox-launcher/reprobuild-sandbox-launcher" \
      "$repo_root/apps/reprobuild-sandbox-launcher/reprobuild-sandbox-launcher.exe"
  do
    if [[ -x "$candidate" ]]; then echo "$candidate"; return; fi
  done
  echo "ERROR: cannot locate reprobuild-sandbox-launcher; build it via:" >&2
  echo "  ./apps/reprobuild-sandbox-launcher/build.sh" >&2
  exit 1
}

c3_manifest_emit_helper() {
  local repo_root
  repo_root="$(c2_repo_root)"
  for candidate in \
      "$repo_root/tests/integration/foreign_packages/lib/c3_manifest_emit.exe" \
      "$repo_root/tests/integration/foreign_packages/lib/c3_manifest_emit"
  do
    if [[ -x "$candidate" ]]; then echo "$candidate"; return; fi
  done
  echo "ERROR: cannot locate c3_manifest_emit helper; build it via:" >&2
  echo "  nim c tests/integration/foreign_packages/lib/c3_manifest_emit.nim" >&2
  exit 1
}

# c3_make_fake_prefix <root> <name>
# Creates a content-addressed-shaped prefix at <root>/prefixes/<name>/
# with a usr/bin/, usr/lib/x86_64-linux-gnu/ tree containing dummy
# files so the launcher manifest generator picks the dirs up via the
# default existsCheck.
c3_make_fake_prefix() {
  local root="$1"
  local name="$2"
  local prefix="$root/prefixes/$name"
  mkdir -p "$prefix/usr/bin" "$prefix/usr/lib/x86_64-linux-gnu" "$prefix/lib"
  echo "$prefix"
}

c3_skip_on_windows() {
  case "$(uname -s 2>/dev/null || echo Unknown)" in
    MINGW*|MSYS*|CYGWIN*)
      echo "SKIP: $* (Windows: launcher namespace setup is a no-op stub)"
      exit 0;;
  esac
}

# c3_have_userns: returns 0 if the host kernel supports unprivileged
# user namespaces. Used to gate tests that require real bind mounts.
c3_have_userns() {
  if [[ ! -e /proc/sys/kernel/unprivileged_userns_clone ]]; then
    # File absent on older / non-Debian kernels; assume userns is on.
    return 0
  fi
  local v
  v="$(cat /proc/sys/kernel/unprivileged_userns_clone)"
  [[ "$v" == "1" ]]
}

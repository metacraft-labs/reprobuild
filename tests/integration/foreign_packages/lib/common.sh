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

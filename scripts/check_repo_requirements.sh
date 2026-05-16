#!/usr/bin/env bash
set -euo pipefail

failures=0

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

require_file() {
  [ -f "$1" ] || fail "missing file $1"
}

require_dir() {
  [ -d "$1" ] || fail "missing directory $1"
}

require_symlink() {
  local path="$1"
  local target="$2"
  if [ ! -L "${path}" ]; then
    fail "missing symlink ${path}"
    return
  fi
  [ "$(readlink "${path}")" = "${target}" ] || fail "${path} must point to ${target}"
}

require_contains() {
  local path="$1"
  local text="$2"
  grep -Fq "${text}" "${path}" || fail "${path} must contain ${text}"
}

for path in README.md LICENSE flake.nix flake.lock .envrc .gitignore Justfile reprobuild.nimble config.nims AGENTS.md; do
  require_file "${path}"
done

for path in .github .github/workflows nix docs libs apps tests benchmarks scripts examples tools references vendor; do
  require_dir "${path}"
done

require_symlink CLAUDE.md AGENTS.md
require_symlink .github/copilot-instructions.md ../AGENTS.md
require_file .github/workflows/ci.yml

require_contains .envrc "use flake"
require_contains flake.nix 'nixos-modules.url = "github:metacraft-labs/nixos-modules"'
require_contains flake.nix 'nixpkgs.follows = "nixos-modules/nixpkgs-unstable"'
require_contains flake.nix 'flake-parts.follows = "nixos-modules/flake-parts"'
require_contains flake.nix 'git-hooks.follows = "nixos-modules/git-hooks-nix"'
for system in x86_64-linux aarch64-linux x86_64-darwin aarch64-darwin; do
  require_contains flake.nix "\"${system}\""
done
require_contains flake.nix "devShells.default"
require_contains flake.nix "packages.default"
require_contains flake.nix "checks ="
require_contains flake.nix "git-hooks.lib"
require_contains flake.nix "shellHook = pre-commit-check.shellHook"

for recipe in build test lint format fmt t bump-version bench bench-quick bench_reprobuild_core_mvp_performance repomix check-repo-requirements; do
  just --summary | tr ' ' '\n' | grep -Fxq "${recipe}" || fail "missing Justfile recipe ${recipe}"
done

require_contains .github/workflows/ci.yml "run: nix develop --command just lint"
require_contains .github/workflows/ci.yml "run: nix develop --command just test"
require_contains .github/workflows/ci.yml "run: nix build .#default"
require_contains .github/workflows/ci.yml "if: always()"
require_contains .github/workflows/ci.yml "actions/upload-artifact@v4"

for pattern in "repomix/" "bench-results/" "nimcache/" "result"; do
  require_contains .gitignore "${pattern}"
done

for forbidden in .github/sibling-pins .github/sibling-pins.json .github/sibling-repos .repo-workspaces.env; do
  [ ! -e "${forbidden}" ] || fail "forbidden workspace pin file present: ${forbidden}"
done

while read -r lib _; do
  case "${lib}" in
    ""|\#*) continue ;;
  esac
  require_dir "libs/${lib}"
  require_file "libs/${lib}/${lib}.nimble"
  require_file "libs/${lib}/README.md"
  require_file "libs/${lib}/src/${lib}.nim"
done < libs/libraries.txt

while read -r name path _; do
  case "${name}" in
    ""|\#*) continue ;;
  esac
  require_dir "apps/${name}"
  require_file "${path}"
done < apps/entrypoints.txt

for path in tests/unit tests/integration tests/compatibility tests/fixtures tests/e2e benchmarks/suites benchmarks/lib benchmarks/fixtures benchmarks/reports; do
  require_dir "${path}"
done

for suite in local-build-engine external-packages fs-snoop monitored-cache multi-project codetracer-subset windows-dev-env hcr-agent-ipc hcr-direct-linker hcr-debug-unwind; do
  require_dir "tests/e2e/${suite}"
done

for suite in build-engine-throughput cache-consultation-latency monitor-overhead runquota-integration hcr-linker-latency; do
  require_dir "benchmarks/suites/${suite}"
done

for example in hello-c hello-nim depfile-c fs-snoop-tool monitored-opaque-tool multi-project codetracer-subset windows-dev-env; do
  require_dir "examples/${example}"
  require_file "examples/${example}/README.md"
done

if [ "${failures}" -ne 0 ]; then
  exit 1
fi

echo "reprobuild repository requirements passed"

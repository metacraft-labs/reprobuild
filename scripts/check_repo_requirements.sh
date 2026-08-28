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
  if [ -L "${path}" ]; then
    [ "$(readlink "${path}")" = "${target}" ] || fail "${path} must point to ${target}"
    return
  fi

  # Git checks symlinks out as files containing their targets when the Windows
  # filesystem or checkout has core.symlinks disabled. Accept only that exact
  # representation of an index entry that is still recorded as a symlink.
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      if [ -f "${path}" ] &&
         [ "$(git ls-files -s -- "${path}" | awk '{print $1}')" = "120000" ] &&
         [ "$(cat "${path}")" = "${target}" ]; then
        return
      fi
      ;;
  esac

  fail "missing symlink ${path}"
}

require_contains() {
  local path="$1"
  local text="$2"
  grep -Fq "${text}" "${path}" || fail "${path} must contain ${text}"
}

require_count() {
  local path="$1"
  local text="$2"
  local expected="$3"
  local actual
  actual="$(grep -Fc -- "${text}" "${path}" || true)"
  [ "${actual}" = "${expected}" ] ||
    fail "${path} must contain ${text} exactly ${expected} time(s), found ${actual}"
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
require_file .github/workflows/benchmark.yml

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
# The dev shell must still run git-hooks.nix's installer. It is no longer the
# WHOLE shellHook: Reprobuild's own hook reconciliation runs after it, and the
# pre-commit hook handoff runs on both sides of it, so the requirement is that
# the installer is composed in — not that nothing else is.
require_contains flake.nix "+ pre-commit-check.shellHook"

# CodeTracer's canonical native target imports span_stream. The trace-format
# pin and every Nix execution surface must therefore agree on one immutable
# source root. Exact counts make removal of any one surface fail this quick
# repository check instead of surfacing after a minute-long CodeTracer compile.
trace_format_rev="bc7c5d256d0a4b1246f9a9bbb51a83071d3d8e26"
require_contains flake.nix "github:metacraft-labs/codetracer-trace-format-nim/${trace_format_rev}"
require_count flake.lock "\"rev\": \"${trace_format_rev}\"" 2
require_contains flake.nix 'requiredModule = "${sourceRoot}/codetracer_trace_writer/span_stream.nim";'
require_count flake.nix 'export CODETRACER_TRACE_FORMAT_NIM_SRC=${codeTracerTraceFormatNimSrc}' 1
require_count flake.nix 'CODETRACER_TRACE_FORMAT_NIM_SRC = codeTracerTraceFormatNimSrc;' 2
require_count flake.nix '--set-default CODETRACER_TRACE_FORMAT_NIM_SRC ${codeTracerTraceFormatNimSrc} \' 1
require_count flake.nix 'CODETRACER_TRACE_FORMAT_NIM_SRC|${codeTracerTraceFormatNimSrc}' 1
require_count flake.nix '                                      ${ct-trace-format-src} \' 1
require_contains tests/e2e/codetracer-subset/t_e2e_codetracer_in_place_project_file.nim \
  '"CODETRACER_TRACE_FORMAT_NIM_SRC",'
require_contains tests/e2e/codetracer-subset/t_e2e_codetracer_in_place_project_file.nim \
  'let pinnedSource = getEnv("CODETRACER_TRACE_FORMAT_NIM_SRC")'
require_contains tests/fixtures/codetracer-subset/config-602e7bb7.nims \
  'addPathIfDir(getEnv("CODETRACER_TRACE_FORMAT_NIM_SRC"))'

# Compiler macro source maps are package data. If they regain executable mode
# or enter the wrapper loop, the Darwin runtime audit sees a hidden non-Mach-O
# "entry point" and the packaged-runtime gate cannot reach its compile checks.
require_count flake.nix 'nim-macro-sourcemaps/' 4
require_count flake.nix 'install -m644' 2
require_count flake.nix 'test -x "$b" || continue' 1
require_contains flake.nix 'unexpected non-executable bin artifact: $wrapper'
require_count flake.nix 'CODESIGN=/usr/bin/codesign \' 1
require_count flake.nix "loaderStrings=\$(strings \"\$candidate\" | sed -e 's/^@//')" 1
require_count flake.nix '<<< "$loaderStrings"' 3

# Capture `just --summary` once and check it through a here-string. Piping into
# `grep -q` under `set -o pipefail` can surface SIGPIPE as a false "missing
# recipe" result when grep finds an early match and closes the pipe.
just_recipes="$(just --summary | tr ' ' '\n')"
for recipe in build bootstrap test lint format fmt t bump-version bench bench-quick bench_reprobuild_core_mvp_performance bench_cmake_reprobuild_vs_ninja bench_cmake_reprobuild_vs_ninja_quick bench_cmake_reprobuild_vs_ninja_medium e2e_reprobuild_mvp_acceptance repomix check-repo-requirements; do
  grep -Fxq "${recipe}" <<< "${just_recipes}" || fail "missing Justfile recipe ${recipe}"
done

# Shared-dev-env policy
# (metacraft-dev-guidelines/policies/ci-shared-dev-env.md): CI runs
# every build/test command through `dev-exec` from the shared
# `setup-dev-env` action so the toolchain matches the local nix shell
# exactly. The literal `nix develop --command` forms enforced before
# the migration are explicitly forbidden going forward.
require_contains .github/workflows/ci.yml "metacraft-labs/metacraft-github-actions/setup-dev-env"
require_contains .github/workflows/ci.yml "run: dev-exec just lint"
require_contains .github/workflows/ci.yml "run: dev-exec just test"
require_contains .github/workflows/ci.yml "run: dev-exec nix build .#default"
require_contains .github/workflows/ci.yml "if: always()"
require_contains .github/workflows/ci.yml "actions/upload-artifact@v4"
require_contains .github/workflows/benchmark.yml 'runner: '\''["self-hosted", "Linux", "X64", "benchmark"]'\'''
# CIP-5 moved the macOS benchmark leg off the persistent self-hosted pool onto
# the ephemeral `eph-macos-arm64` class; the Linux benchmark leg stays on the
# persistent self-hosted `benchmark` runner (big-iron bench box).
require_contains .github/workflows/benchmark.yml 'runner: '\''["eph-macos-arm64"]'\'''
require_contains .github/workflows/benchmark.yml "metacraft-labs/runquota"
require_contains .github/workflows/benchmark.yml "metacraft-labs/reprobuild-cmake"
require_contains .github/workflows/benchmark.yml "ref: reprobuild"
require_contains .github/workflows/benchmark.yml "cmake --build build --target cmake"
require_contains .github/workflows/benchmark.yml "run: nix develop --command just bench --quick"
require_contains .github/workflows/benchmark.yml "actions/upload-artifact@v4"
require_contains .github/workflows/benchmark.yml "benchmark-action/github-action-benchmark@v1"
require_contains .github/workflows/benchmark.yml "issues: write"
require_contains .github/workflows/benchmark.yml "max-parallel: 1"
require_contains .github/workflows/benchmark.yml "tool: customSmallerIsBetter"
require_contains .github/workflows/benchmark.yml "auto-push: false"
require_contains .github/workflows/benchmark.yml "save-data-file: false"
require_contains .github/workflows/benchmark.yml "comment-always: true"
require_contains .github/workflows/benchmark.yml "auto-push: true"
require_contains .github/workflows/benchmark.yml "gh-pages-branch: gh-pages"
require_contains .github/workflows/benchmark.yml "benchmark-data-dir-path: perf/bench/"
require_contains .github/workflows/benchmark.yml "alert-threshold: '120%'"
require_contains scripts/collect-benchmark-metrics.sh "REPROBUILD_BENCH_SUITES"
require_contains scripts/collect-benchmark-metrics.sh "run-m23-benchmark.sh"
require_contains scripts/collect-benchmark-metrics.sh "run-cmake-generator-competitiveness-benchmark.sh"
require_contains scripts/collect-benchmark-metrics.sh "bench-results/report.html"
require_contains scripts/collect-benchmark-metrics.sh "ratioSummary"

for pattern in "repomix/" "bench-results/" "nimcache/" "result"; do
  require_contains .gitignore "${pattern}"
done

for forbidden in .github/sibling-pins .github/sibling-pins.json .github/rr-backend-pin.txt .repo-workspaces.env; do
  [ ! -e "${forbidden}" ] || fail "forbidden workspace pin file present: ${forbidden}"
done

while IFS=$' \t\r' read -r lib _; do
  case "${lib}" in
    ""|\#*) continue ;;
  esac
  require_dir "libs/${lib}"
  require_file "libs/${lib}/${lib}.nimble"
  require_file "libs/${lib}/README.md"
  require_file "libs/${lib}/src/${lib}.nim"
done < libs/libraries.txt

while IFS=$' \t\r' read -r name path _; do
  case "${name}" in
    ""|\#*) continue ;;
  esac
  require_dir "apps/${name}"
  require_file "${path}"
done < apps/entrypoints.txt

for path in tests/unit tests/integration tests/compatibility tests/fixtures tests/e2e benchmarks/suites benchmarks/lib benchmarks/fixtures benchmarks/reports; do
  require_dir "${path}"
done

for suite in local-build-engine external-packages io-monitor monitored-cache multi-project codetracer-subset windows-dev-env hcr-agent-ipc hcr-direct-linker hcr-debug-unwind; do
  require_dir "tests/e2e/${suite}"
done

for suite in build-engine-throughput cache-consultation-latency monitor-overhead runquota-integration hcr-linker-latency cmake-generator-competitiveness; do
  require_dir "benchmarks/suites/${suite}"
done

for example in hello-c hello-nim depfile-c io-monitor-tool monitored-opaque-tool multi-project codetracer-subset windows-dev-env; do
  require_dir "examples/${example}"
  require_file "examples/${example}/README.md"
done

if [ "${failures}" -ne 0 ]; then
  exit 1
fi

echo "reprobuild repository requirements passed"

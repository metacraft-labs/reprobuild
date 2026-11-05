#!/usr/bin/env bash
# Run one add-on unit gate (libs/repro_addon/tests/<test>.nim, the apt
# closure realiser's libs/repro_dsl_stdlib/tests/<test>.nim, or the deploy
# agent's libs/repro_deploy_agent/tests and libs/repro_cli_support/tests),
# green and then
# under a falsifying mutation, and require red under the mutation.
#
#   scripts/run_addon_unit_mutation.sh <test-basename> <mutation>
#
# The mutation is compiled in with -d:reproAddonMutation=<mutation>
# (libs/repro_addon/src/repro_addon/mutations.nim); it never exists in a
# product build. Exit 0 only when the gate is green without the mutation
# and red with it.
set -euo pipefail
# A verdict taken under a foreign preload is about that preload, not this
# tree: an agent session's command-trace shim printed a line of its own on a
# tool's output and read t_addon_preflight_needs_a_c_compiler green while it
# was red. Unsetting the variable is not enough -- a library already loaded
# into this shell re-inserts itself into every child at exec -- so the shared
# guard re-executes this script once in a shell started without it (keeping
# reprobuild's own monitor shim), and refuses when it comes back. It runs
# before the `cd`, so the re-exec finds this script by the path it was given.
# shellcheck source=scripts/lib/foreign_preload.sh
source "$(dirname "$0")/lib/foreign_preload.sh"
foreign_preload_guard "$@"
cd "$(dirname "$0")/.."

test="${1:?usage: run_addon_unit_mutation.sh <test-basename> <mutation>}"
mutation="${2:?usage: run_addon_unit_mutation.sh <test-basename> <mutation>}"
# The add-on's gates live beside the add-on, the apt closure realiser, the
# deploy agent and its CLI; the first that has the test wins.
src=""
for dir in libs/repro_addon/tests libs/repro_dsl_stdlib/tests \
           libs/repro_deploy_agent/tests libs/repro_cli_support/tests \
           libs/repro_infra/tests libs/repro_profile_compile/tests; do
  if [ -f "${dir}/${test}.nim" ]; then src="${dir}/${test}.nim"; break; fi
done
[ -n "$src" ] || src="libs/repro_addon/tests/${test}.nim"
[ -f "$src" ] || { echo "run_addon_unit_mutation: no such test: $src" >&2; exit 2; }
mkdir -p build/test-bin

nim c --hints:off --warnings:off --nimcache:"build/nimcache/${test}" \
  --out:"build/test-bin/${test}" "$src"
if ! "build/test-bin/${test}"; then
  echo "run_addon_unit_mutation: ${test} is RED without the mutation" >&2
  exit 1
fi
echo "run_addon_unit_mutation: ${test} green without the mutation"

nim c --hints:off --warnings:off -d:reproAddonMutation="$mutation" \
  --nimcache:"build/nimcache/${test}-${mutation}" \
  --out:"build/test-bin/${test}-${mutation}" "$src"
if "build/test-bin/${test}-${mutation}"; then
  echo "run_addon_unit_mutation: ${test} stayed GREEN under ${mutation}" >&2
  exit 1
fi
echo "run_addon_unit_mutation: ${test} red under ${mutation}, as required"

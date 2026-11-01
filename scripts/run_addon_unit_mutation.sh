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
cd "$(dirname "$0")/.."
# A verdict taken under a foreign preload is not about this tree.
# shellcheck source=scripts/strip_foreign_preload.sh
source scripts/strip_foreign_preload.sh

test="${1:?usage: run_addon_unit_mutation.sh <test-basename> <mutation>}"
mutation="${2:?usage: run_addon_unit_mutation.sh <test-basename> <mutation>}"
# The add-on's gates live beside the add-on, the apt closure realiser, the
# deploy agent and its CLI; the first that has the test wins.
src=""
for dir in libs/repro_addon/tests libs/repro_dsl_stdlib/tests \
           libs/repro_deploy_agent/tests libs/repro_cli_support/tests; do
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

#!/usr/bin/env bash
# Run one add-on unit gate (libs/repro_addon/tests/<test>.nim, or the apt
# closure realiser's libs/repro_dsl_stdlib/tests/<test>.nim), green and then
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

test="${1:?usage: run_addon_unit_mutation.sh <test-basename> <mutation>}"
mutation="${2:?usage: run_addon_unit_mutation.sh <test-basename> <mutation>}"
src="libs/repro_addon/tests/${test}.nim"
[ -f "$src" ] || src="libs/repro_dsl_stdlib/tests/${test}.nim"
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

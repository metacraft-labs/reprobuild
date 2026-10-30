#!/usr/bin/env bash
# Run one add-on-mode VM gate (tests/e2e/addon/<test>.nim) end to end.
#
#   scripts/run_addon_gate.sh <test-basename>
#
# Environment:
#   REPRO_ADDON_BASES     comma-separated test-bed bases (default: the amd64
#                         matrix debian-12-amd64,debian-13-amd64,
#                         ubuntu-24.04-amd64; also debian-13-arm64 and
#                         ubuntu-24.04-armhf, which run under TCG)
#   REPRO_ADDON_MUTATION  build and run the falsifying mutation of that name
#                         (libs/repro_addon/src/repro_addon/mutations.nim);
#                         the gate is then expected to FAIL
#   REPRO_ADDON_BACKEND   "incus" for the Incus inner loop (amd64 only)
#   REPRO_ADDON_TEST_SEAMS  "1" builds and runs the variant with the
#                         switch's pause points (seams.nim); the gates that
#                         stop a switch mid-way set it themselves in
#                         GatesNeedingSeams below
#   GOSTI_SRC             gosti's src directory (default: ../gosti/src, else
#                         ../vm-harness/src)
#
# The static add-on binary for each base's architecture is (re)built first,
# so a gate always runs the binary of the tree it was invoked from. Records
# land in build/addon-gates/records/. Missing KVM, QEMU or gosti is a failure
# with the reason, never a skip: a gate the operator invoked must run.
set -euo pipefail
cd "$(dirname "$0")/.."

test="${1:?usage: run_addon_gate.sh <test-basename>}"
src="tests/e2e/addon/${test}.nim"
[ -f "$src" ] || { echo "run_addon_gate: no such gate: $src" >&2; exit 2; }

bases="${REPRO_ADDON_BASES:-debian-12-amd64,debian-13-amd64,ubuntu-24.04-amd64}"
arches=()
IFS=',' read -ra base_list <<< "$bases"
for b in "${base_list[@]}"; do
  a="${b##*-}"
  case " ${arches[*]-} " in *" $a "*) ;; *) arches+=("$a") ;; esac
done

if [ -z "${GOSTI_SRC:-}" ]; then
  for c in ../gosti/src ../vm-harness/src; do
    if [ -f "$c/gosti.nim" ]; then GOSTI_SRC="$(cd "$c" && pwd)"; break; fi
  done
fi
[ -n "${GOSTI_SRC:-}" ] && [ -f "$GOSTI_SRC/gosti.nim" ] || {
  echo "run_addon_gate: gosti not found; check it out beside reprobuild or set GOSTI_SRC" >&2
  exit 2
}
export GOSTI_SRC
if [ "${REPRO_ADDON_BACKEND:-}" != "incus" ]; then
  for tool in qemu-system-x86_64 qemu-img ssh ssh-keygen scp curl; do
    command -v "$tool" >/dev/null || { echo "run_addon_gate: $tool is not on PATH" >&2; exit 2; }
  done
  [ -w /dev/kvm ] || { echo "run_addon_gate: /dev/kvm is not writable" >&2; exit 2; }
else
  command -v incus >/dev/null || { echo "run_addon_gate: incus is not on PATH" >&2; exit 2; }
fi

mutation_args=()
[ -n "${REPRO_ADDON_MUTATION:-}" ] && mutation_args=(--mutation "$REPRO_ADDON_MUTATION")
# Gates that pause a switch at a step need the seam build.
case "$test" in
  t_e2e_addon_hard_reset_at_every_step)
    export REPRO_ADDON_TEST_SEAMS=1 ;;
esac
[ "${REPRO_ADDON_TEST_SEAMS:-}" = "1" ] && mutation_args+=(--test-seams)
bash ./scripts/build_addon_static.sh ${mutation_args[@]+"${mutation_args[@]}"} "${arches[@]}"

mkdir -p build/test-bin
nim c --hints:off --warnings:off --nimcache:"build/nimcache/${test}" \
  --out:"build/test-bin/${test}" "$src"
REPRO_ADDON_VM_GATES=1 REPRO_ADDON_BASES="$bases" "build/test-bin/${test}"

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
#   GOSTI_SRC             a gosti checkout's src directory, at the pinned
#                         revision (default: a detached worktree of the pin
#                         from ../gosti or ../vm-harness, under build/)
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

# gosti is pinned (tests/e2e/addon/gosti.pin, mirrored in
# .github/sibling-repos): a gate runs against that revision and no other.
# GOSTI_SRC may name a checkout's src directory, but only one at the pinned
# revision; otherwise the pinned revision is checked out from a sibling
# gosti (or vm-harness) clone into a detached worktree under build/, and
# that is what the gate compiles against.
gosti_pin="$(tr -d ' \n' < tests/e2e/addon/gosti.pin)"
if [ -n "${GOSTI_SRC:-}" ]; then
  have="$(git -C "$GOSTI_SRC/.." rev-parse HEAD 2>/dev/null || true)"
  [ "$have" = "$gosti_pin" ] || {
    echo "run_addon_gate: GOSTI_SRC is at ${have:-?}, not the pinned $gosti_pin (tests/e2e/addon/gosti.pin)" >&2
    exit 2
  }
else
  clone=""
  for c in ../gosti ../vm-harness; do
    if [ -d "$c/.git" ] || [ -f "$c/.git" ]; then clone="$(cd "$c" && pwd)"; break; fi
  done
  [ -n "$clone" ] || { echo "run_addon_gate: no gosti clone beside reprobuild" >&2; exit 2; }
  git -C "$clone" cat-file -e "$gosti_pin^{commit}" 2>/dev/null ||
    git -C "$clone" fetch -q origin "$gosti_pin" || {
      echo "run_addon_gate: $clone cannot provide the pinned gosti $gosti_pin" >&2; exit 2; }
  wt="$(pwd)/build/gosti-$gosti_pin"
  if [ ! -f "$wt/src/gosti.nim" ]; then
    git -C "$clone" worktree add -q --detach "$wt" "$gosti_pin"
  fi
  GOSTI_SRC="$wt/src"
fi
export GOSTI_SRC
if [ "${REPRO_ADDON_BACKEND:-}" != "incus" ]; then
  for tool in qemu-system-x86_64 qemu-img ssh ssh-keygen scp curl socat flock; do
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
  t_e2e_addon_hard_reset_at_every_step|t_e2e_addon_recovery_never_holds_up_boot|t_e2e_addon_refused_recovery_keeps_its_record|t_e2e_addon_confirm_or_revert|t_e2e_addon_exclusive_never_overlaps|t_e2e_addon_no_plaintext_secret_on_disk|t_e2e_addon_secrets_follow_generations|t_e2e_addon_secrets_without_memory_controller|t_e2e_addon_apply_unit_has_no_network|t_e2e_addon_fetch_unit_reaches_only_its_origins|t_e2e_addon_sequence_floor_survives_and_is_root_only|t_e2e_addon_staging_swap_after_verify_is_refused|t_e2e_addon_profile_compiles_unprivileged)
    export REPRO_ADDON_TEST_SEAMS=1 ;;
esac
[ "${REPRO_ADDON_TEST_SEAMS:-}" = "1" ] && mutation_args+=(--test-seams)
bash ./scripts/build_addon_static.sh ${mutation_args[@]+"${mutation_args[@]}"} "${arches[@]}"

mkdir -p build/test-bin
# Concurrent runs of the same gate share its nimcache: the compile takes a
# lock, and each run executes its own copy of the binary.
mkdir -p build/test-bin build/nimcache
bin="build/test-bin/${test}.run-$$"
(
  flock 8
  nim c --hints:off --warnings:off --nimcache:"build/nimcache/${test}" \
    --out:"build/test-bin/${test}" "$src"
  cp "build/test-bin/${test}" "$bin"
) 8>"build/nimcache/${test}.lock"
trap 'rm -f "$bin"' EXIT
REPRO_ADDON_VM_GATES=1 REPRO_ADDON_BASES="$bases" "$bin"

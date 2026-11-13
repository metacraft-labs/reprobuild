#!/usr/bin/env bash
# Run one add-on-mode VM gate (tests/e2e/addon/<test>.nim) end to end.
#
#   scripts/run_addon_gate.sh <test-basename>
#
# Environment:
#   REPRO_ADDON_BASES     comma-separated test-bed bases (default: the amd64
#                         matrix debian-12-amd64,debian-13-amd64,
#                         ubuntu-24.04-amd64; also debian-13-arm64 and
#                         ubuntu-24.04-armhf, which run under TCG; the Arch
#                         gates take arch-btrfs-amd64, arch-ext4-amd64 and
#                         arch-old-systemd-amd64, tests/e2e/addon/arch_testbed.nim)
#   REPRO_ADDON_MUTATION  build and run the falsifying mutation of that name
#                         (libs/repro_addon/src/repro_addon/mutations.nim);
#                         the gate is then expected to FAIL. The off-host
#                         check's mutations are compiled into the gate
#                         binary too (see gate_defines below)
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
# A library another tool preloaded into this shell (an agent harness's
# command-trace shim) is inherited by every engine action the gate starts,
# where it sits beside the monitor shim: a monitor loss on every monitored
# edge, and agent-harbor 0.6.16's shim deadlocks in its constructor under
# the monitor (its ld_preload::later_copy_original waits without bound), so
# the profile compile a gate runs hangs. The shared guard removes it and
# re-executes this script once without it, as run_tests.sh and
# run_addon_unit_mutation.sh do. It runs before the `cd`, so the re-exec
# finds this script by the path it was given.
# shellcheck source=scripts/lib/foreign_preload.sh
source "$(dirname "$0")/lib/foreign_preload.sh"
foreign_preload_guard "$@"
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
  t_e2e_addon_hard_reset_at_every_step|t_e2e_addon_recovery_never_holds_up_boot|t_e2e_addon_refused_recovery_keeps_its_record|t_e2e_addon_confirm_or_revert|t_e2e_addon_exclusive_never_overlaps|t_e2e_addon_no_plaintext_secret_on_disk|t_e2e_addon_secrets_follow_generations|t_e2e_addon_secrets_without_memory_controller|t_e2e_addon_apply_unit_has_no_network|t_e2e_addon_fetch_unit_reaches_only_its_origins|t_e2e_addon_sequence_floor_survives_and_is_root_only|t_e2e_addon_tick_observes_a_fresh_cycle|t_e2e_addon_staging_swap_after_verify_is_refused|t_e2e_addon_store_is_read_only_to_everything_else|t_addon_agent_apply_unit_lacks_cap_net_admin|t_e2e_addon_unit_syscall_filters_cover_their_traces|t_e2e_addon_detectors_positive_controls|t_e2e_addon_egress_observer|t_e2e_addon_audit_bed|t_e2e_addon_custody_crash_points)
    export REPRO_ADDON_TEST_SEAMS=1 ;;
esac
[ "${REPRO_ADDON_TEST_SEAMS:-}" = "1" ] && mutation_args+=(--test-seams)
# A gate of the test bed itself (that its guests are what their pins say)
# runs no add-on binary, so none is built for it.
case "$test" in
  t_e2e_arch_testbed_is_pinned) ;;
  *) bash ./scripts/build_addon_static.sh ${mutation_args[@]+"${mutation_args[@]}"} "${arches[@]}" ;;
esac

mkdir -p build/test-bin
# Mutations of code that runs in the GATE process, not on the guest: the
# off-host evidence check (libs/repro_addon/src/repro_addon/evidence_check.nim)
# is the build host's half of the A11 detectors, so its falsifying builds
# must reach the gate binary itself. Every other mutation is the add-on
# binary's (built above) or the sink's (built by the gate).
gate_defines=()
gate_tag=""
case "${REPRO_ADDON_MUTATION:-}" in
  check-silence-as-idle|check-skips-attestation|lag-detector-disabled|lag-from-newest-copy|check-ignores-ship-delay|check-status-ignores-silence|check-forgets-enrolled-key|lag-ignores-check-state)
    gate_defines=(--define:reproAddonMutation="$REPRO_ADDON_MUTATION")
    gate_tag="-$REPRO_ADDON_MUTATION" ;;
esac
# Concurrent runs of the same gate share its nimcache: the compile takes a
# lock, and each run executes its own copy of the binary.
mkdir -p build/test-bin build/nimcache
bin="build/test-bin/${test}${gate_tag}.run-$$"
(
  flock 8
  nim c --hints:off --warnings:off ${gate_defines[@]+"${gate_defines[@]}"} \
    --nimcache:"build/nimcache/${test}${gate_tag}" \
    --out:"build/test-bin/${test}${gate_tag}" "$src"
  cp "build/test-bin/${test}${gate_tag}" "$bin"
) 8>"build/nimcache/${test}${gate_tag}.lock"
trap 'rm -f "$bin"' EXIT
# The gate and every helper it starts (cache, HTTP origins, sink, QEMU) run
# as one process group, ended together however the gate ends, and with no
# descriptor of this script's caller (scripts/lib/process_group.sh).
# shellcheck source=scripts/lib/process_group.sh
source scripts/lib/process_group.sh
gate_rc=0
run_in_own_group env REPRO_ADDON_VM_GATES=1 REPRO_ADDON_BASES="$bases" "$bin" || gate_rc=$?
exit "$gate_rc"

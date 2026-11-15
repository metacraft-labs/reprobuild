#!/usr/bin/env bash
# The Nim 2.2.4 lane (owner decision 2026-11-07, A11 code review round 4):
# build and run, with the lowest Nim the `uses: "nim >=2.2 <3.0"` range of
# repro.nim admits, the suites of the async code that once awaited inside
# a `finally` -- a construct Nim 2.2.4's async transform compiles into an
# AssertionDefect ("yielded nil") that later releases do not. The dev
# shell's Nim compiles it right, so without this lane nothing would notice
# it coming back.
#
# Nim 2.2.4 is the flake's own nixpkgs `nim` (pinned by flake.lock). Run
# inside the dev shell (`just test-nim224`), which provides the C toolchain
# and the libraries the tests link.
#
#   scripts/run_nim224_lane.sh            # every lane suite
#   scripts/run_nim224_lane.sh <test>...  # some of them
#
# NIM224_FLAGS adds compiler flags to the suites' builds (not the sink's):
# a falsifying build, e.g.
#   NIM224_FLAGS=-d:reproAddonMutation=signer-close-in-finally \
#     scripts/run_nim224_lane.sh t_signer_closes_after_its_early_returns
#
# NIM224_LANE_MUTATION=unknown-suite-runs-nothing is the falsifier of the
# selection check (a name that matches nothing is then dropped silently, as
# before round 5).
#
# The signer has two suites: an in-process one, and the engine's own
# (t_worker_signing_certificates_are_time_bound), which links
# repro_cli_support and runs the engine's `cert-signer`. The lane builds
# that engine with Nim 2.2.4 too, when the suite is selected. It held only
# the first until repro_cli_support compiled under Nim 2.2.4 (reprobuild-pm
# issue 2026-11-07-repro-cli-support-does-not-build-under-nim-2-2-4).
set -euo pipefail
cd "$(dirname "$0")/.."

# The lane's suites. A name given on the command line must name one of
# them: a misspelt name used to select nothing, run nothing and report the
# lane green (reprobuild-pm issue 2026-11-08-nim224-lane-reports-green-for-
# an-unknown-suite-and-does-not-hold-the-simulator), which turned a
# falsifier run into a vacuous green. The selection is checked before
# anything is built.
suites=(
  libs/repro_addon/tests/t_addon_evidence_credential_is_append_only.nim
  libs/repro_addon/tests/t_addon_evidence_probe_owns_its_connection.nim
  libs/repro_addon/tests/t_addon_review_round3.nim
  libs/repro_addon/tests/t_addon_review_round4.nim
  libs/repro_addon/tests/t_addon_review_round5.nim
  libs/repro_addon/tests/t_addon_review_round8.nim
  libs/repro_peer_cache/tests/t_evidence_sink_append_only_and_liveness.nim
  libs/repro_peer_cache/tests/t_evidence_store_receipts_and_key_separation.nim
  libs/repro_peer_cache/tests/t_sim_tls_smoke_pass_stops_its_peers.nim
  libs/repro_distributed_worker/tests/t_signer_closes_after_its_early_returns.nim
  libs/repro_cli_support/tests/t_worker_signing_certificates_are_time_bound.nim
)
if [ "$#" -gt 0 ]; then
  selected=()
  for t in "$@"; do
    # An empty argument (an unset variable, `just test-nim224 ''`) names no
    # suite; if every argument is empty the selection is empty and refused
    # below.
    [ -z "$t" ] && continue
    found=0
    for s in "${suites[@]}"; do
      if [ "$(basename "$s" .nim)" = "$t" ]; then
        selected+=("$s"); found=1
      fi
    done
    if [ "$found" -eq 0 ] && [ "${NIM224_LANE_MUTATION:-}" != "unknown-suite-runs-nothing" ]; then
      echo "run_nim224_lane: '${t}' is not a lane suite; the lane's suites are:" >&2
      for s in "${suites[@]}"; do echo "  $(basename "$s" .nim)" >&2; done
      exit 2
    fi
  done
  suites=(${selected[@]+"${selected[@]}"})
fi
if [ "${#suites[@]}" -eq 0 ] && [ "${NIM224_LANE_MUTATION:-}" != "unknown-suite-runs-nothing" ]; then
  echo "run_nim224_lane: no suite selected; nothing would run" >&2
  exit 2
fi
if [ -n "${NIM224_LANE_SELECT_ONLY:-}" ]; then
  # For the lane's own test (tests/unit/test_nim224_lane_selection.py):
  # print the selection and stop before resolving Nim or building.
  for s in ${suites[@]+"${suites[@]}"}; do echo "selected: $(basename "$s" .nim)"; done
  echo "run_nim224_lane: every lane suite green under Nim 2.2.4 (selection only)"
  exit 0
fi

expected="2.2.4"
nimdir="$(nix build --no-link --print-out-paths --inputs-from . nixpkgs#nim)/bin"
version="$("$nimdir/nim" --version | head -1)"
case "$version" in
  *"Version ${expected} "*) ;;
  *) echo "run_nim224_lane: nixpkgs#nim is '${version}', not ${expected}" >&2; exit 2 ;;
esac
echo "run_nim224_lane: Nim ${expected} is $(readlink -f "$nimdir/nim")"
export PATH="$nimdir:$PATH"

# The sink the evidence suites spawn, built by the same Nim, with its
# dependency list, where repro_test_support/fresh_binary looks for them
# (REPRO_TEST_BUILD_DIR).
lane=build/nim224
mkdir -p "$lane/bin" "$lane/nimcache" "$lane/test-bin"
export REPRO_TEST_BUILD_DIR="$PWD/$lane"
nim c --hints:off --warnings:off \
  --nimcache:"$lane/nimcache/repro-evidence-sink" \
  --out:"$lane/bin/repro-evidence-sink" \
  apps/repro-evidence-sink/repro_evidence_sink.nim
bash scripts/write_helper_deps.sh repro-evidence-sink \
  apps/repro-evidence-sink/repro_evidence_sink.nim

# The engine, for the suites that spawn it (m7_test_pki.engineBin), with
# the flags apps/entrypoints.txt gives it. Only when one is selected: it is
# by far the largest build of the lane.
case " ${suites[*]} " in
  *"/t_worker_signing_certificates_are_time_bound.nim "*)
    nim c --hints:off --warnings:off --define:ssl --define:reproVendoredHash \
      --nimcache:"$lane/nimcache/reprobuild" \
      --out:"$lane/bin/reprobuild" \
      apps/repro/repro.nim ;;
esac

failed=()
for src in "${suites[@]}"; do
  name="$(basename "$src" .nim)"
  echo "nim224: ${name}"
  # shellcheck disable=SC2086  # NIM224_FLAGS is a list of flags
  if ! nim c --hints:off --warnings:off ${NIM224_FLAGS:-} \
      --nimcache:"$lane/nimcache/${name}" \
      --out:"$lane/test-bin/${name}" "$src"; then
    failed+=("${name} (build)")
    continue
  fi
  "$lane/test-bin/${name}" || failed+=("${name}")
done
if [ "${#failed[@]}" -gt 0 ]; then
  echo "run_nim224_lane: red under Nim ${expected}: ${failed[*]}" >&2
  exit 1
fi
echo "run_nim224_lane: every lane suite green under Nim ${expected}"

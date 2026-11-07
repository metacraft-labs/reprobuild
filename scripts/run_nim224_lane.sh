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
# The signer's suite is an in-process one: the engine's own signer test
# (t_worker_signing_certificates_are_time_bound) needs repro_cli_support,
# which does not build under Nim 2.2.4 (reprobuild-pm issue
# 2026-11-07-repro-cli-support-does-not-build-under-nim-2-2-4).
set -euo pipefail
cd "$(dirname "$0")/.."

expected="2.2.4"
nimdir="$(nix build --no-link --print-out-paths --inputs-from . nixpkgs#nim)/bin"
version="$("$nimdir/nim" --version | head -1)"
case "$version" in
  *"Version ${expected} "*) ;;
  *) echo "run_nim224_lane: nixpkgs#nim is '${version}', not ${expected}" >&2; exit 2 ;;
esac
export PATH="$nimdir:$PATH"

# The sink the evidence suites spawn, built by the same Nim, where
# repro_test_support/fresh_binary looks for it (REPRO_TEST_BUILD_DIR).
lane=build/nim224
mkdir -p "$lane/bin" "$lane/nimcache" "$lane/test-bin"
export REPRO_TEST_BUILD_DIR="$PWD/$lane"
nim c --hints:off --warnings:off \
  --nimcache:"$lane/nimcache/repro-evidence-sink" \
  --out:"$lane/bin/repro-evidence-sink" \
  apps/repro-evidence-sink/repro_evidence_sink.nim

suites=(
  libs/repro_addon/tests/t_addon_evidence_credential_is_append_only.nim
  libs/repro_addon/tests/t_addon_evidence_probe_owns_its_connection.nim
  libs/repro_addon/tests/t_addon_review_round3.nim
  libs/repro_addon/tests/t_addon_review_round4.nim
  libs/repro_peer_cache/tests/t_evidence_sink_append_only_and_liveness.nim
  libs/repro_peer_cache/tests/t_evidence_store_receipts_and_key_separation.nim
  libs/repro_distributed_worker/tests/t_signer_closes_after_its_early_returns.nim
)
if [ "$#" -gt 0 ]; then
  selected=()
  for t in "$@"; do
    for s in "${suites[@]}"; do
      [ "$(basename "$s" .nim)" = "$t" ] && selected+=("$s")
    done
  done
  suites=("${selected[@]}")
fi

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

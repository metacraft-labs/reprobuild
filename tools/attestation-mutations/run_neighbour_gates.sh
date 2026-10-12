#!/usr/bin/env bash
# Rebuild and RUN every gate that imports the attestation libraries this
# change edits, and report one line each.
#
# The define list mirrors the test-edge generator's
# `needsSoftwareRootTestTrustDefine`; a gate that needs it and is built
# without refuses at its own `static` assertion rather than failing at
# run time, which is what makes a mismatch here visible.
set -u
OUT="${OUT:-/tmp/neighbour-gates}"
mkdir -p "$OUT"
needs_define() {
  case "$1" in
    t_e2e_software_root_attestation_roundtrip) return 0 ;;
    t_e2e_local_attestation_emulator_all_protocol_paths) return 0 ;;
    t_e2e_authenticated_inference_local_and_cloud) return 0 ;;
    t_authenticated_inference_binding_mutations) return 0 ;;
    t_inference_commitment_is_hiding_and_binding) return 0 ;;
    *) return 1 ;;
  esac
}
pass=0; fail=0; nobuild=0
while read -r stem; do
  [ -z "$stem" ] && continue
  src="tests/integration/$stem.nim"
  log="$OUT/$stem.log"
  if needs_define "$stem"; then
    nim c -d:reproAttestSoftwareRootTestTrust -o:"$OUT/$stem" "$src" > "$log" 2>&1
  else
    nim c -o:"$OUT/$stem" "$src" > "$log" 2>&1
  fi
  if [ $? -ne 0 ]; then
    echo "DID-NOT-BUILD $stem"; nobuild=$((nobuild+1)); continue
  fi
  "$OUT/$stem" >> "$log" 2>&1
  rc=$?
  ok=$(grep -c '\[OK\]' "$log")
  bad=$(grep -c 'FAILED' "$log")
  if [ "$rc" -eq 0 ]; then
    echo "PASS  $stem ($ok cases)"; pass=$((pass+1))
  else
    echo "FAIL  $stem ($ok OK / $bad FAILED, exit $rc)"; fail=$((fail+1))
  fi
done
echo "NEIGHBOURS: $pass pass, $fail fail, $nobuild did-not-build"

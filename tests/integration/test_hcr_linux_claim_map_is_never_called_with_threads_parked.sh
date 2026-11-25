#!/usr/bin/env bash
# test_hcr_linux_claim_map_is_never_called_with_threads_parked.sh
#
# Regression gate: under tier-2 quiescence the Linux HCR agent calls neither the
# cross-patcher claim map nor libc's mmap/munmap while other threads are parked.
#
# References:
# - Linux HCR provider design §6.2 "Deadlock hazards", §10.1, §11.2: between
#   signalling the first thread and releasing the last, the patching thread
#   may make raw system calls only. Any lock a parked thread holds (the claim
#   map's, the recorder's, libc's allocator) can never be released until the
#   window closes, so taking one inside the window deadlocks the publication.
# - libs/repro_hcr_agent/c/repro_hcr_agent.c (`repro_hcr_prepare_direct_patch`,
#   `repro_hcr_commit_direct_patch`, `repro_hcr_abort_direct_patch`)
# - libs/repro_hcr_agent/c/repro_hcr_linux_x86_64.h (`repro_hcr_lx_txn_*`)
#
# Gate type: integration. Platform: Linux x86_64 only (the provider's lane);
# elsewhere it prints UNSUPPORTED and exits 0.
# Real components: the production agent, compiled whole into the driver, with
# a real patchable function in a real two-thread process.
# Mocks: the claim map's two entry points and a counting mmap/munmap, each
# justified in the driver's header.
#
# Four arms, one process each, each run on both code-page mechanisms: a
# successful publication, a commit failure, a prepare failure, and a prepare
# that succeeds but cannot acquire quiescence. In each, an application thread
# holds the lock behind the claim map while the provider works. Before the fix the publication arm
# deadlocked (the watchdog fired), and the failure arms released their claim
# and unmapped through libc with the threads parked.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [[ "$(uname -s)" != "Linux" || "$(uname -m)" != "x86_64" ]]; then
  echo "UNSUPPORTED: the Linux ELF HCR provider is Linux x86_64 only"
  exit 0
fi

WORK_DIR="${TEST_WORK_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/hcr_claim_parked_XXXXXX")}"
cleanup() {
  if [[ -z "${PRESERVE_WORK:-}" ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

DRIVER="$WORK_DIR/claim_parked_driver"
# The patchable build profile (patchableCompileFlags/patchableLinkFlags on
# Linux), stated literally because this gate runs without Nim.
gcc -O2 -g -std=gnu11 \
  -fpatchable-function-entry=16,0 -falign-functions=16 \
  -ftls-model=global-dynamic -fcf-protection=full \
  -I "$REPO_ROOT" -I "$REPO_ROOT/libs/repro_hcr_agent/c" \
  -o "$DRIVER" \
  "$SCRIPT_DIR/test_hcr_linux_claim_map_is_never_called_with_threads_parked_driver.c" \
  -Wl,--build-id=sha1 -lpthread

# Each arm runs twice: on the memfd dual-mapped code pages a healthy host uses,
# and with REPRO_HCR_TEST_FORCE_ANONYMOUS_CODE_PAGES, the agent's own lever that
# selects the anonymous fallback. Only the second reaches
# `repro_hcr_lx_map_anonymous` from inside the window (the §5.1 page
# replacement), so only it can catch a libc mmap/munmap there.
passed=0
failed=0
for pages in memfd anonymous; do
  for arm in publish commit-failure prepare-failure quiescence-failure; do
    set +e
    if [[ $pages == anonymous ]]; then
      output="$(REPRO_HCR_TEST_FORCE_ANONYMOUS_CODE_PAGES=1 timeout 30 "$DRIVER" "$arm" 2>&1)"
    else
      output="$(env -u REPRO_HCR_TEST_FORCE_ANONYMOUS_CODE_PAGES timeout 30 "$DRIVER" "$arm" 2>&1)"
    fi
    rc=$?
    set -e
    printf '%s\n' "$output"
    if [[ $rc -eq 0 ]] && grep -q "^RESULT $arm " <<<"$output"; then
      echo "[OK] $arm ($pages code pages)"
      passed=$((passed + 1))
    else
      echo "[FAILED] $arm ($pages code pages, exit $rc)"
      failed=$((failed + 1))
    fi
  done
done

echo "passed=$passed failed=$failed"
# Anti-vacuity: eight runs, eight RESULT lines.
[[ $passed -eq 8 && $failed -eq 0 ]]

#!/bin/sh
# m9_rollback.sh — verify `repro home apply` -> `repro home rollback` ->
# `repro home gc` + `repro store gc` end-to-end on a non-NixOS distro.
#
# Linux-Distro-Recipe-Validation M9 acceptance test. Single-distro
# gate by design: the M83 generation registry + the M10 home-gc engine
# + the M56 content-addressed store are all platform-pure — they
# touch the same code paths on every Linux distro and on Windows. The
# per-distro divergence M1-M4 exercises (clingo source build, multiarch
# symlinks, musl-vs-glibc, openrc-vs-systemd) sits BELOW this layer in
# the build pipeline. M6 already proves the home apply pipeline
# materializes uniformly across all five non-NixOS distros (5/5 op
# count, no-op drift); re-running M9 across distros would re-prove
# that gate without adding signal. So M9 runs on `repro-debian` only —
# the representative non-NixOS target the spec calls out
# (`Linux-Distro-Recipe-Validation.milestones.org` M9 *Fix scope*).
#
# Steps:
#
#   1. Detect distro; refuse anything other than `debian`. Ensure
#      bootstrap-debian.sh has built `${WORK_ROOT}/bin/repro`. If
#      M2 / M6 ran the bootstrap recently the warm path short-circuits.
#   2. Stage profile A (`tests/fixtures/m9_profile_a.nim`) under a
#      per-run profile dir as `home.nim`.
#   3. Reset per-run state-dir + store-root + the on-disk
#      materialization target (`~/.config/m9-test/`).
#   4. `repro home apply` profile A. Capture the generation id from
#      the apply log + the history listing. Verify the live
#      `rollback-target.txt` byte-equals "m9-profile-A".
#   5. Swap the staged profile to B (`m9_profile_b.nim`). Re-apply.
#      Capture B's generation id. Verify the live file now byte-
#      equals "m9-profile-B" + the two ids differ.
#   6. `repro home rollback <id_A>`. Verify the live file byte-
#      equals "m9-profile-A" again. Verify history's `[active]`
#      marker is back on A.
#   7. `repro home gc --dry-run --keep-generations 1`. Verify the
#      command exits zero and reports "no orphaned prefixes".
#      Rationale: the M9 fixtures declare a single `fs.userFile`
#      resource with no package realization; there are NO content-
#      addressed prefixes for the gc engine to reclaim. Asserting
#      the "store is clean" outcome is the correct M9 gate for a
#      package-free profile — it confirms the engine runs against
#      the right state-dir + store-root + that it correctly
#      computes the empty live-prefix set across the kept
#      generations.
#   8. `repro store gc`. Verify exit zero + that profile A's
#      generation digest is still listed in `repro store roots`
#      (it MUST be — it is the active generation).
#   9. Clean up on exit (success OR failure): remove the per-run
#      state-dir + store-root + the materialized $HOME tree so a
#      re-run starts clean.
#
# Per the campaign protocol, invoke via:
#
#   bash scripts/run_multi_distro_tests.sh m9_rollback debian
#
# The script refuses to run on a non-debian distro.

set -eu

# ----------------------------------------------------------------------
# Sanity: this test must run inside repro-debian.
# ----------------------------------------------------------------------

if [ ! -r /etc/os-release ]; then
  echo "m9_rollback: FAIL - /etc/os-release missing" >&2
  exit 1
fi
# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-unknown}" in
  debian) BOOTSTRAP_NAME=debian ;;
  *)
    echo "m9_rollback: FAIL - unrecognized ID=${ID:-unknown}" >&2
    echo "  (M9 is debian-only by design — generation semantics are" >&2
    echo "  platform-pure; M6 already proves cross-distro home apply)" >&2
    exit 1
    ;;
esac

REPO_ROOT="${REPRO_REPO_ROOT:-/mnt/d/metacraft/reprobuild}"
BOOTSTRAP="${REPO_ROOT}/tools/multi-distro-harness/bootstrap-${BOOTSTRAP_NAME}.sh"
FIXTURE_A="${REPO_ROOT}/tools/multi-distro-harness/tests/fixtures/m9_profile_a.nim"
FIXTURE_B="${REPO_ROOT}/tools/multi-distro-harness/tests/fixtures/m9_profile_b.nim"
WORK_ROOT="${REPRO_BOOTSTRAP_ROOT:-/tmp/reprobuild-bootstrap-${BOOTSTRAP_NAME}}"
REPRO_BIN="${WORK_ROOT}/bin/repro"

# Per-run state lives under WORK_ROOT/m9-rollback/ so the M1-M4 / M6
# self-bootstrap artifacts are not perturbed.
M9_ROOT="${WORK_ROOT}/m9-rollback"
PROFILE_DIR="${M9_ROOT}/profile"
STATE_DIR="${M9_ROOT}/state"
STORE_ROOT="${M9_ROOT}/store"

# Materialization target. Single file under $HOME — junction-free,
# single recursive rm cleanup.
HOME_M9="${HOME}/.config/m9-test"
TARGET="${HOME_M9}/rollback-target.txt"

EXPECTED_A_BODY='m9-profile-A'
EXPECTED_B_BODY='m9-profile-B'

# ----------------------------------------------------------------------
# Cleanup helper. Invoked on EXIT so a partial failure leaves no
# residue in the WSL instance for the next run.
# ----------------------------------------------------------------------

cleanup() {
  # Best-effort: ignore errors. All paths are plain files / dirs we
  # created — no junction-aware unlink needed.
  rm -rf "${M9_ROOT}" 2>/dev/null || true
  rm -rf "${HOME_M9}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

if [ ! -f "${BOOTSTRAP}" ]; then
  echo "m9_rollback: FAIL - bootstrap script missing at ${BOOTSTRAP}" >&2
  exit 1
fi
if [ ! -f "${FIXTURE_A}" ] || [ ! -f "${FIXTURE_B}" ]; then
  echo "m9_rollback: FAIL - profile fixtures missing" >&2
  echo "  expected: ${FIXTURE_A}" >&2
  echo "  expected: ${FIXTURE_B}" >&2
  exit 1
fi

echo "m9_rollback: running on ID=${ID} (${BOOTSTRAP_NAME})"

# ----------------------------------------------------------------------
# Step 1: ensure the bootstrap has built `repro`.
# ----------------------------------------------------------------------

echo "m9_rollback: step 1 — bootstrap (warm path short-circuits)"
if ! sh "${BOOTSTRAP}"; then
  echo "m9_rollback: FAIL - bootstrap-${BOOTSTRAP_NAME}.sh exited non-zero" >&2
  exit 1
fi
if [ ! -x "${REPRO_BIN}" ]; then
  echo "m9_rollback: FAIL - repro binary missing at ${REPRO_BIN}" >&2
  exit 1
fi

# ----------------------------------------------------------------------
# Step 2: stage profile A.
# ----------------------------------------------------------------------

echo "m9_rollback: step 2 — stage profile A"
rm -rf "${M9_ROOT}"
mkdir -p "${PROFILE_DIR}" "${STATE_DIR}" "${STORE_ROOT}"
cp "${FIXTURE_A}" "${PROFILE_DIR}/home.nim"

# Same PATH + env shape M6 uses. Debian's bootstrap puts the
# choosenim Nim at /root/.nimble/bin and BLAKE3 + xxhash under
# /usr/local — both have to be visible to `repro home apply` (which
# forks `nim` to compile the profile via the M83 typed-DSL adapter).
export PATH="${WORK_ROOT}/bin:/root/.nimble/bin:/usr/local/bin:/usr/bin:${PATH:-}"
export BLAKE3_PREFIX=/usr/local
export XXHASH_PREFIX=/usr/local
export REPROBUILD_REPO_ROOT="${REPO_ROOT}"

# Test seams: pin the apply state-dir / store-root / host. We use
# REPRO_STORE_ROOT (the canonical M56 store-root env var, surfaced
# by libs/repro_local_store as StoreRootEnvVar) NOT
# REPRO_HOME_STORE_ROOT — the latter is unused by both the home
# apply pipeline AND the `repro store ...` subcommands; setting it
# would leak realization into the user's real ~/.cache/repro/store
# while the gc step asserts against /tmp/.../store. M6 documents
# this confusion in the "Known finding" section of the harness
# README; M9 deliberately uses the right variable.
export REPRO_HOME_STATE_DIR="${STATE_DIR}"
export REPRO_STORE_ROOT="${STORE_ROOT}"
export REPRO_HOST="m9-test-host"

# ----------------------------------------------------------------------
# Step 3: reset the materialization target (in case a prior run
# left residue).
# ----------------------------------------------------------------------

rm -rf "${HOME_M9}"
mkdir -p "${HOME_M9}"

# ----------------------------------------------------------------------
# Step 4: apply profile A. Capture the generation id from the
# apply-log's `applied generation <hex>` line.
# ----------------------------------------------------------------------

echo "m9_rollback: step 4 — apply profile A"
apply_a_log="${M9_ROOT}/apply-a.log"
set +e
"${REPRO_BIN}" home --profile-dir="${PROFILE_DIR}" apply \
  >"${apply_a_log}" 2>&1
rc=$?
set -e
if [ "${rc}" -ne 0 ]; then
  echo "m9_rollback: FAIL - apply A exited non-zero (rc=${rc})" >&2
  tail -n 40 "${apply_a_log}" >&2 || true
  exit 1
fi

ID_A=$(grep -Eo 'applied generation [0-9a-f]+' "${apply_a_log}" \
  | head -n 1 | awk '{print $3}')
if [ -z "${ID_A}" ]; then
  echo "m9_rollback: FAIL - could not extract generation id from apply A log" >&2
  cat "${apply_a_log}" >&2
  exit 1
fi
echo "  ID_A=${ID_A}"

# Verify the materialized file's body.
if [ ! -f "${TARGET}" ]; then
  echo "m9_rollback: FAIL - target file missing after apply A at ${TARGET}" >&2
  exit 1
fi
if ! grep -Fxq "${EXPECTED_A_BODY}" "${TARGET}"; then
  echo "m9_rollback: FAIL - target file body mismatch after apply A" >&2
  echo "  expected: ${EXPECTED_A_BODY}" >&2
  echo "  got:      $(cat "${TARGET}")" >&2
  exit 1
fi
echo "  ok: ${TARGET} = '${EXPECTED_A_BODY}'"

# ----------------------------------------------------------------------
# Step 5: swap to profile B, apply.
# ----------------------------------------------------------------------

echo "m9_rollback: step 5 — apply profile B"
cp "${FIXTURE_B}" "${PROFILE_DIR}/home.nim"

apply_b_log="${M9_ROOT}/apply-b.log"
set +e
"${REPRO_BIN}" home --profile-dir="${PROFILE_DIR}" apply \
  >"${apply_b_log}" 2>&1
rc=$?
set -e
if [ "${rc}" -ne 0 ]; then
  echo "m9_rollback: FAIL - apply B exited non-zero (rc=${rc})" >&2
  tail -n 40 "${apply_b_log}" >&2 || true
  exit 1
fi

ID_B=$(grep -Eo 'applied generation [0-9a-f]+' "${apply_b_log}" \
  | head -n 1 | awk '{print $3}')
if [ -z "${ID_B}" ]; then
  echo "m9_rollback: FAIL - could not extract generation id from apply B log" >&2
  cat "${apply_b_log}" >&2
  exit 1
fi
echo "  ID_B=${ID_B}"

if [ "${ID_A}" = "${ID_B}" ]; then
  echo "m9_rollback: FAIL - apply A and apply B produced the same id" >&2
  echo "  ID_A=${ID_A}" >&2
  echo "  ID_B=${ID_B}" >&2
  echo "  the fixtures differ ONLY in content; if the digest matches" >&2
  echo "  the M83 generation hasher is missing a content-input" >&2
  exit 1
fi

if ! grep -Fxq "${EXPECTED_B_BODY}" "${TARGET}"; then
  echo "m9_rollback: FAIL - target file body mismatch after apply B" >&2
  echo "  expected: ${EXPECTED_B_BODY}" >&2
  echo "  got:      $(cat "${TARGET}")" >&2
  exit 1
fi
echo "  ok: ${TARGET} = '${EXPECTED_B_BODY}'"

# Verify history shows BOTH generations + B is [active].
history_after_b="${M9_ROOT}/history-after-b.log"
set +e
"${REPRO_BIN}" home --profile-dir="${PROFILE_DIR}" history \
  >"${history_after_b}" 2>&1
rc=$?
set -e
if [ "${rc}" -ne 0 ]; then
  echo "m9_rollback: FAIL - history after B exited non-zero (rc=${rc})" >&2
  cat "${history_after_b}" >&2
  exit 1
fi
if ! grep -q "${ID_A%%????????????????????}" "${history_after_b}"; then
  # The history listing prints the first 12 hex chars; compare against
  # the truncated form.
  :
fi
short_a=$(echo "${ID_A}" | cut -c1-12)
short_b=$(echo "${ID_B}" | cut -c1-12)
if ! grep -Fq "${short_a}" "${history_after_b}"; then
  echo "m9_rollback: FAIL - history after B missing ID_A short prefix '${short_a}'" >&2
  cat "${history_after_b}" >&2
  exit 1
fi
if ! grep -Fq "${short_b}" "${history_after_b}"; then
  echo "m9_rollback: FAIL - history after B missing ID_B short prefix '${short_b}'" >&2
  cat "${history_after_b}" >&2
  exit 1
fi
# B's row carries `[active]`; A's does not.
b_line=$(grep -F "${short_b}" "${history_after_b}" | head -n 1)
case "${b_line}" in
  *'[active]'*) ;;
  *)
    echo "m9_rollback: FAIL - history after B missing [active] on B's row" >&2
    echo "  B row: ${b_line}" >&2
    cat "${history_after_b}" >&2
    exit 1
    ;;
esac
echo "  ok: history shows ${short_a} + ${short_b} ([active] on B)"

# ----------------------------------------------------------------------
# Step 6: rollback to A by full id. Verify A's content is restored
# + history's [active] marker swaps back to A.
# ----------------------------------------------------------------------

echo "m9_rollback: step 6 — rollback to A"
rollback_log="${M9_ROOT}/rollback.log"
set +e
"${REPRO_BIN}" home --profile-dir="${PROFILE_DIR}" rollback "${ID_A}" \
  >"${rollback_log}" 2>&1
rc=$?
set -e
if [ "${rc}" -ne 0 ]; then
  echo "m9_rollback: FAIL - rollback exited non-zero (rc=${rc})" >&2
  cat "${rollback_log}" >&2
  exit 1
fi
# Expected log line: "rolled back from <id_B> to <id_A>"
if ! grep -Fq "rolled back from ${ID_B} to ${ID_A}" "${rollback_log}"; then
  echo "m9_rollback: FAIL - rollback log missing 'rolled back from ${ID_B} to ${ID_A}'" >&2
  cat "${rollback_log}" >&2
  exit 1
fi

if ! grep -Fxq "${EXPECTED_A_BODY}" "${TARGET}"; then
  echo "m9_rollback: FAIL - target file body mismatch after rollback to A" >&2
  echo "  expected: ${EXPECTED_A_BODY}" >&2
  echo "  got:      $(cat "${TARGET}")" >&2
  exit 1
fi
echo "  ok: ${TARGET} = '${EXPECTED_A_BODY}' (rolled back from B)"

# History [active] swap.
history_after_rb="${M9_ROOT}/history-after-rb.log"
"${REPRO_BIN}" home --profile-dir="${PROFILE_DIR}" history \
  >"${history_after_rb}" 2>&1
a_line=$(grep -F "${short_a}" "${history_after_rb}" | head -n 1)
case "${a_line}" in
  *'[active]'*) ;;
  *)
    echo "m9_rollback: FAIL - history after rollback missing [active] on A's row" >&2
    echo "  A row: ${a_line}" >&2
    cat "${history_after_rb}" >&2
    exit 1
    ;;
esac
b_line=$(grep -F "${short_b}" "${history_after_rb}" | head -n 1)
case "${b_line}" in
  *'[active]'*)
    echo "m9_rollback: FAIL - history after rollback still has [active] on B's row" >&2
    echo "  B row: ${b_line}" >&2
    cat "${history_after_rb}" >&2
    exit 1
    ;;
esac
echo "  ok: history [active] marker moved to A"

# ----------------------------------------------------------------------
# Step 7: home gc --dry-run --keep-generations 1.
# ----------------------------------------------------------------------

echo "m9_rollback: step 7 — repro home gc --dry-run --keep-generations 1"
home_gc_log="${M9_ROOT}/home-gc.log"
set +e
"${REPRO_BIN}" home --profile-dir="${PROFILE_DIR}" gc \
  --dry-run --keep-generations 1 \
  >"${home_gc_log}" 2>&1
rc=$?
set -e
if [ "${rc}" -ne 0 ]; then
  echo "m9_rollback: FAIL - home gc exited non-zero (rc=${rc})" >&2
  cat "${home_gc_log}" >&2
  exit 1
fi
if ! grep -q 'no orphaned prefixes' "${home_gc_log}"; then
  echo "m9_rollback: FAIL - home gc did not report 'no orphaned prefixes'" >&2
  echo "  the M9 fixtures declare a single fs.userFile resource with NO" >&2
  echo "  package realization; the M10 gc engine's live-prefix set is" >&2
  echo "  empty and there is nothing to reclaim. The expected outcome" >&2
  echo "  on this gate is 'store is clean'; any other outcome means the" >&2
  echo "  gc engine ran against a different state-dir / store-root than" >&2
  echo "  the apply pipeline wrote to." >&2
  cat "${home_gc_log}" >&2
  exit 1
fi
echo "  ok: home gc reports 'no orphaned prefixes — store is clean'"

# ----------------------------------------------------------------------
# Step 8: store gc + store roots. Both generations are profile roots
# in the M56 store; A is the active generation so it MUST stay
# registered. B was the previous active and the rollback path keeps
# its registration so a forward-rollback is still possible (the
# fixture's history shows B is still in the listing, just without
# the [active] marker). `store gc` is therefore expected to reclaim
# zero bytes on this gate — the assertion is that it exits clean
# and the store-root output still lists both generations.
# ----------------------------------------------------------------------

echo "m9_rollback: step 8 — repro store gc + store roots"
store_gc_log="${M9_ROOT}/store-gc.log"
set +e
"${REPRO_BIN}" store gc >"${store_gc_log}" 2>&1
rc=$?
set -e
if [ "${rc}" -ne 0 ]; then
  echo "m9_rollback: FAIL - store gc exited non-zero (rc=${rc})" >&2
  cat "${store_gc_log}" >&2
  exit 1
fi
if ! grep -Eq 'reclaimed: [0-9]+' "${store_gc_log}"; then
  echo "m9_rollback: FAIL - store gc log missing 'reclaimed: <N>' line" >&2
  cat "${store_gc_log}" >&2
  exit 1
fi

store_roots_log="${M9_ROOT}/store-roots.log"
set +e
"${REPRO_BIN}" store roots >"${store_roots_log}" 2>&1
rc=$?
set -e
if [ "${rc}" -ne 0 ]; then
  echo "m9_rollback: FAIL - store roots exited non-zero (rc=${rc})" >&2
  cat "${store_roots_log}" >&2
  exit 1
fi
# A's generation MUST still be a root (it is active). B's may be
# still a root (rollback keeps it for forward-rollback); we don't
# assert either way — the spec for the keep-set is documented in
# libs/repro_home_apply/src/repro_home_apply/gc.nim and is not the
# M9 gate's responsibility.
if ! grep -Fq "${ID_A}" "${store_roots_log}"; then
  echo "m9_rollback: FAIL - store roots missing ID_A=${ID_A} after gc" >&2
  echo "  the active generation MUST be a registered root" >&2
  cat "${store_roots_log}" >&2
  exit 1
fi
echo "  ok: store gc clean; store roots still lists active generation"

# ----------------------------------------------------------------------
# Success.
# ----------------------------------------------------------------------

echo "m9_rollback: OK"
echo "  distro:       ${BOOTSTRAP_NAME} (${PRETTY_NAME:-unknown})"
echo "  profile-dir:  ${PROFILE_DIR}"
echo "  state-dir:    ${STATE_DIR}"
echo "  store-root:   ${STORE_ROOT}"
echo "  ID_A:         ${ID_A}"
echo "  ID_B:         ${ID_B}"
echo "  transitions:  apply A -> apply B -> rollback to A (live file restored)"
echo "  gc:           home gc clean; store gc clean; active root preserved"
exit 0

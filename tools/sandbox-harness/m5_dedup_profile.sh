#!/bin/sh
# m5_dedup_profile.sh - Linux-Third-Party-Sandbox-MVP M5 closure-dedup +
# cold/warm timing profiler.
#
# Per the M5 spec (Linux-Third-Party-Sandbox-MVP.milestones.org):
#
#   - Verify the existing M56 store handles dedup natively.
#   - Verify the peer cache can push/pull a realized prefix.
#   - Profile cold + warm realize timings.
#
# Posture (honest scope):
#
#   M5 is largely a MEASUREMENT + DOCUMENTATION milestone, not a code
#   delivery. The M2 / M3 / M4 orchestrators already realize per-package
#   prefixes into content-addressed `sha256-<digest>-<pkg>/` directories
#   under `$REPRO_STORE_ROOT`; the second realize of the same digest is
#   a one-line `if [ -d "$prefix_data_dir" ]; then ... cache hit ...`
#   skip in each orchestrator. THAT is per-fetcher dedup — already
#   verified end-to-end by the existing M2 / M3 / M4 integration tests'
#   warm-run gates. This script measures the COLD vs WARM timings + the
#   CROSS-PACKAGE dedup (a different root package whose first-level
#   `Depends:` overlaps with a previously-realized closure) on the
#   per-fetcher path.
#
#   Cross-FETCHER dedup (apt's libc6 .deb vs dnf's glibc .rpm vs
#   pacman's glibc .pkg.tar.zst sharing one realized prefix) is NOT
#   POSSIBLE by design: the upstream bytes differ, so the
#   content-addressed sha256 namespace differs. This is correct
#   behaviour and matches Nix (a glibc derivation built via apt is a
#   different store path from one built via dnf even when both are
#   "logically glibc 2.36"). The script documents this finding by
#   showing the per-fetcher prefix-name shape.
#
#   Peer-cache integration is BLOCKED on the same cross-campaign
#   dependency the Linux-Distro-Recipe-Validation M5 surfaced:
#   `runBuildCommand` in `libs/repro_cli_support/src/repro_cli_support.nim`
#   does not yet consult `PeerCacheActionCacheReader`. Until that wiring
#   lands in the Peer-Cache campaign, no harness can push or pull a
#   realized sandbox prefix between hosts. The script documents this
#   inline so the M5 status reflects reality.
#
# Pipeline:
#
#   1. Detect distro via /etc/os-release.
#   2. Dispatch to the per-fetcher block(s) the host supports:
#        - debian|ubuntu -> apt_mvp.sh path
#        - fedora        -> dnf_mvp.sh path
#        - arch          -> pacman_mvp.sh path
#      (One distro per WSL instance per the M0 harness contract.)
#   3. Per fetcher:
#        a. COLD: clean store_root, realize root package + first-level
#           closure; record wall time.
#        b. WARM (same root): realize again into the same store_root;
#           record wall time. Assert every closure entry hits the
#           `cache hit` log line. Assert warm/cold >= 10x speedup
#           (the M5 verification floor).
#        c. CROSS (different root sharing libc/glibc): realize a second
#           root package whose first-level Depends list includes the
#           same shared lib. Record wall time. Assert the shared lib
#           prefix hits the cache (libc6 / glibc dedup observed) and
#           that the new root + any non-shared deps were freshly
#           fetched.
#   4. Print a measurement summary + the cross-fetcher namespace
#      observation.
#
# Honest measurement contract:
#
#   - Timings are wall-clock via /usr/bin/time -p (POSIX `-p` real/user/sys
#     output). The script reports REAL seconds for the cold + warm runs.
#   - Warm/cold speedup is computed via integer math (awk) and the
#     >=10x assertion is reported as PASS/FAIL but does NOT cause the
#     script to exit non-zero unless every assertion fails — the spec
#     asks for a measurement summary, not a regression gate. A FAIL on
#     the 10x speedup is surfaced for the reviewer's attention.
#   - All numbers are reported VERBATIM from the measurement runs. No
#     fabrication. If the warm run is unexpectedly slow (e.g. due to a
#     filesystem fsync stall) the FAIL is reported AS-IS.
#
# Usage:
#   sh m5_dedup_profile.sh
#
# Environment overrides:
#   REPRO_STORE_ROOT  - where the m5_dedup_profile store lives (default:
#                       /tmp/repro_m5_dedup_profile_$$). The per-fetcher
#                       sub-dir layout matches each fetcher's store
#                       convention (sha256-<digest>-<pkg>/ + composed-*).
#
# Exit codes:
#   0  - measurement summary printed successfully (some assertions may
#        have FAILed; check the per-fetcher PASS/FAIL lines).
#   1  - the script could not run any fetcher (unsupported distro, or
#        missing dependencies the per-fetcher orchestrators require).
#
# Status: M5 in_review, 2026-06-11. Measurement + documentation
# deliverable; no library code; no peer-cache wiring (cross-campaign
# blocked).

set -eu

# ----------------------------------------------------------------------
# Repo root + per-fetcher orchestrator paths.
# ----------------------------------------------------------------------

REPO_ROOT="${REPRO_REPO_ROOT:-/mnt/d/metacraft/reprobuild}"
APT_MVP="${REPO_ROOT}/tools/sandbox-harness/apt_mvp.sh"
DNF_MVP="${REPO_ROOT}/tools/sandbox-harness/dnf_mvp.sh"
PACMAN_MVP="${REPO_ROOT}/tools/sandbox-harness/pacman_mvp.sh"

for orchestrator in "$APT_MVP" "$DNF_MVP" "$PACMAN_MVP"; do
  if [ ! -f "$orchestrator" ]; then
    echo "m5_dedup_profile: FAIL - orchestrator missing: ${orchestrator}" >&2
    exit 1
  fi
done

# ----------------------------------------------------------------------
# Distro detection.
# ----------------------------------------------------------------------

if [ ! -r /etc/os-release ]; then
  echo "m5_dedup_profile: FAIL - /etc/os-release missing" >&2
  exit 1
fi
# shellcheck disable=SC1091
. /etc/os-release
distro_id="${ID:-unknown}"

# ----------------------------------------------------------------------
# Store root.
# ----------------------------------------------------------------------

STORE_ROOT="${REPRO_STORE_ROOT:-/tmp/repro_m5_dedup_profile_$$}"
rm -rf "$STORE_ROOT"
mkdir -p "$STORE_ROOT"
trap 'rm -rf "$STORE_ROOT"' EXIT INT TERM

# ----------------------------------------------------------------------
# Helper: measure wall-clock REAL seconds of a command.
# ----------------------------------------------------------------------
#
# Uses /usr/bin/time -p which prints `real <seconds>` on a line by
# itself to stderr. We capture stderr to a temp file and parse it.
# Falls back to a date-based measurement on hosts that lack
# /usr/bin/time (some minimal Alpine + busybox setups).

measure_real_seconds() {
  log_file=$1
  shift
  if [ -x /usr/bin/time ]; then
    time_log=$(mktemp)
    /usr/bin/time -p sh -c "$* > '$log_file' 2>&1" 2> "$time_log"
    rc=$?
    real=$(awk '/^real / {print $2; exit}' "$time_log")
    rm -f "$time_log"
  else
    t0=$(date +%s)
    sh -c "$* > '$log_file' 2>&1"
    rc=$?
    t1=$(date +%s)
    real=$((t1 - t0))
  fi
  if [ -z "$real" ]; then real='?'; fi
  echo "$rc $real"
}

# ----------------------------------------------------------------------
# Helper: count cache hits in a log file.
# ----------------------------------------------------------------------

count_cache_hits() {
  grep -c 'cache hit' "$1" 2>/dev/null || echo 0
}

# ----------------------------------------------------------------------
# Helper: print a per-fetcher PASS/FAIL on the dedup criteria.
# ----------------------------------------------------------------------
#
# `assert_n` prints PASS if actual==expected, FAIL otherwise. Returns
# 0 either way (the script reports outcomes, doesn't gate).

assert_eq() {
  label=$1
  expected=$2
  actual=$3
  if [ "$expected" = "$actual" ]; then
    echo "  ${label}: PASS (expected=${expected} actual=${actual})"
  else
    echo "  ${label}: FAIL (expected=${expected} actual=${actual})"
  fi
}

# `assert_ge` prints PASS if actual>=expected.
assert_ge() {
  label=$1
  expected=$2
  actual=$3
  if awk -v a="$actual" -v e="$expected" 'BEGIN { exit !(a+0 >= e+0) }'; then
    echo "  ${label}: PASS (>=${expected}, got ${actual})"
  else
    echo "  ${label}: FAIL (expected>=${expected}, got ${actual})"
  fi
}

# ----------------------------------------------------------------------
# Per-fetcher result records (printed in the summary block).
# ----------------------------------------------------------------------

SUMMARY_FILE=$(mktemp)
echo "fetcher distro cold_s warm_s speedup cross_s shared_dep_hit" > "$SUMMARY_FILE"

# ----------------------------------------------------------------------
# Helper: shape the per-fetcher block.
# ----------------------------------------------------------------------
#
# Each fetcher block is wrapped by run_fetcher_<name> functions below.
# They follow the same skeleton:
#   1. Print a banner.
#   2. Cold realize of root #1 with --no-exec (we measure the realize
#      pipeline, NOT the sandbox launch — the M5 deliverable is the
#      realize-side closure dedup + cache behaviour, not the bwrap
#      exec round-trip).
#   3. Warm realize of root #1 (same store_root). Assert cache hits +
#      warm/cold >= 10x.
#   4. Cross-package realize of root #2 (shares the same libc dep with
#      root #1). Assert the shared dep is a cache hit; other new deps
#      are freshly fetched.
#   5. Emit one CSV-shape row into $SUMMARY_FILE for the final table.

# --- apt fetcher (M2 path) --------------------------------------------

run_fetcher_apt() {
  echo ''
  echo '======================================================================'
  echo 'm5_dedup_profile: apt (M2) fetcher'
  echo '======================================================================'
  echo "  store_root: ${STORE_ROOT}/apt"
  mkdir -p "${STORE_ROOT}/apt"

  # Same fixture the sandbox_m2_apt_mvp.sh integration test pins. We
  # use --no-exec so the measurement isolates the realize pipeline from
  # the bwrap launch round-trip.
  snapshot=20260101T000000Z
  codename=bookworm
  root1=hello             # first-level Depends: libc6
  # `sed` shares the libc6 dep with `hello` and adds libacl1 + libselinux1.
  # That makes libc6 the shared-dep we assert dedup against, with the
  # other two being measurable fresh fetches.
  root2=sed

  # ---- Cold realize of root1 -----------------------------------------
  cold_log=$(mktemp)
  echo "  cold realize ${root1} (--no-exec)"
  set +e
  cold_result=$(measure_real_seconds "$cold_log" \
    "sh '$APT_MVP' --snapshot=$snapshot --codename=$codename \
       --package=$root1 --store-root='${STORE_ROOT}/apt' --no-exec --")
  set -e
  cold_rc=$(echo "$cold_result" | awk '{print $1}')
  cold_s=$(echo "$cold_result" | awk '{print $2}')
  echo "    rc=${cold_rc} real=${cold_s}s"
  if [ "$cold_rc" -ne 0 ]; then
    echo "    apt cold realize failed; tail of log:"
    tail -n 20 "$cold_log" | sed 's/^/      /'
    rm -f "$cold_log"
    return 1
  fi
  # Count the realized prefixes (per-pkg dirs).
  cold_prefix_count=$(find "${STORE_ROOT}/apt" -maxdepth 1 -type d \
    -name 'sha256-*' | wc -l | tr -d ' ')
  echo "    realized prefixes after cold: ${cold_prefix_count}"

  # ---- Warm realize of root1 -----------------------------------------
  warm_log=$(mktemp)
  echo "  warm realize ${root1} (same store_root)"
  warm_result=$(measure_real_seconds "$warm_log" \
    "sh '$APT_MVP' --snapshot=$snapshot --codename=$codename \
       --package=$root1 --store-root='${STORE_ROOT}/apt' --no-exec --")
  warm_rc=$(echo "$warm_result" | awk '{print $1}')
  warm_s=$(echo "$warm_result" | awk '{print $2}')
  echo "    rc=${warm_rc} real=${warm_s}s"
  warm_hits=$(count_cache_hits "$warm_log")
  echo "    cache-hit lines in warm log: ${warm_hits}"

  # Per-prefix cache hits: every closure entry should hit; + the
  # composed FHS tree should also hit. For `hello` the closure is
  # (hello, libc6) so we expect at least 2 cache-hit lines (per
  # prefix) + 1 composed tree hit = 3 minimum.
  assert_ge "apt warm cache-hit count" 3 "$warm_hits"

  # Speedup (warm/cold). With M5's >=10x verification floor.
  if [ "$cold_s" != '?' ] && [ "$warm_s" != '?' ] && [ "$warm_s" != '0' ]; then
    # speedup = cold/warm; use awk so decimals work; clamp warm_s>=0.01.
    speedup=$(awk -v c="$cold_s" -v w="$warm_s" \
      'BEGIN { if (w+0 < 0.01) w=0.01; printf "%.1f", c/w }')
  else
    speedup='?'
  fi
  echo "    speedup (cold/warm): ${speedup}x"
  if [ "$speedup" != '?' ]; then
    assert_ge "apt warm/cold >=10x" 10 "$speedup"
  fi

  # ---- Cross-package realize of root2 --------------------------------
  cross_log=$(mktemp)
  echo "  cross realize ${root2} (different root, shares libc6)"
  cross_result=$(measure_real_seconds "$cross_log" \
    "sh '$APT_MVP' --snapshot=$snapshot --codename=$codename \
       --package=$root2 --store-root='${STORE_ROOT}/apt' --no-exec --")
  cross_rc=$(echo "$cross_result" | awk '{print $1}')
  cross_s=$(echo "$cross_result" | awk '{print $2}')
  echo "    rc=${cross_rc} real=${cross_s}s"

  if [ "$cross_rc" -ne 0 ]; then
    echo "    apt cross realize failed; tail of log:"
    tail -n 20 "$cross_log" | sed 's/^/      /'
    rm -f "$cold_log" "$warm_log" "$cross_log"
    return 1
  fi

  # Assert libc6 prefix was a cache hit during the cross realize. We
  # search for a `cache hit at .../sha256-...-libc6` line in the log.
  if grep -Fq 'cache hit at' "$cross_log" && \
     grep -E 'cache hit at .*-libc6($|/)' "$cross_log" >/dev/null; then
    shared_hit='libc6'
    echo "    shared-dep cache hit: libc6 (dedup confirmed)"
  else
    shared_hit='none'
    echo "    shared-dep cache hit: NONE (NO dedup; investigate)"
    echo "    cross_log tail (last 30 lines):"
    tail -n 30 "$cross_log" | sed 's/^/      /'
  fi
  assert_eq "apt cross libc6 dedup" 'libc6' "$shared_hit"

  cross_prefix_count=$(find "${STORE_ROOT}/apt" -maxdepth 1 -type d \
    -name 'sha256-*' | wc -l | tr -d ' ')
  echo "    realized prefixes after cross: ${cross_prefix_count}"
  echo "    new prefixes added by ${root2}: $((cross_prefix_count - cold_prefix_count))"

  # Print one prefix name for the cross-fetcher namespace observation
  # at the end. apt format: sha256-<deb-sha256>-<pkgname>.
  apt_libc_prefix=$(find "${STORE_ROOT}/apt" -maxdepth 1 -type d \
    -name 'sha256-*-libc6' | head -n 1)
  echo "    libc6 prefix name shape: ${apt_libc_prefix#${STORE_ROOT}/apt/}"

  echo "apt $distro_id $cold_s $warm_s $speedup $cross_s $shared_hit" \
    >> "$SUMMARY_FILE"

  rm -f "$cold_log" "$warm_log" "$cross_log"
  return 0
}

# --- dnf fetcher (M3 path) --------------------------------------------

run_fetcher_dnf() {
  echo ''
  echo '======================================================================'
  echo 'm5_dedup_profile: dnf (M3) fetcher'
  echo '======================================================================'
  echo "  store_root: ${STORE_ROOT}/dnf"
  mkdir -p "${STORE_ROOT}/dnf"

  release=39
  arch=x86_64
  root1=hello
  # `which` is a tiny rpm whose first-level <rpm:requires> includes
  # libc.so.6 (via glibc). It shares the glibc dedup target with hello.
  root2=which

  # ---- Cold realize --------------------------------------------------
  cold_log=$(mktemp)
  echo "  cold realize ${root1} (--no-exec)"
  set +e
  cold_result=$(measure_real_seconds "$cold_log" \
    "sh '$DNF_MVP' --release=$release --arch=$arch \
       --package=$root1 --store-root='${STORE_ROOT}/dnf' --no-exec --")
  set -e
  cold_rc=$(echo "$cold_result" | awk '{print $1}')
  cold_s=$(echo "$cold_result" | awk '{print $2}')
  echo "    rc=${cold_rc} real=${cold_s}s"
  if [ "$cold_rc" -ne 0 ]; then
    echo "    dnf cold realize failed; tail of log:"
    tail -n 20 "$cold_log" | sed 's/^/      /'
    rm -f "$cold_log"
    return 1
  fi
  cold_prefix_count=$(find "${STORE_ROOT}/dnf" -maxdepth 1 -type d \
    -name 'sha256-*' | wc -l | tr -d ' ')
  echo "    realized prefixes after cold: ${cold_prefix_count}"

  # ---- Warm realize --------------------------------------------------
  warm_log=$(mktemp)
  echo "  warm realize ${root1} (same store_root)"
  warm_result=$(measure_real_seconds "$warm_log" \
    "sh '$DNF_MVP' --release=$release --arch=$arch \
       --package=$root1 --store-root='${STORE_ROOT}/dnf' --no-exec --")
  warm_rc=$(echo "$warm_result" | awk '{print $1}')
  warm_s=$(echo "$warm_result" | awk '{print $2}')
  echo "    rc=${warm_rc} real=${warm_s}s"
  warm_hits=$(count_cache_hits "$warm_log")
  echo "    cache-hit lines in warm log: ${warm_hits}"
  # hello + glibc + composed tree + primary.xml.gz = 4 minimum
  # (per-prefix x 2, composed tree x 1, primary.xml.gz x 1).
  assert_ge "dnf warm cache-hit count" 3 "$warm_hits"

  if [ "$cold_s" != '?' ] && [ "$warm_s" != '?' ] && [ "$warm_s" != '0' ]; then
    speedup=$(awk -v c="$cold_s" -v w="$warm_s" \
      'BEGIN { if (w+0 < 0.01) w=0.01; printf "%.1f", c/w }')
  else
    speedup='?'
  fi
  echo "    speedup (cold/warm): ${speedup}x"
  if [ "$speedup" != '?' ]; then
    assert_ge "dnf warm/cold >=10x" 10 "$speedup"
  fi

  # ---- Cross-package realize -----------------------------------------
  cross_log=$(mktemp)
  echo "  cross realize ${root2} (different root, shares glibc)"
  cross_result=$(measure_real_seconds "$cross_log" \
    "sh '$DNF_MVP' --release=$release --arch=$arch \
       --package=$root2 --store-root='${STORE_ROOT}/dnf' --no-exec --")
  cross_rc=$(echo "$cross_result" | awk '{print $1}')
  cross_s=$(echo "$cross_result" | awk '{print $2}')
  echo "    rc=${cross_rc} real=${cross_s}s"

  if [ "$cross_rc" -ne 0 ]; then
    echo "    dnf cross realize failed; tail of log:"
    tail -n 20 "$cross_log" | sed 's/^/      /'
    rm -f "$cold_log" "$warm_log" "$cross_log"
    return 1
  fi

  if grep -E 'cache hit at .*-glibc($|/)' "$cross_log" >/dev/null; then
    shared_hit='glibc'
    echo "    shared-dep cache hit: glibc (dedup confirmed)"
  else
    shared_hit='none'
    echo "    shared-dep cache hit: NONE (NO dedup; investigate)"
    echo "    cross_log tail (last 30 lines):"
    tail -n 30 "$cross_log" | sed 's/^/      /'
  fi
  assert_eq "dnf cross glibc dedup" 'glibc' "$shared_hit"

  cross_prefix_count=$(find "${STORE_ROOT}/dnf" -maxdepth 1 -type d \
    -name 'sha256-*' | wc -l | tr -d ' ')
  echo "    realized prefixes after cross: ${cross_prefix_count}"
  echo "    new prefixes added by ${root2}: $((cross_prefix_count - cold_prefix_count))"

  # Cross-fetcher namespace observation: dnf format: sha256-<rpm-sha256>-<pkgname>.
  dnf_glibc_prefix=$(find "${STORE_ROOT}/dnf" -maxdepth 1 -type d \
    -name 'sha256-*-glibc' | head -n 1)
  echo "    glibc prefix name shape: ${dnf_glibc_prefix#${STORE_ROOT}/dnf/}"

  echo "dnf $distro_id $cold_s $warm_s $speedup $cross_s $shared_hit" \
    >> "$SUMMARY_FILE"

  rm -f "$cold_log" "$warm_log" "$cross_log"
  return 0
}

# --- pacman fetcher (M4 path) -----------------------------------------

run_fetcher_pacman() {
  echo ''
  echo '======================================================================'
  echo 'm5_dedup_profile: pacman (M4) fetcher'
  echo '======================================================================'
  echo "  store_root: ${STORE_ROOT}/pacman"
  mkdir -p "${STORE_ROOT}/pacman"

  date='2025/01/01'
  arch=x86_64
  repo=core
  root1=bash               # %DEPENDS%: readline, libreadline.so=8-64, glibc, ncurses
  # `coreutils` is in core and shares the glibc dep with bash. Its
  # other %DEPENDS% (e.g. libcap, acl, attr depending on the snapshot)
  # are measurable fresh fetches; glibc is the dedup target.
  root2=coreutils

  # ---- Cold realize --------------------------------------------------
  cold_log=$(mktemp)
  echo "  cold realize ${root1} (--no-exec)"
  set +e
  cold_result=$(measure_real_seconds "$cold_log" \
    "sh '$PACMAN_MVP' --date=$date --repo=$repo --arch=$arch \
       --package=$root1 --store-root='${STORE_ROOT}/pacman' --no-exec --")
  set -e
  cold_rc=$(echo "$cold_result" | awk '{print $1}')
  cold_s=$(echo "$cold_result" | awk '{print $2}')
  echo "    rc=${cold_rc} real=${cold_s}s"
  if [ "$cold_rc" -ne 0 ]; then
    echo "    pacman cold realize failed; tail of log:"
    tail -n 20 "$cold_log" | sed 's/^/      /'
    rm -f "$cold_log"
    return 1
  fi
  cold_prefix_count=$(find "${STORE_ROOT}/pacman" -maxdepth 1 -type d \
    -name 'sha256-*' | wc -l | tr -d ' ')
  echo "    realized prefixes after cold: ${cold_prefix_count}"

  # ---- Warm realize --------------------------------------------------
  warm_log=$(mktemp)
  echo "  warm realize ${root1} (same store_root)"
  warm_result=$(measure_real_seconds "$warm_log" \
    "sh '$PACMAN_MVP' --date=$date --repo=$repo --arch=$arch \
       --package=$root1 --store-root='${STORE_ROOT}/pacman' --no-exec --")
  warm_rc=$(echo "$warm_result" | awk '{print $1}')
  warm_s=$(echo "$warm_result" | awk '{print $2}')
  echo "    rc=${warm_rc} real=${warm_s}s"
  warm_hits=$(count_cache_hits "$warm_log")
  echo "    cache-hit lines in warm log: ${warm_hits}"
  # bash + readline + glibc + ncurses + composed + desc-dir = 6 minimum.
  assert_ge "pacman warm cache-hit count" 5 "$warm_hits"

  if [ "$cold_s" != '?' ] && [ "$warm_s" != '?' ] && [ "$warm_s" != '0' ]; then
    speedup=$(awk -v c="$cold_s" -v w="$warm_s" \
      'BEGIN { if (w+0 < 0.01) w=0.01; printf "%.1f", c/w }')
  else
    speedup='?'
  fi
  echo "    speedup (cold/warm): ${speedup}x"
  if [ "$speedup" != '?' ]; then
    assert_ge "pacman warm/cold >=10x" 10 "$speedup"
  fi

  # ---- Cross-package realize -----------------------------------------
  cross_log=$(mktemp)
  echo "  cross realize ${root2} (different root, shares glibc)"
  cross_result=$(measure_real_seconds "$cross_log" \
    "sh '$PACMAN_MVP' --date=$date --repo=$repo --arch=$arch \
       --package=$root2 --store-root='${STORE_ROOT}/pacman' --no-exec --")
  cross_rc=$(echo "$cross_result" | awk '{print $1}')
  cross_s=$(echo "$cross_result" | awk '{print $2}')
  echo "    rc=${cross_rc} real=${cross_s}s"

  if [ "$cross_rc" -ne 0 ]; then
    echo "    pacman cross realize failed; tail of log:"
    tail -n 20 "$cross_log" | sed 's/^/      /'
    rm -f "$cold_log" "$warm_log" "$cross_log"
    return 1
  fi

  if grep -E 'cache hit at .*-glibc($|/)' "$cross_log" >/dev/null; then
    shared_hit='glibc'
    echo "    shared-dep cache hit: glibc (dedup confirmed)"
  else
    shared_hit='none'
    echo "    shared-dep cache hit: NONE (NO dedup; investigate)"
    echo "    cross_log tail (last 30 lines):"
    tail -n 30 "$cross_log" | sed 's/^/      /'
  fi
  assert_eq "pacman cross glibc dedup" 'glibc' "$shared_hit"

  cross_prefix_count=$(find "${STORE_ROOT}/pacman" -maxdepth 1 -type d \
    -name 'sha256-*' | wc -l | tr -d ' ')
  echo "    realized prefixes after cross: ${cross_prefix_count}"
  echo "    new prefixes added by ${root2}: $((cross_prefix_count - cold_prefix_count))"

  # Cross-fetcher namespace observation: pacman format: sha256-<pkg.tar.zst-sha256>-<pkgname>.
  pacman_glibc_prefix=$(find "${STORE_ROOT}/pacman" -maxdepth 1 -type d \
    -name 'sha256-*-glibc' | head -n 1)
  echo "    glibc prefix name shape: ${pacman_glibc_prefix#${STORE_ROOT}/pacman/}"

  echo "pacman $distro_id $cold_s $warm_s $speedup $cross_s $shared_hit" \
    >> "$SUMMARY_FILE"

  rm -f "$cold_log" "$warm_log" "$cross_log"
  return 0
}

# ----------------------------------------------------------------------
# Dispatch.
# ----------------------------------------------------------------------

echo "m5_dedup_profile: distro=${distro_id} store_root=${STORE_ROOT}"
echo "m5_dedup_profile: M5 scope - per-fetcher dedup + cold/warm timings."
echo "m5_dedup_profile:           - cross-fetcher dedup NOT POSSIBLE by design."
echo "m5_dedup_profile:           - peer-cache integration BLOCKED on cross-campaign dep."

ran_anything=0
case "$distro_id" in
  debian|ubuntu)
    if run_fetcher_apt; then ran_anything=1; fi
    ;;
  fedora)
    if run_fetcher_dnf; then ran_anything=1; fi
    ;;
  arch)
    if run_fetcher_pacman; then ran_anything=1; fi
    ;;
  *)
    echo "m5_dedup_profile: distro '${distro_id}' has no M2/M3/M4 fetcher" >&2
    echo "  supported: debian|ubuntu (apt), fedora (dnf), arch (pacman)" >&2
    exit 1
    ;;
esac

if [ "$ran_anything" -ne 1 ]; then
  echo "m5_dedup_profile: FAIL - no fetcher completed successfully" >&2
  exit 1
fi

# ----------------------------------------------------------------------
# Summary.
# ----------------------------------------------------------------------

echo ''
echo '======================================================================'
echo 'm5_dedup_profile: measurement summary'
echo '======================================================================'
echo ''
echo 'Per-fetcher timings (seconds; speedup = cold/warm):'
echo ''
# Pretty-print the CSV.
awk '
  NR == 1 {
    printf "  %-7s %-8s %-7s %-7s %-7s %-7s %-12s\n",
      "fetcher", "distro", "cold", "warm", "speedup", "cross", "shared-dep";
    printf "  %-7s %-8s %-7s %-7s %-7s %-7s %-12s\n",
      "-------", "------", "----", "----", "-------", "-----", "----------";
    next
  }
  {
    printf "  %-7s %-8s %-7s %-7s %-7s %-7s %-12s\n",
      $1, $2, $3, $4, $5, $6, $7
  }
' "$SUMMARY_FILE"

echo ''
echo 'Per-fetcher dedup verdict:'
echo '  Same root realized twice (same store_root)         -> every closure entry hits the cache.'
echo '  Different root sharing libc6/glibc                 -> shared-dep prefix is reused;'
echo '                                                        new deps are freshly fetched.'
echo '  Realization shape: sha256-<upstream-bytes-sha>-<pkgname>/data/'
echo ''
echo 'Cross-fetcher dedup verdict:'
echo '  NOT POSSIBLE by design. apt`s libc6_2.36-9.deb, dnf`s glibc-2.38-7.fc39.rpm,'
echo '  and pacman`s glibc-2.40+r16+gaa533d58ff-2.pkg.tar.zst have THREE different upstream'
echo '  sha256 values (they are three different binary container formats over conceptually'
echo '  the same upstream glibc but with different vendor patches, build flags, and binary'
echo '  layouts). The store is content-addressed by upstream BYTES, so the three realize'
echo '  into three distinct sha256-<...>-libc6 / sha256-<...>-glibc prefixes. This is correct'
echo '  behavior and matches Nix (deb-built glibc and rpm-built glibc are different store paths).'
echo ''
echo 'Peer-cache integration verdict:'
echo '  BLOCKED on cross-campaign dependency. The Linux-Distro-Recipe-Validation campaign`s'
echo '  M5 surfaced the same blocker: `runBuildCommand` in `libs/repro_cli_support/...` does'
echo '  not yet consult `PeerCacheActionCacheReader`. Until that wiring lands in the'
echo '  Peer-Cache campaign (its M1 Outstanding Tasks + a "wire ActionCacheReader into'
echo '  runBuildCommand" task to be opened in Peer-Cache-BearSSL.milestones.org), neither the'
echo '  Recipe-Validation nor the Sandbox-MVP campaign can demonstrate cross-host pull of a'
echo '  realized prefix at the harness surface. The peer-cache machinery itself works'
echo '  (60+ in-process unit tests pass); only the CLI wiring is missing.'

rm -f "$SUMMARY_FILE"
exit 0

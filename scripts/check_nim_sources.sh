#!/usr/bin/env bash
set -euo pipefail

mkdir -p build/nimcache

# Keep standalone ``nim check`` invocations on the same source-path resolver
# as the app build and test-suite entry points.  In particular,
# ``io_mon`` imports the extracted ``shm_queue`` package even when a
# sibling checkout is absent and the dev shell supplies it from the Nix store.
# shellcheck source=scripts/source_paths.sh
source scripts/source_paths.sh
export SHM_QUEUE_SRC="$(resolve_shm_queue_src)"
# ``repro_project_dsl`` imports the ``clispec`` package (nim-cli-spec).
export CLI_SPEC_SRC="$(resolve_cli_spec_src)"
# The ``entrypoints`` package (nim-entrypoints).
export ENTRYPOINTS_SRC="$(resolve_entrypoints_src)"
# repro's own command line goes through confutils (nim-confutils).
export CONFUTILS_SRC="$(resolve_confutils_src)"
export BEARSSL_SRC="$(resolve_bearssl_src)"

# Mirror the compile defines used by the real app build in
# scripts/build_apps.sh:
#   --define:reproProviderMode  — gates the repro_provider_runtime
#     re-export inside repro_project_dsl, plus several proc bodies in
#     runtime_provider.nim that the standard provider and trycompile
#     direct providers depend on. Without it, `nim check` on
#     libs/repro_standard_provider/* (and any other lib that walks
#     through buildPackageFragment) reports spurious "undeclared
#     identifier" errors because the visibility of the conditionally-
#     gated symbols differs from a real build.
nim_check_flags=(--define:reproProviderMode)

# Every ``nim check`` below is independent of the others (each has its own
# nimcache), so they run concurrently. Serially the sweep took about five
# minutes on a 32-core machine; concurrently, under one. Each check's output is
# held until all have finished and then printed in list order, so the log reads
# exactly as a serial run's would, and the exit status is non-zero if any check
# failed.
#
# WHO DECIDES HOW MANY RUN AT ONCE. This script runs inside every `git commit`
# (the `just-lint` pre-commit hook), so no caller's wrapper -- a host lock, a
# `-j4`, a memory-capped scope -- covers it. It used to start one check per
# processor, unleased: on a 32-core shared host that was ~20 GB of `nim check`
# per commit, and it took a build host to 5 GB available three times in one
# night (2026-11-25/26). So:
#
#   * Where a RunQuota daemon answers (the caller's RUNQUOTA_SOCKET, the host
#     service, or the user's shared per-user daemon `repro` itself uses; see
#     scripts/lib/runquota_lease_endpoint.sh), every check runs under its own
#     `runquota acquire` lease of one CPU slot and REPRO_LINT_CHECK_MEM of
#     memory. The coordinator admits them against the host's CPU and memory
#     budget together with every other leased build on it. Up to one check per
#     processor may be WAITING for a grant; how many RUN is RunQuota's answer.
#   * Where none answers there is no coordinator to ask, and the sweep runs
#     at most REPRO_LINT_UNLEASED_JOBS_DEFAULT checks at a time -- a fixed
#     bound, not the core count, because the host it runs on may be shared
#     with work nothing here can see.
#
# REPRO_LINT_JOBS, when set, overrides the number started at once in either
# case (leases are still taken when a daemon answers).
#
# EACH CHECK RESERVES WHAT IT WAS MEASURED TO USE. Measured 2026-11-26 on
# nixos-ci-bare-002 against reprobuild `agents` at c618f1c03 (peak resident
# set, VmHWM, of each `nim check` process): 64 of the 67 checks peaked at
# 2.36 GiB or less (the largest, repro_addon, 2478160 KiB), and the three
# that compile the whole engine peaked at 5.6-5.85 GiB -- apps/repro
# (6129608 KiB), apps/reprobuild-helper (6124108 KiB) and repro_cli_support
# (5886040 KiB). One reservation for all would either serialise a small host
# behind 7 GiB per check, or under-reserve the engine checks by about 3.5 GiB
# each, so the sweep reserves check_mem_default for a check and
# check_mem_engine for the sources in engine_check_sources. A source added
# later that grows past check_mem_default is under-reserved until it is
# listed here; RunQuota enforces memory only at admission, so a check that
# outgrows its reservation is not stopped. REPRO_LINT_CHECK_MEM, when set,
# is every check's reservation (a `runquota acquire --mem` SIZE).
REPRO_LINT_UNLEASED_JOBS_DEFAULT=4
check_mem_default=2560MiB
check_mem_engine=7GiB
engine_check_sources=(
  apps/repro/repro.nim
  apps/reprobuild-helper/reprobuild_helper.nim
  libs/repro_cli_support/src/repro_cli_support.nim
)

# check_mem_for SOURCE: the memory one check of SOURCE reserves.
check_mem_for() {
  local source=$1 engine
  if [[ -n "${REPRO_LINT_CHECK_MEM:-}" ]]; then
    printf '%s\n' "${REPRO_LINT_CHECK_MEM}"
    return
  fi
  for engine in "${engine_check_sources[@]}"; do
    if [[ "${source}" == "${engine}" ]]; then
      printf '%s\n' "${check_mem_engine}"
      return
    fi
  done
  printf '%s\n' "${check_mem_default}"
}

# shellcheck source=scripts/lib/runquota_lease_endpoint.sh
source scripts/lib/runquota_lease_endpoint.sh
leased=0
if runquota_lease_endpoint_find; then
  leased=1
  jobs_max="${REPRO_LINT_JOBS:-$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo "${REPRO_LINT_UNLEASED_JOBS_DEFAULT}")}"
  if [[ -n "${REPRO_LINT_CHECK_MEM:-}" ]]; then
    mem_note="${REPRO_LINT_CHECK_MEM} each"
  else
    mem_note="${check_mem_default}, or ${check_mem_engine} for the engine"
  fi
  echo "check_nim_sources: leasing each nim check (1 CPU, ${mem_note}) from ${RUNQUOTA_LEASE_REASON}" >&2
else
  jobs_max="${REPRO_LINT_JOBS:-${REPRO_LINT_UNLEASED_JOBS_DEFAULT}}"
  echo "check_nim_sources: unleased, at most ${jobs_max} nim checks at a time: ${RUNQUOTA_LEASE_REASON}" >&2
fi
out_dir="$(mktemp -d)"
trap 'rm -rf "${out_dir}"' EXIT
labels=()

# The command that runs one check: `nim check ARGS...`, under a lease when
# there is a daemon to lease from. `runquota acquire` starts the command only
# once the grant arrives, forwards signals, and exits with the command's
# status; when no lease can be granted it exits non-zero and says why on
# stderr, which lands in that check's log, so the sweep fails visibly rather
# than running the check unadmitted.
check_command() {
  local label=$1
  shift
  if (( leased )); then
    if [[ -n "${RUNQUOTA_LEASE_SCOPE}" ]]; then
      export RUNQUOTA_ENDPOINT_SCOPE="${RUNQUOTA_LEASE_SCOPE}"
    else
      unset RUNQUOTA_ENDPOINT_SCOPE
    fi
    RUNQUOTA_SOCKET="${RUNQUOTA_LEASE_SOCKET}" "${RUNQUOTA_LEASE_CLI}" acquire \
      --cpu 1000 --mem "$(check_mem_for "${label}")" \
      --label "just lint: nim check ${label}" \
      --project reprobuild --entry-point lint \
      -- nim check "$@"
  else
    nim check "$@"
  fi
}

run_check() {
  local index=$1
  shift
  while (( $(jobs -rp | wc -l) >= jobs_max )); do
    wait -n || true
  done
  (
    status=0
    check_command "${labels[$((index - 1))]}" "$@" >"${out_dir}/${index}.log" 2>&1 || status=$?
    echo "${status}" >"${out_dir}/${index}.status"
  ) &
}

while read -r lib _; do
  case "${lib}" in
    ""|\#*) continue ;;
  esac
  labels+=("libs/${lib}/src/${lib}.nim")
  run_check "${#labels[@]}" \
    "${nim_check_flags[@]}" \
    --nimcache:"build/nimcache/check-${lib}" \
    "libs/${lib}/src/${lib}.nim"
done < libs/libraries.txt

# ``apps/entrypoints.txt`` is ``name path [extra-nim-flags...]`` per
# its header: every token AFTER ``path`` is an extra ``nim`` flag the
# entrypoint needs (``--define:ssl``, ``--path:apps/<name>/src``,
# ``--define:reproProviderMode``, …).  ``nim check`` MUST receive
# them too — without ``--path:apps/repro-harvest-apt/src`` the
# repro_harvest_apt entry's local sub-module imports
# (``repro_harvest_apt/fetch`` / ``signature`` / ``source_spec``)
# fail to resolve and the lint reports spurious "cannot open file"
# errors while the actual ``nim c`` build in
# ``scripts/build_apps.sh`` succeeds.
#
# An entrypoint is checked with exactly the defines its build gets: its
# own extra flags, and not ``nim_check_flags``. ``scripts/build_apps.sh``
# gives ``--define:reproProviderMode`` only to the two provider apps, whose
# rows carry it; the other entrypoints compile in the mode this
# repository's ``config.nims`` selects. A program that imports the root
# ``repro.nim`` in the DSL's thin mode (``repro-cmake-dyndep-fragment``)
# refuses any other mode at compile time, so a check under the provider
# mode would report a failure no build has.
while read -r name path extra_flags; do
  case "${name}" in
    ""|\#*) continue ;;
  esac
  # Git may check this file out with CRLF on Windows. Bash does not include
  # carriage return in its default IFS, so strip it from the final field.
  path="${path%$'\r'}"
  extra_flags="${extra_flags%$'\r'}"
  # ``read -r name path extra_flags`` packs everything after ``path``
  # into ``extra_flags`` as a single whitespace-separated string;
  # word-split it here so each token becomes its own ``nim`` argv
  # entry.  Empty when the entry has no extra flags.
  read -r -a extra_flags_array <<<"${extra_flags:-}"
  labels+=("${path}")
  run_check "${#labels[@]}" \
    ${extra_flags_array[@]+"${extra_flags_array[@]}"} \
    --nimcache:"build/nimcache/check-${name}" \
    "${path}"
done < apps/entrypoints.txt
wait

failed=()
for index in "${!labels[@]}"; do
  n=$((index + 1))
  cat "${out_dir}/${n}.log"
  status="$(cat "${out_dir}/${n}.status" 2>/dev/null || echo missing)"
  [[ "${status}" == 0 ]] || failed+=("${labels[$index]} (exit ${status})")
done
if (( ${#failed[@]} )); then
  printf 'check_nim_sources: nim check failed for %d of %d source(s):\n' "${#failed[@]}" "${#labels[@]}" >&2
  printf '  %s\n' "${failed[@]}" >&2
  exit 1
fi
if (( leased )); then
  printf 'check_nim_sources: nim check passed for %d source(s), up to %s at a time as RunQuota admitted them.\n' "${#labels[@]}" "${jobs_max}"
else
  printf 'check_nim_sources: nim check passed for %d source(s), %s at a time.\n' "${#labels[@]}" "${jobs_max}"
fi

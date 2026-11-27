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

# `nim check` evaluates config.nims where git cannot run, so it cannot tell a
# workspace sibling that is behind its pin from one ahead of it, and would
# compile a stale one that `nim c` replaces with the pinned `$<PKG>_SRC`. The
# siblings are judged once here, where git runs, and every check below
# follows that verdict (scripts/lib/sibling_verdicts.sh).
# shellcheck source=scripts/lib/sibling_verdicts.sh
source scripts/lib/sibling_verdicts.sh
judge_config_siblings

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
# NEITHER SEES THE MEMORY THIS SWEEP MAY USE. A daemon admits against the
# host's budget and the unleased bound is a count, but a caller can run the
# sweep inside a memory cap -- the fleet's build hosts require
# `systemd-run --user --scope -p MemoryMax=16G` around every Nim step -- and
# a cgroup's `memory.max` is invisible to both. One check per processor was
# OOM-killed 42 s into a commit inside such a scope (measured 2026-11-26),
# and four unleased checks can still meet the three ~6 GiB engine checks
# there. So, in both cases, a check also starts only while its reservation
# (below) plus those of the checks already running fit in the memory
# available when the sweep began: what scripts/test_parallelism.sh measures,
# MemAvailable or the headroom under this process's tightest cgroup
# `memory.max`, whichever is smaller. With nothing running a check always
# starts, so one larger than the whole budget runs alone rather than never.
#
# REPRO_LINT_JOBS, when set, overrides the number started at once in either
# case (leases are still taken when a daemon answers), and the memory bound
# is then off: the caller has said how many.
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
lint_refuse() {
  printf 'check_nim_sources: %s\n' "$*" >&2
  exit 2
}
[[ -z "${REPRO_LINT_JOBS:-}" || "${REPRO_LINT_JOBS}" =~ ^[1-9][0-9]{0,8}$ ]] ||
  lint_refuse "REPRO_LINT_JOBS must be a positive integer (checks at a time); got '${REPRO_LINT_JOBS}'"

# size_mib SIZE: a `runquota acquire --mem` SIZE (bytes, or a K/M/G/T unit
# with or without `iB`) in MiB, rounded up; fails on anything else.
size_mib() {
  local size=$1 n unit
  [[ "${size}" =~ ^([0-9]{1,12})(B|K|KiB|M|MiB|G|GiB|T|TiB)?$ ]] || return 1
  n="${BASH_REMATCH[1]}"
  unit="${BASH_REMATCH[2]}"
  case "${unit}" in
    ""|B) printf '%s\n' "$(( (n + 1048575) / 1048576 ))" ;;
    K|KiB) printf '%s\n' "$(( (n + 1023) / 1024 ))" ;;
    M|MiB) printf '%s\n' "${n}" ;;
    G|GiB) printf '%s\n' "$(( n * 1024 ))" ;;
    T|TiB) printf '%s\n' "$(( n * 1024 * 1024 ))" ;;
  esac
}
if [[ -n "${REPRO_LINT_CHECK_MEM:-}" ]]; then
  size_mib "${REPRO_LINT_CHECK_MEM}" >/dev/null ||
    lint_refuse "REPRO_LINT_CHECK_MEM must be a size such as 2560MiB or 7GiB; got '${REPRO_LINT_CHECK_MEM}'"
fi

# The memory budget of the local bound, in MiB, or empty when it is off.
budget_mb=""
if [[ -z "${REPRO_LINT_JOBS:-}" ]]; then
  # shellcheck source=scripts/test_parallelism.sh
  source scripts/test_parallelism.sh
  budget_mb="$(reprobuild_available_memory_mb)"
  if [[ "${budget_mb}" =~ ^[0-9]+$ ]]; then
    echo "check_nim_sources: and only as many as fit in ${budget_mb} MiB available (MemAvailable, or the cgroup memory.max headroom if smaller), at each check's reservation" >&2
  else
    budget_mb=""
    echo "check_nim_sources: available memory is not measurable; no memory bound beyond the above" >&2
  fi
fi

# The kernel's count of OOM kills in this process's cgroup subtree, so a
# failure report can say whether memory is why a check died. Empty where there
# is no cgroup v2 ``memory.events``.
oom_kill_count() {
  local rel root
  rel="$(sed -n 's/^0::\(.*\)$/\1/p' /proc/self/cgroup 2>/dev/null | head -n 1)"
  root="$(awk '$3 == "cgroup2" { print $2; exit }' /proc/self/mounts 2>/dev/null || true)"
  [[ -n "${rel}" && -n "${root}" ]] || return 0
  awk '$1 == "oom_kill" { print $2; exit }' "${root}${rel%/}/memory.events" 2>/dev/null || true
}
oom_kills_before="$(oom_kill_count)"

out_dir="$(mktemp -d)"
trap 'rm -rf "${out_dir}"' EXIT
labels=()

# Names a status the way the failure report prints it: an exit above 128 is a
# signal (``bash`` reports a child killed by signal N as 128+N).
describe_status() {
  local status=$1
  if [[ "${status}" =~ ^[0-9]+$ ]] && (( status > 128 )); then
    local sig
    sig="$(kill -l "$((status - 128))" 2>/dev/null || echo "$((status - 128))")"
    printf 'killed by SIG%s, exit %s' "${sig#SIG}" "${status}"
  else
    printf 'exit %s' "${status}"
  fi
}

# Says, on stderr, whether the kernel OOM-killed anything in this cgroup since
# the sweep started, and which knobs bound the fan-out.
report_oom_kills() {
  local after
  after="$(oom_kill_count)"
  if [[ "${oom_kills_before}" =~ ^[0-9]+$ && "${after}" =~ ^[0-9]+$ ]] &&
      (( after > oom_kills_before )); then
    printf 'check_nim_sources: the kernel OOM killer killed %s process(es) in this cgroup during the sweep (up to %s check(s) at a time, memory budget %s MiB). Set REPRO_LINT_JOBS lower, or REPRO_LINT_CHECK_MEM higher if a check outgrew its reservation.\n' \
      "$((after - oom_kills_before))" "${jobs_max}" "${budget_mb:-none}" >&2
  fi
}

# MiB reserved by each check started and not yet seen to finish, keyed by its
# index; on_signal reads it to tell running checks from waiting ones.
declare -A reserved=()

# A sweep that is itself stopped -- systemd stops a whole scope with
# OOMPolicy=stop when any process in it is OOM-killed, and a commit hook used
# to end on a bare ``Terminated`` -- names the checks it was still running.
on_signal() {
  local sig=$1 n running=()
  trap - TERM INT HUP
  # A check is running when it was started (it holds a reservation) and has
  # not written its status; a check still waiting to start has neither.
  for n in $(printf '%s\n' "${!reserved[@]}" | sort -n); do
    [[ -e "${out_dir}/${n}.status" ]] || running+=("${labels[$((n - 1))]}")
  done
  printf 'check_nim_sources: terminated by SIG%s with %d check(s) running:\n' "${sig}" "${#running[@]}" >&2
  if (( ${#running[@]} )); then
    printf '  %s (running)\n' "${running[@]}" >&2
  fi
  report_oom_kills
  # Each per-check subshell passes the signal on to the one process it
  # started (see run_check), so signalling the subshells, which are this
  # shell's own jobs, reaches every running check and nothing else.
  local pids
  pids="$(jobs -p)"
  if [[ -n "${pids}" ]]; then
    # shellcheck disable=SC2086 # one pid per word
    kill -TERM ${pids} 2>/dev/null || true
  fi
  rm -rf "${out_dir}"
  case "${sig}" in INT) exit 130 ;; HUP) exit 129 ;; *) exit 143 ;; esac
}
trap 'on_signal TERM' TERM
trap 'on_signal INT' INT
trap 'on_signal HUP' HUP

# The command that runs one check: `nim check ARGS...`, under a lease when
# there is a daemon to lease from. `runquota acquire` starts the command only
# once the grant arrives, forwards signals, and exits with the command's
# status; when no lease can be granted it exits non-zero and says why on
# stderr, which lands in that check's log, so the sweep fails visibly rather
# than running the check unadmitted.
#
# It ``exec``s, so it MUST run in a subshell of its own (run_check starts it
# with ``&``): the process it leaves behind is then the check itself, or the
# `runquota acquire` that forwards signals to it, and a TERM sent to that PID
# stops the check instead of orphaning it.
check_command() {
  local label=$1
  shift
  if (( leased )); then
    if [[ -n "${RUNQUOTA_LEASE_SCOPE}" ]]; then
      export RUNQUOTA_ENDPOINT_SCOPE="${RUNQUOTA_LEASE_SCOPE}"
    else
      unset RUNQUOTA_ENDPOINT_SCOPE
    fi
    RUNQUOTA_SOCKET="${RUNQUOTA_LEASE_SOCKET}" exec "${RUNQUOTA_LEASE_CLI}" acquire \
      --cpu 1000 --mem "$(check_mem_for "${label}")" \
      --label "just lint: nim check ${label}" \
      --project reprobuild --entry-point lint \
      -- nim check "$@"
  else
    exec nim check "$@"
  fi
}

# Starts check $1 (an index into ``labels``) once it fits: fewer than
# ``jobs_max`` started and unfinished and, under a memory budget, its
# reservation plus those of the others within the budget (or none at all).
run_check() {
  local index=$1
  shift
  local label="${labels[$((index - 1))]}"
  local need=0
  [[ -z "${budget_mb}" ]] || need="$(size_mib "$(check_mem_for "${label}")")"
  while :; do
    local i used=0 n_running=0
    for i in "${!reserved[@]}"; do
      if [[ -e "${out_dir}/${i}.status" ]]; then
        unset 'reserved[$i]'
      else
        used=$((used + reserved[$i]))
        n_running=$((n_running + 1))
      fi
    done
    if (( n_running == 0 )); then
      break
    fi
    if (( n_running < jobs_max )) &&
        { [[ -z "${budget_mb}" ]] || (( used + need <= budget_mb )); }; then
      break
    fi
    # 127: no child is left to wait for, so a check counted as running died
    # without writing its status (its subshell was killed). Nothing will free
    # its reservation, and waiting again would spin; the final report shows
    # its status as missing.
    local waited=0
    wait -n || waited=$?
    if (( waited == 127 )); then
      reserved=()
    fi
  done
  reserved[${index}]="${need}"
  (
    # The check runs as this subshell's child, by PID, so a TERM sent to the
    # subshell by on_signal is passed on to it (`runquota acquire` forwards
    # it to nim). ``wait`` returns early when a trapped signal arrives, so it
    # is repeated until the check has exited.
    child=""
    trap '[[ -z "${child}" ]] || kill -TERM "${child}" 2>/dev/null || true' TERM
    check_command "${label}" "$@" >"${out_dir}/${index}.log" 2>&1 &
    child=$!
    status=0
    wait "${child}" || status=$?
    while kill -0 "${child}" 2>/dev/null; do
      status=0
      wait "${child}" || status=$?
    done
    echo "${status}" >"${out_dir}/${index}.status" 2>/dev/null || true
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
  [[ "${status}" == 0 ]] || failed+=("${labels[$index]} ($(describe_status "${status}"))")
done
if (( ${#failed[@]} )); then
  printf 'check_nim_sources: nim check failed for %d of %d source(s):\n' "${#failed[@]}" "${#labels[@]}" >&2
  printf '  %s\n' "${failed[@]}" >&2
  report_oom_kills
  exit 1
fi
if (( leased )); then
  printf 'check_nim_sources: nim check passed for %d source(s), up to %s at a time as RunQuota admitted them.\n' "${#labels[@]}" "${jobs_max}"
else
  printf 'check_nim_sources: nim check passed for %d source(s), %s at a time.\n' "${#labels[@]}" "${jobs_max}"
fi

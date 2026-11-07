#!/usr/bin/env bash
# cold_plan_loop.sh — run N cold `repro infra plan`s on a target host and
# report every one that did not exit 0.
#
# Usage:
#   scripts/cross/cold_plan_loop.sh [--ssh <program>] [--repro <path>] \
#       [--count N] [--profile <system.nim>] [--host <name>] <ssh-destination-or-empty>
#
# Each iteration compiles the profile from nothing: a fresh state directory,
# so the profile compile (the monitored edge that runs the target's own `nim`
# under io-mon's shim) runs every time and no action-cache hit stands in for
# it. The output is one line per run with its exit code and seconds, a tail
# of the output of every run that failed, and a last line
# `cold_plan_loop: N runs, F failed`; the exit status is 1 when F > 0.
#
# WHY. An intermittent crash in that compile -- the SIGBUS in io-mon's ILP32
# set creation on armhf hit about one run in five -- is invisible to a single
# verification run and to any run after the first, which the action cache
# answers. The fix for such a crash is measured by this loop reporting zero
# failures over a count that would have shown it (twenty, for a 1-in-5), and
# that is what convergence on a new host uses it for.
#
# The default profile is the smallest system profile there is (one managed
# file under /etc); planning it writes nothing to the system. `--profile`
# takes a real one instead. Everything on the target happens under a
# temporary directory the loop removes.
set -euo pipefail

ssh_program=""
repro_bin=repro
count=20
profile=""
host="$(hostname 2>/dev/null || echo cold-plan-loop)"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --ssh) ssh_program="$2"; shift 2 ;;
    --ssh=*) ssh_program="${1#--ssh=}"; shift ;;
    --repro) repro_bin="$2"; shift 2 ;;
    --repro=*) repro_bin="${1#--repro=}"; shift ;;
    --count) count="$2"; shift 2 ;;
    --count=*) count="${1#--count=}"; shift ;;
    --profile) profile="$2"; shift 2 ;;
    --profile=*) profile="${1#--profile=}"; shift ;;
    --host) host="$2"; shift 2 ;;
    --host=*) host="${1#--host=}"; shift ;;
    -h|--help) sed -n '2,8p' "$0" >&2; exit 64 ;;
    --) shift; break ;;
    -*) echo "cold_plan_loop: unknown option: $1" >&2; exit 64 ;;
    *) break ;;
  esac
done
[ "$#" -le 1 ] || { echo "cold_plan_loop: one ssh destination at most" >&2; exit 64; }
destination="${1:-}"
case "${count}" in ''|*[!0-9]*|0) echo "cold_plan_loop: --count needs a positive number" >&2; exit 64 ;; esac

remote_cmd=(ssh)
[ -n "${ssh_program}" ] && remote_cmd=("${ssh_program}")
[ -n "${destination}" ] && remote_cmd+=("${destination}")

if [ -n "${profile}" ]; then
  profile_text="$(cat "${profile}")"
else
  profile_text='import repro_profile

profile "cold-plan-loop":
  resources:
    fsSystemFile(path = "/etc/repro-cold-plan-loop/marker",
      content = "planned, never applied\n",
      mode = "0644",
      address = "coldPlanLoopMarker")
'
fi

# The loop runs on the target in one ssh session; the profile travels on
# stdin so no name on the target has to be agreed on. `--host` is given so the
# plan does not depend on the target's hostname being resolvable.
"${remote_cmd[@]}" "set -u
  work=\$(mktemp -d /tmp/repro-cold-plan-loop.XXXXXX)
  trap 'rm -rf \"\$work\"' EXIT
  cat > \"\$work/system.nim\"
  failed=0
  for i in \$(seq 1 ${count}); do
    rm -rf \"\$work/state\"
    start=\$(date +%s)
    '${repro_bin}' infra plan --profile \"\$work/system.nim\" --state-dir \"\$work/state\" --host '${host}' > \"\$work/run-\$i.log\" 2>&1
    rc=\$?
    echo \"run \$i: exit \$rc, \$(( \$(date +%s) - start ))s\"
    if [ \"\$rc\" != 0 ]; then
      failed=\$((failed + 1))
      echo \"--- run \$i output (tail):\"; tail -n 25 \"\$work/run-\$i.log\" | sed 's/^/    /'
      dmesg 2>/dev/null | tail -n 5 | grep -iE 'segfault|bus error|sigbus|killed process' | sed 's/^/    dmesg: /' || true
    fi
  done
  echo \"cold_plan_loop: ${count} runs, \$failed failed\"
  [ \"\$failed\" = 0 ]" <<< "${profile_text}"

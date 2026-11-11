# shellcheck shell=bash
# Run a command in a process group of its own, and end the whole group when
# the command ends or this script is stopped.
#
# A VM gate starts helpers on the host -- the binary cache, HTTP origins,
# an evidence sink, QEMU through gosti -- and stops them in its own
# teardown. When the gate's process is killed instead (an operator ending a
# hung cell, a harness timeout), that teardown never runs: the helpers were
# orphaned, kept running, and kept every file descriptor they inherited --
# among them the flock a harness holds for the VM slot, which then stayed
# taken for hours (A13, 2026-11-07). The group makes the gate's whole tree
# one unit: whatever ends the command, the rest of its group is ended with
# it. Every inherited descriptor above stderr is closed for the command, so
# a helper it starts cannot hold a lock its caller took.
#
#   run_in_own_group <command> [args...]
#
# Returns the command's exit status (143 when this script was stopped by
# SIGTERM, 130 by SIGINT, 129 by SIGHUP). A SIGKILL of this script itself
# is the one case it cannot handle; the caller's own group then holds the
# tree.

process_group_end() {
  # SIGTERM to every process of the group, then SIGKILL to any left after
  # a grace period. Ignores an empty or already gone group.
  local pgid="$1" i
  kill -TERM -- "-${pgid}" 2>/dev/null || return 0
  for i in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 -- "-${pgid}" 2>/dev/null || return 0
    sleep 0.5
  done
  kill -KILL -- "-${pgid}" 2>/dev/null || true
}

run_in_own_group() {
  local fd
  # The command must not inherit a descriptor above stderr (a caller's
  # lock, a pipe): close them in the subshell that becomes the group.
  (
    for fd in /proc/${BASHPID}/fd/*; do
      fd="${fd##*/}"
      [[ "${fd}" =~ ^[0-9]+$ ]] || continue
      (( fd > 2 )) || continue
      eval "exec ${fd}>&-" 2>/dev/null || true
    done
    exec setsid "$@"
  ) &
  local pid=$!
  local rc=0
  trap 'process_group_end "${pid}"; trap - TERM INT HUP; exit 143' TERM
  trap 'process_group_end "${pid}"; trap - TERM INT HUP; exit 130' INT
  trap 'process_group_end "${pid}"; trap - TERM INT HUP; exit 129' HUP
  wait "${pid}" || rc=$?
  # The command is gone (it ended, or something killed it); end what it
  # left behind in its group.
  process_group_end "${pid}"
  trap - TERM INT HUP
  return "${rc}"
}

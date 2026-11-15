# shellcheck shell=bash
# shellcheck disable=SC2034  # the MODE and REASON variables are outputs read by the sourcing script
# Which RunQuota daemon does the test suite's `repro` use?
#
#   . scripts/lib/runquota_test_endpoint.sh
#   repro_test_runquota_decide          # sets the two variables below
#
# A resource coordinator is only useful with a view of the whole host, so the
# suite uses the host's daemon whenever there is one, and a daemon of its own
# only where sharing would be wrong:
#
#   host     The suite's `repro` runs find the daemon the way any `repro` does:
#            the provisioned host service when there is one (it is never
#            spawned and never asked to make way), else the invoking user's
#            shared per-user daemon. The runner sets nothing.
#   private  The runner gives the run a per-user endpoint directory of its own,
#            so a `repro` built from the tree under test does not adopt, and
#            ask to retire, the developer's per-user daemon (a build from
#            another image asks the daemon it finds to retire once its
#            clients are gone).
#
# REPRO_TEST_RUNQUOTA selects: `auto` (the default), `host` or `private`.
# In `auto`, the answer is `host` when
#   * the caller set RUNQUOTA_SOCKET (an explicit endpoint, managed by whoever
#     set it and never asked to retire), or
#   * the caller set RUNQUOTA_USER_ENDPOINT_DIR (the caller already chose which
#     per-user endpoint the run uses), or
#   * a provisioned host service answers on its rendezvous socket;
# and `private` otherwise, which is the case on an unprovisioned host.
#
# Tests OF RunQuota itself (the daemon, its handover, the per-user endpoint, the
# private-endpoint policy) are unaffected either way: their fixtures start
# their own daemon on an endpoint they name, with RUNQUOTA_SOCKET given
# explicitly, and treat it as the host's. Use `REPRO_TEST_RUNQUOTA=private` to
# force the isolated endpoint for a suite that depends on it.
#
# Inputs (all optional): REPRO_TEST_RUNQUOTA, RUNQUOTA_SOCKET,
# RUNQUOTA_USER_ENDPOINT_DIR, RUNQUOTA_BIN (the `runquota` CLI, else PATH),
# REPRO_TEST_HOST_RUNQUOTA_SOCKETS (space-separated rendezvous sockets to try,
# default the host service's: /run/runquota/runquotad.sock on Linux,
# /var/run/runquota/runquotad.sock on macOS).
#
# Outputs: REPRO_TEST_RUNQUOTA_MODE (`host` or `private`) and
# REPRO_TEST_RUNQUOTA_REASON (one line naming why, for the run's log).
# Returns 2 on an unknown REPRO_TEST_RUNQUOTA value.

# True when a daemon answers a `status` on socket $1. A socket file alone is not
# an answer: a stale one outlives its daemon.
repro_test_runquota_answers() {
  local sock="$1" cli
  [[ -S "${sock}" ]] || return 1
  cli="${RUNQUOTA_BIN:-$(command -v runquota 2>/dev/null || true)}"
  [[ -n "${cli}" && -x "${cli}" ]] || return 1
  RUNQUOTA_SOCKET="${sock}" "${cli}" status >/dev/null 2>&1
}

repro_test_runquota_decide() {
  local selection="${REPRO_TEST_RUNQUOTA:-auto}" sock
  REPRO_TEST_RUNQUOTA_MODE=private
  case "${selection}" in
    private)
      REPRO_TEST_RUNQUOTA_REASON="REPRO_TEST_RUNQUOTA=private"
      return 0
      ;;
    host)
      REPRO_TEST_RUNQUOTA_MODE=host
      REPRO_TEST_RUNQUOTA_REASON="REPRO_TEST_RUNQUOTA=host"
      return 0
      ;;
    auto) ;;
    *)
      echo "REPRO_TEST_RUNQUOTA must be auto, host or private, not '${selection}'" >&2
      return 2
      ;;
  esac
  if [[ -n "${RUNQUOTA_SOCKET:-}" ]]; then
    REPRO_TEST_RUNQUOTA_MODE=host
    REPRO_TEST_RUNQUOTA_REASON="the caller's RUNQUOTA_SOCKET (${RUNQUOTA_SOCKET})"
    return 0
  fi
  if [[ -n "${RUNQUOTA_USER_ENDPOINT_DIR:-}" ]]; then
    REPRO_TEST_RUNQUOTA_MODE=host
    REPRO_TEST_RUNQUOTA_REASON="the caller's RUNQUOTA_USER_ENDPOINT_DIR (${RUNQUOTA_USER_ENDPOINT_DIR})"
    return 0
  fi
  for sock in ${REPRO_TEST_HOST_RUNQUOTA_SOCKETS:-/run/runquota/runquotad.sock /var/run/runquota/runquotad.sock}; do
    if repro_test_runquota_answers "${sock}"; then
      REPRO_TEST_RUNQUOTA_MODE=host
      REPRO_TEST_RUNQUOTA_REASON="the host service answers on ${sock}"
      return 0
    fi
  done
  REPRO_TEST_RUNQUOTA_REASON="no host service answers; a build from this tree would otherwise ask the user's shared daemon to make way"
  return 0
}

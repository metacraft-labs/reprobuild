## Actual daemon IPC bodies and nested records, without sockets or mocks.
include binary_decoder_count_support
include "../../libs/repro_daemon_core/src/repro_daemon_core/protocol.nim"
import std/unittest

suite "daemon bounded count decoding":
  test "sessions body":
    var value: seq[UserDaemonSession]
    populateCountFixture(value)
    checkCountMutations(sessionsBody(value), proc(data: seq[byte]) =
      discard parseSessionsBody(data), expectedCounts = 3)
  test "substitute response body":
    var value: DaemonSubstituteIpcResponse
    populateCountFixture(value)
    checkCountMutations(substituteResponseBody(value), proc(data: seq[byte]) =
      discard parseSubstituteResponseBody(data), expectedCounts = 3)
  # The lease-reap-provider count is already refused against
  # `MaxLeaseReapProviders` before allocation, with the `ValueError` that
  # libs/repro_daemon_core/tests/t_l4_daemon_leases.nim case (n) pins.

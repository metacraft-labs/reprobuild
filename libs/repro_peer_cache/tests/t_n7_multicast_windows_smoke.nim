## Dotfiles-Migration-Completion N7: Windows-only smoke test for the
## `repro_peer_cache/multicast.nim` Windows port. Validates that the
## winlean-backed multicast socket implementation can complete a
## sender→receiver loopback round-trip on the local host.
##
## On non-Windows platforms this test is a no-op (the POSIX branch is
## already covered by the cross-platform multicast tests in
## `t_peer_cache_multicast_loopback_discovery.nim`).
##
## Strategy: open a receiver bound to the admin-scope group
## 239.255.42.99 on port 54321, open a sender on the same group, push
## a 5-byte payload, and wait up to 2 s for the receiver's `recvFrom`
## to complete. Self-receipt is expected because Windows' default for
## `IP_MULTICAST_LOOP` is on (we also set it explicitly on the
## sender for symmetry with the POSIX branch).

import std/[asyncdispatch, asyncnet, os, unittest]

import repro_peer_cache/multicast
import repro_peer_cache/types

when defined(windows):
  const
    SmokeMulticastAddress = "239.255.42.99"
    SmokeMulticastPort = Port(54321)
    SmokePayload = "n7smk"  # 5 bytes
    PollIntervalMs = 50
    MaxWaitMs = 2_000

  suite "N7 Windows multicast smoke":
    test "sender → receiver loopback on 239.255.42.99":
      let group = loopbackMulticastGroup(SmokeMulticastAddress,
                                         SmokeMulticastPort)
      let receiver = newMulticastReceiverSocket(group)
      let sender = newMulticastSenderSocket(group)
      try:
        # Start the receive future BEFORE sending so the IOCP wait is
        # armed; sendMulticastPacket is synchronous and returns
        # immediately on the non-blocking socket.
        let recvFut = receiver.recvFrom(64)
        sendMulticastPacket(sender, group, SmokePayload)

        # Deterministic-budget poll: 50 ms ticks, 2 s ceiling.
        var waited = 0
        while waited < MaxWaitMs and not recvFut.finished:
          try: poll(0) except ValueError: discard
          sleep(PollIntervalMs)
          waited += PollIntervalMs

        check recvFut.finished
        if recvFut.finished:
          let (data, address, port) = recvFut.read()
          check data == SmokePayload
          # `port` is the sender's SOURCE port, not the multicast
          # destination port. Senders aren't bound (the OS assigns an
          # ephemeral port), so we only assert non-zero rather than
          # equality with `SmokeMulticastPort`.
          check uint16(port) != 0
          # Source address on loopback multicast is the bound
          # interface; we only assert non-empty here because the
          # exact representation can vary by host config (127.0.0.1
          # is typical but not guaranteed across all Winsock builds).
          check address.len > 0
      finally:
        receiver.close()
        sender.close()
else:
  # Non-Windows: silent no-op so the umbrella test runner doesn't
  # report a "no tests in suite" failure.
  discard

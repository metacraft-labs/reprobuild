# repro_hcr_agent

In-target HCR runtime pieces for the direct-patch profile.

The library now includes:

- framed coordinator-to-agent protocol messages and digest-checked patch
  payloads
- session validation for hello/helloAck negotiation, patch requests, lifecycle
  events, and patch-applied responses
- coordinator helpers for packaging direct patch bundles and recording the
  protocol transcript
- JSON views for coordinator reports and protocol transcript artifacts
- agent endpoint helpers that drive the direct patch runtime from protocol
  messages
- POSIX Unix-domain socket IPC helpers using the same protocol framing
- launch-env startup helper for an in-target endpoint using
  `REPRO_HCR_AGENT_SOCKET`
- the M27 same-process target environment over mmap/mprotect,
  instruction-cache flushing, and direct AArch64 trampoline installation

The executable-memory path is still a non-hardened macOS arm64 test profile; it
does not validate the hardened-runtime MAP_JIT entitlement path.

This is still not the complete production `librepro_hcr_agent`: target launch
linkage/injection, launch-time IPC environment binding, thread coordination, CodeTracer MCR
launch integration, and source-generation replay/debugger integration remain
out of scope.

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
- the HLX-M0 Linux x86_64 ELF direct-patch arm of the C agent
  (`c/repro_hcr_linux_x86_64.h`), support profile
  `linux-x86_64-elf-direct-hcr-v1`

The executable-memory path is still a non-hardened macOS arm64 test profile; it
does not validate the hardened-runtime MAP_JIT entitlement path.

## Linux x86_64 arm (HLX-M0)

Design: `reprobuild-specs/HCR/Linux-ELF-Provider.md`. Scope, stated so nothing
reads as more than it is:

- **Single-threaded only.** HLX-M0 proves a Linux patch path exists. It does not
  exercise the cross-core or in-window-PC hazards of design §4.4 and §6.1, and
  nothing here may be reported as safe for a multithreaded target until HLX-M4
  resolves `HLX-OQ-2` and `HLX-OQ-3`.
- **Publication is one naturally aligned 8-byte store** holding a 5-byte
  `E9 rel32`, followed by
  `membarrier(MEMBARRIER_CMD_PRIVATE_EXPEDITED_SYNC_CORE)`. The window offset is
  computed from the observed entry bytes; the sled address comes from the
  runtime-mapped `__patchable_function_entries` section.
- **`mprotect` is a raw syscall**, never libc, so an MCR-recorded process does
  not re-enter the recording path.
- **The host is probed at agent start.** If the `PROT_READ|PROT_WRITE` →
  `PROT_READ|PROT_EXEC` round trip cannot complete, the agent drops
  `direct-patch-injection` from the capabilities it advertises in its hello and
  refuses any patch request with `unsupported-host` *before* touching a byte of
  target text. The coordinator does not yet fail the handshake on the missing
  capability; that half is HLX-M9's, along with the gate that runs under
  `PR_SET_MDWE`.
- **Symbol resolution is registered symbols only.** There is deliberately no
  `dlsym` fallback: `dlsym` cannot see `static` or hidden functions and a
  partial resolver would hide that. HLX-M1 lands the real ELF pipeline.
- **No rollback, no islands, no unwind/debugger registration** — HLX-M3,
  HLX-M2 and HLX-M5 respectively. A patch request carrying a debug-object or
  unwind-metadata payload fails loudly rather than registering nothing.
- **Clang under `-fcf-protection` is refused**, with the named diagnostic
  `sled-window-not-instruction-boundary`: it emits the patchable sled as one
  maximal-length NOP, whose only interior instruction boundary is not 8-byte
  aligned. Clang without `-fcf-protection`, and GCC either way, are usable.

This is still not the complete production `librepro_hcr_agent`: target launch
linkage/injection, launch-time IPC environment binding, thread coordination, CodeTracer MCR
launch integration, and source-generation replay/debugger integration remain
out of scope.

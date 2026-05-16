# repro_hcr_agent

Minimal in-target runtime pieces used by the M27 direct-HCR gate. The current
module exposes a tiny same-process target environment over mmap/mprotect,
instruction-cache flushing, and direct AArch64 trampoline installation.

The M27 executable-memory path is a non-hardened macOS arm64 test profile; it
does not validate the hardened-runtime MAP_JIT entitlement path.

It is not yet the production `librepro_hcr_agent`: IPC, debugger/unwind
registration, thread coordination, CodeTracer replay integration, and
shared-library fallback support remain out of scope.

# HCR Debug Unwind

M28 macOS arm64 E2E gate for the narrow direct-patch debugger, unwind, and
IPC-byte replay profile.

The gate compiles a tiny target process, verifies that the executable exports
`__jit_debug_register_code` and `__jit_debug_descriptor`, sends one binary
patch/debug/unwind packet over a stdin pipe, applies the M27 direct patch
transaction path, registers retained debug-object bytes through the in-process
JIT descriptor, calls the real dynamic unwind registration API, and validates a
`backtrace()` captured inside generated patched code crosses the patch page.

It then launches a fresh target with the exact same packet bytes. This is an
IPC-recording assumption gate for CodeTracer behavior, not CTFS or native
replayer integration.

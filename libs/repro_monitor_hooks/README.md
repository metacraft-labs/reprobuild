# repro_monitor_hooks

Reusable hook backend adapter layer for monitor shims.

This package owns the common mechanics that should not live in a
Reprobuild-specific shim:

- monitor fragment collection/finalization helpers;
- macOS `DYLD_INSERT_LIBRARIES` interpose support and original-call resolution;
- Linux `LD_PRELOAD` symbol exports and `dlsym(RTLD_NEXT)` original-call
  resolution;
- priority-ordered stackable hook dispatch with `callNext` and `callReal`;
- child-process preload propagation helpers.

Linux hook bodies import `repro_monitor_hooks/linux_preload_runtime`, register
typed callbacks such as `registerOpenHook`, and wrap the rest of the chain with
`callNext`. This keeps individual shims interoperable and avoids duplicating
the interposition trampoline in every consumer.

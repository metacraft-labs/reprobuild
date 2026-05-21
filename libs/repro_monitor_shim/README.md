# repro_monitor_shim

Reprobuild-specific monitor shim.

The injected shim writes binary monitor evidence fragments that are merged into
canonical `.rdep` files by `repro_monitor_depfile`.

Platform-specific interposition mechanics live in reusable hook layers:

- macOS consumes the extracted sibling `ct_interpose` package;
- Linux consumes `repro_monitor_hooks/linux_preload_runtime`, registering
  Reprobuild hook bodies into the stackable `LD_PRELOAD` dispatcher.

The shim package should contain Reprobuild event taxonomy, state tracking, and
record emission only. New OS hook mechanics belong in the reusable hook layer
first, then this package registers monitor-specific callbacks on top.

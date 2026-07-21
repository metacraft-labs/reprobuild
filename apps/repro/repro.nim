## The single `repro` CLI (Executable-Consolidation-And-Size-Optimization.md).
##
## `repro` is one binary that dispatches by subcommand via `runThinApp` and
## self-spawns its internal role-processes (`repro internal …`). There is no
## separate `repro-full` image and no thin POSIX launcher: the shell-hook
## `dev-env export` fast path (Shell-Direnv-Hook.md) runs directly in this
## binary through the same cache-key no-op check, trading the former sub-5 ms
## launcher for one binary at a ~10 ms cold start (accepted; the sub-ms path is
## the M78 daemon).

import repro_cli_support

when isMainModule:
  quit runThinApp("repro")

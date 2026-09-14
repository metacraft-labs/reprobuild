## The single `repro` CLI (Executable-Consolidation-And-Size-Optimization.md).
##
## `repro` is one binary that dispatches by subcommand via `runThinApp` and
## self-spawns its internal role-processes (`repro internal …`). There is no
## separate `repro-full` image and no thin POSIX launcher: the shell-hook
## `dev-env export` fast path (Shell-Direnv-Hook.md) runs directly in this
## binary through the same cache-key no-op check, trading the former sub-5 ms
## launcher for one binary at a ~10 ms cold start (accepted; the sub-ms path is
## the M78 daemon).
##
## THE ~10 ms COLD START WAS RE-MEASURED and is no longer accepted for
## daemon-hosted builds. `repro --version` — image load, module init, teardown
## and nothing else — costs 8.0 ms on macOS arm64 against 1.8 ms for
## `/usr/bin/true`, because this image is 16 MB with ~12,000 dynamic-linker
## fixups. That cost is paid on EVERY invocation and the daemon cannot reach
## it: the daemon amortises build work done repeatedly, not process start.
## `apps/repro-client` (Dependency-Attribution MAC-1) is a ~780 KB binary that
## links only `repro_daemon_core`, hands a `repro build` to the daemon and
## streams the result back, and `execv`s THIS image for everything else. It
## serves a NARROWER surface than "every build" — progress explicitly quiet
## and stderr not a terminal — because this image's progress-line clear is not
## gated on the renderer being enabled and writes ANSI to a TTY even under
## `--progress=quiet`. Interactive builds therefore still pay this image's
## full start cost.
##
## It is not the launcher this comment says was removed, and the reason for
## that removal does not carry over. That launcher decided per invocation
## which of several images to run, so it had to know the CLI surface and grew
## a second place to change for every verb. `repro-client` knows one verb,
## parses no build flag it does not hand over on, and forwards the caller's
## argv to a daemon worker that re-parses it with THIS binary's own
## `runBuildCommand`. Read the header of `apps/repro-client/repro_client.nim`
## before changing either side.

import repro_cli_support

when isMainModule:
  quit runThinApp("repro")

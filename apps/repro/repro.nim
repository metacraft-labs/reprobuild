## The reprobuild ENGINE: the full CLI
## (Executable-Consolidation-And-Size-Optimization.md).
##
## INSTALLED AS `reprobuild`, NOT `repro`. The name `repro` belongs to the
## thin daemon client (`apps/repro-client/repro_client.nim`), which is what a
## user types and what every packaging route puts on `PATH`; it `execv`s this
## image for everything it cannot route to the daemon. See
## `libs/repro_core/src/repro_core/cli_images.nim` for the naming rationale
## and `apps/repro-client`'s header for the layering, including how it composes
## with the M5 self-host trampoline.
##
## THIS BINARY STILL DECLARES ITSELF `repro`, and that is not a leftover. The
## literal in `runThinApp("repro")` below is what
## `runningImageIsReproCli` reads to permit self-spawning the internal verbs
## (`internal io monitor`, `__repro-extract-interface`,
## `__repro-compile-provider`), and it is what `renderUsage` prints — so the
## usage text and every diagnostic still say `repro`, which is the command a
## user typed. The rename is a FILENAME change and nothing else. Verified: this
## image builds a `reprobuild.nim` project, provider-compile edge included,
## under the filenames `repro`, `reprobuild` and `zzz-not-a-repro` alike;
## with the declaration arm of that predicate removed the last of those fails
## with "no `repro` image to spawn it with".
##
## It is one binary that dispatches by subcommand via `runThinApp` and
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
## `apps/repro-client` (Dependency-Attribution MAC-1) is a ~520 KB binary that
## links only `repro_daemon_core`, hands a `repro build` to the daemon and
## streams the result back, and `execv`s THIS image for everything else. It
## serves a NARROWER surface than "every build" — progress explicitly quiet
## and stderr not a terminal — because this image's progress-line clear is not
## gated on the renderer being enabled and writes ANSI to a TTY even under
## `--progress=quiet`. Interactive builds therefore still pay this image's
## full start cost, PLUS the thin client's own ~1-3 ms handover; that is the
## trade the rename makes, and it is stated in full in the thin client's
## header.
##
## It is not the launcher this comment says was removed, and the reason for
## that removal does not carry over. That launcher decided per invocation
## which of several images to run, so it had to know the CLI surface and grew
## a second place to change for every verb. The thin client knows one verb,
## parses no build flag it does not hand over on, and forwards the caller's
## argv to a daemon worker that re-parses it with THIS binary's own
## `runBuildCommand`. Read the header of `apps/repro-client/repro_client.nim`
## before changing either side.

import repro_cli_support

when isMainModule:
  quit runThinApp("repro")

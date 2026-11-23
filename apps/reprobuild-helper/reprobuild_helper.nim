## The GRAPH HELPER image, installed as `reprobuild-helper` beside the
## engine (`reprobuild`) and the thin client (`repro`).
##
## The build graph runs some of its own work as helper commands of the
## engine: the provider compile and interface extraction of a recipe, the
## profile compile and its platform probe, the development environment's
## introspection and shell rendering, and CMake regeneration
## (`repro internal <role>`, also spelt `__repro-<role>`). Each runs INSIDE a
## monitored action, so everything its process does is evidence for that
## action, including what happens before `main`.
##
## The engine is built with `--define:ssl` so its cache and deploy paths can
## speak https. On Windows that maps the OpenSSL DLLs at start-up, and their
## stack-protector start-up seeds a canary through `rand_s` ->
## `RtlGenRandom` -> `ProcessPrng`: an entropy read in every engine process,
## whatever it was started to do. An action whose process tree reads entropy
## is not cached on its first run, so every edge that ran an engine helper
## re-ran on the next build.
##
## This image runs those helpers from the same sources and through the same
## dispatch (`runGraphHelperApp` in `repro_cli_support`), and is built
## WITHOUT `--define:ssl`, so nothing in it loads OpenSSL: the draw is
## removed rather than waived, and the engine keeps TLS. It answers only the
## helper commands (`GraphHelperRoles`) and refuses everything else.
## `libs/repro_core/src/repro_core/cli_images.nim` holds its name and
## `graphHelperImagePath`, which is how the engine finds it: always beside
## its own image, never a fallback to running the helpers in the engine.

import repro_cli_support

when isMainModule:
  quit runGraphHelperApp()

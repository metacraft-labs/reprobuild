## Spec example: a ``buildType`` configuration axis drives the output
## directory (Standard-Configurations.md).
##
## Demonstrates the pattern codetracer relies on: a single solver-
## participating ``buildType`` variant whose resolved value selects the
## build output directory. This fixture uses reprobuild's RECOMMENDED
## default — a single ``build/`` root with a per-configuration subdir
## (``build/<buildType>``, the same structure as cargo's
## ``target/{debug,release}``; a single ``/build/`` line covers it in
## ``.gitignore``). Setting ``--variant buildType=release`` (or the
## ``--release`` shorthand) moves every output from ``build/debug/`` to
## ``build/release/`` in one consistent pass, so the two configurations
## never share a directory and are cache-keyed on the resolved variant
## value. (A project may override this default — e.g. codetracer uses
## ``src/build-<buildType>-repro`` so its reprobuild outputs sit beside,
## and never collide with, tup's ``src/build-debug`` variant dir.)
##
## Status: Standard-Configurations spec exhibit. Mirrors the long-form
## shape of ``variant-feature-flag/repro.nim``.

import repro_project_dsl

package buildtype_output:
  config:
    sourceRepository = "https://example.invalid/buildtype-output.git"
    sourceRevision = "refs/heads/main"
    sourceChecksum = "sha256-workspace"

    ## Standard build configuration axis. Its value names the output
    ## directory; a real recipe would also derive optimization / debug-info
    ## defaults from it. Overridable per build via ``--variant
    ## buildType=release`` or the ``--release`` shorthand.
    buildType: variant string = "debug"

  uses:
    "nim >=2.2 <3.0"

  build:
    # The output directory is derived from the resolved variant value, so a
    # debug build lands under ``build/debug/`` and a release build under
    # ``build/release/`` — distinct, non-colliding output trees under one
    # ``build/`` root.
    let outRoot = "build/" & buildType.value
    discard nim.c(
      source = "src/app.nim",
      binary = outRoot & "/bin/app")

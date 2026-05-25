## Shared DSL runtime library entry point.
##
## When built with ``--app:lib`` this module produces
## ``librepro_project_dsl_runtime.{dll,so,dylib}`` — the shared DSL+runtime
## library that the Tier 1 design (see
## ``reprobuild-specs/Provider-Compile-Tiering.md``) ships next to
## ``repro.exe``. Per-project provider compiles link against this DLL
## instead of statically embedding ~5000 lines of stable DSL+runtime
## code into every output.
##
## The module imports the umbrella DSL with the ``reproProviderMode``
## define active (so the provider-mode-only runtime procs are included)
## and re-exports the entire surface. The DLL build does not yet apply
## ``{.exportc, dynlib.}`` annotations per proc — that is the next
## milestone; the structural prerequisite (DLL artifact, build edge,
## library directory, opt-in flag) is delivered first so it can be
## verified before the proc-level pragma surface lands.
##
## NOTE: This module is the build root for the DLL only. It is NOT
## imported by any other Reprobuild library; everyone else imports the
## umbrella ``repro_project_dsl`` directly.

import repro_project_dsl
export repro_project_dsl

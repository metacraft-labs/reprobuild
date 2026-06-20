## Hello World — Mode 3 C recipe.
##
## Minimal end-to-end fixture for the Linux-Distro-Recipe-Validation M1
## milestone: a single C executable that prints
## "hello from reprobuild M1". Built through reprobuild's c_cpp_direct
## convention (libs/repro_standard_provider/.../conventions/c_cpp_direct.nim)
## via `repro-standard-provider`, no Makefile / CMakeLists.txt /
## ecosystem manifest required.
##
## Why Mode 3 (explicit repro.nim) rather than Mode 1 (no project file)?
##
##   The Mode 1 layout-as-manifest path (loadMode1Workspace +
##   materializeMode1ProjectFile) synthesises a project file that lacks
##   a `build:` block and DOES NOT yet emit a C source shim — Mode 1's
##   per-language shim helpers only handle Nim and Rust as of 2026-06.
##   For C/C++ the standard provider therefore lands on the synthesised
##   `.repro/mode1-synth/` dir, which has no `src/main.c`, and reports
##   "no convention matched". Mode 3 sidesteps this by giving the
##   c_cpp_direct convention what it expects directly: a repro.nim at
##   the workspace root, a `uses: "gcc"` line, an `executable ... :
##   discard` member, and the standard layout `src/main.c`.
##
## Expected output:
##
##   $ repro build .
##   $ ./.repro/build/hello-world-c/hello-world-c
##   hello from reprobuild M1
##
## Verified: bit-identical re-builds. Same sources -> same gcc argv ->
## same compiled binary -> same sha256 across cold rebuilds (the
## `~/.cache/repro/action-cache/` action cache is independent of the
## per-project `.repro/build/` output tree, so wiping both still
## reproduces the same digest).

import repro_project_dsl
# DSL-port M9.R.2c — Library/Executable in scope for typed artifact slot vars.
import repro_dsl_stdlib/types

package helloWorldC:
  uses:
    "gcc"

  executable hello-world-c:
    discard

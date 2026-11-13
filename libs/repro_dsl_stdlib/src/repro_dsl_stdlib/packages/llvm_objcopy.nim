## ``llvm-objcopy`` -- LLVM's object copier, which reads every target LLVM
## supports.
##
## The installed prefix strips the debug info of a bundled library built for
## another machine (Distribution-And-Packaging.md §5.3, amendment C2). The
## build host's GNU objcopy recognises only its own architectures ("Unable to
## recognise the architecture of the input file" on an armv7 library), and
## zig 0.13's `zig objcopy` failed with "error: Unexpected" on the same
## library and left a truncated output (measured 2026-11-03).
## https://llvm.org/docs/CommandGuide/llvm-objcopy.html

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `llvm-objcopy`:
  provisioning:
    nixPackage "nixpkgs#llvm", executablePath = "bin/llvm-objcopy",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

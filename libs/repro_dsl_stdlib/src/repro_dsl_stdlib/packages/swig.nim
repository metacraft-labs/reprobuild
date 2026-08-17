## DSL-port M9.R.10a — stdlib provisioning stub for ``swig``.
##
## Widened in M9.R.11 from the original M9.R.10a single-nix stub.
## ``swig`` (Simplified Wrapper and Interface Generator) is consumed by
## recipes that expose C/C++ bindings to scripting languages.
##
## sha256 cross-checked against nixpkgs's ``pkgs/by-name/sw/swig/
## package.nix`` (version 4.4.1, github archive). The Windows
## ``swigwin-4.4.1`` Scoop manifest unpacks ``swig.exe`` at the
## prefix root.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `swig`:
  provisioning:
    nixPackage "nixpkgs#swig", executablePath = "bin/swig",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    scoopApp(bucket = "main", app = "swig",
      preferredVersion = ">=4", executablePath = "swig.exe",
      requiresExecutionProfileChecksum = false)
    # **executablePath = "autogen.sh"** (M9.R.11 source-tarball
    # placeholder): the swig source tarball (github archive shape)
    # ships ``autogen.sh`` at the root with +x. See ``packages/
    # texinfo.nim`` for the broader rationale.
    tarball url = "https://github.com/swig/swig/archive/refs/tags/v4.4.1.tar.gz",
      sha256 = "8ec8bcdeff6c8349f99147c3002a9d3404b656e2d2cb1bfea5ed8b45c3b82a17",
      archiveType = "tar.gz",
      stripComponents = 1,
      executablePath = "autogen.sh",
      packageId = "swig@4.4.1",
      cpu = "any",
      os = "any",
      lockIdentity = "tarball:swig@4.4.1:sha256:8ec8bcdeff6c8349f99147c3002a9d3404b656e2d2cb1bfea5ed8b45c3b82a17"

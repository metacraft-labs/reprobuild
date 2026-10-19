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
    #
    # **sha256**: corrected 2026-10-14 against the bytes GitHub serves
    # for that tag (stable over two fetches). The arm had carried
    # ``8ec8bcde…`` and so could never realize — every attempt failed
    # the digest check with "all tarball archive URLs failed for swig",
    # and nothing noticed because no check had fetched the archive.
    # A GitHub ``/archive/refs/tags/`` tarball is generated on demand
    # and is not guaranteed byte-stable across upstream tooling
    # changes, so this pin is one the catalog conformance sweep has to
    # keep honest. The URL stays: the SourceForge dist tarball is a
    # different tree (``40162a70…``) with no ``autogen.sh``, which is
    # the file this arm declares.
    tarball url = "https://github.com/swig/swig/archive/refs/tags/v4.4.1.tar.gz",
      sha256 = "8bf32042beb7ee1eeb5c71aa15a62513d964893f84234f2cd77e4a8e2ed41e87",
      archiveType = "tar.gz",
      stripComponents = 1,
      executablePath = "autogen.sh",
      packageId = "swig@4.4.1",
      cpu = "any",
      os = "any",
      lockIdentity = "tarball:swig@4.4.1:sha256:8bf32042beb7ee1eeb5c71aa15a62513d964893f84234f2cd77e4a8e2ed41e87"

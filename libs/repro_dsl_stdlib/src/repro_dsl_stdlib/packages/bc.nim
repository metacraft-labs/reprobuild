## DSL-port M9.R.10a — stdlib provisioning stub for ``bc``.
##
## Widened in M9.R.11 from the original M9.R.10a single-nix stub.
## ``bc`` is consumed by glibc / kernel configure scripts during the
## from-source bootstrap; reached transitively via the gcc → glibc arm.
##
## sha256 cross-checked against nixpkgs's ``pkgs/by-name/bc/bc/
## package.nix`` (version 1.08.2). Scoop ``main`` ships an
## ``bc-embedeo`` Windows binary under the ``bc`` manifest, but the
## ``bin`` entry is a per-arch executable list — keep the manifest
## opt-in via the same ``bin/bc.exe`` shape the lessmsi adapter
## consumes elsewhere.

import repro_project_dsl

package `bc`:
  provisioning:
    nixPackage "nixpkgs#bc", executablePath = "bin/bc",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
    scoopApp(bucket = "main", app = "bc",
      preferredVersion = ">=1", executablePath = "bin/bc.exe",
      requiresExecutionProfileChecksum = false)
    # **executablePath = "configure"** (M9.R.11 source-tarball
    # placeholder): see ``packages/texinfo.nim`` for the rationale.
    tarball url = "https://ftp.gnu.org/gnu/bc/bc-1.08.2.tar.gz",
      sha256 = "79e31e022a84b31dd809815063d4b8ea590b409637a52c50ec9f42c2bf332711",
      archiveType = "tar.gz",
      stripComponents = 1,
      executablePath = "configure",
      packageId = "bc@1.08.2",
      cpu = "any",
      os = "any",
      lockIdentity = "tarball:bc@1.08.2:sha256:79e31e022a84b31dd809815063d4b8ea590b409637a52c50ec9f42c2bf332711"

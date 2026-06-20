## DSL-port M9.R.10a — stdlib provisioning stub for ``file``.
##
## Widened in M9.R.11 from the original M9.R.10a single-nix stub.
## ``file`` is the libmagic CLI; consumed by autoconf-generated configure
## scripts to probe binary layouts at configure time.
##
## sha256 cross-checked against nixpkgs's ``pkgs/tools/misc/file/
## default.nix`` (version 5.47). Scoop ``main`` ships a ``file``
## manifest with a flat ``file.exe`` extract.

import repro_project_dsl

package `file`:
  provisioning:
    nixPackage "nixpkgs#file", executablePath = "bin/file",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
    scoopApp(bucket = "main", app = "file",
      preferredVersion = ">=5", executablePath = "file.exe",
      requiresExecutionProfileChecksum = false)
    # **executablePath = "configure"** (M9.R.11 source-tarball
    # placeholder): see ``packages/texinfo.nim`` for the rationale.
    tarball url = "https://astron.com/pub/file/file-5.47.tar.gz",
      sha256 = "45672fec165cb4cc1358a2d76b5d57d22876dcb97ab169427ac385cbe1d5597a",
      archiveType = "tar.gz",
      stripComponents = 1,
      executablePath = "configure",
      packageId = "file@5.47",
      cpu = "any",
      os = "any",
      lockIdentity = "tarball:file@5.47:sha256:45672fec165cb4cc1358a2d76b5d57d22876dcb97ab169427ac385cbe1d5597a"

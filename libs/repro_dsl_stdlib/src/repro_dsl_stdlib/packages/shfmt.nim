## ``shfmt`` — the shell-script formatter from mvdan/sh.
##
## **Windows ships a bare .exe**, like ``jq``: upstream's Windows asset is
## ``shfmt_v<version>_windows_amd64.exe`` with no archive around it, so
## ``archiveType = "raw"`` and the realize step renames rather than extracts.
## The declared ``executablePath`` is what makes the program callable as
## ``shfmt`` despite the versioned upstream filename.
##
## Version 3.12.0; the digest is Agent Harbor's ``SHFMT_SHA256_WINDOWS_AMD64``.
## No arm64 Windows slice: upstream publishes none for this release, which is
## an upstream platform gap rather than a missing recipe — the distinction
## the catalog's coverage reporting has to preserve.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package shfmt:
  provisioning:
    nixPackage "nixpkgs#shfmt", executablePath = "bin/shfmt",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

    tarball url = "https://github.com/mvdan/sh/releases/download/v3.12.0/shfmt_v3.12.0_windows_amd64.exe",
      sha256 = "c8bda517ba1c640ce4a715c0fa665439ddbe4357ba5e9b77b0e51e70e2b9c94b",
      archiveType = "raw",
      executablePath = "shfmt.exe",
      packageId = "shfmt@3.12.0",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:shfmt@3.12.0:windows-x86_64:sha256:c8bda517ba1c640ce4a715c0fa665439ddbe4357ba5e9b77b0e51e70e2b9c94b"

## ``jq`` — the command-line JSON processor.
##
## **Windows ships a bare .exe.** jqlang publishes ``jq-win64.exe`` as a
## single unwrapped binary rather than an archive, so the realization is
## ``archiveType = "raw"``: the download IS the program and the realize step
## renames it into the prefix instead of extracting anything.
##
## The version pin is 1.7.1 and the digest is the one Agent Harbor's
## ``scripts/windows-devenv/toolchain-versions.env`` carries as
## ``JQ_SHA256_WIN64``, harvested independently of this catalog.
##
## Linux and macOS come from nixpkgs. Upstream does publish per-platform
## binaries for both, but pinning them here would mean asserting digests this
## change did not verify; the nix channel covers those axes today and the
## direct-download slices can be backfilled when someone harvests them.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package jq:
  provisioning:
    nixPackage "nixpkgs#jq", executablePath = "bin/jq",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

    tarball url = "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-win64.exe",
      sha256 = "7451fbbf37feffb9bf262bd97c54f0da558c63f0748e64152dd87b0a07b6d6ab",
      archiveType = "raw",
      executablePath = "jq.exe",
      packageId = "jq@1.7.1",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:jq@1.7.1:windows-x86_64:sha256:7451fbbf37feffb9bf262bd97c54f0da558c63f0748e64152dd87b0a07b6d6ab"

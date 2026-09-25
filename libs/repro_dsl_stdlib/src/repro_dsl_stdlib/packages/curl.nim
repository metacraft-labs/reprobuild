import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package curl:
  provisioning:
    nixPackage "nixpkgs#curl", executablePath = "bin/curl",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    # Windows: Git for Windows ships this at `mingw64/bin/curl.exe`. Same
    # two channels as `sh` -- Scoop's `main/git` and the pinned
    # PortableGit archive (one download, deduped by the store; only the
    # `executablePath` view differs). Precedent: sh.nim, tar.nim, gzip.nim.
    scoopApp(bucket = "main", app = "git",
      preferredVersion = ">=2", executablePath = "mingw64/bin/curl.exe",
      requiresExecutionProfileChecksum = false)
    tarball url = "https://github.com/git-for-windows/git/releases/download/v2.54.0.windows.1/PortableGit-2.54.0-64-bit.7z.exe",
      sha256 = "bea006a6cc69673f27b1647e84ab3a68e912fbc175ab6320c5987e012897f311",
      archiveType = "7z.exe",
      executablePath = "mingw64/bin/curl.exe",
      packageId = "git@2.54.0",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:git@2.54.0:sha256:bea006a6cc69673f27b1647e84ab3a68e912fbc175ab6320c5987e012897f311"

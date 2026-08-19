import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package bash:
  provisioning:
    nixPackage "nixpkgs#bash", executablePath = "bin/bash",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    # Windows: there is no standalone `bash` Scoop package; bash comes
    # bundled with Git for Windows (PortableGit), where it ships at
    # `bin/bash.exe`. Resolving the `bash` selector via Scoop installs
    # `main/git` and exposes its bin tree on PATH.
    scoopApp(bucket = "main", app = "git",
      preferredVersion = ">=2", executablePath = "bin/bash.exe",
      requiresExecutionProfileChecksum = false)
    # Direct-download: same PortableGit archive as `git.nim`; bash.exe
    # ships at `bin/bash.exe` in the SFX-extracted tree.
    tarball url = "https://github.com/git-for-windows/git/releases/download/v2.54.0.windows.1/PortableGit-2.54.0-64-bit.7z.exe",
      sha256 = "bea006a6cc69673f27b1647e84ab3a68e912fbc175ab6320c5987e012897f311",
      archiveType = "7z.exe",
      executablePath = "bin/bash.exe",
      packageId = "git@2.54.0",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:git@2.54.0:sha256:bea006a6cc69673f27b1647e84ab3a68e912fbc175ab6320c5987e012897f311"

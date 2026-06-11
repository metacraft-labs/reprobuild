import repro_project_dsl

package nimble:
  provisioning:
    nixPackage "nixpkgs#nimble", executablePath = "bin/nimble",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
    # Windows: nimble ships as part of the upstream Nim Windows zip
    # (ScoopInstaller/Main `nim`), so the `nimble` selector resolves
    # against the same scoop app with a different executablePath.
    scoopApp(bucket = "main", app = "nim",
      preferredVersion = ">=1.6,<3.0", executablePath = "bin/nimble.exe",
      requiresExecutionProfileChecksum = false)
    # Direct-download: same nim-X.Y.Z_x64.zip as `nim.nim` since the
    # archive ships both binaries; executablePath selects which one is
    # exposed to the typed-tool wrapper.
    tarball url = "https://nim-lang.org/download/nim-2.2.10_x64.zip",
      sha256 = "fe0686a9b298e5b13d0a983df37e002a8c6320f8b16cc45a51d15cf4046a109f",
      archiveType = "zip",
      stripComponents = 1,
      executablePath = "bin/nimble.exe",
      packageId = "nim@2.2.10",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:nim@2.2.10:sha256:fe0686a9b298e5b13d0a983df37e002a8c6320f8b16cc45a51d15cf4046a109f"

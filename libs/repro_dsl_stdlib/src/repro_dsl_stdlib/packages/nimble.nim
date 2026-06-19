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
    # Linux x86_64: same upstream nim-lang.org tar.xz as nim.nim — the
    # archive ships both binaries, so executablePath selects nimble.
    tarball url = "https://nim-lang.org/download/nim-2.2.10-linux_x64.tar.xz",
      sha256 = "0a3a38752e97e9d44aa479b3a7b37336dfe0176daf22ee5b5218ad0991ecd211",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "bin/nimble",
      packageId = "nim@2.2.10",
      cpu = "x86_64",
      os = "linux",
      lockIdentity = "tarball:nim@2.2.10:linux:sha256:0a3a38752e97e9d44aa479b3a7b37336dfe0176daf22ee5b5218ad0991ecd211"

import repro_project_dsl

package npx:
  provisioning:
    nixPackage "nixpkgs#nodejs", executablePath = "bin/npx",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
    # Windows: npx ships as part of the Node.js zip from ScoopInstaller/
    # Main's `nodejs` app. After extract, npx.cmd lives at the prefix
    # root alongside node.exe.
    scoopApp(bucket = "main", app = "nodejs",
      preferredVersion = ">=20", executablePath = "npx.cmd",
      requiresExecutionProfileChecksum = false)
    # Direct-download: same Node.js 7z as `node.nim`; npx.cmd ships at
    # the root of the flattened tree.
    tarball url = "https://nodejs.org/dist/v24.16.0/node-v24.16.0-win-x64.7z",
      sha256 = "9f0ad977a75a1ca1a2ebe1294caf64e6c6b4de89d3b6dff218455de3fa0a3211",
      archiveType = "7z",
      stripComponents = 1,
      executablePath = "npx.cmd",
      packageId = "node@24.16.0",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:node@24.16.0:sha256:9f0ad977a75a1ca1a2ebe1294caf64e6c6b4de89d3b6dff218455de3fa0a3211"
    # Linux x86_64: same Node.js distribution as `node.nim` — the Linux
    # tar.xz ships `npx` as a shell wrapper at `bin/npx` (POSIX symlink
    # to the npm-cli script). stripComponents=1 flattens the outer
    # `node-v24.16.0-linux-x64/` dir.
    tarball url = "https://nodejs.org/dist/v24.16.0/node-v24.16.0-linux-x64.tar.xz",
      sha256 = "d804845d34eddc21dc1092b519d643ef40b1f58ec5dec5c22b1f4bd8fabde6c9",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "bin/npx",
      packageId = "node@24.16.0",
      cpu = "x86_64",
      os = "linux",
      lockIdentity = "tarball:node@24.16.0:linux:sha256:d804845d34eddc21dc1092b519d643ef40b1f58ec5dec5c22b1f4bd8fabde6c9"
    # macOS aarch64: same Node.js distribution as `node.nim` — the
    # darwin-arm64 tar.xz ships `npx` as a POSIX symlink at `bin/npx`
    # (pointing at the npm-cli script). stripComponents=1 flattens the
    # outer `node-v24.16.0-darwin-arm64/` dir.
    tarball url = "https://nodejs.org/dist/v24.16.0/node-v24.16.0-darwin-arm64.tar.xz",
      sha256 = "e28ad5531b2aafe0ea555a51b2412c42fdc0f91a6a53fbd03ac93e3847e91389",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "bin/npx",
      packageId = "node@24.16.0",
      cpu = "aarch64",
      os = "macos",
      lockIdentity = "tarball:node@24.16.0:macos-aarch64:sha256:e28ad5531b2aafe0ea555a51b2412c42fdc0f91a6a53fbd03ac93e3847e91389"

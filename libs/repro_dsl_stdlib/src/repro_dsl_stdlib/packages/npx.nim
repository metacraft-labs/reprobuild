import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package npx:
  provisioning:
    nixPackage "nixpkgs#nodejs", executablePath = "bin/npx",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    # Windows: npx ships as part of the Node.js zip from ScoopInstaller/
    # Main's `nodejs` app. After extract, npx.cmd lives at the prefix
    # root alongside node.exe.
    scoopApp(bucket = "main", app = "nodejs",
      preferredVersion = ">=20", executablePath = "npx.cmd",
      requiresExecutionProfileChecksum = false)
    # Direct-download: same Node.js 7z as `node.nim`; npx.cmd ships at
    # the root of the flattened tree.
    tarball url = "https://nodejs.org/dist/v24.16.0/node-v24.16.0-win-x64.zip",
      sha256 = "edaca9bd58ec8e92037dac4e877d52f6b8f430b81c18b57e264b4e2fb111cd56",
      archiveType = "zip",
      stripComponents = 1,
      executablePath = "npx.cmd",
      packageId = "node@24.16.0",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:node@24.16.0:sha256:edaca9bd58ec8e92037dac4e877d52f6b8f430b81c18b57e264b4e2fb111cd56"
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
    tarball url = "https://nodejs.org/dist/v24.16.0/node-v24.16.0-darwin-arm64.tar.gz",
      sha256 = "39189dab4eeb15706c424af0ac08a3044c9e48f7db12a7d77f6b7aafc7dd5df6",
      archiveType = "tar.gz",
      stripComponents = 1,
      executablePath = "bin/npx",
      packageId = "node@24.16.0",
      cpu = "aarch64",
      os = "macos",
      lockIdentity = "tarball:node@24.16.0:macos-aarch64:sha256:39189dab4eeb15706c424af0ac08a3044c9e48f7db12a7d77f6b7aafc7dd5df6"

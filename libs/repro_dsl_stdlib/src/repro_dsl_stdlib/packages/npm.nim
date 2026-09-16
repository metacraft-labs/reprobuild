## ``npm`` — Node Package Manager, ships in the ``nodejs`` Nix package
## alongside ``node`` and ``npx``.
##
## Dispatched by the JS/TS convention (M16/M21) for:
##   * ``npm ci`` — M21 A1 deterministic dependency install when the
##     project ships ``package-lock.json``.
##   * ``npm install`` — M24 Mode B crude fallback when a bundler config
##     (vite / webpack / rollup / parcel / next / nuxt) drives the
##     build script.
##   * ``npm run build`` — M24 Mode B build dispatch.
##
## Listed in M29 (Provisioning catalog cleanup) so the JS/TS dispatch
## path has a closed-set catalog footprint matching the existing
## ``node`` + ``npx`` entries.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package npm:
  provisioning:
    nixPackage "nixpkgs#nodejs", executablePath = "bin/npm",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    # MR2: npm ships INSIDE the Node.js tarball — there is no
    # separate upstream npm distribution. Mirror node.nim's tarball
    # url + sha256 (the engine deduplicates downloads by content hash,
    # so the bytes are fetched once even though both selectors point
    # at the same URL); the only difference is ``executablePath`` which
    # picks the ``npm`` / ``npm.cmd`` shim out of the shared archive.
    # Same shape as npx.nim. Sha256 + URL come from
    # https://nodejs.org/dist/v24.16.0/SHASUMS256.txt.
    tarball url = "https://nodejs.org/dist/v24.16.0/node-v24.16.0-win-x64.zip",
      sha256 = "edaca9bd58ec8e92037dac4e877d52f6b8f430b81c18b57e264b4e2fb111cd56",
      archiveType = "zip",
      stripComponents = 1,
      executablePath = "npm.cmd",
      packageId = "node@24.16.0",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:node@24.16.0:sha256:edaca9bd58ec8e92037dac4e877d52f6b8f430b81c18b57e264b4e2fb111cd56"
    tarball url = "https://nodejs.org/dist/v24.16.0/node-v24.16.0-linux-x64.tar.xz",
      sha256 = "d804845d34eddc21dc1092b519d643ef40b1f58ec5dec5c22b1f4bd8fabde6c9",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "bin/npm",
      packageId = "node@24.16.0",
      cpu = "x86_64",
      os = "linux",
      lockIdentity = "tarball:node@24.16.0:sha256:d804845d34eddc21dc1092b519d643ef40b1f58ec5dec5c22b1f4bd8fabde6c9"
    tarball url = "https://nodejs.org/dist/v24.16.0/node-v24.16.0-darwin-arm64.tar.gz",
      sha256 = "39189dab4eeb15706c424af0ac08a3044c9e48f7db12a7d77f6b7aafc7dd5df6",
      archiveType = "tar.gz",
      stripComponents = 1,
      executablePath = "bin/npm",
      packageId = "node@24.16.0",
      cpu = "aarch64",
      os = "macos",
      lockIdentity = "tarball:node@24.16.0:sha256:39189dab4eeb15706c424af0ac08a3044c9e48f7db12a7d77f6b7aafc7dd5df6"
    tarball url = "https://nodejs.org/dist/v24.16.0/node-v24.16.0-darwin-x64.tar.gz",
      sha256 = "298b4c7b3cb80765c8703e42b90324a4ece3b6634947b89e769c3c980ab55185",
      archiveType = "tar.gz",
      stripComponents = 1,
      executablePath = "bin/npm",
      packageId = "node@24.16.0",
      cpu = "x86_64",
      os = "macos",
      lockIdentity = "tarball:node@24.16.0:sha256:298b4c7b3cb80765c8703e42b90324a4ece3b6634947b89e769c3c980ab55185"

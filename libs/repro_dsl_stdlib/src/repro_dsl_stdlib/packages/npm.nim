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

package npm:
  provisioning:
    nixPackage "nixpkgs#nodejs", executablePath = "bin/npm",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
    # MR2: npm ships INSIDE the Node.js tarball — there is no
    # separate upstream npm distribution. Mirror node.nim's tarball
    # url + sha256 (the engine deduplicates downloads by content hash,
    # so the bytes are fetched once even though both selectors point
    # at the same URL); the only difference is ``executablePath`` which
    # picks the ``npm`` / ``npm.cmd`` shim out of the shared archive.
    # Same shape as npx.nim. Sha256 + URL come from
    # https://nodejs.org/dist/v20.18.0/SHASUMS256.txt.
    tarball url = "https://nodejs.org/dist/v20.18.0/node-v20.18.0-win-x64.zip",
      sha256 = "f5cea43414cc33024bbe5867f208d1c9c915d6a38e92abeee07ed9e563662297",
      archiveType = "zip",
      stripComponents = 1,
      executablePath = "npm.cmd",
      packageId = "node@20.18.0",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:node@20.18.0:sha256:f5cea43414cc33024bbe5867f208d1c9c915d6a38e92abeee07ed9e563662297"
    tarball url = "https://nodejs.org/dist/v20.18.0/node-v20.18.0-linux-x64.tar.xz",
      sha256 = "4543670b589593f8fa5f106111fd5139081da42bb165a9239f05195e405f240a",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "bin/npm",
      packageId = "node@20.18.0",
      cpu = "x86_64",
      os = "linux",
      lockIdentity = "tarball:node@20.18.0:sha256:4543670b589593f8fa5f106111fd5139081da42bb165a9239f05195e405f240a"
    tarball url = "https://nodejs.org/dist/v20.18.0/node-v20.18.0-darwin-arm64.tar.gz",
      sha256 = "92e180624259d082562592bb12548037c6a417069be29e452ec5d158d657b4be",
      archiveType = "tar.gz",
      stripComponents = 1,
      executablePath = "bin/npm",
      packageId = "node@20.18.0",
      cpu = "aarch64",
      os = "macos",
      lockIdentity = "tarball:node@20.18.0:sha256:92e180624259d082562592bb12548037c6a417069be29e452ec5d158d657b4be"
    tarball url = "https://nodejs.org/dist/v20.18.0/node-v20.18.0-darwin-x64.tar.gz",
      sha256 = "c02aa7560612a4e2cc359fd89fae7aedde370c06db621f2040a4a9f830a125dc",
      archiveType = "tar.gz",
      stripComponents = 1,
      executablePath = "bin/npm",
      packageId = "node@20.18.0",
      cpu = "x86_64",
      os = "macos",
      lockIdentity = "tarball:node@20.18.0:sha256:c02aa7560612a4e2cc359fd89fae7aedde370c06db621f2040a4a9f830a125dc"

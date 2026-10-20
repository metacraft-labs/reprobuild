## ``npx`` — the npm package runner, shipped inside the Node.js distribution.
##
## ## Why the POSIX arms declare a script and a launcher
##
## In every POSIX Node tarball ``bin/npx`` is a relative SYMLINK to
## ``../lib/node_modules/npm/bin/npx-cli.js``, and tarball realization refuses
## a declared executable reached through a symlink
## (``executableInStorePath(..., rejectSymlinks = true)``). The arms used to
## declare ``bin/npx`` — the comments on them even said it was a symlink —
## so provisioning downloaded the archive, verified its digest, extracted it
## and then refused with "extracted tarball lacks executable bin/npx" —
## about an archive that contains that entry — leaving `npx` to resolve from
## the ambient PATH. (Restoring the declaration today refuses with "declares
## executable bin/npx, which is present but reached through a symlink";
## naming the two cases apart landed with the sweep below.)
## Nothing caught it because every
## catalog check read the recipe's TEXT; the catalog conformance sweep that
## realizes each arm is what found it
## (reprobuild-pm/issues/2026-09-24-no-conformance-check-runs-against-stdlib-tarball-arms.md).
##
## The fix is npm.nim's, for the same reason and in the same shape — see its
## header for the full account of the launcher pair, why ``prune`` is
## load-bearing rather than tidying, why each arm prunes BOTH tools' upstream
## launchers rather than only its own, and why ``node`` becomes a requirement
## this package cannot express.

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
    # the root of the flattened tree as a regular file, so the Windows arm
    # needs none of the launcher machinery the POSIX arms below do.
    # ``version`` is npm's, as in npm.nim: npx is npm's ``npx-cli.js`` and
    # reports npm's version, read from each archive's npm ``package.json``.
    tarball url = "https://nodejs.org/dist/v24.16.0/node-v24.16.0-win-x64.zip",
      sha256 = "edaca9bd58ec8e92037dac4e877d52f6b8f430b81c18b57e264b4e2fb111cd56",
      archiveType = "zip",
      stripComponents = 1,
      executablePath = "npx.cmd",
      version = "11.13.0",
      packageId = "node@24.16.0",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:node@24.16.0:sha256:edaca9bd58ec8e92037dac4e877d52f6b8f430b81c18b57e264b4e2fb111cd56"
    # Linux x86_64: same Node.js distribution as `node.nim`.
    # stripComponents=1 flattens the outer `node-v24.16.0-linux-x64/` dir.
    tarball url = "https://nodejs.org/dist/v24.16.0/node-v24.16.0-linux-x64.tar.xz",
      sha256 = "d804845d34eddc21dc1092b519d643ef40b1f58ec5dec5c22b1f4bd8fabde6c9",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "lib/node_modules/npm/bin/npx-cli.js",
      executableAlias = "npx",
      launcher = "node",
      prune = "lib/node_modules/npm/bin/npx",
      prune = "lib/node_modules/npm/bin/npx.cmd",
      prune = "lib/node_modules/npm/bin/npm",
      prune = "lib/node_modules/npm/bin/npm.cmd",
      version = "11.13.0",
      packageId = "node@24.16.0",
      cpu = "x86_64",
      os = "linux",
      lockIdentity = "tarball:node@24.16.0:linux:sha256:d804845d34eddc21dc1092b519d643ef40b1f58ec5dec5c22b1f4bd8fabde6c9"
    # macOS aarch64: same Node.js distribution as `node.nim`.
    # stripComponents=1 flattens the outer `node-v24.16.0-darwin-arm64/` dir.
    tarball url = "https://nodejs.org/dist/v24.16.0/node-v24.16.0-darwin-arm64.tar.gz",
      sha256 = "39189dab4eeb15706c424af0ac08a3044c9e48f7db12a7d77f6b7aafc7dd5df6",
      archiveType = "tar.gz",
      stripComponents = 1,
      executablePath = "lib/node_modules/npm/bin/npx-cli.js",
      executableAlias = "npx",
      launcher = "node",
      prune = "lib/node_modules/npm/bin/npx",
      prune = "lib/node_modules/npm/bin/npx.cmd",
      prune = "lib/node_modules/npm/bin/npm",
      prune = "lib/node_modules/npm/bin/npm.cmd",
      version = "11.13.0",
      packageId = "node@24.16.0",
      cpu = "aarch64",
      os = "macos",
      lockIdentity = "tarball:node@24.16.0:macos-aarch64:sha256:39189dab4eeb15706c424af0ac08a3044c9e48f7db12a7d77f6b7aafc7dd5df6"

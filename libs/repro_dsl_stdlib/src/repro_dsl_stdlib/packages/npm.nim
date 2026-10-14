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
##
## ## Why the POSIX arms declare a script and a launcher
##
## In every POSIX Node tarball ``bin/npm`` is a relative SYMLINK to
## ``../lib/node_modules/npm/bin/npm-cli.js``, and tarball realization refuses
## a declared executable reached through a symlink
## (``executableInStorePath(..., rejectSymlinks = true)``). The arms used to
## declare ``bin/npm``, so provisioning downloaded the archive, verified its
## digest, extracted it and then refused with "extracted tarball lacks
## executable bin/npm" — about an archive that contains that entry — and
## `npm` resolved from the ambient PATH instead. (Restoring the declaration
## today refuses with "declares executable bin/npm, which is present but
## reached through a symlink"; naming the two cases apart landed with the
## sweep below.)
## Nothing caught it, because every catalog check read the recipe's TEXT; the
## catalog conformance sweep that now does is what found it
## (reprobuild-pm/issues/2026-09-24-no-conformance-check-runs-against-stdlib-tarball-arms.md).
##
## So the arms declare the CLI script itself and ask realize for the launcher
## pair npm's own installer would generate, exactly as the ``gemini-cli``
## vendor contribution does: ``executableAlias`` supplies the name and
## ``launcher = "node"`` the interpreter, so ``npm`` and ``npm.cmd`` are
## written into ``lib/node_modules/npm/bin/`` and that directory is what goes
## on PATH.
##
## ``prune`` is load-bearing, not tidying. Realize skips an alias whose
## name already exists, and upstream ships its own ``npm`` and ``npm.cmd``
## in that very directory — cygwin/mingw shell scripts that derive their CLI
## path from ``process.execPath`` of whichever ``node`` the PATH resolves,
## i.e. from the AMBIENT node's install prefix. Left in place they would win
## the name and run somebody else's npm out of the pinned prefix. Pruning runs
## before the executable probe and before the alias write, so the launcher
## realize writes is what ends up there.
##
## Upstream's ``npx`` and ``npx.cmd`` are pruned for the same reason even
## though this package does not declare them. A realized prefix reaches PATH
## as a DIRECTORY, so everything in it is offered, not just the command the
## package exports — and this directory is shared with ``npx.nim``'s arms,
## whose own prefix is where a working ``npx`` comes from. Leaving upstream's
## copy here would put a second, broken ``npx`` on PATH whenever a recipe uses
## both, and which one wins would be decided by prefix order. Each arm
## therefore prunes BOTH tools' upstream launchers, so the directory it
## contributes offers exactly the one command it declares.
##
## ``node`` is therefore a REQUIREMENT of this package that the package cannot
## express: the launcher resolves its interpreter from PATH, so a recipe that
## uses ``npm`` must declare ``node`` as well. Resolving it from PATH rather
## than baking a store path in keeps the prefix relocatable and lets the
## consuming activation decide which node runs.
##
## The Windows arm is unaffected: the Node zip ships ``npm.cmd`` at the prefix
## root as a regular file.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package npm:
  provisioning:
    nixPackage "nixpkgs#nodejs", executablePath = "bin/npm",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    # Windows: npm ships as part of the Node.js zip from ScoopInstaller/
    # Main's `nodejs` app; npm.cmd lives at the prefix root alongside
    # node.exe. The same stanza node.nim and npx.nim carry — without it a
    # `--tool-provisioning=scoop` build that declares `npm` (every
    # from-source-npm recipe) fails tool resolution on this one package.
    scoopApp(bucket = "main", app = "nodejs",
      preferredVersion = ">=20", executablePath = "npm.cmd",
      requiresExecutionProfileChecksum = false)
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
      executablePath = "lib/node_modules/npm/bin/npm-cli.js",
      executableAlias = "npm",
      launcher = "node",
      prune = "lib/node_modules/npm/bin/npm",
      prune = "lib/node_modules/npm/bin/npm.cmd",
      prune = "lib/node_modules/npm/bin/npx",
      prune = "lib/node_modules/npm/bin/npx.cmd",
      packageId = "node@24.16.0",
      cpu = "x86_64",
      os = "linux",
      lockIdentity = "tarball:node@24.16.0:sha256:d804845d34eddc21dc1092b519d643ef40b1f58ec5dec5c22b1f4bd8fabde6c9"
    tarball url = "https://nodejs.org/dist/v24.16.0/node-v24.16.0-darwin-arm64.tar.gz",
      sha256 = "39189dab4eeb15706c424af0ac08a3044c9e48f7db12a7d77f6b7aafc7dd5df6",
      archiveType = "tar.gz",
      stripComponents = 1,
      executablePath = "lib/node_modules/npm/bin/npm-cli.js",
      executableAlias = "npm",
      launcher = "node",
      prune = "lib/node_modules/npm/bin/npm",
      prune = "lib/node_modules/npm/bin/npm.cmd",
      prune = "lib/node_modules/npm/bin/npx",
      prune = "lib/node_modules/npm/bin/npx.cmd",
      packageId = "node@24.16.0",
      cpu = "aarch64",
      os = "macos",
      lockIdentity = "tarball:node@24.16.0:sha256:39189dab4eeb15706c424af0ac08a3044c9e48f7db12a7d77f6b7aafc7dd5df6"
    tarball url = "https://nodejs.org/dist/v24.16.0/node-v24.16.0-darwin-x64.tar.gz",
      sha256 = "298b4c7b3cb80765c8703e42b90324a4ece3b6634947b89e769c3c980ab55185",
      archiveType = "tar.gz",
      stripComponents = 1,
      executablePath = "lib/node_modules/npm/bin/npm-cli.js",
      executableAlias = "npm",
      launcher = "node",
      prune = "lib/node_modules/npm/bin/npm",
      prune = "lib/node_modules/npm/bin/npm.cmd",
      prune = "lib/node_modules/npm/bin/npx",
      prune = "lib/node_modules/npm/bin/npx.cmd",
      packageId = "node@24.16.0",
      cpu = "x86_64",
      os = "macos",
      lockIdentity = "tarball:node@24.16.0:sha256:298b4c7b3cb80765c8703e42b90324a4ece3b6634947b89e769c3c980ab55185"

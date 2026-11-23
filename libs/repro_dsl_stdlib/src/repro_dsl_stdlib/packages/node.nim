## GM4b: every archive realization of ``node`` is a ``tarball`` statement
## in the ``provisioning:`` block below. The M68 ``nodeCatalog``
## (``VersionedProvisioning``) copy that once sat beside it tracked the
## upstream ``nodejs-lts`` Scoop manifest; it was merged into those
## statements and removed. Its x86_64-windows record was corrupt — the
## ``.zip`` URL paired with the SHA-256 and ``7z`` format of
## ``node-v24.16.0-win-x64.7z`` — so the in-package zip (verified digest)
## is the only x86_64-windows realization; on that layout only the
## root-relative ``node.exe``, ``npm.cmd``, ``npx.cmd`` exist (the
## catalog's ``bin/*`` entries appeared only after Scoop's
## ``post_install`` hook), and those are the executables it declares.
##
## M9.5: the Linux realization was added by hand (Node ships on ``nodejs.org/dist/``, not
## GitHub Releases — the M7 gh-releases harvester doesn't apply). URL
## pattern: ``node-v<ver>-linux-x64.tar.xz``; sha256 lifted from
## upstream's ``SHASUMS256.txt``. The inner dir is
## ``node-v<ver>-linux-x64/``; binaries live under ``bin/`` (``node``,
## ``npm``, ``npx``) without the ``.exe`` / ``.cmd`` shims that
## Windows requires. Upstream Node's Linux LTS build targets glibc 2.28
## (Debian 10 / Ubuntu 20.04 floor) — higher than the spec's 2.17
## target; documented here.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin
import repro_dsl_stdlib/packages_schema
export packages_schema

# ---------------------------------------------------------------------------
# Pre-existing M21 DSL declaration (CLI surface + Nix provisioning).
# ---------------------------------------------------------------------------

package node:
  provisioning:
    nixPackage "nixpkgs#nodejs", executablePath = "bin/node",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    # Windows / non-Nix Linux: Node.js zip via ScoopInstaller/Main. The
    # manifest extracts the `node-vX.Y.Z-win-x64/` subtree to the prefix
    # root, so node.exe ends up at the top level.
    scoopApp(bucket = "main", app = "nodejs",
      preferredVersion = ">=20", executablePath = "node.exe",
      requiresExecutionProfileChecksum = false)
    # Direct-download (MR2): official Node.js 20.x LTS tarballs from
    # nodejs.org. The Windows asset is a .zip (vs. the 24.x .7z) because
    # nodejs.org's 20.x line publishes the win-x64 zip alongside the 7z
    # and the zip extractor path does not require a system-level ``7z``
    # binary at realize time. Sha256s lifted from
    # https://nodejs.org/dist/v24.16.0/SHASUMS256.txt — single source of
    # truth for the v24.16.0 release. The archive layout is
    # ``node-v24.16.0-win-x64/node.exe`` + ``npm.cmd`` + ``npx.cmd`` so
    # stripComponents=1 flattens the leading dir; npm.nim and npx.nim
    # declare the SAME tarball URL with their own executablePath so the
    # engine's content-addressed store dedupes the extracted prefix.
    tarball url = "https://nodejs.org/dist/v24.16.0/node-v24.16.0-win-x64.zip",
      sha256 = "edaca9bd58ec8e92037dac4e877d52f6b8f430b81c18b57e264b4e2fb111cd56",
      archiveType = "zip",
      stripComponents = 1,
      executablePath = "node.exe",
      packageId = "node@24.16.0",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:node@24.16.0:sha256:edaca9bd58ec8e92037dac4e877d52f6b8f430b81c18b57e264b4e2fb111cd56",
      version = "24.16.0",
      extraExecutable = "npm.cmd",
      extraExecutable = "npx.cmd"
    # Linux x86_64: official Node.js tar.xz. Inner dir
    # ``node-v24.16.0-linux-x64/`` flattens via stripComponents=1; the
    # interpreter lives at ``bin/node`` post-flatten (no .exe suffix,
    # no .cmd shims).
    tarball url = "https://nodejs.org/dist/v24.16.0/node-v24.16.0-linux-x64.tar.xz",
      sha256 = "d804845d34eddc21dc1092b519d643ef40b1f58ec5dec5c22b1f4bd8fabde6c9",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "bin/node",
      packageId = "node@24.16.0",
      cpu = "x86_64",
      os = "linux",
      lockIdentity = "tarball:node@24.16.0:sha256:d804845d34eddc21dc1092b519d643ef40b1f58ec5dec5c22b1f4bd8fabde6c9",
      version = "24.16.0",
      extraExecutable = "bin/npm",
      extraExecutable = "bin/npx"
    # macOS arm64: official Node.js tar.gz for Apple silicon. Inner dir
    # ``node-v24.16.0-darwin-arm64/`` flattens to bin/node.
    tarball url = "https://nodejs.org/dist/v24.16.0/node-v24.16.0-darwin-arm64.tar.gz",
      sha256 = "39189dab4eeb15706c424af0ac08a3044c9e48f7db12a7d77f6b7aafc7dd5df6",
      archiveType = "tar.gz",
      stripComponents = 1,
      executablePath = "bin/node",
      packageId = "node@24.16.0",
      cpu = "aarch64",
      os = "macos",
      lockIdentity = "tarball:node@24.16.0:sha256:39189dab4eeb15706c424af0ac08a3044c9e48f7db12a7d77f6b7aafc7dd5df6",
      version = "24.16.0"
    # macOS x86_64: official Node.js tar.gz for Intel Macs. Same shape
    # as the arm64 entry above.
    tarball url = "https://nodejs.org/dist/v24.16.0/node-v24.16.0-darwin-x64.tar.gz",
      sha256 = "298b4c7b3cb80765c8703e42b90324a4ece3b6634947b89e769c3c980ab55185",
      archiveType = "tar.gz",
      stripComponents = 1,
      executablePath = "bin/node",
      packageId = "node@24.16.0",
      cpu = "x86_64",
      os = "macos",
      lockIdentity = "tarball:node@24.16.0:sha256:298b4c7b3cb80765c8703e42b90324a4ece3b6634947b89e769c3c980ab55185",
      version = "24.16.0"
    # GM4b: archive realizations formerly held by the retired
    # `VersionedProvisioning` catalog record (see the conflict notes
    # in the Gradual-Nix-To-Reprobuild-Migration GM4b milestone).
    tarball url = "https://nodejs.org/dist/v24.16.0/node-v24.16.0-win-arm64.7z",
      sha256 = "e4357cd1ef3b6c67fb99547c4b736aa6732e2b4abd38ece252e119332fb49621",
      archiveType = "7z",
      executablePath = "bin/node.exe",
      extraExecutable = "bin/npm.cmd",
      extraExecutable = "bin/npx.cmd",
      extraExecutable = "node.exe",
      extraExecutable = "npm.cmd",
      extraExecutable = "npx.cmd",
      version = "24.16.0",
      packageId = "node@24.16.0",
      extractPath = "node-v24.16.0-win-arm64",
      cpu = "aarch64",
      os = "windows"

  executable node:
    cli:
      call:
        pos args is seq[string],
          position = 0,
          required = false

## M68 merge note (hand-edited): the auto-generated ``nodeCatalog`` body
## sits below the pre-existing ``package node:`` DSL block. The DSL
## block remains the source of truth for the Node CLI surface and the
## Nix provisioning shape on Nix-capable hosts; the ``nodeCatalog``
## slice is consumed by the M64 ``cakBuiltin`` adapter on Windows.
## Re-harvest emits ONLY the catalog half; re-attach the DSL block
## by hand if you regenerate.
##
## **Known M69 realize-time gaps.** The catalog tracks the upstream
## ``nodejs-lts`` Scoop manifest (24.x current LTS). Several
## consequences for cakBuiltin realize:
##
##   * The archive is a ``.7z`` — M64 currently raises
##     ``EBuiltinExtractFailed`` on ``afSevenZip``.
##   * ``bin_relpath`` was synthesized via ``--bin-default
##     nodejs-lts=node.exe,npm.cmd,npx.cmd`` and the manifest's
##     ``env_add_path = ["bin", "."]`` cross-product. The ``bin/*``
##     entries (``bin/node.exe`` etc.) only exist after Scoop's
##     ``post_install`` hook runs ``Set-Content`` against
##     ``node_modules/npm/npmrc`` to point npm's prefix at the persist
##     directory; on a fresh extract only the root-relative entries
##     (``node.exe``, ``npm.cmd``, ``npx.cmd``) resolve. M69 needs
##     either a post-extract hook runner OR the catalog needs to drop
##     the ``bin/`` prefix entries.
##
## **M9.5 merge note (hand-edited):** added a ``(pcX86_64, poLinux)``
## platform slice manually (Node ships on ``nodejs.org/dist/``, not
## GitHub Releases — the M7 gh-releases harvester doesn't apply). URL
## pattern: ``node-v<ver>-linux-x64.tar.xz``; sha256 lifted from
## upstream's ``SHASUMS256.txt``. The inner dir is
## ``node-v<ver>-linux-x64/``; binaries live under ``bin/`` (``node``,
## ``npm``, ``npx``) without the ``.exe`` / ``.cmd`` shims that
## Windows requires. archive_format_override = afTarXz (vs. Windows
## afSevenZip). Upstream Node's Linux LTS build targets glibc 2.28
## (Debian 10 / Ubuntu 20.04 floor) — higher than the spec's 2.17
## target; documented here.

import std/tables
import repro_project_dsl
import repro_dsl_stdlib/packages_schema
export packages_schema

# ---------------------------------------------------------------------------
# Pre-existing M21 DSL declaration (CLI surface + Nix provisioning).
# ---------------------------------------------------------------------------

package node:
  provisioning:
    nixPackage "nixpkgs#nodejs", executablePath = "bin/node",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
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
    # https://nodejs.org/dist/v20.18.0/SHASUMS256.txt — single source of
    # truth for the v20.18.0 release. The archive layout is
    # ``node-v20.18.0-win-x64/node.exe`` + ``npm.cmd`` + ``npx.cmd`` so
    # stripComponents=1 flattens the leading dir; npm.nim and npx.nim
    # declare the SAME tarball URL with their own executablePath so the
    # engine's content-addressed store dedupes the extracted prefix.
    tarball url = "https://nodejs.org/dist/v20.18.0/node-v20.18.0-win-x64.zip",
      sha256 = "f5cea43414cc33024bbe5867f208d1c9c915d6a38e92abeee07ed9e563662297",
      archiveType = "zip",
      stripComponents = 1,
      executablePath = "node.exe",
      packageId = "node@20.18.0",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:node@20.18.0:sha256:f5cea43414cc33024bbe5867f208d1c9c915d6a38e92abeee07ed9e563662297"
    # Linux x86_64: official Node.js tar.xz. Inner dir
    # ``node-v20.18.0-linux-x64/`` flattens via stripComponents=1; the
    # interpreter lives at ``bin/node`` post-flatten (no .exe suffix,
    # no .cmd shims).
    tarball url = "https://nodejs.org/dist/v20.18.0/node-v20.18.0-linux-x64.tar.xz",
      sha256 = "4543670b589593f8fa5f106111fd5139081da42bb165a9239f05195e405f240a",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "bin/node",
      packageId = "node@20.18.0",
      cpu = "x86_64",
      os = "linux",
      lockIdentity = "tarball:node@20.18.0:sha256:4543670b589593f8fa5f106111fd5139081da42bb165a9239f05195e405f240a"
    # macOS arm64: official Node.js tar.gz for Apple silicon. Inner dir
    # ``node-v20.18.0-darwin-arm64/`` flattens to bin/node.
    tarball url = "https://nodejs.org/dist/v20.18.0/node-v20.18.0-darwin-arm64.tar.gz",
      sha256 = "92e180624259d082562592bb12548037c6a417069be29e452ec5d158d657b4be",
      archiveType = "tar.gz",
      stripComponents = 1,
      executablePath = "bin/node",
      packageId = "node@20.18.0",
      cpu = "aarch64",
      os = "macos",
      lockIdentity = "tarball:node@20.18.0:sha256:92e180624259d082562592bb12548037c6a417069be29e452ec5d158d657b4be"
    # macOS x86_64: official Node.js tar.gz for Intel Macs. Same shape
    # as the arm64 entry above.
    tarball url = "https://nodejs.org/dist/v20.18.0/node-v20.18.0-darwin-x64.tar.gz",
      sha256 = "c02aa7560612a4e2cc359fd89fae7aedde370c06db621f2040a4a9f830a125dc",
      archiveType = "tar.gz",
      stripComponents = 1,
      executablePath = "bin/node",
      packageId = "node@20.18.0",
      cpu = "x86_64",
      os = "macos",
      lockIdentity = "tarball:node@20.18.0:sha256:c02aa7560612a4e2cc359fd89fae7aedde370c06db621f2040a4a9f830a125dc"

  executable node:
    cli:
      call:
        pos args is seq[string],
          position = 0,
          required = false

# ---------------------------------------------------------------------------
# M68 bulk-harvest catalog (cakBuiltin adapter consumer on Windows).
# Harvested from bucket: ScoopInstaller/Main
# Manifest app: nodejs-lts (renamed to ``node`` via --app-alias)
# Versions (newest-first): 24.16.0
# ---------------------------------------------------------------------------

let nodeCatalog* = @[
  VersionedProvisioning(
    version: "24.16.0",
    archive_format: afSevenZip,
    install_method: imExtract,
    bin_relpath: @["bin/node.exe", "bin/npm.cmd", "bin/npx.cmd", "node.exe", "npm.cmd", "npx.cmd"],
    platforms: @[
      PlatformBinary(cpu: pcX86_64, os: poWindows, url: "https://nodejs.org/dist/v24.16.0/node-v24.16.0-win-x64.7z", sha256: "9f0ad977a75a1ca1a2ebe1294caf64e6c6b4de89d3b6dff218455de3fa0a3211", sha512: "", extract_path: "node-v24.16.0-win-x64"),
      PlatformBinary(cpu: pcAArch64, os: poWindows, url: "https://nodejs.org/dist/v24.16.0/node-v24.16.0-win-arm64.7z", sha256: "e4357cd1ef3b6c67fb99547c4b736aa6732e2b4abd38ece252e119332fb49621", sha512: "", extract_path: "node-v24.16.0-win-arm64"),
      # M9.5: Linux x86_64 slice. afTarXz (vs. Windows af7zip); bin
      # layout is the canonical Unix bin/node + bin/npm + bin/npx
      # without the .cmd shims.
      PlatformBinary(cpu: pcX86_64, os: poLinux, url: "https://nodejs.org/dist/v24.16.0/node-v24.16.0-linux-x64.tar.xz", sha256: "d804845d34eddc21dc1092b519d643ef40b1f58ec5dec5c22b1f4bd8fabde6c9", sha512: "", sha1: "", extract_path: "node-v24.16.0-linux-x64", archive_format_override: afTarXz, has_archive_format_override: true, bin_relpath_override: @["bin/node", "bin/npm", "bin/npx"])
    ],
    installer_args: @[],
    pacman_packages: @[],
    bootstrap_argv: @[],
    env: initTable[string, string]())
]

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

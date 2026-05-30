## M68 merge note (hand-edited): the auto-generated ``gitCatalog`` body
## sits below the pre-existing ``package git:`` Nix block. The Nix
## block remains the source of truth for Nix-capable hosts; the
## ``gitCatalog`` slice below is consumed by the M64 ``cakBuiltin``
## adapter on Windows. Re-harvest emits ONLY the catalog half;
## re-attach the Nix block by hand if you regenerate.
##
## **Known M69 realize-time gaps.** Git-for-Windows ships as a
## ``PortableGit-X-64-bit.7z.exe`` self-extracting archive that
## Scoop downloads as ``dl.7z`` (via the ``#/dl.7z`` rename suffix)
## and unpacks as a 7z archive — M64's cakBuiltin currently raises
## ``EBuiltinExtractFailed`` on ``afSevenZip``. The manifest also
## declares ``pre_install`` (restore persisted ``etc/gitconfig``) and
## ``post_install`` (emit ``install-context.reg`` template files) hooks
## that the harvester silently drops; a freshly-realized prefix will
## ship ``bin/git.exe`` without the persisted system-level config.

import std/tables
import repro_project_dsl
import repro_dsl_stdlib/packages_schema
export packages_schema

# ---------------------------------------------------------------------------
# Pre-existing M21 Nix provisioning (preserved across the M68 harvest).
# ---------------------------------------------------------------------------

package git:
  provisioning:
    nixPackage "nixpkgs#git", executablePath = "bin/git",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

# ---------------------------------------------------------------------------
# M68 bulk-harvest catalog (cakBuiltin adapter consumer on Windows).
# Harvested from bucket: ScoopInstaller/Main
# Versions (newest-first): 2.54.0
# ---------------------------------------------------------------------------

let gitCatalog* = @[
  VersionedProvisioning(
    version: "2.54.0",
    archive_format: afSevenZip,
    install_method: imExtract,
    bin_relpath: @["bin\\sh.exe", "bin\\git.exe", "git-bash.exe", "usr\\bin\\gpg.exe", "usr\\bin\\gpg-agent.exe", "usr\\bin\\gpgconf.exe", "usr\\bin\\gpg-connect-agent.exe", "usr\\bin\\pinentry.exe"],
    platforms: @[
      PlatformBinary(cpu: pcX86_64, os: poWindows, url: "https://github.com/git-for-windows/git/releases/download/v2.54.0.windows.1/PortableGit-2.54.0-64-bit.7z.exe#/dl.7z", sha256: "bea006a6cc69673f27b1647e84ab3a68e912fbc175ab6320c5987e012897f311", sha512: "", extract_path: ""),
      PlatformBinary(cpu: pcAArch64, os: poWindows, url: "https://github.com/git-for-windows/git/releases/download/v2.54.0.windows.1/PortableGit-2.54.0-arm64.7z.exe#/dl.7z", sha256: "f8e92cd3359fcbb96998cfd606a536ccc6dbfb23c04e12b29042f9ba45b6b0c7", sha512: "", extract_path: "")
    ],
    installer_args: @[],
    pacman_packages: @[],
    bootstrap_argv: @[],
    env: {"GIT_INSTALL_ROOT": "${prefix}"}.toTable())
]

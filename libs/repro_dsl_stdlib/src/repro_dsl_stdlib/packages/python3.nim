## M68 merge note (hand-edited): the auto-generated ``python3Catalog``
## body sits below the pre-existing ``package python3:`` Nix block.
## The Nix block remains the source of truth for Nix-capable hosts;
## the ``python3Catalog`` slice below is consumed by the M64
## ``cakBuiltin`` adapter on Windows. Re-harvest from Scoop's
## ``python`` manifest with ``--app-alias python=python3``; re-attach
## the Nix block by hand if you regenerate.
##
## **Known M69 realize-time gaps.** The Scoop ``python`` manifest's
## download URL is a self-extracting CPython installer ``.exe`` (the
## ``#/setup.exe`` rename makes Scoop save it as ``setup.exe``);
## extraction is gated by a hefty ``installer.script`` that runs
## ``Expand-DarkArchive`` to crack the MSI bundle open, then
## ``Expand-MsiArchive`` on each ``.msi`` payload. The M68 harvester
## refinement treats ``installer.script``-only blocks as post-extract
## hooks (consistent with how ``post_install`` is dropped), so this
## record currently emits ``install_method = imExtract +
## archive_format = afRaw`` — cakBuiltin would deposit the raw
## ``setup.exe`` at the prefix root without ever extracting it.
## M69 needs either an ``installer.script`` runner or a
## ``afSelfExtractingMsi`` archive_format with a built-in dark/msiexec
## flatten step.
##
## The manifest also carries a ``pre_install`` hook that materializes
## PEP 514 registry files (``install-pep-514.reg``) and a separate
## ``post_install`` (``python -E -s -m ensurepip``). Both are dropped;
## a freshly-realized prefix will surface ``setup.exe`` only.

import std/tables
import repro_project_dsl
import repro_dsl_stdlib/packages_schema
export packages_schema

# ---------------------------------------------------------------------------
# Pre-existing M21 Nix provisioning (preserved across the M68 harvest).
# ---------------------------------------------------------------------------

package python3:
  provisioning:
    nixPackage "nixpkgs#python3", executablePath = "bin/python3",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

# ---------------------------------------------------------------------------
# M68 bulk-harvest catalog (cakBuiltin adapter consumer on Windows).
# Harvested from bucket: ScoopInstaller/Main
# Manifest app: python (renamed to ``python3`` via --app-alias)
# Versions (newest-first): 3.14.5
# ---------------------------------------------------------------------------

let python3Catalog* = @[
  VersionedProvisioning(
    version: "3.14.5",
    archive_format: afRaw,
    install_method: imExtract,
    bin_relpath: @["python.exe", "Lib\\idlelib\\idle.bat", "Lib\\idlelib\\idle.bat"],
    platforms: @[
      PlatformBinary(cpu: pcX86_64, os: poWindows, url: "https://www.python.org/ftp/python/3.14.5/python-3.14.5-amd64.exe#/setup.exe", sha256: "f9c09f5ed6f796fd1a8bc5ddfa41715a494b453c4781f0e35d5077cf9fa58f6d", sha512: "", extract_path: ""),
      PlatformBinary(cpu: pcAArch64, os: poWindows, url: "https://www.python.org/ftp/python/3.14.5/python-3.14.5-arm64.exe#/setup.exe", sha256: "f4a7df6ab4fa375cd7296127ff6b9a14fbd1313f51864ce020185deba10144fa", sha512: "", extract_path: "")
    ],
    installer_args: @[],
    pacman_packages: @[],
    bootstrap_argv: @[],
    env: initTable[string, string]())
]

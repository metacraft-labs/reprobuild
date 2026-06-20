## M68 merge note (hand-edited): the auto-generated ``python3Catalog``
## body sits below the pre-existing ``package python3:`` Nix block.
## The Nix block remains the source of truth for Nix-capable hosts;
## the ``python3Catalog`` slice below is consumed by the M64
## ``cakBuiltin`` adapter on Windows. Re-harvest from Scoop's
## ``python`` manifest with ``--app-alias python=python3``; re-attach
## the Nix block by hand if you regenerate.
##
## **M4 (Realize-Closure-And-Catalog-Expansion spec) update**: the
## ``install_method`` flipped from ``imExtract`` to
## ``imInstallerNsisBundle`` so the cakBuiltin realize loop dispatches
## through the M4 NSIS-unwrap + per-MSI dark extractor. The Scoop
## manifest's ``installer.script`` block carries the canonical
## Expand-DarkArchive + Expand-MsiArchive pattern; M4's harvester
## detects this and emits ``imInstallerNsisBundle``. The realize loop:
##
##   1. 7z-unwraps the outer NSIS shell (the upstream
##      ``python-<ver>-amd64.exe`` is a Burn/NSIS bundle from the
##      CPython installer team).
##   2. Locates the inner ``.msi`` payloads (core.msi + dev.msi +
##      doc.msi + exe.msi + lib.msi + path.msi + pip.msi + tcltk.msi +
##      test.msi + tools.msi).
##   3. Per-MSI dark-extracts into a per-MSI scratch dir.
##   4. Merges every per-MSI tree into the realized prefix with
##      conflict detection (same-relpath + different-bytes raises
##      ``EBuiltinPrefixMergeConflict``).
##
## **Honest scope**: python3's NSIS bundle has an ``add-to-PATH`` side
## effect at install time. cakBuiltin's realize DOES NOT mutate the
## host PATH — the PATH contribution flows through
## ``repro_home_resources`` per M69. The ``install-pep-514.reg`` /
## ``uninstall-pep-514.reg`` registry entries from the manifest's
## ``pre_install`` block are also NOT replayed (out of M4 allowlist
## scope — those would require ``reg import`` which has no safe
## allowlist analogue).

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
    # Windows / non-Nix Linux: official Python embeddable build via
    # ScoopInstaller/Main's `python` manifest. The DSL package name
    # remains `python3` (matches the POSIX command); `app = "python"`
    # is the Scoop side.
    scoopApp(bucket = "main", app = "python",
      preferredVersion = ">=3", executablePath = "python.exe",
      requiresExecutionProfileChecksum = false)
    # Direct-download: python.org embeddable zip (not the NSIS
    # installer — the official `python-X.Y.Z-amd64.exe` is not a
    # passive archive). The embeddable distribution is the same
    # python interpreter without the launcher / IDLE / docs, ships
    # `python.exe` at the archive root and is what the existing
    # `python3Catalog` consumes on Windows.
    tarball url = "https://www.python.org/ftp/python/3.12.10/python-3.12.10-embed-amd64.zip",
      sha256 = "4acbed6dd1c744b0376e3b1cf57ce906f9dc9e95e68824584c8099a63025a3c3",
      archiveType = "zip",
      executablePath = "python.exe",
      packageId = "python@3.12.10",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:python@3.12.10:sha256:4acbed6dd1c744b0376e3b1cf57ce906f9dc9e95e68824584c8099a63025a3c3"
    # Linux x86_64: python.org does NOT publish a Linux "embeddable"
    # equivalent of the Windows python-X.Y.Z-embed-amd64.zip. Use the
    # astral-sh/python-build-standalone install_only tarball as the
    # Linux counterpart — same source `python_dev.nim` consumes; ships
    # `python/bin/python3` plus the full Lib/ tree under a top-level
    # `python/` directory.
    tarball url = "https://github.com/astral-sh/python-build-standalone/releases/download/20260610/cpython-3.12.13+20260610-x86_64-unknown-linux-gnu-install_only.tar.gz",
      sha256 = "c218f50baeb2c06a30c2f03db5986b2bad6ab7c8a52faad2d5a59bda0677b93a",
      archiveType = "tar.gz",
      executablePath = "python/bin/python3",
      packageId = "python@3.12.13+20260610",
      cpu = "x86_64",
      os = "linux",
      lockIdentity = "tarball:python@3.12.13+20260610:linux:sha256:c218f50baeb2c06a30c2f03db5986b2bad6ab7c8a52faad2d5a59bda0677b93a"

# ---------------------------------------------------------------------------
# M68 bulk-harvest catalog (cakBuiltin adapter consumer on Windows).
# Harvested from bucket: ScoopInstaller/Main
# Manifest app: python (renamed to ``python3`` via --app-alias)
# Versions (newest-first): 3.14.5
# M4 amendment: install_method = imInstallerNsisBundle (was imExtract).
# ---------------------------------------------------------------------------

let python3Catalog* = @[
  VersionedProvisioning(
    version: "3.14.5",
    archive_format: afInstallerNsis,
    install_method: imInstallerNsisBundle,
    bin_relpath: @["python.exe"],
    platforms: @[
      PlatformBinary(cpu: pcX86_64, os: poWindows, url: "https://www.python.org/ftp/python/3.14.5/python-3.14.5-amd64.exe", sha256: "f9c09f5ed6f796fd1a8bc5ddfa41715a494b453c4781f0e35d5077cf9fa58f6d", sha512: "", extract_path: "SourceDir"),
      PlatformBinary(cpu: pcAArch64, os: poWindows, url: "https://www.python.org/ftp/python/3.14.5/python-3.14.5-arm64.exe", sha256: "f4a7df6ab4fa375cd7296127ff6b9a14fbd1313f51864ce020185deba10144fa", sha512: "", extract_path: "SourceDir")
    ],
    installer_args: @[],
    pacman_packages: @[],
    bootstrap_argv: @[],
    env: initTable[string, string]())
]

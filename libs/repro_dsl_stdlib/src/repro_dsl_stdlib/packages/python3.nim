## GM4b: every archive realization of ``python3`` is a ``tarball``
## statement in the ``provisioning:`` block below. The M68
## ``python3Catalog`` (``VersionedProvisioning``) record that once sat
## beside it — the 3.14.5 NSIS-bundle installer, harvested from Scoop's
## ``python`` manifest with ``--app-alias python=python3`` — was merged
## into those statements and removed. It follows the in-package
## embeddable 3.12.10 zip for the same target.
##
## **M4 (Realize-Closure-And-Catalog-Expansion spec) update**: the
## installer realization's install method is ``installer-nsis-bundle``
## so the home archive realizer dispatches
## through the M4 NSIS-unwrap + per-MSI dark extractor. The Scoop
## manifest's ``installer.script`` block carries the canonical
## Expand-DarkArchive + Expand-MsiArchive pattern; M4's harvester
## detects this and emits ``installer-nsis-bundle``. The realize loop:
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
## effect at install time. The home archive realizer DOES NOT mutate the
## host PATH — the PATH contribution flows through
## ``repro_home_resources`` per M69. The ``install-pep-514.reg`` /
## ``uninstall-pep-514.reg`` registry entries from the manifest's
## ``pre_install`` block are also NOT replayed (out of M4 allowlist
## scope — those would require ``reg import`` which has no safe
## allowlist analogue).

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin
import repro_dsl_stdlib/packages_schema
export packages_schema

# ---------------------------------------------------------------------------
# Pre-existing M21 Nix provisioning (preserved across the M68 harvest).
# ---------------------------------------------------------------------------

package python3:
  provisioning:
    nixPackage "nixpkgs#python3", executablePath = "bin/python3",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
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
    # python interpreter without the launcher / IDLE / docs and ships
    # `python.exe` at the archive root. Listed first, so it is the
    # default Windows realization for recipes and home profiles alike;
    # the full NSIS-bundle installer below is selected by pinning 3.14.5.
    tarball url = "https://www.python.org/ftp/python/3.12.10/python-3.12.10-embed-amd64.zip",
      sha256 = "4acbed6dd1c744b0376e3b1cf57ce906f9dc9e95e68824584c8099a63025a3c3",
      archiveType = "zip",
      executablePath = "python.exe",
      # The embeddable distribution ships ``python.exe`` and nothing named
      # ``python3``, while the DSL package name, every recipe that declares
      # it and every script that invokes it say ``python3`` — the POSIX
      # command name the Linux and macOS entries below get for free from
      # ``python/bin/python3``.
      #
      # Without the alias a realized prefix contributes ``python.exe`` to
      # PATH and ``python3`` resolves to whatever the HOST has. Measured
      # against a clean store: the dev env realized this package and
      # ``command -v python3`` still answered out of the user's Scoop
      # shims — precisely the out-of-band resolution a declared toolchain
      # exists to remove, and invisible in practice because the wrong
      # python usually works.
      executableAlias = "python3.exe",
      packageId = "python@3.12.10",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:python@3.12.10:sha256:4acbed6dd1c744b0376e3b1cf57ce906f9dc9e95e68824584c8099a63025a3c3",
      version = "3.12.10"
    # Linux x86_64: python.org does NOT publish a Linux "embeddable"
    # equivalent of the Windows python-X.Y.Z-embed-amd64.zip. Use the
    # astral-sh/python-build-standalone install_only tarball as the
    # Linux counterpart — same source `python_dev.nim` consumes; ships
    # the interpreter plus the full Lib/ tree under a top-level `python/`
    # directory.
    #
    # The declared executable is `python/bin/python3.12`, the one regular
    # file. `python/bin/python3` (and `python`) are relative symlinks to
    # it, and tarball realization refuses a declared executable reached
    # through a symlink. `python3` is still on PATH: it sits beside the
    # declared file in the same `bin/` directory.
    tarball url = "https://github.com/astral-sh/python-build-standalone/releases/download/20260610/cpython-3.12.13+20260610-x86_64-unknown-linux-gnu-install_only.tar.gz",
      sha256 = "c218f50baeb2c06a30c2f03db5986b2bad6ab7c8a52faad2d5a59bda0677b93a",
      archiveType = "tar.gz",
      executablePath = "python/bin/python3.12",
      packageId = "python@3.12.13+20260610",
      cpu = "x86_64",
      os = "linux",
      lockIdentity = "tarball:python@3.12.13+20260610:linux:sha256:c218f50baeb2c06a30c2f03db5986b2bad6ab7c8a52faad2d5a59bda0677b93a",
      version = "3.12.13+20260610"
    # macOS aarch64: same astral-sh/python-build-standalone install_only
    # tarball as the Linux entry (and the one `python_dev.nim` consumes
    # for its macOS aarch64 realization) — native Apple Silicon build, with the
    # same layout, so the same `python3.12` declaration applies for the
    # same reason.
    tarball url = "https://github.com/astral-sh/python-build-standalone/releases/download/20260610/cpython-3.12.13+20260610-aarch64-apple-darwin-install_only.tar.gz",
      sha256 = "e18ddd4c1e8f4a1d6c4590b37f423d76aec734447edc20ed08e93983d95f2132",
      archiveType = "tar.gz",
      executablePath = "python/bin/python3.12",
      packageId = "python@3.12.13+20260610",
      cpu = "aarch64",
      os = "macos",
      lockIdentity = "tarball:python@3.12.13+20260610:macos-aarch64:sha256:e18ddd4c1e8f4a1d6c4590b37f423d76aec734447edc20ed08e93983d95f2132",
      version = "3.12.13+20260610"
    # GM4b: archive realizations formerly held by the retired
    # `VersionedProvisioning` catalog record (see the conflict notes
    # in the Gradual-Nix-To-Reprobuild-Migration GM4b milestone).
    tarball url = "https://www.python.org/ftp/python/3.14.5/python-3.14.5-amd64.exe",
      sha256 = "f9c09f5ed6f796fd1a8bc5ddfa41715a494b453c4781f0e35d5077cf9fa58f6d",
      archiveType = "installer-nsis",
      executablePath = "python.exe",
      version = "3.14.5",
      packageId = "python3@3.14.5",
      installMethod = "installer-nsis-bundle",
      extractPath = "SourceDir",
      cpu = "x86_64",
      os = "windows"
    tarball url = "https://www.python.org/ftp/python/3.14.5/python-3.14.5-arm64.exe",
      sha256 = "f4a7df6ab4fa375cd7296127ff6b9a14fbd1313f51864ce020185deba10144fa",
      archiveType = "installer-nsis",
      executablePath = "python.exe",
      version = "3.14.5",
      packageId = "python3@3.14.5",
      installMethod = "installer-nsis-bundle",
      extractPath = "SourceDir",
      cpu = "aarch64",
      os = "windows"

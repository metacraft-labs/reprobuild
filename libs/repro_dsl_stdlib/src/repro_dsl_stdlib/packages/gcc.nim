## M68 merge note (hand-edited): the auto-generated ``gccCatalog`` body
## sits below the pre-existing ``package gcc:`` DSL block. The DSL
## block remains the source of truth for the GCC CLI surface and the
## Nix provisioning shape on Nix-capable hosts; the ``gccCatalog``
## slice is consumed by the M64 ``cakBuiltin`` adapter on Windows.
## Re-harvest emits ONLY the catalog half; re-attach the DSL block
## by hand if you regenerate.
##
## **Known M69 realize-time gaps.** The catalog tracks the
## nuwen.net ``components-20.0.7z`` distribution, which (a) is a 7z
## archive — M64's cakBuiltin currently raises ``EBuiltinExtractFailed``
## on ``afSevenZip``; and (b) requires a ``pre_install`` PowerShell
## hook that expands ``binutils-*.7z`` and ``mingw-w64+gcc.7z``
## (themselves contained inside the outer 7z) before any binary is
## usable. The harvester silently drops the hook, so a freshly-realized
## prefix will surface ``components-20.0/`` but no ``bin/gcc.exe``.
## ``--bin-default gcc=gcc.exe,g++.exe,gfortran.exe`` records the
## end-state binary names; M69 needs a nested-7z extractor + a
## ``pre_install`` hook runner for this catalog to realize.

import std/tables
import repro_project_dsl
import repro_dsl_stdlib/packages_schema
export packages_schema

# ---------------------------------------------------------------------------
# Pre-existing M21 DSL declaration (CLI surface + Nix provisioning).
# ---------------------------------------------------------------------------

package gcc:
  provisioning:
    nixPackage "nixpkgs#gcc", executablePath = "bin/gcc",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

  executable gcc:
    cli:
      dependencyPolicy automaticMonitor

      call:
        boolFlag pic is bool, alias = "-fPIC"
        boolFlag debug3 is bool, alias = "-g3"
        boolFlag compileOnly is bool, alias = "-c"
        flag includes is seq[string],
          alias = "-include",
          role = input,
          repeated = true
        flag output is string,
          alias = "-o",
          role = output,
          required = true
        pos source is string,
          role = input,
          position = 0

# ---------------------------------------------------------------------------
# M68 bulk-harvest catalog (cakBuiltin adapter consumer on Windows).
# Harvested from bucket: ScoopInstaller/Main
# Versions (newest-first): 15.2.0
# ---------------------------------------------------------------------------

let gccCatalog* = @[
  VersionedProvisioning(
    version: "15.2.0",
    archive_format: afSevenZip,
    install_method: imExtract,
    bin_relpath: @["bin/gcc.exe", "bin/g++.exe", "bin/gfortran.exe"],
    platforms: @[
      PlatformBinary(cpu: pcX86_64, os: poWindows, url: "https://nuwen.net/files/mingw/components-20.0.7z", sha256: "561d873b7f95dbb39a34b7ab00050dc6028808310a847721a8aea5e5b0bff1c9", sha512: "", extract_path: "components-20.0")
    ],
    installer_args: @[],
    pacman_packages: @[],
    bootstrap_argv: @[],
    env: {"CPLUS_INCLUDE_PATH": "${prefix}\\include", "C_INCLUDE_PATH": "${prefix}\\include"}.toTable())
]

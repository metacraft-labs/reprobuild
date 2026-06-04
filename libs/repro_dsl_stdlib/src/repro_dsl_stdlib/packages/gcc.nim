## M68 merge note (hand-edited): the auto-generated ``gccCatalog`` body
## sits below the pre-existing ``package gcc:`` DSL block. The DSL
## block remains the source of truth for the GCC CLI surface and the
## Nix provisioning shape on Nix-capable hosts; the ``gccCatalog``
## slice is consumed by the M64 ``cakBuiltin`` adapter on Windows.
## Re-harvest emits ONLY the catalog half; re-attach the DSL block
## by hand if you regenerate.
##
## **M3 update (Realize-Closure-And-Catalog-Expansion spec).** The
## previously-documented M69 realize-time gaps for gcc closed via M3:
## the harvester now emits ``nested_7z = true`` on the platform slice
## AND an allowlisted ``pre_install_actions`` list capturing the two
## ``Expand-7zArchive`` invocations (binutils + mingw-w64+gcc). The
## remaining ``Get-ChildItem | Remove-Item -Recurse -Force`` pipeline
## lands in ``pre_install_unrecognized`` (pipelines are out of the
## allowlist), but the nested_7z + the recursive extract pass remove
## the inner archives anyway — the unrecognized line is a NO-OP
## post-extraction, so the operator's only observable effect is the
## one ``WPreInstallUnrecognized`` stderr warning at apply time.
##
## **Hand-edited bin_relpath divergence from the harvester.** The
## harvester (driven by ``--bin-default gcc=gcc.exe,g++.exe,gfortran.exe``)
## emits all three binaries. nuwen.net's components-20.0 distribution
## ships gcc + g++ + binutils (as, ld, gcc-ar, gcc-nm, gcc-ranlib, etc.)
## but does NOT ship a Fortran front-end. M3 live smoke verified the
## bin/ tree carries gcc.exe + g++.exe + as.exe + ld.exe — and
## ``gcc.exe --version`` returns ``(GCC) 15.2.0`` cleanly. We drop
## ``bin/gfortran.exe`` from the catalog so the realize loop's
## bin-existence sanity check passes. Operators who need Fortran
## should harvest the winlibs ``components-mingw-w64-msvcrt-13.0.0-rev3``
## (or newer) variant which DOES bundle a Fortran front-end.

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

        # Named-Targets M0: ``-o`` is the primary output, exposed as
        # ``output`` in the typed-tool wrapper. M1 reads this to assign
        # an implicit target name to each compile edge.
        outputs output

# ---------------------------------------------------------------------------
# M3-extended bulk-harvest catalog (cakBuiltin adapter consumer on Windows).
# Harvested from bucket: ScoopInstaller/Main
# Versions (newest-first): 15.2.0
# ---------------------------------------------------------------------------

let gccCatalog* = @[
  VersionedProvisioning(
    version: "15.2.0",
    archive_format: afSevenZip,
    install_method: imExtract,
    bin_relpath: @["bin/gcc.exe", "bin/g++.exe"],
    platforms: @[
      PlatformBinary(cpu: pcX86_64, os: poWindows, url: "https://nuwen.net/files/mingw/components-20.0.7z", sha256: "561d873b7f95dbb39a34b7ab00050dc6028808310a847721a8aea5e5b0bff1c9", sha512: "", sha1: "", extract_path: "components-20.0", nested_7z: true)
    ],
    installer_args: @[],
    pacman_packages: @[],
    bootstrap_argv: @[],
    env: {"CPLUS_INCLUDE_PATH": "${prefix}\\include", "C_INCLUDE_PATH": "${prefix}\\include"}.toTable(),
    pre_install_actions: @[
      PreInstallAction(kind: piaExpand7z, source: "$dir\\binutils-*.7z", target: "$dir", recurse: false, literal: ""),
      PreInstallAction(kind: piaExpand7z, source: "$dir\\mingw-w64+gcc.7z", target: "$dir", recurse: false, literal: "")
    ],
    pre_install_unrecognized: @["Get-ChildItem \"$dir\\*.7z\" | Remove-Item -Recurse -Force"])
]

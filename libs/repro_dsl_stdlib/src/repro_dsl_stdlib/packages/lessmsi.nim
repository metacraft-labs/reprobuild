## M4 (Realize-Closure-And-Catalog-Expansion spec) — ``lessmsi``
## catalog entry. The cakBuiltin MSI realize hook's actual extractor.
##
## **Why not WiX dark.exe (as the M4 spec text originally chose).**
## M4 live-smoke against the upstream meson MSI revealed that WiX v3's
## ``dark.exe`` is the **wrong tool** for the "extract MSI to a usable
## file tree" use case:
##
##   * ``dark.exe -x <outdir> <msi>`` extracts the MSI's *internal
##     payload streams* as numbered/UUID-named files under ``File/``
##     and ``Binary/`` subdirectories — NOT at the MSI's logical
##     install hierarchy (``Program Files\Vendor\App\bin\tool.exe``).
##     The output is intended for *MSI decompilation* (recovering the
##     WiX source), not for the install-time file tree.
##   * Mapping ``File/<uuid>`` → ``<vendor>\<product>\<bin>\tool.exe``
##     would require parsing the decompiled WiX source's File +
##     Directory tables, which is a substantial additional layer and
##     redundant with what lessmsi already implements.
##
## ``lessmsi`` is the canonical Windows-native tool for "extract an
## MSI to a real file tree": single-zip distribution (~3MB; MIT
## licensed; Scoop main carries it as ``main/lessmsi``), CLI shape
## ``lessmsi x <msi> <outdir>/`` writes files under
## ``<outdir>/SourceDir/<MSI's install hierarchy>/`` (e.g.
## ``meson/SourceDir/PFiles64/Meson/meson.exe``). The catalog's
## ``extract_path`` field bridges from the prefix root to the
## per-tool inner subtree (``SourceDir/PFiles64/Meson`` for meson).
##
## **Discovery contract** (per the M4 ``discoverLessmsiExe`` order):
## the cakBuiltin MSI realize loop probes the M4 store FIRST for a
## ``lessmsi``-registered prefix containing ``lessmsi.exe`` at the
## prefix root. Falls back to PATH ``lessmsi.exe`` (host Scoop
## install) and finally raises ``EBuiltinLessmsiUnavailable``.

import std/tables
import repro_dsl_stdlib/packages_schema
export packages_schema

let lessmsiCatalog* = @[
  VersionedProvisioning(
    version: "2.12.9",
    archive_format: afZip,
    install_method: imExtract,
    bin_relpath: @["lessmsi.exe"],
    platforms: @[
      PlatformBinary(cpu: pcAny, os: poWindows,
        url: "https://github.com/activescott/lessmsi/releases/download/v2.12.9/lessmsi-v2.12.9.zip",
        sha256: "5b4e187e74b184ad3a63ccf06c3d17dae2b8c4b6c298a996dbd51a9f6db29d21",
        sha512: "", sha1: "", extract_path: "")
    ],
    installer_args: @[],
    pacman_packages: @[],
    bootstrap_argv: @[],
    env: initTable[string, string]())
]

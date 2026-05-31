## M4 (Realize-Closure-And-Catalog-Expansion spec) — WiX Toolset v3
## catalog entry. **Hand-authored** rather than harvested from a Scoop
## bucket because:
##
##   * Scoop's ``main/wixtoolset`` ships WiX **v7** (NuGet ``.nupkg``
##     package; v7's ``wix.exe`` is a unified tool that does NOT carry
##     a stand-alone ``dark.exe`` decompiler — WiX dropped the dedicated
##     ``dark`` binary in the v4 rewrite); not useful for the M4 MSI
##     extraction hook.
##   * No Scoop bucket carries WiX v3 as of M4 (the last v3 release was
##     v3.14, March 2024, and WiX moved to v4/v5/v6/v7 since); the
##     upstream project's GitHub releases page is the only first-party
##     source.
##
## Instead this entry harvests the upstream **official WiX v3.14
## binaries zip** ``wix314-binaries.zip`` directly from
## ``github.com/wixtoolset/wix3/releases/tag/wix3141rtm``. That archive:
##
##   * is a single .zip carrying every WiX v3 tool at the archive root
##     (``dark.exe``, ``candle.exe``, ``light.exe``, ``heat.exe``, …)
##     — fits cakBuiltin's M64 baseline ``afZip + imExtract`` path
##     without any new dispatch surface;
##   * ships ``dark.exe`` — the WiX decompiler — which the M4 MSI
##     realize hook uses to turn an ``.msi`` into a file tree without
##     running the installer's side effects (no registry writes, no
##     COM registration, no Add/Remove entry);
##   * is the canonical WiX v3 distribution shape (this is what the
##     legacy WiX v3 documentation links to and what the bulk of MSI-
##     extraction tooling on the internet targets);
##   * has zero installer footprint (no MSI, no registry writes).
##
## **License**: Microsoft Reciprocal License (MS-RL). The reprobuild
## distribution does NOT redistribute the WiX binaries — this catalog
## file only carries the upstream URL + sha256. The operator's host
## fetches WiX v3.14 from the upstream GitHub release at realize time.
##
## **Discovery contract** (per the M4 ``discoverDarkExe`` order):
## the cakBuiltin MSI realize loop probes the M4 store FIRST for a
## ``wix3``-registered prefix containing ``dark.exe`` at the prefix
## root. Falls back to PATH ``dark.exe`` (Scoop wix3 historical install,
## Chocolatey wix.portable, manual install) and finally raises
## ``EBuiltinDarkUnavailable``.
##
## **Bootstrap-order**: this catalog is hand-authored pre-M7 (M7 adds
## ``--source gh-releases:`` to the harvester). After M7, re-harvest
## via ``repro_catalog_harvester harvest --source
## gh-releases:wixtoolset/wix3``. The hand-authored entry is correct
## in the catalog-as-source-of-truth sense; the harvester replay just
## makes the provenance walkable.
##
## **Operator-visible consequences of the hand-authored shape**: the
## harvester's ``verify`` subcommand will report DRIFT against this
## hand-author until M7 (or until a Scoop bucket adopts WiX v3 again).
## That drift is EXPECTED.

import std/tables
import repro_dsl_stdlib/packages_schema
export packages_schema

let wix3Catalog* = @[
  VersionedProvisioning(
    version: "3.14.1",
    archive_format: afZip,
    install_method: imExtract,
    bin_relpath: @["dark.exe"],
    platforms: @[
      PlatformBinary(cpu: pcAny, os: poWindows,
        url: "https://github.com/wixtoolset/wix3/releases/download/wix3141rtm/wix314-binaries.zip",
        sha256: "6ac824e1642d6f7277d0ed7ea09411a508f6116ba6fae0aa5f2c7daa2ff43d31",
        sha512: "", sha1: "", extract_path: "")
    ],
    installer_args: @[],
    pacman_packages: @[],
    bootstrap_argv: @[],
    env: initTable[string, string]())
]

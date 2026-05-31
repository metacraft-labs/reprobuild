## M3 (Realize-Closure-And-Catalog-Expansion spec) — 7-Zip catalog
## entry. **Hand-authored** rather than harvested from the Scoop
## ``main/7zip`` bucket because the upstream manifest currently ships
## the 64-bit and 32-bit variants as ``.msi`` installers (which would
## require the M4 MSI-realize hook — out of M3 scope per the campaign's
## "no MSI in M3" honest scope rule). The arm64 variant ships as a
## pre_install-bootstrapped ``.exe`` whose bootstrap helper itself
## requires an already-installed 7zr.exe — a chicken-and-egg.
##
## Instead this entry harvests the upstream **official standalone
## console binary** ``7zr.exe`` directly from
## ``github.com/ip7z/7zip/releases``. That binary:
##   * is a single .exe (afRaw + imExtract) — fits cakBuiltin's M64
##     baseline extraction without any new dispatch surface;
##   * speaks the same ``7z x`` / ``7z a`` / ``7z l`` CLI cakBuiltin's
##     M3 7z-family realize hooks invoke;
##   * supports both raw .7z and SFX-wrapped .7z (transparently);
##   * has zero installer footprint (no MSI, no registry writes, no
##     filesystem side effects beyond the single .exe);
##   * is the same binary the upstream project ships AS the bootstrap
##     for installing the full 7zip suite (the Scoop arm64 pre_install
##     downloads exactly this file).
##
## **Operator-visible consequences of the hand-authored shape**:
##   * Re-harvesting via ``repro_catalog_harvester harvest --app 7zip
##     --bucket ScoopInstaller/Main`` would clobber this file with the
##     MSI shape that does not realize under M3. The harvester's
##     ``verify`` subcommand will report DRIFT against this hand-author;
##     that drift is EXPECTED and the M3 reviewer documents it as a
##     known-OK divergence until the M4 MSI-realize hook lands.
##   * Once M4 ships MSI realize, the operator can choose: re-harvest
##     to the upstream MSI shape (full 7zip suite — File Manager + GUI
##     + plugins) OR keep the hand-authored 7zr.exe shape (smaller,
##     CLI-only, exact bootstrap surface). Both options will work
##     post-M4.
##
## **Discovery contract** (per the M3 ``discoverSevenZipExe`` order):
## the cakBuiltin realize loop probes the M3 store FIRST for a
## ``7zip``-registered prefix containing ``bin/7z.exe``. This file
## emits ``bin/7z.exe`` (renamed-by-relpath from the upstream
## ``7zr.exe`` filename) so the lookup is hit even on hosts whose
## ``PATH`` lacks 7z entirely.

import std/tables
import repro_dsl_stdlib/packages_schema
export packages_schema

let sevenzipCatalog* = @[
  VersionedProvisioning(
    version: "26.01",
    archive_format: afRaw,
    install_method: imExtract,
    bin_relpath: @["bin/7z.exe"],
    platforms: @[
      PlatformBinary(cpu: pcX86_64, os: poWindows,
        url: "https://github.com/ip7z/7zip/releases/download/26.01/7zr.exe",
        sha256: "abcf64ae1cbafddb5395e4cdd3bdc7e3e0561d54a0c6380e3dd43bdbffe519a2",
        sha512: "", sha1: "", extract_path: "")
    ],
    installer_args: @[],
    pacman_packages: @[],
    bootstrap_argv: @[],
    env: initTable[string, string]())
]

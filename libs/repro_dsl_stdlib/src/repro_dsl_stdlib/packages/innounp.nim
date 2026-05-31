## M4 (Realize-Closure-And-Catalog-Expansion spec) — Inno Setup
## Unpacker (``innounp``) catalog entry. Provides the ``innounp.exe``
## binary the M4 ``imInstallerInnoSetup`` realize hook needs to extract
## the contents of an Inno-Setup-built installer (the freepascal/fpc
## shape, marked by ``innosetup: true`` in the upstream Scoop manifest).
##
## **innounp vs innoextract**: per the spec's Outstanding Tasks note,
## M4 picks ONE of:
##   * ``innounp`` (Inno Setup Unpacker, Andrey Shtchiglov + Jens
##     Rathlev's GUI fork; **GPL-3.0**, Windows-native, 1.7 MB single
##     .exe — matches the Scoop convention; the few Inno-Setup-shipped
##     tools in the M71 catalog set are all Windows-targeted);
##   * ``innoextract`` (Daniel Scharrer; **Zlib**, cross-platform C++;
##     the Linux-portable choice if M9-style Linux validation ever
##     needs to read an Inno installer on Linux).
##
## M4 picks ``innounp`` (matches Scoop convention; smaller; aligns
## with the Windows-only target set). If a future milestone needs Linux
## Inno extraction, ``packages/innoextract.nim`` can be added alongside
## as a peer catalog without removing this entry.
##
## **License note**: the M4 catalog records the GPL-3.0 license in this
## docstring (not in the catalog entry — the M63 schema does not have a
## license field yet; M11+ may add one). The GPL applies to ``innounp.exe``
## itself; reprobuild does NOT redistribute the binary — the catalog
## file only carries the upstream URL + sha256. The operator's host
## fetches innounp from the upstream GitHub mirror at realize time.
##
## **Source**: this catalog is **hand-authored from the upstream
## InnoUnpacker-Windows-GUI GitHub mirror**
## (``raw.githubusercontent.com/jrathlev/InnoUnpacker-Windows-GUI``).
## That repo's ``innounp-2/bin/innounp-2.zip`` ships the latest
## innounp v2.x binary. The sha256 below was computed via a one-shot
## ``certutil -hashfile`` against the live mirror download (M4
## bootstrap pre-M7); re-verify via the same command before
## upgrading the version pin.
##
## **Bootstrap-order note**: Scoop main DOES carry ``innounp`` as
## of M4 (the Scoop ``main/innounp.json`` manifest also pins
## ``innounp-2/bin/innounp-2.zip`` with the same sha256). M4 still
## hand-authors this catalog because:
##   (i)  the harvester's existing Scoop path emits ``imExtract``
##        (afZip) — perfectly correct for ``innounp`` — but the
##        docstring header note about "innounp is the cakBuiltin
##        EXTRACTOR for the Inno-Setup family realize hook" needs to
##        survive a re-harvest (per the M3 sevenzip + M1 fpc pattern
##        of merge-note docstrings);
##   (ii) M4 lands the catalog without making the operator add a
##        ``scoop bucket add main`` invocation as a prerequisite.
##
## A later milestone may re-harvest from Scoop and reattach this
## docstring; the entry's bytes (URL + sha256) match Scoop's exactly.
##
## **M7 re-harvest option (post-M7)**: ``jrathlev/InnoUnpacker-Windows-GUI``
## DOES publish GitHub releases (tagged ``ui_2_2_9``, ``iu_2_2_8``, …)
## that ship ``innounp-2.zip`` as a release asset with the SAME bytes
## (sha256 ``1439f8d9...``) as the master-branch raw file this catalog
## currently links to, and the asset's ``digest`` field already carries
## that sha256. A re-harvest via
##   ``repro_catalog_harvester harvest \
##      --source gh-releases:jrathlev/InnoUnpacker-Windows-GUI \
##      --asset-pattern 'innounp-2\.zip' \
##      --bin-relpath innounp.exe --output-app innounp``
## would emit a working catalog (same bytes, different URL —
## ``releases/download/ui_2_2_9/innounp-2.zip`` instead of the master-
## branch raw path). The catalog is kept hand-authored because:
##   (i)  the release tag scheme (``ui_2_2_9`` for "Inno Unpack GUI
##        2.2.9", versioning the GUI front-end) doesn't map to this
##        catalog's ``2.67.9`` version (which tracks the bundled
##        ``innounp.exe`` itself, named in the release body) via a
##        single ``--version-extract`` regex;
##   (ii) the docstring above ("innounp is the cakBuiltin EXTRACTOR for
##        the Inno-Setup-family realize hook" + the innounp-vs-innoextract
##        rationale) needs to survive a re-harvest. A future milestone
##        may add a ``--version-override`` flag or a per-source mapping
##        table that lets the harvester re-emit while preserving the
##        version field; in the meantime, the bytes match upstream and
##        re-verification is one ``certutil -hashfile`` away.
##
## **Discovery contract** (per the M4 ``discoverInnounpExe`` order):
## the cakBuiltin Inno Setup realize loop probes the M4 store FIRST
## for an ``innounp``-registered prefix containing ``innounp.exe`` at
## the prefix root. Falls back to PATH ``innounp.exe`` (host Scoop
## install, manual install) and finally raises
## ``EBuiltinInnounpUnavailable``.

import std/tables
import repro_dsl_stdlib/packages_schema
export packages_schema

let innounpCatalog* = @[
  VersionedProvisioning(
    version: "2.67.9",
    archive_format: afZip,
    install_method: imExtract,
    bin_relpath: @["innounp.exe"],
    platforms: @[
      PlatformBinary(cpu: pcAny, os: poWindows,
        url: "https://raw.githubusercontent.com/jrathlev/InnoUnpacker-Windows-GUI/refs/heads/master/innounp-2/bin/innounp-2.zip",
        sha256: "1439f8d9e24b19e7d0b31b9c427ba4533387522a370c39280f17d3371eb7febf",
        sha512: "", sha1: "", extract_path: "")
    ],
    installer_args: @[],
    pacman_packages: @[],
    bootstrap_argv: @[],
    env: initTable[string, string]())
]

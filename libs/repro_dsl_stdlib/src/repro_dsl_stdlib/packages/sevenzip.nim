## M8 (Realize-Closure-And-Catalog-Expansion spec) — 7-Zip archive
## realization. REPLACED the M3 hand-authored standalone-7zr bootstrap with
## the harvested Scoop ``7zip`` MSI manifest. The MSI ships the full
## 7-Zip distribution (CLI + GUI + plugins including the zstd codec —
## closes a follow-up from M6's MSYS2 .zst extraction).
##
## **Re-harvest command (for byte-equal verify):**
##   repro_catalog_harvester harvest --bucket ScoopInstaller/Main \
##     --app 7zip --app-alias 7zip=sevenzip \
##     --output-dir libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/
##
## **Post-harvest hand-edit** (per the M4 lessmsi convention also used
## by ``packages/meson.nim`` and ``packages/python3.nim``): the
## ``extractPath`` for the x86_64 MSI is bumped from
## ``Files\7-Zip`` (Scoop's manifest, correct under msiexec /a) to
## ``SourceDir\Files\7-Zip`` so the M4 lessmsi extractor flow
## (``<destDir>\SourceDir\<MSI install path>\``) resolves cleanly.
## See ``packages/lessmsi.nim`` for the rationale.
##
## **Discovery contract**: the M8 ``discoverSevenZipExe`` probes
## ``<prefix>\bin\7z.exe`` first (M3 hand-author + synthetic test
## seeds) THEN ``<prefix>\7z.exe`` at the root (M8 MSI shape — after
## lessmsi flattens ``SourceDir\Files\7-Zip`` the binary lands at
## ``<prefix>\7z.exe``). Both paths must continue to resolve.
##
## **Operator-visible consequence**: the standalone 7zr.exe is gone.
## Operators relying on M3's ``bin/7z.exe`` shape (e.g. operators who
## seeded a synthetic ``7zip`` prefix in tests) must either rename to
## the MSI shape or accept that synthetic tests stay on the bin/
## probe path (the M8 discovery extension keeps that working).
##
## **arm64 record**: the harvest also carries an arm64
## platform whose URL is the upstream ``7z2601-arm64.exe`` self-
## extractor. This is the Scoop ``pre_install`` path; the M4 NSIS
## family-hook can extract it but the operator's machine is x86_64
## so this realization is not LIVE-validated in M8. The realization stays for
## future cross-arch work.

## Archive realizations harvested by tools/catalog-harvester. GM4b: the
## harvester emits ``tarball`` statements, which live in the hand-maintained
## ``package`` block below; merge a re-harvest into it.
## Harvested from bucket: ScoopInstaller/Main
## Versions (newest-first): 26.01

import repro_project_dsl
import repro_dsl_stdlib/packages_schema
export packages_schema

# GM4b: the registry key and the extractor provider name are ``7zip``, but
# the package macro cannot declare that name — `7zip` does not lex, and
# `` `7 zip` `` lexes but the macro then emits ``7zip`` as a type/value
# identifier and the generated code fails to parse. The package is
# therefore declared as ``sevenzip`` (its module name); mapping ``7zip`` to
# it is the registry's job.
package sevenzip:
  platforms [windows], msg = "This entry is the Windows 7-Zip distribution used by the realize closure. p7zip exists on POSIX but is a DIFFERENT package with a different provisioning shape; catalogue it separately rather than widening this entry."
  provisioning:
    tarball url = "https://github.com/ip7z/7zip/releases/download/26.01/7z2601-x64.msi",
      sha256 = "a47ea8dcf8bc08e6de474cae77c828e031fa22cb528f6095defffebf11cd02f2",
      archiveType = "installer-msi",
      executablePath = "7z.exe",
      extraExecutable = "7zG.exe",
      extraExecutable = "7zFM.exe",
      version = "26.01",
      packageId = "7zip@26.01",
      installMethod = "installer-msi",
      extractPath = "SourceDir\\Files\\7-Zip",
      cpu = "x86_64",
      os = "windows"
    tarball url = "https://github.com/ip7z/7zip/releases/download/26.01/7z2601-arm64.exe",
      sha256 = "1fecf4e3407950939c8ffcc3e42e3039821997dea155301c75369474e5f15175",
      archiveType = "installer-msi",
      executablePath = "7z.exe",
      extraExecutable = "7zG.exe",
      extraExecutable = "7zFM.exe",
      version = "26.01",
      packageId = "7zip@26.01",
      installMethod = "installer-msi",
      cpu = "aarch64",
      os = "windows"

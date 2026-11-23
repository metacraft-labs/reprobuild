## Archive realizations harvested by tools/catalog-harvester. GM4b: the
## harvester emits ``tarball`` statements, which live in the hand-maintained
## ``package`` block below; merge a re-harvest into it.
## Harvested from bucket: ScoopInstaller/Main
## Versions (newest-first): 28.5
##
## **M3 LIVE-smoke status (Realize-Closure-And-Catalog-Expansion spec).**
## The M3 spec text predicted erlang would unblock via the basic
## ``7z`` dispatch ("7z auto-detects NSIS-wrapped 7z"). The
## live smoke against the upstream ``otp_win64_28.5.exe`` artifact
## refuted that prediction — 7z reports ``Cannot open the file as
## [7z] archive`` on the downloaded bytes. The upstream installer is
## a *true* NSIS installer (not a 7z-with-NSIS-stub the way Git-for-
## Windows ships); the ``#/dl.7z`` Scoop rename is metadata-only and
## does NOT change the file's on-disk structure.
##
## **M4 amendment**: install method flipped to ``installer-nsis-bundle``
## so the home archive realizer dispatches through the M4 dark.exe
## (Burn outer unwrap) + 7z (fallback) + lessmsi (per-MSI extract)
## sandwich. **LIVE smoke status: STILL BLOCKED.** dark.exe rejects
## the OTP installer with ``DARK0339: Stub executable does not contain
## a .wixburn data section.`` (i.e. OTP is NOT a Burn bundle — it's a
## bona-fide NSIS installer using the modern NSIS installer format that
## the standalone 7zr.exe carried by ``packages/sevenzip.nim`` does NOT
## handle (7zr is the "Reduced 7z" — supports only .7z and .lzma;
## requires the FULL 7-Zip distribution to crack NSIS).
##
## **Root cause**: the M3 ``packages/sevenzip.nim`` chose the
## standalone ``7zr.exe`` for bootstrap simplicity (no MSI dep).
## The full 7-Zip ships as an MSI on Windows main — which now (post-M4)
## CAN be extracted via lessmsi but requires re-harvesting the
## sevenzip realization with archive type and install method
## ``installer-msi``.
##
## **M8 (Realize-Closure-And-Catalog-Expansion spec) status update:**
## the M8 sevenzip re-harvest is DONE — ``packages/sevenzip.nim`` now
## ships the full 7-Zip 26.01 distribution. LIVE-validated (manual
## probe): ``7z.exe x otp_win64_28.5.exe`` extracts the OTP payload
## cleanly (detects the file as PE/NSIS, dumps the inner tree with
## ``erts-<ver>/bin/erl.exe`` runnable end-to-end — ``erl -version``
## returns the BEAM emulator version). **The 7z-capability blocker
## the M3/M4 docstring above predicted is GONE.**
##
## **M11 (Realize-Closure-And-Catalog-Expansion spec) closes the
## carryover:** the M8-flagged "current catalog dispatches through the
## Burn/MSI sandwich and dark.exe rejects OTP with ``DARK0339``" is
## fixed by:
##   1. a new ``installer-nsis`` (plain NSIS) install-method enum
##      variant in ``packages_schema.nim`` that dispatches to
##      ``extract7z`` directly on the .exe payload (no dark, no
##      lessmsi, no per-MSI sandwich);
##   2. the dispatch case in ``builtin_adapter.nim`` (mirror the
##      ``extract + 7z`` shape — the full 7-Zip 26.01
##      MSI re-harvest from M8 transparently understands the modern
##      NSIS installer envelope);
##   3. the declared executable list update below from ``bin\\erl.exe`` to
##      ``erts-16.4\\bin\\erl.exe`` matching the actual OTP layout
##      (``erts-<ver>/bin/erl.exe``). **Empirical correction**: the
##      M8 retro hypothesized OTP 28.x ships ``erts-16.x`` matching
##      the OTP minor version (28.5 → 16.5). The 2026-06-01 live
##      probe of the actual installer (``7z l otp_win64_28.5.exe``)
##      shows the inner tree carries ``erts-16.4``, not 16.5 (erts
##      minor lags OTP minor by one in this release). OTP 28.5 also
##      DROPPED ``werl.exe`` (the legacy Windows GUI wrapper —
##      removed in OTP 26+; ``erl.exe`` is the canonical entry point
##      on modern Windows OTP releases). The executable list below
##      reflects the true layout: ``erts-16.4\\bin\\erl.exe`` +
##      ``erts-16.4\\bin\\erlc.exe`` + ``erts-16.4\\bin\\escript.exe``.
##
## LIVE-validated 2026-06-01 against the upstream
## ``otp_win64_28.5.exe`` artifact via a focused home.nim profile
## (single ``package(erlang, "28.5")``; host PATH 7z used via the M3
## ``discoverSevenZipExe`` Step ii fallback to side-step the
## 7zip/lessmsi pre-realize ordering issue in plan.nim's alphabetical
## sort). ``erl -version`` returns the BEAM emulator version. See
## the M11 LIVE smoke transcript in the campaign-close section of
## ``Realize-Closure-And-Catalog-Expansion.milestones.org``.
##
## **Honest scope continued**: the OTP installer historically writes
## a per-user ``vcredist*`` redistributable side-effect and a
## ``post_install`` ``Remove-Item $PLUGINSDIR vcredist*`` cleanup;
## neither would be exercised by the home archive realizer's NSIS-bundle hook even
## if the outer extraction worked (the M4 hook materializes the file
## tree only; vcredist would need a separate home archive realizer
## ``vcredist2022`` tarball realization per the Scoop ``suggest`` block).

import repro_project_dsl
import repro_dsl_stdlib/packages_schema
export packages_schema

package erlang:
  provisioning:
    tarball url = "https://github.com/erlang/otp/releases/download/OTP-28.5/otp_win64_28.5.exe",
      sha256 = "46f56351e2e67865c6aaff83bcd0a7d97d73bea643a0531774dd9ba8fbee7dc0",
      archiveType = "installer-nsis",
      executablePath = "erts-16.4\\bin\\erl.exe",
      extraExecutable = "erts-16.4\\bin\\erlc.exe",
      extraExecutable = "erts-16.4\\bin\\escript.exe",
      version = "28.5",
      packageId = "erlang@28.5",
      installMethod = "installer-nsis",
      env = "ERLANG_HOME=${prefix}",
      cpu = "x86_64",
      os = "windows"

## WiX Toolset v3 ``candle`` + ``light`` — the MSI producer's tools, as
## reprobuild packages.
##
## ``packages/wix3.nim`` already carries the WiX v3.14 upstream zip as a
## ``VersionedProvisioning`` **catalog** entry, consumed by the M4
## ``cakBuiltin`` MSI-realize hook to run ``dark.exe``. That entry is a
## catalog row, not a ``package`` block, so it cannot be the target of a
## build-graph ``uses:`` dependency and it exposes no typed CLI.
##
## Distribution-And-Packaging.md §6 rule 2 requires the MSI producer to
## take a REAL build-graph dependency on its tool. This module supplies
## that: two ``package`` blocks over the SAME upstream archive
## (``wix314-binaries.zip``, byte-identical url + sha256 to
## ``wix3.nim``'s catalog row, deliberately — the two must not drift),
## differing only in ``executablePath``.
##
## The one-executable-per-package split is the ``packages/binutils.nim``
## shape and is forced by the macro layer: the typed wrapper procs are
## emitted only when a ``package`` declares exactly one ``executable``.
##
## **Why WiX v3 and not v4+.** WiX v4 collapsed ``candle``/``light``
## into a single ``wix.exe`` distributed as a .NET tool via NuGet, which
## needs a .NET SDK on the host — a much larger and less hermetic
## dependency than a self-contained zip of native executables. v3.14 is
## the last release that ships as "unzip it and run it", which is what
## makes it expressible as an ordinary reprobuild tarball provisioning
## channel. WiX v3 also still carries ``ServiceInstall``/
## ``ServiceControl`` authoring, which is what makes a service-
## installing MSI expressible at all (Distribution-And-Packaging
## M1's "the three daemon roles' service units … Windows service").
##
## **Windows only, deliberately.** There is no Linux/macOS channel: WiX
## v3's tools are native PE executables. A Linux host asking for the
## WiX-backed MSI producer gets an unresolvable tool dependency, which
## §6.1 names as the correct and only mechanism for "this format is not
## available here" — the engine must not learn what an ``.msi`` is.
## A Linux-hosted MSI path is a *different producer* over a *different*
## tool package (msitools' ``wixl``); the format set being open is
## exactly what makes that a user-space addition rather than an engine
## change. See ``packaging/producers/msi.nim``.

import repro_project_dsl
# DSL-port M9.R.2c — typed slot vars for the ``executable`` blocks below.
import repro_dsl_stdlib/types/executable

const
  Wix3BinariesUrl* =
    "https://github.com/wixtoolset/wix3/releases/download/wix3141rtm/wix314-binaries.zip"
    ## Kept byte-identical to ``packages/wix3.nim``'s catalog row so the
    ## two provisioning surfaces over the same upstream archive can
    ## never disagree about which archive they mean.
  Wix3BinariesSha256* =
    "6ac824e1642d6f7277d0ed7ea09411a508f6116ba6fae0aa5f2c7daa2ff43d31"

package `wix-candle`:
  provisioning:
    # The upstream zip carries every WiX v3 tool at the archive ROOT
    # (no wrapper directory), so no ``stripComponents`` and the
    # executable path is the bare file name.
    tarball url = Wix3BinariesUrl,
      sha256 = Wix3BinariesSha256,
      archiveType = "zip",
      executablePath = "candle.exe",
      packageId = "wix3@3.14.1",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:wix3@3.14.1:sha256:" & Wix3BinariesSha256

  executable candleBin:
    cli:
      dependencyPolicy automaticMonitor

      call:
        boolFlag noLogo is bool, alias = "-nologo"
        flag arch is string,
          alias = "-arch",
          format = separate
        flag defines is seq[string],
          alias = "-d",
          format = concat,
          repeated = true
        flag extensions is seq[string],
          alias = "-ext",
          format = separate,
          repeated = true
        flag output is string,
          alias = "-out",
          format = separate,
          role = output,
          required = true
        pos sources is seq[string],
          position = 0,
          role = input,
          repeated = true

        outputs output

package `wix-light`:
  provisioning:
    tarball url = Wix3BinariesUrl,
      sha256 = Wix3BinariesSha256,
      archiveType = "zip",
      executablePath = "light.exe",
      packageId = "wix3@3.14.1",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:wix3@3.14.1:sha256:" & Wix3BinariesSha256

  executable lightBin:
    cli:
      dependencyPolicy automaticMonitor

      call:
        boolFlag noLogo is bool, alias = "-nologo"
        # ICE validation runs the produced database through the Windows
        # Installer service on the BUILD host. That makes the edge
        # depend on host state the engine cannot see or fingerprint, so
        # the producer suppresses it and treats validation as a
        # verification step run against the artifact, not as part of
        # producing it.
        boolFlag suppressValidation is bool, alias = "-sval"
        flag suppressWarnings is seq[string],
          alias = "-sw",
          format = concat,
          repeated = true
        flag extensions is seq[string],
          alias = "-ext",
          format = separate,
          repeated = true
        flag output is string,
          alias = "-out",
          format = separate,
          role = output,
          required = true
        pos objects is seq[string],
          position = 0,
          role = input,
          repeated = true

        outputs output

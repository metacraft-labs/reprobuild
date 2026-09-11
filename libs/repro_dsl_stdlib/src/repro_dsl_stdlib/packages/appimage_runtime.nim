## The AppImage **type-2 runtime** — the ELF stub an AppImage is made
## of, as a reprobuild package.
##
## An AppImage is not an archive with a header: it is this ~950 KB
## static ELF image with a squashfs filesystem concatenated onto it. The
## stub is what mounts that filesystem (through libfuse, or unpacks it
## when ``--appimage-extract-and-run`` is given) and execs ``AppRun``
## out of it. So it is the single most load-bearing byte-level input to
## an ``.AppImage``, and it is an input the PRODUCER has to supply.
##
## ## Why this is a package of its own rather than a flag
##
## ``appimagetool`` will happily produce an AppImage without being given
## a runtime. It does so **by downloading one over the network, from a
## tag that moves** — measured, in a container started ``--network
## none``::
##
##   Downloading runtime file from https://github.com/AppImage/
##       type2-runtime/releases/download/continuous/runtime-x86_64
##
## An unpinned network fetch inside a build action defeats content
## addressing outright: the same graph would produce different bytes on
## different days, and it would do so silently, because the fetch
## SUCCEEDS on any machine with a network. Declaring the runtime as a
## pinned package and passing ``--runtime-file`` is what turns that
## input into graph data. ``packaging/producers/appimage.nim`` then
## refuses the build if the runtime is not on its action's PATH, rather
## than letting appimagetool fall back to the download.
##
## ## Provisioning-only, no ``executable`` block
##
## Nothing invokes this file as a tool: appimagetool reads it. It is
## declared as a package purely so the resolver realizes it and puts its
## directory on the consuming action's PATH, the same job
## ``packages/gzip.nim`` does for the compressor ``tar -z`` forks.
##
## The file IS a real executable (it is the ELF stub, and running it
## directly prints the runtime's own usage), so ``executablePath`` is
## not a placeholder and the ``raw`` extractor's 0755 is not a lie —
## which matters, because the producer locates it with ``command -v``
## and ``command -v`` consults the executable bit.
##
## ## The pin
##
## ``AppImage/type2-runtime`` publishes dated release tags beside a
## moving ``continuous``. The dated one is pinnable; ``continuous`` is
## the thing this module exists to keep out of the build.

import repro_project_dsl

const
  AppImageRuntimeRelease* = "20251108"
    ## The dated upstream tag. Deliberately not ``continuous``: a moving
    ## tag behind a fixed sha256 is a pin that breaks rather than one
    ## that holds.
  AppImageRuntimeFileName* = "runtime-x86_64"
    ## Kept as the upstream asset's own name. The producer looks the
    ## file up by this name with ``command -v``, so the name is part of
    ## the contract between this module and
    ## ``packaging/producers/appimage.nim``.
  AppImageRuntimeUrl* =
    "https://github.com/AppImage/type2-runtime/releases/download/" &
    AppImageRuntimeRelease & "/" & AppImageRuntimeFileName
  AppImageRuntimeSha256* =
    "2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d"
    ## Measured with ``sha256sum`` over the downloaded asset on
    ## 2026-09-11 (944,632 bytes).

package `appimage-runtime`:
  provisioning:
    tarball url = AppImageRuntimeUrl,
      sha256 = AppImageRuntimeSha256,
      archiveType = "raw",
      executablePath = AppImageRuntimeFileName,
      packageId = "appimage-runtime@" & AppImageRuntimeRelease,
      cpu = "x86_64",
      os = "linux",
      lockIdentity = "tarball:appimage-runtime@" & AppImageRuntimeRelease &
        ":sha256:" & AppImageRuntimeSha256

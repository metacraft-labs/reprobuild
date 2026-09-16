## ``msys2-libevent`` — the libevent runtime tmux links against on Windows.
##
## Named for its DISTRIBUTION, not just its project: this is the MSYS2 build,
## whose DLLs carry the ``msys-`` prefix and are ABI-bound to the MSYS2 POSIX
## runtime. A libevent from anywhere else will not load into MSYS2's tmux, so
## the distribution is part of the package's identity rather than an
## implementation detail.
##
## **Consumed for its DLLs.** ``msys-event-2-1-7.dll`` and its siblings are
## what tmux needs; the declared member is ``event_rpcgen.py``, the one
## program the archive ships. That is not a workaround — it is the honest
## answer to "what executable does this package provide" — but a reader
## should know the package is named in ``uses:`` for the runtime beside it.
##
## MSYS2 packages are ``.pkg.tar.zst``; support for that archive type was
## added alongside this package, since nothing else in the catalog needed it.
##
## Digest matches the ``TMUX_LIBEVENT_SHA256_X86_64`` pin its consumer
## harvested independently.

import repro_project_dsl

const LibeventVersion = "2.1.12-4"

package `msys2-libevent`:
  provisioning:
    tarball url = "https://repo.msys2.org/msys/x86_64/libevent-" &
        LibeventVersion & "-x86_64.pkg.tar.zst",
      sha256 = "c2f087afa1718f5015086bd24afebe21423dbfce2525fd0b3a6b179825ee7904",
      archiveType = "tar.zst",
      executablePath = "usr/bin/event_rpcgen.py",
      packageId = "msys2-libevent@" & LibeventVersion,
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:msys2-libevent@" & LibeventVersion &
        ":windows-x86_64:sha256:c2f087afa1718f5015086bd24afebe21423dbfce2525fd0b3a6b179825ee7904"

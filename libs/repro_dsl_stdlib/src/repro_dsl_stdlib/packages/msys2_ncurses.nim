## ``msys2-ncurses`` — the ncurses runtime and terminfo database tmux needs
## on Windows.
##
## The MSYS2 build specifically, for the same ABI reason as
## ``msys2-libevent``: its ``msys-ncursesw6.dll`` is bound to the MSYS2 POSIX
## runtime.
##
## Ships real programs (``infocmp``, ``tic``, ``clear``, ``captoinfo``)
## alongside the runtime, so the declared member is an actual tool; ``tic``
## and ``infocmp`` are also what a terminal-behaviour test reaches for when
## it needs to inspect a terminfo entry.
##
## Digest matches the ``TMUX_NCURSES_SHA256_X86_64`` pin its consumer
## harvested independently.

import repro_project_dsl

const NcursesVersion = "6.6-1"

package `msys2-ncurses`:
  provisioning:
    tarball url = "https://repo.msys2.org/msys/x86_64/ncurses-" &
        NcursesVersion & "-x86_64.pkg.tar.zst",
      sha256 = "15748b99784cdafc4916c21f81a55d46b93f59b7c92840acc14ea7717df1c42f",
      archiveType = "tar.zst",
      executablePath = "usr/bin/infocmp.exe",
      packageId = "msys2-ncurses@" & NcursesVersion,
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:msys2-ncurses@" & NcursesVersion &
        ":windows-x86_64:sha256:15748b99784cdafc4916c21f81a55d46b93f59b7c92840acc14ea7717df1c42f"

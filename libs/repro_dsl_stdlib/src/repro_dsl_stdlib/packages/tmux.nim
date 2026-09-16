## ``tmux`` — the terminal multiplexer.
##
## **Windows has no native tmux.** Upstream targets POSIX, so on Windows the
## program runs on the MSYS2 POSIX layer and the MSYS2 package IS the
## upstream artifact. That has two consequences this recipe cannot hide:
##
##   1. The archive is a ``.pkg.tar.zst``, an MSYS2 format nothing else in
##      this catalog needed until now.
##   2. tmux does not run alone. It links ``msys-event-*`` and
##      ``msys-ncursesw6``, so ``msys2-libevent`` and ``msys2-ncurses`` must
##      be on PATH beside it. They are separate packages because MSYS2 ships
##      them as separate archives; a recipe that wants tmux on Windows names
##      all three.
##
##   The MSYS2 runtime itself (``msys-2.0.dll``) is NOT packaged here: Git
##   for Windows already ships it, and every host that can run this
##   environment's bash has it. That is a real assumption rather than an
##   oversight, and it is the same one the environment this replaces made.
##
## The version is an MSYS2 package version (``pkgver-pkgrel``), not upstream
## tmux's. Digest matches the ``TMUX_SHA256_X86_64`` pin its consumer
## harvested independently.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

const TmuxMsys2Version = "3.6.a-1"

package tmux:
  provisioning:
    nixPackage "nixpkgs#tmux", executablePath = "bin/tmux",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

    tarball url = "https://repo.msys2.org/msys/x86_64/tmux-" &
        TmuxMsys2Version & "-x86_64.pkg.tar.zst",
      sha256 = "873137dc39f54d3b86829c43878877ccd3ca642669a51641d6470d8caf28277c",
      archiveType = "tar.zst",
      executablePath = "usr/bin/tmux.exe",
      packageId = "tmux@" & TmuxMsys2Version,
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:tmux@" & TmuxMsys2Version &
        ":windows-x86_64:sha256:873137dc39f54d3b86829c43878877ccd3ca642669a51641d6470d8caf28277c"

import repro_project_dsl
# DSL-port M9.R.2c — typed slot var for ``executable makeBin:``.
import repro_dsl_stdlib/types/executable

# GNU make. On Nix it ships under bin/make.
#
# **M9.R.11 widening**: GNU make is reached by the from-source cycle-
# break path (``wayland → gcc → binutils → make``), so it needs a stdlib
# fall-through channel on Windows + non-Nix Linux. The tarball channel
# uses the upstream ftp.gnu.org tarball; ``executablePath = "configure"``
# is the source-mode placeholder shared with the other M9.R.11-widened
# GNU build-tool stubs (see ``packages/texinfo.nim`` for the rationale).
package make:
  provisioning:
    nixPackage "nixpkgs#gnumake", executablePath = "bin/make",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
    # M9.R.13b.4 — direct-download tarball channel pointing at the
    # WinLibs gcc distribution which BUNDLES a 64-bit ``mingw32-make.exe``
    # at ``bin/mingw32-make.exe``. The previous M9.R.13b.2 attempt
    # (scoop ``main/make``) shipped the ezwinports 32-bit make.exe,
    # and the M9.R.12 io-monitor shim DLL (loaded via CreateRemoteThread +
    # LoadLibraryW) is x86_64 -- LoadLibraryW returns NULL in the
    # 32-bit child process and ``makebin`` actions fail with
    # ``LoadLibraryW in child returned NULL — the shim DLL did not
    # load``. WinLibs's bundled ``mingw32-make`` is the natural 64-bit
    # peer; reusing the same tarball as ``gcc.nim`` also folds the
    # download into the same tool-store prefix the gcc auto-recurse
    # already realizes, so there is no separate download cost. The
    # source-mode ``ftp.gnu.org`` tarball below is preserved as a
    # `os = "any"` fallback for hosts that don't want WinLibs.
    tarball url = "https://github.com/brechtsanders/winlibs_mingw/releases/download/16.1.0posix-14.0.0-ucrt-r2/winlibs-x86_64-posix-seh-gcc-16.1.0-mingw-w64ucrt-14.0.0-r2.7z",
      sha256 = "62fb8588d2deee7d662dbcbd386702adbf19643764c971c38aa4839472eee232",
      archiveType = "7z",
      stripComponents = 1,
      executablePath = "bin/mingw32-make.exe",
      packageId = "make-winlibs@16.1.0",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:make-winlibs@16.1.0:sha256:62fb8588d2deee7d662dbcbd386702adbf19643764c971c38aa4839472eee232"
    tarball url = "https://ftp.gnu.org/gnu/make/make-4.4.1.tar.gz",
      sha256 = "dd16fb1d67bfab79a72f5e8390735c49e3e8e70b4945a15ab1f81ddb78658fb3",
      archiveType = "tar.gz",
      stripComponents = 1,
      executablePath = "configure",
      packageId = "make@4.4.1",
      cpu = "any",
      os = "any",
      lockIdentity = "tarball:make@4.4.1:sha256:dd16fb1d67bfab79a72f5e8390735c49e3e8e70b4945a15ab1f81ddb78658fb3"

  # -------------------------------------------------------------------
  # DSL-port M9.R.2 — typed Layer-3 CLI surface for ``make``.
  #
  # Recipes write ``make.call(workDir = "./b", target = "install",
  # vars = @["DESTDIR=/tmp/out"])`` instead of an inline
  # ``sh.call(["make", "-C", "./b", "DESTDIR=/tmp/out", "install"])``.
  # ``vars`` and ``targets`` are positionals: ``make`` accepts both
  # ``VAR=val`` overrides AND target names interleaved on the command
  # line in source order. The positional list (``vars`` then
  # ``targets``) reflects the canonical convention "vars-before-targets"
  # since make's variable assignments are typically passed before the
  # target list.
  # -------------------------------------------------------------------
  executable makeBin:
    cli:
      dependencyPolicy automaticMonitor

      call:
        flag workDir is string,
          alias = "-C",
          format = separate,
          role = input
        flag file is string,
          alias = "-f",
          format = separate,
          role = input
        flag jobs is int,
          alias = "-j",
          format = separate
        pos vars is seq[string],
          position = 0,
          repeated = true
        pos targets is seq[string],
          position = 1,
          repeated = true

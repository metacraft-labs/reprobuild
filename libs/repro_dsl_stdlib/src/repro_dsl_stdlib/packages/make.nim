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

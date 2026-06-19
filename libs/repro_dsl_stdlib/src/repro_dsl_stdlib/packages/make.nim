import repro_project_dsl

# GNU make. On Nix it ships under bin/make.
package make:
  provisioning:
    nixPackage "nixpkgs#gnumake", executablePath = "bin/make",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="

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

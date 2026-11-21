## The environment variables that only choose where a process puts its
## disposable files.
##
## ``TMPDIR`` is POSIX's (https://pubs.opengroup.org/onlinepubs/9799919799/basedefs/V1_chap08.html,
## "TMPDIR"); ``TMP`` and ``TEMP`` are what Windows' ``GetTempPath2`` consults
## (https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-gettemppath2w)
## and what GCC's libiberty ``choose_tmpdir`` tries after ``TMPDIR``;
## ``TEMPDIR`` is the fourth spelling ``nix develop`` exports. ``nix develop``
## points all four at a fresh ``/tmp/nix-shell.XXXXXX`` directory in every
## shell it starts.
##
## Three edge classes name these as environment PASSTHROUGH
## (reprobuild-pm ``spec/Filesystem-Policy-And-Observed-Inputs.md``
## §"Declared And Passthrough Variables"): the provider compile
## (``ProviderCompileEnvironmentPassthrough`` in ``repro_interface_artifacts``),
## the profile compile and run (``ProfileCompileScratchEnvNames`` in
## ``repro_profile_compile``) and the standard library's Nim compile edges
## (the ``nim`` tool declares them with ``envPassthrough`` on its ``c``
## subcommand in ``repro_dsl_stdlib/packages/nim``, so every edge its typed
## ``nim.c`` wrapper records carries them, and the ``ct_test_nim_unittest``
## compile, which is not recorded through that wrapper, names them itself).
## A passthrough name is
## keyed by NAME only, so an edge whose compiler reads one of them no longer
## misses on the first build in every new shell. Each of those sites states
## the cost of that rule for its own edge; this module only holds the list,
## so the classes cannot drift apart.

const ScratchLocationEnvNames* = ["TMPDIR", "TMP", "TEMP", "TEMPDIR"]
  ## The four temp-directory variables, in the order the provider and
  ## profile compiles have always listed them.

const NixShellScratchNames* = ["NIX_BUILD_TOP", "TMP", "TMPDIR", "TEMP",
  "TEMPDIR", "terminfo"]
  ## What `nix print-dev-env`'s script sets for the SHELL SESSION rather
  ## than for the environment: `NIX_BUILD_TOP` and the four temp-directory
  ## names above all point at a `/tmp/nix-shell.XXXXXX` directory the script
  ## creates with `mktemp -d` on every sourcing, and `terminfo` at the
  ## builder's terminal database. nix-direnv's `_nix_import_env` restores
  ## exactly this list to its pre-import values and deletes the directory
  ## (nix-direnv 3.0.7, `direnvrc`); `direnv exec` therefore leaves `TMPDIR`
  ## unset in this repository's shell.
  ##
  ## Two captures of a flake shell leave them out, so that every program the
  ## captured shell starts uses the caller's own `TMPDIR` (or the platform
  ## default), as under direnv:
  ##
  ##   * the dev-env capture (`withoutNixShellScratch` in
  ##     `repro_dsl_stdlib/foreign_env/flake`). Absorbing them made the
  ##     contribution different on EVERY activation, so the dev-env artifact
  ##     could never be byte-stable, and left one `/tmp/nix-shell.*`
  ##     directory behind per entry (3,975 of them on one host, measured on
  ##     reprobuild's own flake shell, 2026-09-28);
  ##   * a workspace bundle's captured shell script (`normaliseDevEnv` in
  ##     `repro_bundle/nix_half`). Kept, they gave every sourcing a fresh
  ##     random temp directory, and a producer that reads one of them (a C
  ##     compiler reads `TMPDIR`, `TMP` and `TEMP`) recorded it, so its edge
  ##     missed in every later activation of the shell, on the same machine
  ##     or after the bundle was restored elsewhere.

static:
  # The session list must cover every temp-directory spelling, or a capture
  # would keep one that names the per-sourcing directory.
  for name in ScratchLocationEnvNames:
    doAssert name in NixShellScratchNames, name

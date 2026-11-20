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

## M9.R.74 verification — ``resolveCanonicalExecRoot`` maps each
## ``ActionCwdKind`` value to the expected absolute path against a
## fixed project root.
##
## The engine's ``lowerGraphAction`` calls this resolver on every
## action to compute the spawn-time ``BuildAction.cwd``. Backward-
## compat semantics are pinned here: an ``acwdRecipeRoot`` +
## empty-custom-path pair MUST resolve to ``projectRoot`` byte-for-
## byte so every pre-M9.R.74 recipe gets an unchanged CWD.

import std/[os, unittest]

import repro_cli_support
import repro_project_dsl

suite "t_m9r74_resolve_canonical_execroot":

  const ProjectRoot = "/abs/proj"

  test "acwdRecipeRoot + empty custom path -> projectRoot":
    ## The legacy default. Pinning byte-for-byte because every
    ## pre-milestone recipe hits this branch.
    check resolveCanonicalExecRoot(acwdRecipeRoot, "", ProjectRoot) ==
      ProjectRoot

  test "acwdRecipeRoot ignores custom path":
    ## Custom path is meaningful only for ``acwdCustom`` (and provides
    ## the resolved absolute path for the three tagged kinds); when the
    ## kind is ``acwdRecipeRoot`` the resolver never touches it.
    check resolveCanonicalExecRoot(acwdRecipeRoot, "irrelevant",
      ProjectRoot) == ProjectRoot

  test "acwdCustom with absolute path returns path verbatim":
    check resolveCanonicalExecRoot(acwdCustom, "/absolute/path",
      ProjectRoot) == "/absolute/path"

  test "acwdCustom with empty path falls back to projectRoot":
    ## Matches the pre-M9.R.74 behaviour of
    ## ``inlineExecCall(argv, cwd = "")``.
    check resolveCanonicalExecRoot(acwdCustom, "", ProjectRoot) ==
      ProjectRoot

  test "acwdCustom with relative path is joined against projectRoot":
    check resolveCanonicalExecRoot(acwdCustom, "sub", ProjectRoot) ==
      ProjectRoot / "sub"

  test "acwdBuild with relative path is joined against projectRoot":
    ## Convention emitters typically pass ``"build"`` as the buildDir;
    ## the resolver joins it against the project root so the engine
    ## spawns actions under ``<projectRoot>/build``.
    check resolveCanonicalExecRoot(acwdBuild, "build", ProjectRoot) ==
      ProjectRoot / "build"

  test "acwdBuild with absolute path returned verbatim":
    check resolveCanonicalExecRoot(acwdBuild, "/abs/build",
      ProjectRoot) == "/abs/build"

  test "acwdSource with relative path is joined against projectRoot":
    check resolveCanonicalExecRoot(acwdSource, "src", ProjectRoot) ==
      ProjectRoot / "src"

  test "acwdInstall with relative path is joined against projectRoot":
    check resolveCanonicalExecRoot(acwdInstall, "build/out",
      ProjectRoot) == ProjectRoot / "build/out"

  test "acwdBuild with empty custom path degrades to projectRoot":
    ## An improperly-declared kind must not silently break execution;
    ## the resolver falls back to projectRoot so the action still
    ## runs somewhere sane.
    check resolveCanonicalExecRoot(acwdBuild, "", ProjectRoot) ==
      ProjectRoot

  test "empty projectRoot with absolute custom path is returned":
    check resolveCanonicalExecRoot(acwdCustom, "/abs/only", "") ==
      "/abs/only"

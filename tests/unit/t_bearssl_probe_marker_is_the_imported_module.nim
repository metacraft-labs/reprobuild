## The probe that resolves a source-only package tests for the MODULE the
## build imports, and every resolver in this repository spells the same one.
##
## WHY THIS EXISTS. reprobuild resolved nim-bearssl through four separate
## mechanisms that did not agree on what a valid checkout is:
##
##   * `scripts/source_paths.sh` (the shell build path) probed for
##     `bearssl/abi/consttypes.nim` — the module
##     `libs/repro_deploy_agent/.../secrets.nim` imports — and its own comment
##     explained why: `bearssl.nim` sits at the root of EVERY revision of the
##     package, including ones predating the `bearssl/abi/` tree, so a probe
##     testing only for the root file ACCEPTS a checkout that cannot satisfy
##     the import. The build then dies tens of modules later on `cannot open
##     file: bearssl/abi/consttypes`, a message naming the module rather than
##     the wrong checkout that lacks it.
##   * `repro.nim`'s own probe, `config.nims`' `--path` declaration, and the
##     release source stager each probed for the ROOT FILE — the defective
##     form, by that statement.
##
## And it was not hypothetical: on the development fleet,
## `/nix/store/…-nim-bearssl-667b404` carries `bearssl.nim` and does NOT carry
## `bearssl/abi/consttypes.nim`, so it passed the weak probes and failed the
## compile. The recipe's probe additionally ended with a `/nix/store` name-
## fragment scan that could return exactly that tree.
##
## ASSERTED, by driving the REAL resolver against real directories:
##
##   1. A checkout carrying only `bearssl.nim` — the stale layout — is
##      REJECTED. The same fixture is shown to be ACCEPTED when the probe is
##      handed the old root-file marker, which is the positive control: it
##      proves the fixture is exactly the shape the old probe let through, so
##      case 1 cannot pass vacuously.
##   2. A checkout carrying the module tree is accepted and reported with the
##      environment entry a consuming compile must inherit.
##   3. An explicitly named STALE checkout is refused LOUDLY and is not
##      silently replaced by a good candidate that is also reachable.
##      Substituting a different checkout for the one the caller named is what
##      hides a stale pin in whatever set the variable.
##   4. The resolver never offers a `/nix/store` scan: nothing in its
##      candidate report mentions the store, and with no candidate reachable
##      it raises instead of guessing. (The pinned tree materializes as
##      `/nix/store/<hash>-source`, so a `nim-bearssl-` fragment could only
##      ever match some other derivation's pin.)
##   5. Every resolver in the repository spells the ONE marker: `repro.nim`
##      passes the shared `BearsslModuleMarker` constant rather than a
##      literal, and `config.nims`, `scripts/source_paths.sh`,
##      `scripts/release/stage_release_sources.sh` and
##      `scripts/verify_release.sh` each carry that same string and no longer
##      probe bearssl by its root file.
##
## FALSIFIABILITY (observed). Against the pre-fix tree: case 1 fails — the
## resolver returns the stale fixture instead of raising; case 3 fails — the
## stale explicit value falls through to the good sibling; case 4 fails — the
## candidate report names "a /nix/store entry whose name contains
## `nim-bearssl-`"; case 5 fails on all four files.
##
## NO MOCKS. The resolver is the production proc from
## `repro_dsl_stdlib/source_only_packages`, the fixtures are real directories
## on a real filesystem, and the four declaration sites are read from the
## repository's own files. The fixture files are empty because the resolver
## asks only whether the module is THERE — it never reads it, and a fixture
## carrying real bearssl source would test Nim's compiler rather than this
## probe.

import std/[os, strutils, tempfiles, unittest]

import repro_dsl_stdlib/source_only_packages

const RootFileOnlyMarker = "bearssl.nim"
  ## The marker the four weak probes used. Named here so the positive control
  ## in case 1 and the "no site still uses it" assertion in case 5 refer to
  ## the same string.

proc repoRoot(): string =
  ## Anchored at this source file rather than at the working directory: the
  ## cases below deliberately move the working directory, and the suite is run
  ## from several different ones.
  var dir = parentDir(currentSourcePath())
  while dir.len > 0 and dir != parentDir(dir):
    if fileExists(dir / "config.nims") and fileExists(dir / "repro.nim"):
      return dir
    dir = parentDir(dir)
  raise newException(IOError,
    "could not locate the repository root from " & currentSourcePath())

proc makeCheckout(path: string; withModuleTree: bool): string =
  ## A nim-bearssl checkout fixture. `bearssl.nim` is ALWAYS present — that is
  ## precisely why it cannot serve as the marker. The `bearssl/abi/` tree is
  ## what distinguishes a usable checkout from a stale one.
  result = path
  createDir(result)
  writeFile(result / RootFileOnlyMarker, "")
  if withModuleTree:
    createDir(result / "bearssl" / "abi")
    writeFile(result / "bearssl" / "abi" / "consttypes.nim", "")

template withScratchCwd(body: untyped) =
  ## Run `body` from a directory that carries no `flake.nix`, so the
  ## resolver's dev-shell fallback (`nix eval` against the flake in the
  ## working directory) cannot answer for the fixtures and make a negative
  ## case pass or fail depending on where the suite was launched from.
  let previousDir = getCurrentDir()
  let cwdScratch {.inject.} = createTempDir("repro-bearssl-cwd-", "")
  setCurrentDir(cwdScratch)
  try:
    body
  finally:
    setCurrentDir(previousDir)
    removeDir(cwdScratch)

proc clearedEnv(name: string) =
  if existsEnv(name): delEnv(name)

const ProbeEnvName = "REPRO_TEST_BEARSSL_SRC"
  ## A variable of this test's own, not `BEARSSL_SRC`: the suite may be run
  ## from inside the dev shell, which exports a REAL `BEARSSL_SRC`, and a case
  ## that depends on the ambient value is not a test of the resolver.

suite "the bearssl probe tests the module the build imports":

  test "t_stale_root_file_only_checkout_is_rejected":
    withScratchCwd:
      clearedEnv(ProbeEnvName)
      let stale = makeCheckout(cwdScratch / "stale-bearssl",
                               withModuleTree = false)
      # The exact shape the weak probes accepted.
      check fileExists(stale / RootFileOnlyMarker)
      check not fileExists(stale / BearsslModuleMarker)

      var raised = ""
      try:
        discard sourceOnlyPackagePath(ProbeEnvName, [stale],
                                      BearsslModuleMarker)
      except OSError as e:
        raised = e.msg
      check raised.len > 0
      check BearsslModuleMarker in raised
      check stale in raised

      # POSITIVE CONTROL. Handed the old root-file marker, the same resolver
      # and the same fixture resolve happily — so the rejection above is the
      # marker doing work, not the fixture being broken in some other way.
      let viaOldMarker = sourceOnlyPackagePath(ProbeEnvName, [stale],
                                               RootFileOnlyMarker)
      check viaOldMarker.path == stale

  test "t_checkout_carrying_the_module_tree_is_accepted":
    withScratchCwd:
      clearedEnv(ProbeEnvName)
      let good = makeCheckout(cwdScratch / "good-bearssl",
                              withModuleTree = true)
      let resolved = sourceOnlyPackagePath(ProbeEnvName, [good],
                                           BearsslModuleMarker)
      check resolved.path == good
      # The environment entry is what threads the SAME tree onto every
      # consuming compile; a resolution that did not report it would leave the
      # action resolving the input again, on its own.
      check resolved.env == @[(ProbeEnvName, good)]

  test "t_named_stale_checkout_is_refused_not_substituted":
    withScratchCwd:
      let good = makeCheckout(cwdScratch / "good-bearssl",
                              withModuleTree = true)
      let stale = makeCheckout(cwdScratch / "stale-bearssl",
                               withModuleTree = false)
      putEnv(ProbeEnvName, stale)
      defer: clearedEnv(ProbeEnvName)

      # A PERFECTLY GOOD checkout is reachable as a candidate, and the call
      # still fails, because the caller NAMED the stale one. Falling back here
      # would paper over a stale pin in whatever set the variable, and the
      # operator would never learn their value was ignored.
      var raised = ""
      try:
        discard sourceOnlyPackagePath(ProbeEnvName, [good],
                                      BearsslModuleMarker)
      except OSError as e:
        raised = e.msg
      check raised.len > 0
      check stale in raised
      check ProbeEnvName in raised
      check BearsslModuleMarker in raised
      # It says what to do, rather than only that something is wrong.
      check "unset" in raised

  test "t_resolver_never_falls_back_to_a_nix_store_scan":
    withScratchCwd:
      clearedEnv(ProbeEnvName)
      let absent = cwdScratch / "no-such-bearssl"
      check not dirExists(absent)
      var raised = ""
      try:
        discard sourceOnlyPackagePath(ProbeEnvName, [absent],
                                      BearsslModuleMarker)
      except OSError as e:
        raised = e.msg
      # Nothing was reachable, so the resolver RAISES rather than returning a
      # guess, and the candidates it reports contain no store scan.
      check raised.len > 0
      check "/nix/store" notin raised
      check "nim-bearssl-" notin raised

    # The source of the resolver carries no scan either, so the behaviour
    # above cannot be restored by a candidate list that happens to be empty.
    let moduleSource = readFile(repoRoot() / "libs" / "repro_dsl_stdlib" /
      "src" / "repro_dsl_stdlib" / "source_only_packages.nim")
    let scansADirectoryTree = "walkDir" in moduleSource
    check not scansADirectoryTree

  test "t_every_bearssl_resolver_spells_the_same_marker":
    let root = repoRoot()

    # The recipe passes the SHARED CONSTANT, so its marker cannot drift from
    # this module's by an edit to a string literal.
    let recipe = readFile(root / "repro.nim")
    let callAt = recipe.find("sourceOnlyPackagePath(\"BEARSSL_SRC\"")
    check callAt >= 0
    let callSite = recipe[callAt ..< min(callAt + 400, recipe.len)]
    check "BearsslModuleMarker" in callSite
    check ("\"" & RootFileOnlyMarker & "\"") notin callSite
    # The store-name fragment argument is gone from the call, not merely
    # unused.
    check "nim-bearssl-" notin callSite

    # The resolvers that cannot import Nim code spell the string. Each
    # predicate is reduced to a bool BEFORE `check` sees it: `check <needle>
    # in <wholeFile>` makes unittest print the failing operands, and one of
    # those operands is a 2000-line file.
    for relative in ["config.nims",
                     "scripts/source_paths.sh",
                     "scripts/release/stage_release_sources.sh",
                     "scripts/verify_release.sh"]:
      let text = readFile(root / relative)
      checkpoint(relative)
      let declaresTheModuleMarker = BearsslModuleMarker in text
      check declaresTheModuleMarker
      # And none of them still probes bearssl by its root file. The string
      # `bearssl.nim` may legitimately appear in prose explaining WHY it is
      # not the marker, so the check is for the probe SHAPES: a quoted marker
      # argument, or the stager's bare positional field.
      let probesByQuotedRootFile =
        ("\"" & RootFileOnlyMarker & "\"") in text
      check not probesByQuotedRootFile
      let probesByBareRootFile = (" " & RootFileOnlyMarker & " ") in text
      check not probesByBareRootFile

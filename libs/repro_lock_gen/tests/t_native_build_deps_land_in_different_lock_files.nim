## NLF-PROP-4 — the same library in `nativeBuildDeps:` and `buildDeps:` is
## two instances.
##
## Named-Lock-Files NLF-M7. Corpus case **NLF-PROP-4**: "The same library in
## both lists yields two instances. **Acceptance test for un-merging.**"
##
## ## The finding this is the acceptance test for
##
## Design §4.6 is the most important section of the DSL design and this is its
## test. The approved DSL **already** declares the host/target split, at
## dependency-list granularity, and `From-Source-Build-Recipes.md` is explicit
## that the lists are not collapsed:
##
## > A dependency that appears in more than one list must be written in each
## > (reprobuild does not collapse them — explicit is better).
##
## §4.6 then MEASURED that the distinction was being erased anyway:
##
## > The `package` macro parses `uses:`, `nativeBuildDeps:`, `buildDeps:` and
## > `runtimeDeps:` into separate fields — but `uses:` and `buildDeps:`
## > populate the *same* `toolUses` sequence, and at serialization all of them
## > are concatenated … So the platform distinction the recipe expressed is
## > **erased before the solver ever sees it**.
##
## And drew the conclusion this file checks:
##
## > **`nativeBuildDeps:` resolves under the `hostTools` lock file;
## > `buildDeps:` and `runtimeDeps:` resolve under the consuming artifact's
## > lock file.**
##
## The consequence, and the reason §4.6 calls it "the single biggest ergonomic
## result available here": **for the motivating case the authoring cost is
## zero.** No `lockFile` line appears anywhere in the recipe below. The
## designation is entirely carried by which list each dependency was written
## in — which is what a recipe author already writes.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## See `nlf_m7_fixture`'s header, which states the policy in full.

import std/[strutils, tables, unittest]

import repro_lock_gen

import ./nlf_m7_fixture

const
  App = "app"
  LibZ = "libz"
  Published = ["1.1.0", "1.4.0", "2.1.0", "2.5.0"]

proc workspace(): Recipe =
  ## One package, one artifact, NO `lockFile` line anywhere. `libz` is written
  ## in both lists — the shape `From-Source-Build-Recipes.md` requires when a
  ## dependency is needed on both platforms — and the two entries carry
  ## different ranges, because the build-machine copy and the linked copy are
  ## genuinely different things and a recipe is free to say so.
  Recipe(
    packages: @[
      RecipePackage(name: App, versions: @["1.0.0"],
        deps: @[
          dep(LibZ, ">=1.0 <2.0", dpNative),
          dep(LibZ, ">=2.0 <3.0", dpTarget)]),
      RecipePackage(name: LibZ, versions: @Published)],
    artifacts: @[
      RecipeArtifact(name: App, package: App, lockFile: "")])

suite "NLF-PROP-4 nativeBuildDeps and buildDeps land in different lock files":

  test "the recipe designates nothing and still gets two lock files":
    let prop = propagationOf(workspace())
    check prop.lockFilesInUse() ==
      @[DefaultLockFileName, HostToolsLockFileName]
    for a in workspace().artifacts:
      check a.lockFile == ""
    for p in workspace().packages:
      check p.pinnedLockFile == ""

  test "the shared library is instantiated twice":
    let prop = propagationOf(workspace())
    check prop.instanceCount(LibZ) == 2
    check prop.lockFilesByPackage[LibZ] ==
      @[DefaultLockFileName, HostToolsLockFileName]

  test "and the two instances resolve to different versions":
    # The acceptance criterion. Under the pre-NLF-M7 behaviour the two entries
    # were concatenated into one list, so the solver saw the intersection of
    # `>=1.0 <2.0` and `>=2.0 <3.0` for one package node — empty — and the
    # workspace was UNSAT. Two graphs give two answers.
    let reg = startRegistry("prop4")
    try:
      let solved = reg.solvePerLockFile(workspace(), lsHighest)
      let host = solved[HostToolsLockFileName].solvedVersions()
      let target = solved[DefaultLockFileName].solvedVersions()
      check host[LibZ] == "1.4.0"
      check target[LibZ] == "2.5.0"
      check host[LibZ] != target[LibZ]
    finally:
      reg.shutdown()

  test "the merged reading of the same recipe is unsatisfiable":
    # The control, and the direct evidence that the un-merging is what made
    # the case pass. `solveUnified` retags every dependency as a target
    # dependency — the pre-NLF-M7 state in which the platform tag never
    # reached the solver — and the identical recipe stops having an answer.
    let reg = startRegistry("prop4-control")
    try:
      var message = ""
      try:
        discard reg.solveUnified(workspace(), lsHighest)
      except CatchableError as err:
        message = err.msg
      checkpoint("merged solve reported: " & message)
      check "no satisfying assignment exists" in message
    finally:
      reg.shutdown()

  test "a runtimeDeps entry follows the consumer, not the host":
    # §4.6 puts `runtimeDeps:` with `buildDeps:`, not with
    # `nativeBuildDeps:` — both are HOST-platform. A propagation that routed
    # everything non-`uses:` to `hostTools` would pass every assertion above.
    var r = workspace()
    r.packages[0].deps = @[dep(LibZ, ">=2.0 <3.0", dpRuntime)]
    let prop = propagationOf(r)
    check prop.lockFilesByPackage[LibZ] == @[DefaultLockFileName]

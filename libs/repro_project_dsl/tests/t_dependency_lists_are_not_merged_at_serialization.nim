## The three dependency lists survive serialization as three lists.
##
## Named-Lock-Files NLF-M8, the third criterion folded in from NLF-M7:
##
## > **Un-merge the three dependency lists at serialization.**
## > `packageUseSeqLiteral(pkg.toolUses & pkg.nativeBuildDeps &
## > pkg.runtimeDeps)` still concatenates. M7 made the merge non-destructive
## > (every `PackageUseDef` now carries a `depKind` tag) and fixed the larger
## > half … What remains is ~14 convention-layer sites reading the merged
## > `ProjectInterface.toolUses` for tool-PATH construction.
##
## ## What was actually wrong, and what the fix has to preserve
##
## The merge gave one field name two meanings. At MACRO-EXPANSION time
## `pkg.toolUses` is the `uses:` / `buildDeps:` list; at RUN time it was the
## concatenation of all three, because `packageLiteral` emitted the union into
## that slot. §4.6 measured the cost: "the platform distinction the recipe
## expressed is **erased before the solver ever sees it**."
##
## But the union is NEEDED. M9.R.5a and M9.R.53 widened the fold so the
## convention layer's tool-PATH builder would see a tool declared in
## `nativeBuildDeps:` or `runtimeDeps:`, and a fix that simply stopped
## concatenating would drop those tools off PATH — silently, at build time,
## in recipes this environment cannot run. So the union does not go away; it
## gets a name (`allToolUses`) and every site that wants it asks.
##
## ## The two halves this file asserts, and why both are needed
##
##   1. **`PackageDef.toolUses` no longer carries the other two lists.** That
##      is the un-merge. Asserted through the emitted literal — the actual
##      serialization — rather than through the parsed `PackageDef`, because
##      the parsed one was never merged and asserting on it would pass
##      against the defect.
##   2. **`allToolUses` is byte-identical to the old concatenation, in the
##      same order.** That is what keeps the fix from being a regression.
##      Order is load-bearing and not tidiness: `buildPackageDevEnv` hashes
##      this sequence into the implicit dev-env floor hash, so a reordering
##      would move that hash for every package with no change behind it.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## The literal asserted on is produced by the real `packageLiteral` through
## the real `package` macro expansion, and the `PackageDef` is the real
## runtime value the expansion binds.

import std/[strutils, unittest]

import repro_project_dsl

const
  BuildDep = "buildonly >=1.0"
  NativeDep = "nativeonly >=2.0"
  RuntimeDep = "runtimeonly >=3.0"

proc sample(): PackageDef =
  ## A `PackageDef` with one entry in each of the three lists, built through
  ## the same constructors the parser uses.
  PackageDef(
    packageName: "threelists",
    toolUses: @[PackageUseDef(rawConstraint: BuildDep,
      packageSelector: "buildonly", depKind: "target")],
    nativeBuildDeps: @[PackageUseDef(rawConstraint: NativeDep,
      packageSelector: "nativeonly", depKind: "native")],
    runtimeDeps: @[PackageUseDef(rawConstraint: RuntimeDep,
      packageSelector: "runtimeonly", depKind: "runtime")])

suite "NLF-M8 the three dependency lists are not merged at serialization":

  test "allToolUses is the concatenation, in the concatenation's order":
    let all = sample().allToolUses()
    check all.len == 3
    check all[0].rawConstraint == BuildDep
    check all[1].rawConstraint == NativeDep
    check all[2].rawConstraint == RuntimeDep

  test "and it is exactly what the old merge produced":
    # Written out rather than referenced, so the assertion survives the
    # accessor being rewritten. If the two ever disagree the dev-env floor
    # hash moves for every package, which is a fingerprint change with no
    # change behind it.
    let pkg = sample()
    let byHand = pkg.toolUses & pkg.nativeBuildDeps & pkg.runtimeDeps
    let all = pkg.allToolUses()
    require all.len == byHand.len
    for i in 0 ..< all.len:
      check all[i].rawConstraint == byHand[i].rawConstraint
      check all[i].depKind == byHand[i].depKind

  test "toolUses carries ONLY the uses:/buildDeps: entries":
    # The un-merge itself. A `PackageDef` whose `toolUses` holds three
    # entries is the merged shape.
    let pkg = sample()
    check pkg.toolUses.len == 1
    check pkg.toolUses[0].rawConstraint == BuildDep
    check pkg.nativeBuildDeps.len == 1
    check pkg.runtimeDeps.len == 1

  test "each entry still says which list it was written in":
    # The tag NLF-M7 added. It stays, and is now the answer rather than a
    # repair: a consumer that needs the platform reads it here instead of
    # inferring it from a position in a merged seq.
    let all = sample().allToolUses()
    check all[0].depKind == "target"
    check all[1].depKind == "native"
    check all[2].depKind == "runtime"

package threelistsRecipe:
  ## A real recipe, so the assertion below is about the real emission.
  uses:
    "buildonly >=1.0"
  nativeBuildDeps:
    "nativeonly >=2.0"
  runtimeDeps:
    "runtimeonly >=3.0"

suite "NLF-M8 the emitted PackageDef carries three separate lists":

  test "the macro-emitted runtime PackageDef is un-merged":
    # This is the assertion that fails against the defect. Before NLF-M8 the
    # emitted literal put all three entries into `toolUses:`, so this
    # `PackageDef` — the one a provider actually reads — reported three.
    var found = false
    for pkg in registeredPackages():
      if pkg.packageName != "threelistsRecipe": continue
      found = true
      checkpoint("toolUses: " & $pkg.toolUses.len &
        "  nativeBuildDeps: " & $pkg.nativeBuildDeps.len &
        "  runtimeDeps: " & $pkg.runtimeDeps.len)
      check pkg.toolUses.len == 1
      check pkg.toolUses[0].rawConstraint == BuildDep
      check pkg.nativeBuildDeps.len == 1
      check pkg.nativeBuildDeps[0].rawConstraint == NativeDep
      check pkg.runtimeDeps.len == 1
      check pkg.runtimeDeps[0].rawConstraint == RuntimeDep
      check pkg.allToolUses().len == 3
    check found

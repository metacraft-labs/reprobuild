## Verification `test_npc_m15_n_component_change_leaves_other_ecosystems_unchanged`
## (NPC-AREQ6, "Versions with any number of components"; spec § 8): the
## solver's Nimble order applies to `nimble:` packages only.
##
## The solver's versions are shared by every ecosystem, and Nimble's order
## over any number of components is chosen per package
## (``PackageDecl.versionScheme``), so nothing else may move:
##
## 1. A non-Nimble solve -- semver packages, one of which publishes a
##    four-component version string that the semver reading cannot parse --
##    reaches clingo as the same program and gives the same answer, and
##    `repro lock solve` writes the same lock bytes, as before the change.
## 2. A Nimble lock whose versions all have three or fewer components
##    (`v1.0`, `1.2`, `0.3.1.0`) is byte-identical to its golden.
##
## The goldens (`fixtures/npc_m15_other_ecosystems/`) were recorded at
## reprobuild `36378344d`, the commit before the change, by compiling this
## file there with `-d:npcM15RecordGolden=<dir>`.
##
## Falsifying mutation (recorded in the plan): spelling a Nimble row with
## the tag's own components (`1.0` for the tag `v1.0`, instead of `1.0.0`)
## changes the committed Nimble golden, and fails the test.

import std/[algorithm, os, strutils, tables, tempfiles, unittest]

import nimcrypto/[hash, sha2]

import repro_solver/[version_encoder, variant_encoder, solver_api]

import ./nimble_m6_fixtures

const
  Goldens = currentSourcePath().parentDir / "fixtures" /
    "npc_m15_other_ecosystems"
  RecordTo {.strdefine: "npcM15RecordGolden".} = ""

proc digest(text: string): string = toLowerAscii($sha256.digest(text))

proc golden(name, actual: string) =
  ## Compare ``actual`` with the golden ``name``, or record it.
  if RecordTo.len > 0:
    createDir(RecordTo)
    writeFile(RecordTo / name, actual)
    return
  let want = readFile(Goldens / name)
  if want != actual:
    checkpoint "golden " & name & " differs:\n--- want\n" & want &
      "\n--- got\n" & actual
  check want == actual

const SolverInputs = """package app
versions: 1.0.0
depends: lib >=1.0.0, <2.0.0
depends: util ^0.3
package lib
versions: 1.0.0, 1.2.3.4, 1.10.0, 1.9.0, 2.0.0
depends: util >=0.3.1
package util
versions: 0.3.0, 0.3.1, 0.3.1.5, 0.4.0
"""

proc decls(): seq[PackageDecl] =
  @[newPackage("app", ["1.0.0"], [newDependency("lib", ">=1.0.0, <2.0.0"),
      newDependency("util", "^0.3")]),
    newPackage("lib", ["1.0.0", "1.2.3.4", "1.10.0", "1.9.0", "2.0.0"],
      [newDependency("util", ">=0.3.1")]),
    newPackage("util", ["0.3.0", "0.3.1", "0.3.1.5", "0.4.0"])]

proc answerText(prefs: openArray[VersionPreference]): string =
  let none: seq[VariantDecl] = @[]
  for pref in prefs:
    let program = encodeUnified(none, decls(), pref)
    result.add $pref & " program " & digest(program) & "\n"
    let sol = solve(none, decls(), pref)
    var names: seq[string]
    for k in sol.packages.keys: names.add k
    names.sort()
    for k in names:
      result.add $pref & " " & k & " " & sol.packages[k] & "\n"

suite "NPC-M15: Nimble's order leaves every other ecosystem unchanged":
  test "a non-Nimble solve: same program, same answer, same lock bytes":
    golden("semver-solve.txt",
      answerText([vpNone, vpLowest, vpHighest, vpLowestDirect]))
    let root = createTempDir("npc-m15-semver-", "")
    putEnv("HOME", root / "home")
    putEnv("REPRO_CACHE_DISABLE", "1")
    createDir(root / "home")
    let dir = root / "project"
    createDir(dir)
    writeFile(dir / "repro.solver", SolverInputs)
    for (verb, extra, name) in [("solve", @["--write"], "semver.lock"),
        ("solve", @["--write", "--lowest"], "semver-lowest.lock")]:
      if fileExists(dir / "repro.lock"): removeFile(dir / "repro.lock")
      let ran = lockVerb(dir, verb, extra)
      checkpoint ran.output
      check ran.rc == 0
      golden(name, readFile(dir / "repro.lock").replace(root, "<root>"))

  test "a Nimble lock of versions with three or fewer components":
    var w = newWorld("ncomp-golden")
    let gen = w.publish(@[
      package("alpha", @[record("alpha", "v1.0"), record("alpha", "0.9")]),
      package("beta", @[record("beta", "0.3.1.0"), record("beta", "1.2")])],
      1_790_000_000, "generation 1")
    let dir = w.newProject(@[("alpha", ">=0.9.0"), ("beta", "<1.0.0")])
    let ran = refreshProvisioning(dir)
    checkpoint ran.output
    check ran.rc == 0
    check nimbleRows(dir)["nimble:alpha"].version == "1.0.0"
    check nimbleRows(dir)["nimble:beta"].version == "0.3.1"
    golden("nimble-three-components.lock",
      readFile(dir / "repro.lock").replace(w.root, "<root>"))
    discard gen

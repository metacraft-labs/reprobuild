## NPC-M9 verification `test_npc_m9_locked_sets_aside_every_override`
## (operator decision M9-P3; Workspace-And-Develop-Mode.md §"A locked build
## sets aside every develop override"; Nimble-Package-Catalog.md NPC-AREQ27
## item 6; threat model G20).
##
## One project, three develop overrides, each with a module whose stamp
## says where it was compiled from:
##
## * `greetlib`, a Reprobuild package (not a `nimble:` one) the lock pins by
##   VCS revision, recorded as a develop override of its sibling checkout,
##   whose working tree is dirty (`GREET-WORKTREE`; the locked commit says
##   `GREET-LOCKED`);
## * `nimble:results`, overridden automatically by the declared repo
##   `nim-result` of its origin identity (`DECLARED-R`);
## * `nimble:stew`, overridden by a recorded override of a fork (`FORK-S`).
##
## Positive control: `repro build` compiles all three overrides. Then
## `repro build --locked`, `repro test --locked`, `repro lint --locked`,
## `repro bench --locked` and `repro certify --locked` each build the trees
## the lock pins -- the locked revision's tree for `greetlib`, read from
## its checkout's object store, and the store trees for the catalog
## packages -- and name each override set aside. With the `greetlib`
## override dropped, its dirty checkout (still where the lock places it)
## does not change the locked build either. A locked revision no clone
## holds is refused, naming it.
##
## Falsifying mutation (recorded in the plan): setting aside only `nimble:`
## overrides under `--locked` (the part-A behaviour) compiles the `greetlib`
## override's working tree and fails the test.
##
## No mock: a real index repository, the production `repro` binary, a real
## HTTPS mirror on loopback, real git repositories and the host's Nim and C
## compiler.

import std/[os, strutils, unittest]

import ./nimble_m7_fixtures
import ./nimble_m9_fixtures

const LockedProject = """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package app:
  defaultToolProvisioning "path"

  uses:
    "nim"
    "gcc"
    "sh"
    "greetlib"
$USES
  build:
    discard nim.c(
      source = "src/app.nim",
      binary = "build/bin/app",
      parallelBuild = 1)
    discard shell(
      command = "mkdir -p build && ./build/bin/app build/app-out.txt",
      actionId = "app.run",
      extraInputs = @["build/bin/app"],
      extraOutputs = @["build/app-out.txt"],
      cacheable = false)
    # Each verb's collection runs the program into its own file.
    for verb in ["test", "lint", "bench"]:
      let ran = shell(
        command = "mkdir -p build && ./build/bin/app build/" & verb &
          "-out.txt",
        actionId = "app." & verb,
        extraInputs = @["build/bin/app"],
        extraOutputs = @["build/" & verb & "-out.txt"],
        cacheable = false)
      discard collect(verb, @[ran])
"""

const GreetlibRecipe = """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package greetlib:
  defaultToolProvisioning "path"

  uses:
    "sh"

  library greetlib:
    kind: static

  build:
    discard shell(
      command = "mkdir -p build && printf built > build/greetlib.stamp",
      actionId = "greetlib.build.stamp",
      extraOutputs = @["build/greetlib.stamp"])
"""

proc greetModule(stamp: string): string =
  "proc greeting*(): string = \"" & stamp & "\"\n"

const AppSource = "import std/os, results, stew, greetlib\n" &
  "writeFile(paramStr(1), rstamp() & \"|\" & sstamp() & \"|\" & " &
  "greeting())\n"

proc locked(verb: string): seq[string] =
  ## ``repro <verb> --locked`` as the CLI tests run a build. `repro build`
  ## names the project; the other verbs build their collection (`test`,
  ## `lint`, `bench`; `certify` the `test` collection) of the project in
  ## the current directory.
  (if verb == "build": @[verb, "."] else: @[verb]) &
    @["--daemon=off", "--tool-provisioning=path", "--locked"]

suite "NPC-M9: --locked sets aside every develop override":
  test "a VCS override, a declared repo and a recorded nimble override":
    var c = newCliWorld("m9-locked-all")
    let f = newFixture("m9-locked-all", c.mirrorRoutes)
    let resultsOrigin = f.url("arnetheduck/nim-results.git")
    let rsrc = f.package("arnetheduck/nim-results.git", @[
      nimbleFile("results"),
      file("src/results.nim", "proc rstamp*(): string = \"CATALOG-R\"\n")])
    let ssrc = f.package("status-im/nim-stew.git", @[nimbleFile("stew"),
      file("src/stew.nim", "proc sstamp*(): string = \"CATALOG-S\"\n")])
    c.mirror.putSource(rsrc)
    c.mirror.putSource(ssrc)
    discard c.w.publish(@[
      f.envelope("results", @[f.recordOf("results", rsrc, "v1.0.0")], rsrc),
      f.envelope("stew", @[f.recordOf("stew", ssrc, "v0.1.0")], ssrc)],
      daysAgo(1), "generation 1", extraFiles = @[("nimble-sources.toml",
        sourceSetText(@[f.ipMirrorUrl("/mirror/")]))])
    let dir = c.w.writeCliProject("app", @[("results", ""), ("stew", "")],
      AppSource, LockedProject)
    let env = cliEnv(c.w, f)
    let refreshed = runRepro(env, dir, @["lock", "refresh", dir, "--inputs",
      dir / "repro.solver", "--provisioning"])
    checkpoint refreshed.output
    check refreshed.rc == 0
    let ws = parentDir(dir)

    # greetlib: a committed revision in a bare remote and in its sibling
    # checkout, whose working tree is then made dirty.
    let greet = ws / "greetlib"
    let greetRemote = c.w.root / "remotes" / "greetlib.git"
    createDir(parentDir(greetRemote))
    discard sh(["git", "init", "-q", "--bare", "-b", "main", greetRemote])
    checkoutAt(greet, greetRemote, @[("repro.nim", GreetlibRecipe),
      ("src/greetlib.nim", greetModule("GREET-LOCKED"))])
    gitCommitAll(greet, "greetlib")
    discard sh(["git", "-C", greet, "push", "-q", "origin", "main"])
    let rev = gitHead(greet)
    writeFile(greet / "src" / "greetlib.nim", greetModule("GREET-WORKTREE"))
    var ld = parseLockedDependencies(readFile(dir / "repro.lock"))
    ld.deps.add LockedDep(name: "greetlib",
      coordinates: Coordinates(kind: ckVcs, url: greetRemote, revision: rev),
      integrity: gitObjectMultihash("sha1", rev), visibility: "public")
    let lockText = serializeLockedDependencies(ld)
    writeFile(dir / "repro.lock", lockText)

    # nimble:results: the declared repo of its origin.
    writeWorkspace(ws, @[
      DeclaredRepoFixture(name: "app", path: extractFilename(dir),
        fetchUrl: "https://example.invalid/app.git"),
      DeclaredRepoFixture(name: "nim-result", path: "nim-result",
        fetchUrl: resultsOrigin)])
    checkoutAt(ws / "nim-result", resultsOrigin, @[
      ("results.nimble", nimbleText()),
      ("src/results.nim", "proc rstamp*(): string = \"DECLARED-R\"\n")])
    # nimble:stew: a fork, recorded in the project's override file, beside
    # the greetlib override.
    checkoutAt(ws / "stew-fork", f.url("someone/stew-fork.git"), @[
      ("stew.nimble", nimbleText()),
      ("src/stew.nim", "proc sstamp*(): string = \"FORK-S\"\n")])
    let recorded = runRepro(env, dir, @["nimble", "develop", "stew",
      "--source=" & (ws / "stew-fork"), "--workspace-root=" & dir])
    checkpoint recorded.output
    check recorded.rc == 0
    let overrides = dir / ".repro" / "develop-overrides.toml"
    writeFile(overrides, readFile(overrides) & """

[[override]]
package = "greetlib"
local_path = "../greetlib"
state = "editable"
created_at = "2026-11-24T00:00:00Z"
provenance = "repro develop greetlib"
""")
    let outFile = dir / "build" / "app-out.txt"

    # Positive control: every override is live without --locked.
    let develop = runRepro(env, dir, BuildArgs)
    checkpoint develop.output
    check develop.rc == 0
    check readFile(outFile) == "DECLARED-R|FORK-S|GREET-WORKTREE"

    # Each build verb with --locked builds the locked trees and names the
    # three overrides it set aside.
    for verb in ["build", "test", "lint", "bench", "certify"]:
      # `repro certify` runs the `test` collection.
      let written = dir / "build" / (
        case verb
        of "build": "app-out.txt"
        of "certify": "test-out.txt"
        else: verb & "-out.txt")
      if fileExists(written): removeFile(written)
      let ran = runRepro(env, dir, locked(verb))
      checkpoint verb & " --locked: rc " & $ran.rc & "\n" & ran.output
      check fileExists(written)
      if fileExists(written):
        check readFile(written) == "CATALOG-R|CATALOG-S|GREET-LOCKED"
      check ("--locked: the develop override of nimble:results " &
        "(../nim-result, declared repo nim-result) is not applied") in
        ran.output
      check ("--locked: the develop override of nimble:stew " &
        "(../stew-fork, recorded override) is not applied") in ran.output
      check "--locked: the develop override of greetlib (" in ran.output
      check ("--locked: greetlib is built from its locked revision " & rev) in
        ran.output
      if verb in ["build", "test", "lint", "bench"]:
        check ran.rc == 0

    # The greetlib override dropped: its checkout is still where the lock
    # places it, dirty, and the locked build still builds the locked tree.
    writeFile(overrides, readFile(overrides).split("\n[[override]]\npackage = \"greetlib\"")[0])
    check "greetlib" notin readFile(overrides)
    removeFile(outFile)
    let placed = runRepro(env, dir, locked("build"))
    checkpoint placed.output
    check placed.rc == 0
    check readFile(outFile) == "CATALOG-R|CATALOG-S|GREET-LOCKED"
    check ("--locked: greetlib is built from its locked revision " & rev &
      ", not from the working tree of " & greet) in placed.output

    # A locked revision no clone holds is refused, naming it.
    let ghost = "0123456789abcdef0123456789abcdef01234567"
    ld = parseLockedDependencies(lockText)
    for d in ld.deps.mitems:
      if d.name == "greetlib":
        d.coordinates.revision = ghost
        d.integrity = gitObjectMultihash("sha1", ghost)
    writeFile(dir / "repro.lock", serializeLockedDependencies(ld))
    removeFile(outFile)
    let missing = runRepro(env, dir, locked("build"))
    checkpoint missing.output
    check missing.rc != 0
    check ("the locked revision " & ghost & " of \"greetlib\" is held by " &
      "no clone") in missing.output
    check not fileExists(outFile)

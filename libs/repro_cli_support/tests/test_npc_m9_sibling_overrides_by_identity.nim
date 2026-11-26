## NPC-M9 verification `test_npc_m9_sibling_overrides_by_identity`
## (Nimble-Package-Catalog NPC-AREQ27; threat model G20).
##
## A project locks `nimble:results`, whose origin is the served repository
## `arnetheduck/nim-results.git`. Beside the project are two checkouts:
##
## * `nim-result`, a clone of that origin: its directory name is not the
##   package's, its remote is the package's origin;
## * `results`, named like the package, holding another repository (its
##   remote is `someone/results.git`).
##
## 1. A `repro build` compiles the store tree: the program prints the
##    catalog's stamp (the positive control for what follows).
## 2. `repro nimble develop` proposes `nim-result` for `nimble:results`,
##    reports `results` as a namesake it does not propose, and records
##    nothing.
## 3. `repro nimble develop results` records the override of the one sibling
##    proposed by identity, with the lock row it replaces.
## 4. The next `repro build` compiles the sibling's working tree, read
##    through its `.nimble` (`srcDir`), and not the namesake: the program
##    prints the sibling's stamp, and `repro.paths` names the sibling's
##    source directory and not the namesake's.
## 5. An edit of the sibling's module reaches the next build. The build
##    also says when the override's `replaces` is not the row the lock now
##    pins, and names an override of a package the lock does not pin.
## 6. The sibling's `.nimble` gains a requirement the locked record lacks:
##    the build refuses, naming the requirement and saying a re-lock is
##    required.
## 7. The sibling's `srcDir` leaves its tree: the build refuses, although
##    the directory it names would compile.
##
## And `repro nimble develop --workspace-root` naming a directory whose
## overrides no build of the project reads is refused: the override would
## be recorded and never applied.
##
## Falsifying mutation (recorded in the plan): matching by directory name
## proposes and records the namesake `results`, and step 4 prints its stamp.
##
## No mock: a real index repository, the production `repro` binary, a real
## HTTPS mirror on loopback and the host's Nim and C compiler.

import std/[os, osproc, strutils, unittest]

from repro_core/process_streams import drainStream

import ./nimble_m7_fixtures

const PathsProject = """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package app:
  defaultToolProvisioning "path"

  uses:
    "nim"
    "gcc"
    "sh"
    "mkdir"
$USES
  build:
    discard nim.nimRepropathsConfig()
    discard nim.c(
      source = "src/app.nim",
      binary = "build/bin/app",
      parallelBuild = 1)
    discard shell(
      command = "mkdir -p build && ./build/bin/app",
      actionId = "app.run",
      extraInputs = @["build/bin/app"],
      extraOutputs = @["build/app-out.txt"],
      cacheable = false)
"""

proc sh(args: openArray[string]; cwd = ""): string =
  let argv = @args
  let p = startProcess(argv[0], workingDir = cwd, args = argv[1 .. ^1],
    options = {poUsePath, poStdErrToStdOut})
  result = drainStream(p.outputStream)
  let rc = p.waitForExit()
  p.close()
  doAssert rc == 0, args.join(" ") & ": " & result

proc checkoutAt(dir, remote: string; files: seq[(string, string)]) =
  ## A git checkout at ``dir`` whose `origin` remote is ``remote``.
  createDir(dir)
  discard sh(["git", "init", "-q", "-b", "main", dir])
  discard sh(["git", "-C", dir, "remote", "add", "origin", remote])
  for (p, content) in files:
    createDir(parentDir(dir / p))
    writeFile(dir / p, content)

suite "NPC-M9: a sibling overrides a catalog package by origin identity":
  test "nim-result overrides results; a namesake with another remote does not":
    var c = newCliWorld("m9-identity")
    let f = newFixture("m9-identity", c.mirrorRoutes)
    let src = f.package("arnetheduck/nim-results.git", @[nimbleFile("results"),
      file("src/results.nim", "proc stamp*(): string = \"CATALOG-M9\"\n")])
    c.mirror.putSource(src)
    let rec = f.recordOf("results", src, "v1.0.0")
    discard c.w.publish(@[f.envelope("results", @[rec], src)], daysAgo(1),
      "generation 1", extraFiles = @[("nimble-sources.toml",
        sourceSetText(@[f.ipMirrorUrl("/mirror/")]))])
    let dir = c.w.writeCliProject("app", @[("results", "")],
      "import results\nwriteFile(\"build/app-out.txt\", stamp())\n",
      PathsProject)
    let env = cliEnv(c.w, f)
    let locked = runRepro(env, dir, @["lock", "refresh", dir, "--inputs",
      dir / "repro.solver", "--provisioning"])
    checkpoint locked.output
    check locked.rc == 0

    # 1. The store tree: the positive control.
    let first = runRepro(env, dir, BuildArgs)
    checkpoint first.output
    check first.rc == 0
    check readFile(dir / "build" / "app-out.txt") == "CATALOG-M9"

    # The siblings: the origin's clone under another name, and a namesake.
    let projects = parentDir(dir)
    let sibling = projects / "nim-result"
    checkoutAt(sibling, f.url("arnetheduck/nim-results.git"), @[
      ("results.nimble", "version = \"1.0.0\"\nsrcDir = \"src\"\n"),
      ("src/results.nim", "proc stamp*(): string = \"SIBLING-M9\"\n")])
    let namesake = projects / "results"
    checkoutAt(namesake, f.url("someone/results.git"), @[
      ("results.nimble", "version = \"1.0.0\"\nsrcDir = \"src\"\n"),
      ("src/results.nim", "proc stamp*(): string = \"NAMESAKE-M9\"\n")])

    # 2. Proposals only.
    let proposed = runRepro(env, dir, @["nimble", "develop"])
    checkpoint proposed.output
    check proposed.rc == 0
    check "propose nimble:results <- ../nim-result" in proposed.output
    check "not proposed: ../results is named like nimble:results" in
      proposed.output
    check not fileExists(dir / ".repro" / "develop-overrides.toml")

    # 3. Recorded explicitly.
    let recorded = runRepro(env, dir, @["nimble", "develop", "results"])
    checkpoint recorded.output
    check recorded.rc == 0
    let overrides = readFile(dir / ".repro" / "develop-overrides.toml")
    checkpoint overrides
    check "package = \"nimble:results\"" in overrides
    check "local_path = \"../nim-result\"" in overrides
    let replaces = "replaces = \"" & f.url("arnetheduck/nim-results.git") &
      "#" & src.commit & " blake3:" & src.tree & "\""
    check replaces in overrides

    # A workspace root no build of the project reads is refused.
    let elsewhere = projects / "elsewhere"
    createDir(elsewhere)
    let misplaced = runRepro(env, dir, @["nimble", "develop", "results",
      "--workspace-root=" & elsewhere])
    checkpoint misplaced.output
    check misplaced.rc == 2
    check "would not be applied" in misplaced.output
    check not fileExists(elsewhere / ".repro" / "develop-overrides.toml")

    # 4. The sibling, not the namesake, not the store.
    let second = runRepro(env, dir, BuildArgs)
    checkpoint second.output
    check second.rc == 0
    check readFile(dir / "build" / "app-out.txt") == "SIBLING-M9"
    let paths = readFile(dir / "repro.paths")
    checkpoint paths
    check (expandFilename(sibling) / "src") in paths
    check "# develop override of nimble:results" in paths
    check (expandFilename(namesake) / "src") notin paths
    check src.tree notin paths

    # 5. An edit of the working tree reaches the build. The override file
    # now says it replaced another identity, and names a package the lock
    # does not pin: the build says both.
    writeFile(sibling / "src" / "results.nim",
      "proc stamp*(): string = \"SIBLING-M9-EDITED\"\n")
    let overridesFile = dir / ".repro" / "develop-overrides.toml"
    writeFile(overridesFile, readFile(overridesFile).replace(replaces,
      "replaces = \"https://example.invalid/stale#0 blake3:0\"") & """

[[override]]
package = "nimble:ghost"
local_path = "../ghost"
state = "editable"
created_at = "2026-11-24T00:00:00Z"
""")
    let third = runRepro(env, dir, BuildArgs)
    checkpoint third.output
    check third.rc == 0
    check readFile(dir / "build" / "app-out.txt") == "SIBLING-M9-EDITED"
    check "was recorded replacing https://example.invalid/stale#0" in
      third.output
    check "nimble:ghost" in third.output
    check "names no package the lock pins" in third.output

    # 6. A requirement the locked record lacks needs a re-lock.
    writeFile(sibling / "results.nimble",
      "version = \"1.0.0\"\nsrcDir = \"src\"\nrequires \"stew >= 0.1.0\"\n")
    let changed = runRepro(env, dir, BuildArgs)
    checkpoint changed.output
    check changed.rc != 0
    check "re-lock required" in changed.output
    check "+ requires \"stew >= 0.1.0\"" in changed.output

    # 7. A `srcDir` that leaves the sibling's tree is refused, although the
    # directory it names holds a module that would compile.
    let outside = projects / "outside"
    createDir(outside)
    writeFile(outside / "results.nim",
      "proc stamp*(): string = \"OUTSIDE-M9\"\n")
    writeFile(sibling / "results.nimble",
      "version = \"1.0.0\"\nsrcDir = \"../outside\"\n")
    let escaped = runRepro(env, dir, BuildArgs)
    checkpoint escaped.output
    check escaped.rc != 0
    check "leaves the package's tree" in escaped.output

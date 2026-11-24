## NPC-M9 verification `test_npc_m9_declared_repo_overrides_catalog_by_identity`
## (Nimble-Package-Catalog.md NPC-AREQ27 as amended 2026-11-24, items 1, 5
## and 7; Nim-Package-Path-Handling.md § 5; threat model T26, G20).
##
## A project locks `nimble:results`, whose origin is the served repository
## `arnetheduck/nim-results.git`. The workspace around it declares, in its
## `repos/*.toml` fragments, and records no develop override:
##
## * `nim-result`, whose fetch URL is that origin: its name and its
##   directory are not the package's;
## * `results`, kept at `results-ns`, whose fetch URL is another repository:
##   a repo named like the package.
##
## Beside them is `results`, a directory the workspace does not declare,
## whose `origin` remote IS the package's origin.
##
## 1. `repro build` compiles `nim-result`'s module, prints `nimble:results
##    <- ../nim-result (declared repo nim-result); lock pins <commit>`, and
##    `repro.paths` says `# develop override of nimble:results:
##    ../nim-result (declared repo nim-result)` before the line. Neither the
##    namesake repo nor the undeclared directory is compiled.
## 2. `repro nimble develop` lists the automatic override, proposes the
##    undeclared checkout, records nothing.
## 3. A recorded override of a fork takes precedence over the declared repo.
## 4. Positive control: with the override dropped and `nim-result`'s
##    declaration removed, the build compiles the store tree and
##    `repro.paths` carries no override comment.
##
## Falsifying mutation (recorded in the plan): matching a declared repo by
## its name instead of its remote identity makes the namesake `results`
## override `nimble:results`, and step 1 compiles its module.
##
## No mock: a real index repository, the production `repro` binary, a real
## HTTPS mirror on loopback and the host's Nim and C compiler.

import std/[os, strutils, unittest]

import ./nimble_m7_fixtures
import ./nimble_m9_fixtures

const PathsProject* = """
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

suite "NPC-M9: a declared repo overrides the catalog package of its origin":
  test "nim-result overrides results by identity; names override nothing":
    var c = newCliWorld("m9-declared")
    let f = newFixture("m9-declared", c.mirrorRoutes)
    let originUrl = f.url("arnetheduck/nim-results.git")
    let src = f.package("arnetheduck/nim-results.git", @[nimbleFile("results"),
      file("src/results.nim", nimbleModule("CATALOG-M9"))])
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

    let ws = parentDir(dir)
    let appRepo = DeclaredRepoFixture(name: "app",
      path: extractFilename(dir), fetchUrl: "https://example.invalid/app.git")
    let declared = DeclaredRepoFixture(name: "nim-result", path: "nim-result",
      fetchUrl: originUrl)
    let namesakeRepo = DeclaredRepoFixture(name: "results",
      path: "results-ns", fetchUrl: f.url("someone/results.git"))
    writeWorkspace(ws, @[appRepo, declared, namesakeRepo])
    checkoutAt(ws / "nim-result", originUrl, @[
      ("results.nimble", nimbleText()),
      ("src/results.nim", nimbleModule("DECLARED-M9"))])
    checkoutAt(ws / "results-ns", f.url("someone/results.git"), @[
      ("results.nimble", nimbleText()),
      ("src/results.nim", nimbleModule("NAMESAKE-REPO-M9"))])
    checkoutAt(ws / "results", originUrl, @[
      ("results.nimble", nimbleText()),
      ("src/results.nim", nimbleModule("UNDECLARED-M9"))])
    check not fileExists(dir / ".repro" / "develop-overrides.toml")
    check not fileExists(ws / ".repro" / "develop-overrides.toml")

    # 1. The declared repo of the origin's identity, automatically.
    let first = runRepro(env, dir, BuildArgs)
    checkpoint first.output
    check first.rc == 0
    check readFile(dir / "build" / "app-out.txt") == "DECLARED-M9"
    check ("nimble:results <- ../nim-result (declared repo nim-result); " &
      "lock pins " & src.commit) in first.output
    let paths = readFile(dir / "repro.paths")
    checkpoint paths
    let comment = "# develop override of nimble:results: ../nim-result " &
      "(declared repo nim-result)"
    check comment in paths
    let line = "switch(\"path\", \"" & expandFilename(ws / "nim-result") &
      "/src\")"
    check (comment & "\n" & line) in paths
    check (expandFilename(ws / "results-ns") / "src") notin paths
    check (expandFilename(ws / "results") / "src") notin paths
    check src.tree notin paths

    # 2. The command lists the automatic override and proposes only the
    # undeclared checkout; it records nothing.
    let listed = runRepro(env, dir, @["nimble", "develop"])
    checkpoint listed.output
    check listed.rc == 0
    check "nimble:results <- ../nim-result (declared repo nim-result)" in
      listed.output
    check "propose nimble:results <- ../results " in listed.output
    check "propose nimble:results <- ../nim-result" notin listed.output
    check not fileExists(ws / ".repro" / "develop-overrides.toml")
    check not fileExists(dir / ".repro" / "develop-overrides.toml")

    # 3. A recorded override of a fork wins over the declared repo.
    checkoutAt(ws / "results-fork", f.url("someone/results-fork.git"), @[
      ("results.nimble", nimbleText()),
      ("src/results.nim", nimbleModule("FORK-M9"))])
    let recorded = runRepro(env, dir, @["nimble", "develop", "results",
      "--source=" & (ws / "results-fork")])
    checkpoint recorded.output
    check recorded.rc == 0
    let forked = runRepro(env, dir, BuildArgs)
    checkpoint forked.output
    check forked.rc == 0
    check readFile(dir / "build" / "app-out.txt") == "FORK-M9"
    check "nimble:results <- ../results-fork (recorded override)" in
      forked.output
    check "# develop override of nimble:results: ../results-fork " &
      "(recorded override)" in readFile(dir / "repro.paths")

    # 4. Positive control: no override recorded, no declared repo of the
    # origin -- the store tree, and no comment.
    removeFile(ws / ".repro" / "develop-overrides.toml")
    writeWorkspace(ws, @[appRepo, namesakeRepo])
    let control = runRepro(env, dir, BuildArgs)
    checkpoint control.output
    check control.rc == 0
    check readFile(dir / "build" / "app-out.txt") == "CATALOG-M9"
    let controlPaths = readFile(dir / "repro.paths")
    checkpoint controlPaths
    check "# develop override" notin controlPaths
    check src.tree in controlPaths

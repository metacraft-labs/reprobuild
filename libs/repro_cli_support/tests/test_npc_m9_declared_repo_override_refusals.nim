## NPC-M9 verification `test_npc_m9_declared_repo_override_refusals`
## (Nimble-Package-Catalog.md NPC-AREQ27 as amended 2026-11-24, items 2-5).
##
## A project locks `nimble:results` (origin `arnetheduck/nim-results.git`)
## in a workspace that declares repos of that origin:
##
## (a) `nim-result` is declared and not checked out: the build compiles the
##     store tree and says `declared repo nim-result has no checkout`;
## (b) `nim-result` and `nim-result-2` are both declared with the origin's
##     identity and both checked out: the build refuses, naming both and the
##     two remedies; after `repro nimble develop results --source=` records
##     one, the build compiles it;
## (c) the declared repo's `.nimble` is named otherwise than the package:
##     the build refuses, naming the repo, the package and the `.nimble`
##     found. A package whose origin has a `subdir` the checkout lacks is
##     refused, naming the subdir (``effectiveNimbleOverrides``, in
##     process: the fixture forge serves no subdir packages);
## (d) `repro nimble develop results` for a package a declared repo
##     overrides records nothing and says so.
##
## Falsifying mutation (recorded in the plan): taking the first of two
## declared repos of one identity builds it silently, and case (b) fails.
##
## No mock: a real index repository, the production `repro` binary, a real
## HTTPS mirror on loopback and the host's Nim and C compiler.

import std/[os, strutils, unittest]

import ./nimble_m7_fixtures
import ./nimble_m9_fixtures
import repro_cli_support/nimble_develop

suite "NPC-M9: what a declared repo's automatic override refuses":
  test "no checkout, two repos of one identity, another package's .nimble":
    var c = newCliWorld("m9-refusals")
    let f = newFixture("m9-refusals", c.mirrorRoutes)
    let originUrl = f.url("arnetheduck/nim-results.git")
    let src = f.package("arnetheduck/nim-results.git", @[nimbleFile("results"),
      file("src/results.nim", nimbleModule("CATALOG-M9"))])
    c.mirror.putSource(src)
    let rec = f.recordOf("results", src, "v1.0.0")
    discard c.w.publish(@[f.envelope("results", @[rec], src)], daysAgo(1),
      "generation 1", extraFiles = @[("nimble-sources.toml",
        sourceSetText(@[f.ipMirrorUrl("/mirror/")]))])
    let dir = c.w.writeCliProject("app", @[("results", "")],
      "import results\nwriteFile(\"build/app-out.txt\", stamp())\n")
    let env = cliEnv(c.w, f)
    let locked = runRepro(env, dir, @["lock", "refresh", dir, "--inputs",
      dir / "repro.solver", "--provisioning"])
    checkpoint locked.output
    check locked.rc == 0
    let ws = parentDir(dir)
    let appRepo = DeclaredRepoFixture(name: "app",
      path: extractFilename(dir), fetchUrl: "https://example.invalid/app.git")
    let one = DeclaredRepoFixture(name: "nim-result", path: "nim-result",
      fetchUrl: originUrl)
    # The same identity under another spelling of the URL (a userinfo,
    # which the canonical remote identity drops).
    let two = DeclaredRepoFixture(name: "nim-result-2", path: "nim-result-2",
      fetchUrl: originUrl.replace("https://", "https://git@"))
    check two.fetchUrl != originUrl

    # (a) Declared, not checked out: the store tree, and a line.
    writeWorkspace(ws, @[appRepo, one])
    let a = runRepro(env, dir, BuildArgs)
    checkpoint a.output
    check a.rc == 0
    check readFile(dir / "build" / "app-out.txt") == "CATALOG-M9"
    check ("nimble:results: declared repo nim-result has no checkout at " &
      (ws / "nim-result") & "; building the locked tree") in a.output

    # (b) Two declared repos of one identity: refused, naming both.
    writeWorkspace(ws, @[appRepo, one, two])
    checkoutAt(ws / "nim-result", originUrl, @[
      ("results.nimble", nimbleText()),
      ("src/results.nim", nimbleModule("ONE-M9"))])
    checkoutAt(ws / "nim-result-2", originUrl, @[
      ("results.nimble", nimbleText()),
      ("src/results.nim", nimbleModule("TWO-M9"))])
    removeFile(dir / "build" / "app-out.txt")
    let b = runRepro(env, dir, BuildArgs)
    checkpoint b.output
    check b.rc != 0
    check "the declared repos nim-result (" in b.output
    check " and nim-result-2 (" in b.output
    check "so neither overrides it" in b.output
    check "repro nimble develop results --source=<dir>" in b.output
    check "--locked" in b.output
    check not fileExists(dir / "build" / "app-out.txt")
    # One recorded: the build compiles it.
    let rec2 = runRepro(env, dir, @["nimble", "develop", "results",
      "--source=" & (ws / "nim-result-2")])
    checkpoint rec2.output
    check rec2.rc == 0
    let b2 = runRepro(env, dir, BuildArgs)
    checkpoint b2.output
    check b2.rc == 0
    check readFile(dir / "build" / "app-out.txt") == "TWO-M9"
    check "nimble:results <- ../nim-result-2 (recorded override)" in b2.output
    removeFile(ws / ".repro" / "develop-overrides.toml")

    # (d) One declared repo of the identity: `repro nimble develop results`
    # records nothing and says so.
    writeWorkspace(ws, @[appRepo, one])
    let d = runRepro(env, dir, @["nimble", "develop", "results"])
    checkpoint d.output
    check d.rc == 0
    check ("nimble:results is overridden by declared repo nim-result " &
      "(../nim-result) without a recorded override; nothing recorded") in
      d.output
    check not fileExists(ws / ".repro" / "develop-overrides.toml")
    check not fileExists(dir / ".repro" / "develop-overrides.toml")

    # (c) The declared repo's package directory holds another package.
    moveFile(ws / "nim-result" / "results.nimble",
      ws / "nim-result" / "result.nimble")
    let cc = runRepro(env, dir, BuildArgs)
    checkpoint cc.output
    check cc.rc != 0
    check ("nimble:results: declared repo nim-result (" & (ws / "nim-result") &
      ") has its origin") in cc.output
    check "holds result.nimble, a package named \"result\", not \"results\"" in
      cc.output

    # (c) A package whose origin has a subdir the checkout lacks.
    let row = NimbleLockRow(name: "sub", origin: originUrl, subdir: "pkg",
      commit: src.commit, tree: src.tree)
    let eff = effectiveNimbleOverrides(@[row], dir, @[DeclaredRepo(
      name: "nim-result", checkout: ws / "nim-result", fetchUrl: originUrl)],
      locked = false)
    checkpoint $eff.refusals
    check eff.overrides.len == 0
    check eff.refusals.len == 1
    check "the subdir \"pkg\"" in eff.refusals[0]
    check (ws / "nim-result" / "pkg") in eff.refusals[0]

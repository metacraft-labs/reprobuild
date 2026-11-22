## NPC-M7 verification `test_npc_m7_path_order_identical_across_hosts`
## (NPC-AREQ21, Nim-Package-Path-Handling.md § 5).
##
## `repro.paths` for one lock is byte-identical on two hosts with different
## store roots, apart from the store prefix. The two hosts are two builds of
## the same project and lock whose user cache directories -- and so source
## stores -- differ; each fetches the trees into its own store.
##
## The order is the lock's topological order, then name: `alpha` requires
## `zeta`, `beta` requires nothing, so the roots are `beta`, `zeta`,
## `alpha` -- not name order -- and every line is a store tree joined with
## the record's `srcDir`; no line names `.nimble`.

import std/[os, strutils, unittest]

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
$USES
  build:
    discard nim.nimRepropathsConfig()
    discard nim.c(
      source = "src/app.nim",
      binary = "build/bin/app",
      parallelBuild = 1)
"""

suite "NPC-M7: repro.paths is the same on every host":
  test "two store roots, one repro.paths up to the prefix":
    var c = newCliWorld("m7-paths")
    let f = newFixture("m7-paths", c.mirrorRoutes)
    let zeta = f.servePackage(c.mirror, "zeta",
      "proc zeta*(): string = \"Z\"\n")
    let beta = f.servePackage(c.mirror, "beta",
      "proc beta*(): string = \"B\"\n")
    let alpha = f.servePackage(c.mirror, "alpha",
      "import zeta\nproc alpha*(): string = \"A\" & zeta()\n",
      @[req("zeta", ">= 1.0.0")])
    discard c.publishServed(f, @[alpha, beta, zeta])
    let dir = c.w.writeCliProject("app", @[("alpha", ""), ("beta", "")],
      "import alpha, beta\necho alpha() & beta()\n", PathsProject)
    let hostA = cliEnv(c.w, f)
    check runRepro(hostA, dir, @["lock", "refresh", dir, "--inputs",
      dir / "repro.solver", "--provisioning"]).rc == 0

    var texts: seq[string]
    for (label, cache) in [("a", c.w.root / "host-a-cache"),
                           ("b", c.w.root / "host-b" / "deeper" / "cache")]:
      let env = cliEnv(c.w, f, @[("XDG_CACHE_HOME", cache)])
      let built = runRepro(env, dir, BuildArgs)
      checkpoint label & ":\n" & built.output
      check built.rc == 0
      let paths = readFile(dir / "repro.paths")
      checkpoint paths
      let store = cache / "reprobuild" / "store" / "nimble-sources"
      check store in paths
      check ".nimble" notin paths
      texts.add paths.replace(store, "<store>")
    check texts.len == 2
    check texts[0] == texts[1]
    var lines: seq[string]
    for l in texts[0].splitLines():
      if "<store>" in l: lines.add l
    check lines == @[
      "switch(\"path\", \"<store>/" & beta.src.tree & "/src\")",
      "switch(\"path\", \"<store>/" & zeta.src.tree & "/src\")",
      "switch(\"path\", \"<store>/" & alpha.src.tree & "/src\")"]

## NPC-M7: `repro.paths` and the compile follow the lock (NPC-AREQ21,
## Nim-Package-Path-Handling.md § 5). The build hands the provider the
## catalog roots through the environment, so a lowered graph served from
## the cache after the lock moved would list the old tree.
##
## A project builds against `nimble:beta` 1.0.0; a new generation of the
## index adds 1.1.0 and `repro lock refresh` moves the lock to it. The next
## `repro build`, with every cache of the first, compiles against 1.1.0 and
## writes the 1.1.0 tree's root -- and not the 1.0.0 one -- into
## `repro.paths`.
##
## Positive control: the first build's `repro.paths` names the 1.0.0 tree
## and its program prints 1.0.0's stamp, so the second build's answer is a
## change the build made.
##
## No mock: a real index repository, the production `repro` binary, a real
## HTTPS mirror on loopback and the host's Nim and C compiler.

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
    discard shell(
      command = "mkdir -p build && ./build/bin/app",
      actionId = "app.run",
      extraInputs = @["build/bin/app"],
      extraOutputs = @["build/app-out.txt"],
      cacheable = false)
"""

suite "NPC-M7: repro.paths follows the lock":
  test "the second build names the new tree":
    var c = newCliWorld("m7-relock")
    let f = newFixture("m7-relock", c.mirrorRoutes)
    let b1 = f.servePackage(c.mirror, "beta",
      "proc beta*(): string = \"B1\"\n", tag = "v1.0.0")
    discard c.publishServed(f, @[b1], "generation 1")
    let dir = c.w.writeCliProject("app", @[("beta", "")],
      "import beta\nwriteFile(\"build/app-out.txt\", beta())\n", PathsProject)
    let env = cliEnv(c.w, f)
    check runRepro(env, dir, @["lock", "refresh", dir, "--inputs",
      dir / "repro.solver", "--provisioning"]).rc == 0
    let first = runRepro(env, dir, BuildArgs)
    checkpoint first.output
    check first.rc == 0
    check readFile(dir / "build" / "app-out.txt") == "B1"
    check b1.src.tree in readFile(dir / "repro.paths")

    # Version 1.1.0: a second tagged commit of the same served repository.
    let work = f.dir / "work" / b1.src.path
    let c2 = commit(work, @[nimbleFile("beta"),
      file("src/beta.nim", "proc beta*(): string = \"B2\"\n")])
    tag(work, "v1.1.0")
    publish(work)
    let src2 = f.sourceOf(b1.src.path, c2)
    c.mirror.putSource(src2)
    discard c.w.publish(@[f.envelope("beta", @[b1.record,
        f.recordOf("beta", src2, "v1.1.0")], src2)], daysAgo(1),
      "generation 2", extraFiles = @[("nimble-sources.toml",
        sourceSetText(@[f.ipMirrorUrl("/mirror/")]))])
    let relock = runRepro(env, dir, @["lock", "refresh", dir, "--inputs",
      dir / "repro.solver", "--provisioning"])
    checkpoint relock.output
    check relock.rc == 0
    check src2.tree in readFile(dir / "repro.lock")
    removeFile(dir / "build" / "app-out.txt")
    let second = runRepro(env, dir, BuildArgs)
    checkpoint second.output
    check second.rc == 0
    check readFile(dir / "build" / "app-out.txt") == "B2"
    let paths = readFile(dir / "repro.paths")
    checkpoint paths
    check src2.tree in paths
    check b1.src.tree notin paths

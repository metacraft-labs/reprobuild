## NPC-M9 verification `test_npc_m9_override_not_in_locked_build`
## (Nimble-Package-Catalog NPC-AREQ27; threat model G20).
##
## A project locks `nimble:results`; a sibling clone of its origin is
## recorded as its develop override (`repro nimble develop results`), and
## the sibling's module is a marker that refuses to compile. Then:
##
## * `repro build --locked` builds from the store tree the lock pins: it
##   succeeds and the program prints the catalog's stamp, and it says the
##   override is not applied;
## * the same build without `--locked` applies the override and fails on
##   the marker. That is the positive control: the override is live, so the
##   locked build's success is the flag's doing;
## * the lock's `nimble:results` row has no checkout location although an
##   override of that name exists, so the commit-path re-pin, which moves an
##   entry to the HEAD of the checkout it is placed at, cannot move the
##   catalog pin to the sibling's HEAD.
##
## Falsifying mutation (recorded in the plan): applying develop overrides in
## a locked build compiles the sibling's marker module and fails the test.
##
## No mock: a real index repository, the production `repro` binary, a real
## HTTPS mirror on loopback and the host's Nim and C compiler.

import std/[os, osproc, strutils, unittest]

from repro_core/process_streams import drainStream

import ./nimble_m7_fixtures

const Marker = "NPC-M9 develop sibling compiled in a locked build"

proc sh(args: openArray[string]; cwd = ""): string =
  let argv = @args
  let p = startProcess(argv[0], workingDir = cwd, args = argv[1 .. ^1],
    options = {poUsePath, poStdErrToStdOut})
  result = drainStream(p.outputStream)
  let rc = p.waitForExit()
  p.close()
  doAssert rc == 0, args.join(" ") & ": " & result

suite "NPC-M9: a locked build ignores develop overrides":
  test "--locked builds the store tree with an override recorded":
    var c = newCliWorld("m9-locked")
    let f = newFixture("m9-locked", c.mirrorRoutes)
    let src = f.package("arnetheduck/nim-results.git", @[nimbleFile("results"),
      file("src/results.nim", "proc stamp*(): string = \"CATALOG-M9\"\n")])
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

    let sibling = parentDir(dir) / "nim-result"
    createDir(sibling / "src")
    discard sh(["git", "init", "-q", "-b", "main", sibling])
    discard sh(["git", "-C", sibling, "remote", "add", "origin",
      f.url("arnetheduck/nim-results.git")])
    writeFile(sibling / "results.nimble",
      "version = \"1.0.0\"\nsrcDir = \"src\"\n")
    writeFile(sibling / "src" / "results.nim",
      "{.error: \"" & Marker & "\".}\nproc stamp*(): string = \"SIBLING\"\n")
    let recorded = runRepro(env, dir, @["nimble", "develop", "results"])
    checkpoint recorded.output
    check recorded.rc == 0
    check fileExists(dir / ".repro" / "develop-overrides.toml")

    let built = runRepro(env, dir, BuildArgs & @["--locked"])
    checkpoint built.output
    check built.rc == 0
    check readFile(dir / "build" / "app-out.txt") == "CATALOG-M9"
    check "the develop override of nimble:results" in built.output
    check "is not applied" in built.output
    check Marker notin built.output

    # Positive control: the override is live outside --locked.
    removeFile(dir / "build" / "app-out.txt")
    let develop = runRepro(env, dir, BuildArgs)
    checkpoint develop.output
    check develop.rc != 0
    check Marker in develop.output

    # The catalog row is never placed at the sibling.
    let ld = parseLockedDepsAt(readFile(dir / "repro.lock"), dir)
    var rows = 0
    for d in ld.deps:
      if d.name == "nimble:results":
        inc rows
        check d.path == ""
        check d.coordinates.revision == src.commit
    check rows == 1

## NPC-M7 verification `test_npc_compile_edge_has_no_package_but_locked`
## (NPC-AREQ20, NPC-AREQ21, threat model G18).
##
## A source file that imports a package which is not in the lock fails to
## compile, and the build made no network attempt for it: the mirror logs
## no request during the build. The package is not missing from the world:
## a tree of it sits in the user's source store (a package cache) and
## under `$HOME/.nimble/pkgs2` of the build's `HOME`, and a compile edge is
## handed neither -- only the lock's packages' roots.
##
## Positive control: the locked package, imported alone, compiles.
##
## Falsifying mutation (recorded in the plan): adding a fallback path to a
## package cache (every tree of the store on the compile's `--path`) makes
## the import succeed and fails the test.

import std/[os, strutils, unittest]

import ./nimble_m7_fixtures

suite "NPC-M7: a compile edge has no package but the locked ones":
  test "an import outside the lock fails without a request":
    var c = newCliWorld("m7-onlylocked")
    let f = newFixture("m7-onlylocked", c.mirrorRoutes)
    let locked = f.servePackage(c.mirror, "locked",
      "proc locked*(): string = \"L\"\n")
    let stray = f.servePackage(c.mirror, "stray",
      "proc stray*(): string = \"S\"\n")
    discard c.publishServed(f, @[locked, stray])
    let dir = c.w.writeCliProject("app", @[("locked", "")],
      "import locked\nwriteFile(\"build/app-out.txt\", locked())\n")
    let env = cliEnv(c.w, f)
    check runRepro(env, dir, @["lock", "refresh", dir, "--inputs",
      dir / "repro.solver", "--provisioning"]).rc == 0
    check "nimble:stray" notin readFile(dir / "repro.lock")

    # Positive control: the locked import compiles (and fills the store).
    let ok = runRepro(env, dir, BuildArgs)
    checkpoint ok.output
    check ok.rc == 0
    check readFile(dir / "build" / "app-out.txt") == "L"

    # The stray package is in reach of a careless compile: in the source
    # store and in Nimble's directory of the build's HOME.
    let store = c.w.storeRootOf()
    let strayTree = c.w.root / "stray-tree"
    createDir(strayTree / "src")
    writeFile(strayTree / "src" / "stray.nim", "proc stray*(): string = \"S\"\n")
    copyDir(strayTree, store / stray.src.tree)
    let pkgs2 = c.w.root / "home" / ".nimble" / "pkgs2" /
      ("stray-1.0.0-" & repeat("cd", 20))
    createDir(pkgs2)
    writeFile(pkgs2 / "stray.nim", "proc stray*(): string = \"S\"\n")

    writeFile(dir / "src" / "app.nim",
      "import locked, stray\nwriteFile(\"build/app-out.txt\", locked() & stray())\n")
    removeFile(dir / "build" / "app-out.txt")
    let before = f.requests().len
    let refused = runRepro(env, dir, BuildArgs)
    checkpoint refused.output
    check refused.rc != 0
    check "cannot open file: stray" in refused.output
    check not fileExists(dir / "build" / "app-out.txt")
    check f.requests().len == before

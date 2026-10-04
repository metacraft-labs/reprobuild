## A lock refresh never re-pins -- and never silently drops -- a catalog
## import pin (ReproOS-Campaign-Completion M6 deliverable 1;
## ``reprobuild-specs/Federated-Catalog-Imports.md`` § Pinning).
##
## A consumer may declare a catalog by a moving ``ref``; the committed lock
## pins the exact revision. Only the explicit ``repro lock refresh
## --provisioning`` re-resolves it. The two doors that rewrite the committed
## lock from a SOLVE -- ``repro lock refresh`` and ``repro lock solve
## --write`` -- know nothing about catalogs, so they carry the
## ``catalog_imports`` array forward byte for byte, and refuse (leaving the
## lock byte-identical) when the incumbent's array cannot be read.
##
## Each assertion has a control: the solved graph DOES move (``highest`` ->
## ``lowest``), so the file really was rewritten; a lock without pins is
## rewritten exactly as before.
##
## Test-double policy: NO mocks, doubles or fakes (see ``nlf_m6_fixture``).

import std/[os, strutils, tables, unittest]

import repro_lock
import repro_lock_gen
import repro_solver

import ./nlf_m6_fixture

const
  App = "app"
  LibFoo = "libfoo"
  Published = ["1.2.0", "1.4.0", "1.9.0"]

proc workspace(): seq[PackageDecl] =
  @[
    newPackage(App, @["1.0.0"], @[newDependency(LibFoo, ">=1.2 <2.0")]),
    newPackage(LibFoo, @["1.2.0"])]

proc pin(): LockedCatalogImport =
  LockedCatalogImport(repo: "libfoo-catalog",
    remote: "https://example.invalid/libfoo-catalog", gitRef: "main",
    revision: repeat('b', 40), interfaceArtifact: repeat('d', 64))

proc pinsLine(document: string): string =
  for line in document.splitLines():
    if line.startsWith(CatalogImportsLockKey & " = "):
      return line
  ""

proc pinCatalogs(committed: string) =
  writeFile(committed, serializeLockedDependencies(
    parseLockedDependencies(readFile(committed)).withCatalogImportPins(
      @[pin()])))

template carriesForwardThrough(door: string) =
  block:
    let reg = startRegistry("pins-carry-" &
      door.replace(" ", "").replace("-", ""))
    try:
      reg.server.publish(App, ["1.0.0"])
      reg.server.publish(LibFoo, Published)
      let committed = reg.scratch / "project" / "repro.lock"
      discard runLockSolve(reg.request(workspace(), lsHighest), committed)
      pinCatalogs(committed)
      let pinned = pinsLine(readFile(committed))
      check pinned.len > 0
      let rewritten =
        if door == "refresh":
          runLockRefresh(reg.request(workspace(), lsLowest), committed)
        else:
          runLockSolve(reg.request(workspace(), lsLowest), committed)
      let after = readFile(committed)
      check lockToSolution(parseSolvedGraphLock(after)).packages[LibFoo] ==
        "1.2.0"
      check rewritten.lockDocument == after
      check pinsLine(after) == pinned
      let parsed = parseLockedDependencies(after)
      check parsed.lockedCatalogImportPins() == @[pin()]
      check rewritten.lockIdentity == lockIdentityOf(parsed)
      check lockIdentityOf(parsed) == lockIdentityOf(
        parseLockedDependencies(after.replace(pinned & "\n", "")))
    finally:
      reg.shutdown()

suite "a lock refresh carries catalog import pins forward":

  test "`repro lock refresh` keeps the catalog_imports array unchanged":
    carriesForwardThrough("refresh")

  test "`repro lock solve --write` keeps the catalog_imports array unchanged":
    carriesForwardThrough("solve --write")

  test "a refresh refuses, and does not overwrite, unreadable catalog import pins":
    let reg = startRegistry("pins-carry-refuse")
    try:
      reg.server.publish(App, ["1.0.0"])
      reg.server.publish(LibFoo, Published)
      let committed = reg.scratch / "project" / "repro.lock"
      discard runLockSolve(reg.request(workspace(), lsHighest), committed)
      pinCatalogs(committed)
      let pinned = pinsLine(readFile(committed))
      let rhs = pinned[pinned.find('=') + 1 .. ^1].strip()
      for damaged in [pinned[0 ..< pinned.len - 3], "catalog_imports",
                      pinned.replace(repeat('b', 40), "main"),
                      "\"catalog_imports\" = " & rhs,
                      "Catalog_Imports = " & rhs,
                      "[CATALOG_IMPORTS]"]:
        let incumbent = readFile(committed).replace(pinned, damaged)
        writeFile(committed, incumbent)
        var refusal = ""
        try:
          discard runLockRefresh(reg.request(workspace(), lsLowest), committed)
        except CatchableError as err:
          refusal = err.msg
        check CatalogImportsLockKey in refusal
        check "refusing" in refusal
        check readFile(committed) == incumbent
        writeFile(committed, incumbent.replace(damaged, pinned))
    finally:
      reg.shutdown()

  test "a lock without catalog import pins is rewritten exactly as before":
    let reg = startRegistry("pins-carry-control")
    try:
      reg.server.publish(App, ["1.0.0"])
      reg.server.publish(LibFoo, Published)
      let committed = reg.scratch / "project" / "repro.lock"
      discard runLockSolve(reg.request(workspace(), lsHighest), committed)
      let rewritten = runLockRefresh(reg.request(workspace(), lsLowest),
        committed)
      let after = readFile(committed)
      check CatalogImportsLockKey notin after
      check after == rewritten.lockDocument
    finally:
      reg.shutdown()

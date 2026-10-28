## The lock's dependency set records the `reprobuild-packages` catalog that
## supplied a realization, at its revision.
##
## reprobuild-specs/Provisioning-Contributions.md, "Locks And Snapshots": a
## locked realization records "catalog repository coordinates and revision".
## `repro lock refresh` assembles `deps` in `lockedDepsForWorkspace`; this test
## drives that assembly directly, with the catalog roots
## `catalogRootsOfToolUses` reads off a tool use's realizations, against real
## git repositories in a temp directory. (The end-to-end form, through a real
## `repro lock refresh` and its provider compile, is
## `t_lock_refresh_records_the_catalog_a_package_resolved_from`.) Nothing is
## mocked.

import std/[options, os, osproc, strutils, tempfiles, unittest]

import repro_interface_artifacts
import repro_lock
import repro_cli_support
import repro_project_dsl/reprobuild_packages_catalog

proc git(repo: string; args: varargs[string]): string =
  var command = "git -C " & quoteShell(repo)
  for arg in args:
    command.add(" " & quoteShell(arg))
  let (output, code) = execCmdEx(command, options = {poStdErrToStdOut, poUsePath})
  doAssert code == 0, command & "\n" & output
  output.strip()

proc initRepo(dir, origin: string) =
  createDir(dir)
  discard git(dir, "init", "-q", "-b", "main")
  discard git(dir, "config", "user.email", "t@example.invalid")
  discard git(dir, "config", "user.name", "Tester")
  discard git(dir, "config", "commit.gpgsign", "false")
  discard git(dir, "remote", "add", "origin", origin)

proc commitAll(dir: string) =
  discard git(dir, "add", ".")
  discard git(dir, "commit", "-q", "-m", "snapshot")

proc catalogUse(interfaceFile: string): InterfaceToolUse =
  InterfaceToolUse(packageSelector: "rpfixture", executableName: "rpfixture",
    tarballProvisioning: @[InterfaceTarballProvisioning(
      packageName: "rpfixture", packageId: "rpfixture@1.0",
      location: SourceLocation(file: interfaceFile, line: 3))])

proc writeInterface(catalog: string): string =
  result = catalog / "packages" / "interfaces" / "rpfixture" / "repro.nim"
  createDir(result.parentDir)
  writeFile(result, "# fixture\n")

proc catalogDep(deps: seq[LockedDep]): Option[LockedDep] =
  for d in deps:
    if d.name == "reprobuild-packages":
      return some(d)

suite "the lock records the catalog revision":
  let scratch = createTempDir("repro-locked-catalog-", "")
  let consumer = scratch / "consumer"
  initRepo(consumer, "https://example.invalid/acme/consumer.git")
  writeFile(consumer / "repro.nim", "# consumer\n")
  commitAll(consumer)

  test "a realization's location names its catalog, and only a catalog's":
    let file = scratch / "reprobuild-packages" / "packages" / "interfaces" /
      "rpfixture" / "repro.nim"
    check catalogRootsOfToolUses([catalogUse(file)]).len == 1
    check cmpPaths(catalogRootsOfToolUses([catalogUse(file)])[0],
      scratch / "reprobuild-packages") == 0
    check catalogRootsOfToolUses([catalogUse(
      scratch / "libs" / "repro_dsl_stdlib" / "packages" / "nim.nim")]).len == 0

  test "a sibling catalog checkout is recorded at its HEAD":
    let catalog = scratch / "reprobuild-packages"
    initRepo(catalog,
      "https://example.invalid/metacraft-labs/reprobuild-packages.git")
    let file = writeInterface(catalog)
    commitAll(catalog)
    let head = git(catalog, "rev-parse", "HEAD")
    let deps = lockedDepsForWorkspace(consumer,
      catalogRoots = catalogRootsOfToolUses([catalogUse(file)]))
    let dep = catalogDep(deps)
    check dep.isSome
    if dep.isSome:
      check dep.get.path == "../reprobuild-packages"
      check dep.get.coordinates.kind == ckVcs
      check dep.get.coordinates.revision == head
      check dep.get.coordinates.url ==
        "https://example.invalid/metacraft-labs/reprobuild-packages.git"
      check dep.get.integrity == "git-sha1:" & head
    var rootDepends: seq[string]
    for d in deps:
      if d.path == ".":
        rootDepends = d.depends
    check "reprobuild-packages" in rootDepends
    removeDir(catalog)

  test "a catalog copy is recorded at the revision its marker names":
    let catalog = scratch / "reprobuild-packages"
    let file = writeInterface(catalog)
    let pinned = "0123456789abcdef0123456789abcdef01234567"
    writeFile(catalog / CatalogRevisionMarkerFile,
      "url=https://example.invalid/metacraft-labs/reprobuild-packages\n" &
      "revision=" & pinned & "\n")
    let dep = catalogDep(lockedDepsForWorkspace(consumer,
      catalogRoots = catalogRootsOfToolUses([catalogUse(file)])))
    check dep.isSome
    if dep.isSome:
      check dep.get.coordinates.revision == pinned
      check dep.get.coordinates.url ==
        "https://example.invalid/metacraft-labs/reprobuild-packages"
      check dep.get.integrity == "git-sha1:" & pinned
      check dep.get.path == "../reprobuild-packages"
    removeDir(catalog)

  test "a catalog inside the project's own repository is not recorded":
    let inside = consumer / "tests" / "reprobuild-packages"
    let file = writeInterface(inside)
    commitAll(consumer)
    check catalogLockedDep(inside, consumer, @[]).isNone
    check catalogDep(lockedDepsForWorkspace(consumer,
      catalogRoots = catalogRootsOfToolUses([catalogUse(file)]))).isNone

  test "a fetched catalog keeps its locked identity through both discovery routes":
    let temp = createTempDir("repro-fetched-catalog-", "")
    defer: removeDir(temp)
    let source = temp / "catalog-source"
    initRepo(source, "https://example.invalid/reprobuild-packages.git")
    discard writeInterface(source)
    commitAll(source)
    let app = temp / "app"
    initRepo(app, "https://example.invalid/app.git")
    writeFile(app / "repro.nim", "# app\n")
    commitAll(app)
    let head = git(source, "rev-parse", "HEAD")
    let pin = LockedDep(name: "reprobuild-packages", path: "../reprobuild-packages",
      coordinates: Coordinates(kind: ckVcs, url: source,
        gitRef: "main", revision: head), integrity: "git-sha1:" & head,
      visibility: "public")
    writeFile(app / "repro.lock",
      serializeLockedDependencies(LockedDependencies(deps: @[pin])))
    # The real fetch deliberately creates no remote. Its directory leaf is
    # the revision, which must never become a dependency identity.
    let fetched = fetchLockPinnedProducer(pin, app)
    check git(fetched, "remote").len == 0
    check fetched.extractFilename == head
    for route in 0 .. 2:
      let deps = lockedDepsForWorkspace(app,
        sourceRecipeRoots = (if route != 1: @[fetched / "packages"] else: @[]),
        catalogRoots = (if route != 0: @[fetched] else: @[]))
      let dep = catalogDep(deps)
      check deps.len == 2
      check dep.isSome
      for entry in deps:
        check entry.name != head
        if isSelfLockedDep(entry):
          check entry.depends == @[pin.name]
      if dep.isSome:
        check dep.get.coordinates.url == pin.coordinates.url
        check dep.get.coordinates.gitRef == pin.coordinates.gitRef
        check dep.get.coordinates.revision == head
        check dep.get.integrity == pin.integrity
      discard serializeLockedDependencies(LockedDependencies(deps: deps))
    var ephemeral = pin
    ephemeral.coordinates.gitRef = "agents-to-dev-2026-10-03"
    writeFile(app / "repro.lock",
      serializeLockedDependencies(LockedDependencies(deps: @[ephemeral])))
    let normalized = catalogDep(lockedDepsForWorkspace(app,
      catalogRoots = @[fetched]))
    require normalized.isSome
    check normalized.get.coordinates.gitRef == ""
    writeFile(app / "repro.lock",
      serializeLockedDependencies(LockedDependencies(deps: @[pin])))
    # The directory's spelling alone is not proof of the pin: an altered
    # cached checkout must fail instead of being certified with old metadata.
    discard git(fetched, "-c", "user.name=Tester", "-c",
      "user.email=t@example.invalid", "-c", "commit.gpgsign=false",
      "commit", "--allow-empty", "-q", "-m", "alter cached HEAD")
    for route in 0 .. 1:
      expect OSError:
        discard lockedDepsForWorkspace(app,
          sourceRecipeRoots = (if route == 0: @[fetched / "packages"] else: @[]),
          catalogRoots = (if route == 1: @[fetched] else: @[]))

  test "a detached sibling at the pinned commit preserves its advisory ref":
    let temp = createTempDir("repro-detached-catalog-", "")
    defer: removeDir(temp)
    let app = temp / "app"
    initRepo(app, "https://example.invalid/app.git")
    writeFile(app / "repro.nim", "# app\n")
    commitAll(app)
    let catalog = temp / "reprobuild-packages"
    initRepo(catalog, "https://example.invalid/reprobuild-packages.git")
    discard writeInterface(catalog)
    commitAll(catalog)
    let head = git(catalog, "rev-parse", "HEAD")
    let pin = LockedDep(name: "reprobuild-packages", path: "../reprobuild-packages",
      coordinates: Coordinates(kind: ckVcs,
        url: "https://example.invalid/reprobuild-packages.git",
        gitRef: "main", revision: head),
      integrity: "git-sha1:" & head, visibility: "public")
    writeFile(app / "repro.lock",
      serializeLockedDependencies(LockedDependencies(deps: @[pin])))
    discard git(catalog, "checkout", "--detach", head)
    discard git(catalog, "fetch", ".", "main:refs/remotes/origin/main")
    let dep = catalogDep(lockedDepsForWorkspace(app, catalogRoots = @[catalog]))
    require dep.isSome
    check dep.get.coordinates.gitRef == pin.coordinates.gitRef
    check dep.get.coordinates.url == pin.coordinates.url
    check dep.get.coordinates.revision == head

  removeDir(scratch)

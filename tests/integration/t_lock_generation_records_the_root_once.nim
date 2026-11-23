## The root may be discovered again through a producer cycle; it remains one
## authoritative self record. Real temporary Git repositories, real discovery,
## real clingo generation and strict v3 writing/reading; no test doubles.
## Repository origins are non-network fixture identities, never fetched.
import std/[os, osproc, strutils, tempfiles, unittest]
import repro_cli_support
import repro_lock
import repro_lock_gen
import repro_solver

proc git(repo: string; args: varargs[string]): string =
  var cmd = "git -C " & quoteShell(repo)
  for arg in args: cmd.add(" " & quoteShell(arg))
  let (output, code) = execCmdEx(cmd)
  doAssert code == 0, output
  output.strip()

proc initRepo(path, name, recipe: string) =
  createDir(path)
  discard git(path, "init", "-q", "-b", "main")
  discard git(path, "config", "user.name", "Fixture")
  discard git(path, "config", "user.email", "fixture@example.invalid")
  discard git(path, "config", "commit.gpgsign", "false")
  discard git(path, "remote", "add", "origin", "https://example.invalid/" & name & ".git")
  writeFile(path / "repro.nim", recipe)
  discard git(path, "add", "repro.nim")
  discard git(path, "commit", "-qm", "fixture")

proc request(scratch: string; deps: seq[LockedDep]): LockGenerationRequest =
  LockGenerationRequest(workDir: scratch / "generation", platform: "amd64-linux",
    inputsText: "consumer uses producer; producer uses consumer",
    packages: @[newPackage("consumer", ["1.0.0"], [newDependency("producer", ">=1")]),
      newPackage("producer", ["1.0.0"], [newDependency("consumer", ">=1")])],
    extraDeps: deps)

suite "lock generation records the root once":
  test "a producer cycle reaches the current checkout without adding a sibling self":
    let scratch = createTempDir("repro-root-cycle-", "")
    defer: removeDir(scratch)
    let app = scratch / "consumer"
    let producer = scratch / "producer"
    initRepo(app, "consumer", "import repro_project_dsl\npackage consumer:\n  library consumer\n  uses: \"producer\"\n")
    initRepo(producer, "producer", "import repro_project_dsl\npackage producer:\n  library producer\n  uses: \"consumer\"\n")
    let deps = lockedDepsForWorkspace(app, usesSelectors = @["producer", "consumer"])
    let generated = runLockRefresh(request(scratch, deps), app / "repro.lock")
    let parsed = parseLockedDependencies(generated.lockDocument)
    check parsed.schema == SolvedGraphLockSchemaV3
    check parsed.deps.len == 2
    check generated.lockDocument.count("self = \"true\"") == 1
    for d in parsed.deps:
      if isSelfLockedDep(d):
        check d.name == "consumer"
        check d.coordinates.revision == git(app, "rev-parse", "HEAD")
        check d.depends == @["producer"]
      else:
        check d.name == "producer"
        check d.coordinates.revision == git(producer, "rev-parse", "HEAD")
    check readFile(app / "repro.lock") == generated.lockDocument

  test "a different repository with the root name is still refused without writing":
    let scratch = createTempDir("repro-root-collision-", "")
    defer: removeDir(scratch)
    let app = scratch / "checkout"
    let collision = scratch / "consumer"
    initRepo(app, "consumer", "# root\n")
    initRepo(collision, "different-repository", "# independent sibling\n")
    let lockPath = app / "repro.lock"
    writeFile(lockPath, "unchanged sentinel\n")
    let deps = lockedDepsForWorkspace(app, usesSelectors = @["consumer"])
    var message = ""
    try:
      discard runLockRefresh(request(scratch, deps), lockPath)
    except CatchableError as err:
      message = err.msg
    checkpoint(message)
    check "duplicate locked dependency name 'consumer'" in message
    check readFile(lockPath) == "unchanged sentinel\n"

  test "targeted regeneration refreshes self while holding every sibling and unnamed package":
    let scratch = createTempDir("repro-root-repin-", "")
    defer: removeDir(scratch)
    let app = scratch / "consumer"
    let producer = scratch / "producer"
    initRepo(app, "consumer", "# consumer\n")
    initRepo(producer, "producer", "# producer\n")
    let selectors = @["producer", "consumer"]
    let oldDeps = lockedDepsForWorkspace(app, usesSelectors = selectors)
    let old = parseLockedDependencies(runLockRefresh(request(scratch, oldDeps),
      app / "repro.lock").lockDocument)
    # Both real repositories move. Only the self provenance may move in the
    # targeted result; the sibling remains at its committed pin.
    for repo in [app, producer]:
      writeFile(repo / "repro.nim", "# advanced\n")
      discard git(repo, "add", "repro.nim")
      discard git(repo, "commit", "-qm", "advance")
    var fresh = request(scratch / "fresh", lockedDepsForWorkspace(app,
      usesSelectors = selectors))
    fresh.inputsText = "new recipe inputs"
    fresh.strategy = lsHighest
    fresh.packages = @[
      newPackage("consumer", ["1.0.0", "1.0.1"], [newDependency("producer", ">=1")]),
      newPackage("producer", ["1.0.0", "2.0.0"], [newDependency("consumer", ">=1")])]
    holdCommittedPins(fresh, old, ["consumer"], app / "repro.lock",
      proc (pkg: string): bool = false)
    let regenerated = runLockRepin(fresh, old, ["consumer"], app / "repro.lock")
    let actual = parseLockedDependencies(regenerated.lockDocument)
    check actual.deps.len == old.deps.len
    check actual.packages.len == old.packages.len
    check actual.inputsDigest != old.inputsDigest
    check actual.platform == old.platform
    check actual.variants == old.variants
    check actual.certificatePolicySection == old.certificatePolicySection
    for d in actual.deps:
      if isSelfLockedDep(d):
        check d.name == "consumer"
        check d.coordinates.revision == git(app, "rev-parse", "HEAD")
        check d.integrity == "git-sha1:" & d.coordinates.revision
        check d.depends == @["producer"]
      else:
        var found = false
        for prior in old.deps:
          if prior.name == d.name:
            check serializeLockedDependencies(LockedDependencies(deps: @[d])) ==
              serializeLockedDependencies(LockedDependencies(deps: @[prior]))
            check d.coordinates.revision != git(producer, "rev-parse", "HEAD")
            found = true
        check found
    for pkg in actual.packages:
      if pkg.name == "consumer":
        check pkg.version == "1.0.1"
      else:
        var found = false
        for prior in old.packages:
          if prior.name == pkg.name:
            check pkg == prior
            found = true
        check found
    check regenerated.lockDocument.count("self = \"true\"") == 1
    check readFile(app / "repro.lock") == regenerated.lockDocument

  test "a root reached through a cycle cannot hide a later different-repository name collision":
    let scratch = createTempDir("repro-root-mixed-", "")
    defer: removeDir(scratch)
    let app = scratch / "consumer"
    let producer = scratch / "producer"
    let collision = scratch / "other-repository"
    initRepo(app, "consumer", "# invoking consumer\n")
    initRepo(producer, "producer", "# producer reaches consumer\n")
    initRepo(collision, "consumer", "# distinct catalog repository\n")
    discard git(collision, "remote", "set-url", "origin",
      "https://example.invalid/other-organization/consumer.git")
    let lockPath = app / "repro.lock"
    for (selectors, roots) in [
        (@["consumer", "producer"], @[collision]),
        (@["producer", "consumer"], @[collision]),
        (@["producer"], @[app, collision]),
        (@["producer"], @[collision, app])]:
      writeFile(lockPath, "unchanged sentinel\n")
      let deps = lockedDepsForWorkspace(app, usesSelectors = selectors,
        sourceRecipeRoots = roots)
      var message = ""
      try:
        discard runLockRefresh(request(scratch / selectors[0], deps), lockPath)
      except CatchableError as err:
        message = err.msg
      checkpoint(message)
      check "duplicate locked dependency name 'consumer'" in message
      check readFile(lockPath) == "unchanged sentinel\n"

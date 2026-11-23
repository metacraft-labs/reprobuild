## Regresses the real isolated provider compile reached by lock refresh.
## A moved stdlib name forces the missing-catalog diagnostic, while a nested
## consumer and explicit A/B selections cover both search-location boundaries.
## No mocks: local git repositories contain minimal, valid catalog interfaces;
## the built CLI runs real interface extraction, monitored provider compilation
## and solve. Archive URLs describe candidates only and are never downloaded.
## The sibling case stages the real libraries in an installed-source layout
## without a bundled catalog, so a development checkout's fallback cannot mask
## a broken consumer anchor. Explicit catalogs export different runtime markers;
## the provider's module initialization writes the selected marker to a fixture
## witness. Lock refresh invokes a manifest, not the build graph, so the witness
## is gated on provider mode and cleared before every refresh.
## See Provisioning-Contributions.md, "Catalog Lookup And Provisioning".

import std/[os, osproc, strtabs, strutils, tempfiles, unittest]

import repro_lock
import repro_test_support/process_fixtures

const ReprobuildRepoRoot = currentSourcePath().parentDir.parentDir.parentDir
let reproBinary = getEnv("REPROBUILD_TEST_CLI",
  ReprobuildRepoRoot / "build/bin/repro".addFileExt(ExeExt))

const CatalogInterface = """
import std/os
import repro_project_dsl

proc selectedCatalogMarker(): string = "catalog-one"

when defined(reproProviderMode):
  writeFile(CATALOG_WITNESS, selectedCatalogMarker())

package shellcheck:
  provisioning:
    tarball url = "https://example.invalid/shellcheck-1.0.zip",
      sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
      archiveType = "zip",
      executablePath = "shellcheck",
      packageId = "shellcheck@1.0",
      lockIdentity = "tarball:shellcheck@1.0:sha256:0000000000000000000000000000000000000000000000000000000000000000"
"""

const ConsumerRecipe = """
import repro_project_dsl

package consumer:
  defaultToolProvisioning "path"
  uses:
    "nim >=2.0"
    "shellcheck"
  build:
    discard aggregate("consumer-aggregate", actions = @[])
"""

proc childEnv(catalogRoot = ""; libsRoot = ""; actionCacheRoot = ""): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    if key.toUpperAscii() != "REPROBUILD_PACKAGES_ROOT":
      result[key] = value
  if catalogRoot.len > 0:
    result["REPROBUILD_PACKAGES_ROOT"] = catalogRoot
  if libsRoot.len > 0:
    result["REPROBUILD_LIBS_DIR"] = libsRoot
  if actionCacheRoot.len > 0:
    result["REPROBUILD_ACTION_CACHE_ROOT"] = actionCacheRoot
  result["REPRO_DAEMON"] = "off"

proc run(command: string; cwd = ""; catalogRoot = ""; libsRoot = ""; actionCacheRoot = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, options = {poStdErrToStdOut, poUsePath},
    workingDir = cwd, env = childEnv(catalogRoot, libsRoot, actionCacheRoot))
  (code: res.exitCode, output: res.output)

proc git(repo: string; args: varargs[string]): string =
  var command = "git -C " & quoteShell(repo)
  for arg in args:
    command.add(" " & quoteShell(arg))
  let (code, output) = run(command)
  doAssert code == 0, command & "\n" & output
  output.strip()

proc initRepo(dir, origin: string) =
  createDir(dir)
  discard git(dir, "init", "-q", "-b", "main")
  discard git(dir, "config", "user.email", "t@example.invalid")
  discard git(dir, "config", "user.name", "Tester")
  discard git(dir, "config", "commit.gpgsign", "false")
  discard git(dir, "remote", "add", "origin", origin)

proc writeCatalog(root: string; marker = "catalog-one"; version = "1.0") =
  let dir = root / "packages" / "interfaces" / "shellcheck"
  createDir(dir)
  writeFile(dir / "repro.nim", CatalogInterface
    .replace("CATALOG_WITNESS", escape(root.parentDir / "catalog-witness"))
    .replace("catalog-one", marker).replace("1.0", version))

proc makeConsumer(scratch: string): string =
  result = scratch / "nested" / "consumer-checkout"
  initRepo(result, "https://example.invalid/acme/consumer.git")
  writeFile(result / "repro.nim", ConsumerRecipe)
  discard git(result, "add", "repro.nim")
  discard git(result, "commit", "-q", "-m", "consumer")

proc catalogEntry(lockBody: string): string =
  ## The `deps` inline table naming reprobuild-packages, or "".
  let start = lockBody.find("{ name = \"reprobuild-packages\"")
  if start < 0:
    return ""
  lockBody[start .. lockBody.find(" }", start) + 1]

proc rootDepends(lockBody: string): string =
  ## The `depends` value of the root (`self = "true"`) dependency.
  let at = lockBody.find("self = \"true\"")
  if at < 0:
    return ""
  let key = lockBody.find("depends = \"", at)
  if key < 0:
    return ""
  let start = key + "depends = \"".len
  lockBody[start ..< lockBody.find('"', start)]

proc commitCatalog(root: string; marker = "catalog-one"): string =
  initRepo(root, "https://example.invalid/metacraft-labs/reprobuild-packages.git")
  writeCatalog(root, marker)
  discard git(root, "add", ".")
  discard git(root, "commit", "-q", "-m", "catalog")
  git(root, "rev-parse", "HEAD")

proc refresh(consumer: string; catalogRoot = ""; libsRoot = ""): tuple[code: int; output: string] =
  let witness = consumer.parentDir.parentDir / "catalog-witness"
  if fileExists(witness):
    removeFile(witness)
  doAssert not fileExists(witness)
  run(quoteShell(reproBinary) & " lock refresh " & quoteShell(consumer),
    catalogRoot = catalogRoot, libsRoot = libsRoot,
    actionCacheRoot = consumer.parentDir / "action-cache")

suite "lock refresh compiles providers using the consumer's catalog":
  test "a moved package resolves from an ancestor's workspace sibling":
    require findExe("git").len > 0
    require fileExists(reproBinary)
    let scratch = createTempDir("repro-provider-sibling-catalog-", "")
    defer: removeDir(scratch)
    let catalog = scratch / "reprobuild-packages"
    let revision = commitCatalog(catalog)
    let consumer = makeConsumer(scratch)
    # A source distribution without a bundled catalog must find the consumer's
    # sibling. The development checkout's fallback catalog defines shellcheck
    # too, so using it here would mask a broken recipe-location diagnostic.
    let installedLibs = scratch / "installed/share/repro/source/libs"
    copyDir(ReprobuildRepoRoot / "libs", installedLibs)
    let result = refresh(consumer, libsRoot = installedLibs)
    checkpoint(result.output)
    require result.code == 0
    require fileExists(scratch / "catalog-witness")
    check readFile(scratch / "catalog-witness") == "catalog-one"
    let body = readFile(consumer / "repro.lock")
    check ("revision = \"" & revision & "\"") in catalogEntry(body)
    check "reprobuild-packages" in rootDepends(body)

  test "the explicit catalog reaches the provider, switches, and never falls back":
    require findExe("git").len > 0
    require fileExists(reproBinary)
    let scratch = createTempDir("repro-provider-explicit-catalog-", "")
    defer: removeDir(scratch)
    # The sibling is deliberately usable: it must not mask a missing or
    # changed explicit selection. Each real catalog is a local git repository.
    discard commitCatalog(scratch / "reprobuild-packages", "catalog-sibling")
    let consumer = makeConsumer(scratch)
    let first = scratch / "selected-a"
    let firstRevision = commitCatalog(first)
    let second = scratch / "selected-b"
    # Preserve ancestry so refreshing to B advances the committed catalog pin.
    copyDir(first, second)
    writeCatalog(second, "catalog-two", "2.0")
    discard git(second, "add", ".")
    discard git(second, "commit", "-q", "-m", "second catalog revision")
    let secondRevision = git(second, "rev-parse", "HEAD")
    require firstRevision != secondRevision
    # Interface extraction must never write the provider-runtime witness.
    # Drive the real extractor helper separately before any provider runs.
    let extracted = run(quoteShellCommand([
      reproBinary, "__repro-extract-interface",
      "--module", consumer / "repro.nim",
      "--artifact", scratch / "interface.rbsz",
      "--stub", scratch / "interface.nim",
      "--work-dir", ReprobuildRepoRoot,
      "--consumer-root", consumer]), catalogRoot = first)
    checkpoint(extracted.output)
    require extracted.code == 0
    require not fileExists(scratch / "catalog-witness")
    for (catalog, revision, marker) in [(first, firstRevision, "catalog-one"),
        (second, secondRevision, "catalog-two")]:
      let result = refresh(consumer, catalog)
      checkpoint(result.output)
      require result.code == 0
      let body = readFile(consumer / "repro.lock")
      check ("revision = \"" & revision & "\"") in catalogEntry(body)
      let witness = scratch / "catalog-witness"
      require fileExists(witness)
      check readFile(witness) == marker
    let previousLock = readFile(consumer / "repro.lock")
    let missing = scratch / "selected-missing"
    createDir(missing)
    let refused = refresh(consumer, missing)
    checkpoint(refused.output)
    check refused.code != 0
    check "shellcheck" in refused.output
    check "no reachable catalog defines it" in refused.output
    check missing in refused.output
    check readFile(consumer / "repro.lock") == previousLock
    check not fileExists(scratch / "catalog-witness")

proc pinCatalog(consumer, remote, revision: string; integrity = "") =
  var lock = LockedDependencies(schema: "reprobuild.solved-graph-lock.v2",
    platform: currentPlatformId(), optimal: true,
    inputsDigest: inputsDigestOf("pinned-catalog-fixture"))
  lock.deps.add(LockedDep(name: "reprobuild-packages",
    coordinates: Coordinates(kind: ckVcs, url: remote, revision: revision),
    integrity: (if integrity.len > 0: integrity else:
      gitObjectMultihash("sha1", revision)), visibility: "public"))
  writeFile(consumer / "repro.lock", serializeLockedDependencies(lock))
  discard git(consumer, "add", "repro.lock")
  discard git(consumer, "commit", "-q", "-m", "pin catalog")

suite "provider compilation materializes the lock-pinned catalog":
  test "cold exec fetches the pinned catalog before compiling its recipe":
    let scratch = createTempDir("repro-exec-pinned-catalog-", "")
    defer: removeDir(scratch)
    let remote = scratch / "remote-catalog"
    let revision = commitCatalog(remote, "locked-catalog")
    let consumer = makeConsumer(scratch)
    writeFile(consumer / "repro.nim", ConsumerRecipe & "  devEnv:\n    setEnv \"PINNED_CATALOG_TEST\", \"ready\"\n")
    discard git(consumer, "add", ".")
    discard git(consumer, "commit", "-q", "-m", "recipe")
    pinCatalog(consumer, remote, revision)
    let installedLibs = scratch / "installed/share/repro/source/libs"
    copyDir(ReprobuildRepoRoot / "libs", installedLibs)
    let fetched = consumer / ".repro/cross-repo-producers/reprobuild-packages" / revision
    require not dirExists(fetched)
    let result = run(quoteShellCommand([reproBinary, "exec", consumer,
      "--", "sh", "-c", "test \"$PINNED_CATALOG_TEST\" = ready"]), libsRoot = installedLibs,
      actionCacheRoot = scratch / "action-cache")
    checkpoint(result.output)
    require result.code == 0
    check git(fetched, "rev-parse", "HEAD") == revision
    require fileExists(scratch / "catalog-witness")
    check readFile(scratch / "catalog-witness") == "locked-catalog"

  test "a direct provider helper fetches the pinned catalog and refuses wrong integrity":
    let scratch = createTempDir("repro-helper-pinned-catalog-", "")
    defer: removeDir(scratch)
    let remote = scratch / "remote-catalog"
    let revision = commitCatalog(remote, "helper-catalog")
    let consumer = makeConsumer(scratch)
    pinCatalog(consumer, remote, revision)
    let installedLibs = scratch / "installed/share/repro/source/libs"
    copyDir(ReprobuildRepoRoot / "libs", installedLibs)
    let extracted = run(quoteShellCommand([reproBinary,
      "__repro-extract-interface", "--module", consumer / "repro.nim",
      "--artifact", scratch / "interface.rbsz", "--stub", scratch / "interface.nim",
      "--work-dir", ReprobuildRepoRoot, "--consumer-root", consumer]),
      catalogRoot = remote, libsRoot = installedLibs)
    checkpoint(extracted.output)
    require extracted.code == 0
    let fetched = consumer / ".repro/cross-repo-producers/reprobuild-packages" / revision
    require not dirExists(fetched)
    let command = quoteShellCommand([reproBinary, "__repro-compile-provider",
      "--module", consumer / "repro.nim", "--out", scratch / "provider",
      "--artifact", scratch / "provider.rbsz", "--interface", scratch / "interface.rbsz",
      "--work-dir", ReprobuildRepoRoot])
    let compiled = run(command, libsRoot = installedLibs)
    checkpoint(compiled.output)
    require compiled.code == 0
    check git(fetched, "rev-parse", "HEAD") == revision
    require fileExists(scratch / "provider")
    removeDir(fetched)
    removeFile(scratch / "provider")
    pinCatalog(consumer, remote, revision,
      gitObjectMultihash("sha1", repeat('0', 40)))
    let refused = run(command, libsRoot = installedLibs)
    checkpoint(refused.output)
    check refused.code != 0
    check "integrity" in refused.output.toLowerAscii()
    check not fileExists(scratch / "provider")
    # Lock acquisition failures are materialization failures too. A directory
    # cannot be opened as an exclusive lock file on supported platforms; the
    # helper must propagate that error instead of compiling from a fallback.
    pinCatalog(consumer, remote, revision)
    let materializationLock = fetched & ".materialize.lock"
    if fileExists(materializationLock):
      removeFile(materializationLock)
    createDir(materializationLock)
    let lockRefused = run(command, libsRoot = installedLibs)
    checkpoint(lockRefused.output)
    check lockRefused.code != 0
    check materializationLock in lockRefused.output
    check not fileExists(scratch / "provider")

  test "concurrent cold execs share one verified catalog materialization":
    # Real concurrent public invocations, with no mocked Git or transport. A
    # substantial incompressible Git object keeps the first cold fetch open
    # long enough to start the second invocation after Git init. This is the
    # legitimate in-progress state that must be protected by the shared lock.
    let scratch = getTempDir() /
      ("repro-concurrent-pinned-catalog-" & $getCurrentProcessId())
    require not dirExists(scratch)
    releaseDirAtProcessExit(scratch)
    createDir(scratch)
    let remote = scratch / "remote-catalog"
    discard commitCatalog(remote, "concurrent-catalog")
    discard git(remote, "config", "pack.threads", "2")
    var payload = newString(32 * 1024 * 1024)
    var state = 0x9e3779b9'u32
    for i in 0 ..< payload.len:
      state = state xor (state shl 13)
      state = state xor (state shr 17)
      state = state xor (state shl 5)
      payload[i] = char(state and 255)
    writeFile(remote / "catalog-payload.bin", payload)
    payload.setLen(0)
    discard git(remote, "add", "catalog-payload.bin")
    discard git(remote, "commit", "-q", "-m", "substantial catalog source")
    let revision = git(remote, "rev-parse", "HEAD")
    let consumer = makeConsumer(scratch)
    writeFile(consumer / "repro.nim", ConsumerRecipe &
      "  devEnv:\n    setEnv \"PINNED_CATALOG_TEST\", \"ready\"\n")
    discard git(consumer, "add", ".")
    discard git(consumer, "commit", "-q", "-m", "activation recipe")
    pinCatalog(consumer, remote, revision)
    let installedLibs = scratch / "installed/share/repro/source/libs"
    copyDir(ReprobuildRepoRoot / "libs", installedLibs)
    let fetched = consumer / ".repro/cross-repo-producers/reprobuild-packages" / revision
    require not dirExists(fetched)
    let command = @["exec", consumer, "--", "sh", "-c",
      "test \"$PINNED_CATALOG_TEST\" = ready"]
    let env = childEnv(libsRoot = installedLibs,
      actionCacheRoot = scratch / "action-cache")
    let first = startProcess(reproBinary, args = command, env = env,
      options = {poUsePath, poParentStreams})
    terminateAtProcessExit(processID(first))
    defer: close(first)
    while not fileExists(fetched / ".git/HEAD") and peekExitCode(first) == -1:
      sleep(1)
    # If the first request exited before the rendezvous, report its actual
    # failure instead of waiting forever for a directory it will not create.
    if not fileExists(fetched / ".git/HEAD"):
      check waitForExit(first) == 0
      fail()
    else:
      check peekExitCode(first) == -1
      check readFile(fetched / ".git/HEAD").strip().startsWith("ref: ")
      let second = startProcess(reproBinary, args = command, env = env,
        options = {poUsePath, poParentStreams})
      terminateAtProcessExit(processID(second))
      defer: close(second)
      let secondCode = waitForExit(second)
      let firstCode = waitForExit(first)
      check firstCode == 0
      check secondCode == 0
      check git(fetched, "rev-parse", "HEAD") == revision
      require fileExists(scratch / "catalog-witness")
      check readFile(scratch / "catalog-witness") == "concurrent-catalog"

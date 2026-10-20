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

const ReprobuildRepoRoot = currentSourcePath().parentDir.parentDir.parentDir
const reproBinary = ReprobuildRepoRoot / "build/bin/repro".addFileExt(ExeExt)

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

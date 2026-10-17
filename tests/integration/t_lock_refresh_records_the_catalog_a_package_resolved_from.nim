## `repro lock refresh` records the `reprobuild-packages` catalog revision a
## `uses:` package's definition came from.
##
## reprobuild-specs/Provisioning-Contributions.md, "Locks And Snapshots": a
## locked realization records "catalog repository coordinates and revision".
## Before this, a lock that selected a catalog package carried nothing about
## the catalog -- CodeTracer's `repro.lock` named `sqlite3` with no
## `reprobuild-packages` entry at all -- so which catalog revision defined the
## package, and therefore which realizations were eligible, was whatever
## checkout the lookup happened to find on the machine.
##
## Fixture (built `build/bin/repro`, black-box, nothing mocked):
##
##   <scratch>/
##     reprobuild-packages/   a git repo: the catalog, defining one package
##     consumer-checkout/     a git repo: `uses: "rplockcatalogfixture"`
##
## The lookup walks up from the consumer and finds the sibling catalog, as it
## does in a workspace. A second case replaces the checkout with a plain copy
## carrying a `catalog-revision` marker -- the shape an installed reprobuild
## ships -- and the lock must record the marker's revision.
##
## Hermetic: every repo lives in a fresh temp dir; `REPROBUILD_PACKAGES_ROOT`
## is removed from the child environment so the walk is what finds the catalog.
## Requires `git` on PATH and a built `build/bin/repro`; it fails, not skips,
## without them.

import std/[os, osproc, strtabs, strutils, tempfiles, unittest]

const ReprobuildRepoRoot = currentSourcePath().parentDir.parentDir.parentDir
const reproBinary = ReprobuildRepoRoot / "build/bin/repro".addFileExt(ExeExt)

const CatalogInterface = """
import repro_project_dsl

package rplockcatalogfixture:
  provisioning:
    tarball url = "https://example.invalid/rplockcatalogfixture-1.0.zip",
      sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
      archiveType = "zip",
      executablePath = "rplockcatalogfixture",
      packageId = "rplockcatalogfixture@1.0",
      lockIdentity = "tarball:rplockcatalogfixture@1.0:sha256:0000000000000000000000000000000000000000000000000000000000000000"
"""

const ConsumerRecipe = """
import repro_project_dsl

package consumer:
  defaultToolProvisioning "path"
  uses:
    "nim >=2.0"
    "rplockcatalogfixture"
  build:
    discard aggregate("consumer-aggregate", actions = @[])
"""

proc childEnv(): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    if key.toUpperAscii() != "REPROBUILD_PACKAGES_ROOT":
      result[key] = value

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, options = {poStdErrToStdOut, poUsePath},
    workingDir = cwd, env = childEnv())
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

proc writeCatalog(root: string) =
  let dir = root / "packages" / "interfaces" / "rplockcatalogfixture"
  createDir(dir)
  writeFile(dir / "repro.nim", CatalogInterface)

proc makeConsumer(scratch: string): string =
  result = scratch / "consumer-checkout"
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
  ## The `depends` value of the root (`path = "."`) dependency.
  let at = lockBody.find("path = \".\"")
  if at < 0:
    return ""
  let key = lockBody.find("depends = \"", at)
  if key < 0:
    return ""
  let start = key + "depends = \"".len
  lockBody[start ..< lockBody.find('"', start)]

suite "lock refresh records the catalog a package resolved from":

  test "a sibling catalog checkout is recorded at its revision":
    require findExe("git").len > 0
    require fileExists(reproBinary)
    let scratch = createTempDir("repro-lock-catalog-", "")
    defer: removeDir(scratch)
    let catalog = scratch / "reprobuild-packages"
    initRepo(catalog,
      "https://example.invalid/metacraft-labs/reprobuild-packages.git")
    writeCatalog(catalog)
    discard git(catalog, "add", ".")
    discard git(catalog, "commit", "-q", "-m", "catalog")
    let catalogSha = git(catalog, "rev-parse", "HEAD")
    let consumer = makeConsumer(scratch)

    let refresh = run(quoteShell(reproBinary) & " lock refresh " &
      quoteShell(consumer))
    checkpoint(refresh.output)
    check refresh.code == 0
    let lockBody = readFile(consumer / "repro.lock")
    checkpoint(lockBody)
    let entry = catalogEntry(lockBody)
    check entry.len > 0
    check "path = \"../reprobuild-packages\"" in entry
    check "coord_kind = \"vcs\"" in entry
    check ("revision = \"" & catalogSha & "\"") in entry
    check "integrity = \"git-" in entry
    # The root project depends on it, like any other locked sibling.
    check "reprobuild-packages" in rootDepends(lockBody)

  test "a catalog copy is recorded at the revision its marker names":
    require findExe("git").len > 0
    require fileExists(reproBinary)
    let scratch = createTempDir("repro-lock-catalog-copy-", "")
    defer: removeDir(scratch)
    let catalog = scratch / "reprobuild-packages"
    writeCatalog(catalog)
    let pinned = "0123456789abcdef0123456789abcdef01234567"
    writeFile(catalog / "catalog-revision",
      "url=https://example.invalid/metacraft-labs/reprobuild-packages\n" &
      "revision=" & pinned & "\n")
    let consumer = makeConsumer(scratch)

    let refresh = run(quoteShell(reproBinary) & " lock refresh " &
      quoteShell(consumer))
    checkpoint(refresh.output)
    check refresh.code == 0
    let lockBody = readFile(consumer / "repro.lock")
    checkpoint(lockBody)
    let entry = catalogEntry(lockBody)
    check entry.len > 0
    check ("revision = \"" & pinned & "\"") in entry
    check ("url = \"https://example.invalid/metacraft-labs/" &
      "reprobuild-packages\"") in entry
    check ("integrity = \"git-sha1:" & pinned & "\"") in entry

## A build materializes and compiles against the catalog revision recorded in
## `repro.lock`, not whichever catalog the lookup happened to find.
##
## reprobuild-pm/issues/2026-09-30-lock-does-not-record-the-catalog-a-package-resolved-from.md
## spec/Provisioning-Contributions.md, "Locks And Snapshots" and
## "Catalog Lookup And Provisioning".
##
## Precedence rule:
## 1. $REPROBUILD_PACKAGES_ROOT (exclusive when set)
## 2. Develop-mode sibling (beside consumer or any ancestor)
## 3. Lock-pinned catalog (materialized under .repro/cross-repo-producers/reprobuild-packages/<rev>)
## 4. Beside reprobuild checkout (bundled catalog)

import std/[os, osproc, strtabs, strutils, tempfiles, unittest]

const ReprobuildRepoRoot = currentSourcePath().parentDir.parentDir.parentDir
const reproBinary = ReprobuildRepoRoot / "build/bin/repro".addFileExt(ExeExt)

# Path to reprobuild_packages_catalog.nim for direct lookup unit tests
const CatalogModulePath = ReprobuildRepoRoot /
  "libs/repro_project_dsl/src/repro_project_dsl/reprobuild_packages_catalog.nim"

const FixtureInterfaceA = """
import repro_project_dsl

package rplockedfixture:
  provisioning:
    tarball url = "https://example.invalid/rplockedfixture-1.0.zip",
      sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
      archiveType = "zip",
      executablePath = "rplockedfixture",
      packageId = "rplockedfixture@1.0",
      lockIdentity = "tarball:rplockedfixture@1.0:sha256:0000000000000000000000000000000000000000000000000000000000000000"
"""

const FixtureInterfaceB = """
import repro_project_dsl

package rplockedfixture:
  provisioning:
    tarball url = "https://example.invalid/rplockedfixture-2.0.zip",
      sha256 = "1111111111111111111111111111111111111111111111111111111111111111",
      archiveType = "zip",
      executablePath = "rplockedfixture",
      packageId = "rplockedfixture@2.0",
      lockIdentity = "tarball:rplockedfixture@2.0:sha256:1111111111111111111111111111111111111111111111111111111111111111"
"""

const ConsumerRecipe = """
import repro_project_dsl

package consumer:
  defaultToolProvisioning "tarball"
  uses:
    "rplockedfixture"
  build:
    discard aggregate("consumer-aggregate", actions = @[])
"""

proc childEnv(extra: openArray[(string, string)] = []): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    if key.toUpperAscii() != "REPROBUILD_PACKAGES_ROOT":
      result[key] = value
  # Ensure REPRO_NIM_COMPILER is an absolute path so child compiles find nim
  let nimExe = findExe("nim")
  if nimExe.len > 0 and "REPRO_NIM_COMPILER" notin result:
    result["REPRO_NIM_COMPILER"] = nimExe
  for (k, v) in extra:
    result[k] = v

proc run(command: string; cwd = ""; env = childEnv()): tuple[code: int; output: string] =
  let res = execCmdEx(command, options = {poStdErrToStdOut, poUsePath},
    workingDir = cwd, env = env)
  (code: res.exitCode, output: res.output)

proc git(repo: string; args: varargs[string]): string =
  var command = "git -C " & quoteShell(repo)
  for arg in args:
    command.add(" " & quoteShell(arg))
  let (code, output) = run(command)
  doAssert code == 0, command & "\n" & output
  output.strip()

proc initGitRepo(dir, origin: string) =
  createDir(dir)
  discard git(dir, "init", "-q", "-b", "main")
  discard git(dir, "config", "user.email", "t@example.invalid")
  discard git(dir, "config", "user.name", "Tester")
  discard git(dir, "config", "commit.gpgsign", "false")
  if origin.len > 0:
    discard git(dir, "remote", "add", "origin", origin)

suite "locked catalog revision is materialized and consulted":

  test "reprobuildPackagesSearch finds lock-pinned catalog when repro.lock pins it":
    let scratch = createTempDir("repro-test-search-", "")
    defer: removeDir(scratch)
    let consumer = scratch / "consumer"
    createDir(consumer)
    writeFile(consumer / "repro.nim", ConsumerRecipe)

    let lockedSha = "1111222233334444555566667777888899990000"
    let lockBody = "schema = \"reprobuild.solved-graph-lock.v2\"\n\n" &
      "[lock]\nplatform = \"x86_64-linux\"\npackages = []\n" &
      "deps = [{ name = \"reprobuild-packages\", path = \"../reprobuild-packages\", " &
      "coord_kind = \"vcs\", url = \"https://example.invalid/reprobuild-packages.git\", " &
      "ref = \"\", revision = \"" & lockedSha & "\", " &
      "integrity = \"git-sha1:" & lockedSha & "\", " &
      "version = \"\", visibility = \"public\", participation = \"\", depends = \"\", tags = \"\" }]\n"
    writeFile(consumer / "repro.lock", lockBody)

    # Materialize the catalog under .repro/cross-repo-producers/reprobuild-packages/<lockedSha>
    let lockedCatalogRoot = consumer / ".repro" / "cross-repo-producers" /
      "reprobuild-packages" / lockedSha
    let interfaceDir = lockedCatalogRoot / "packages" / "interfaces" / "rplockedfixture"
    createDir(interfaceDir)
    writeFile(interfaceDir / "repro.nim", FixtureInterfaceA)

    # Compile and run a probe script that imports reprobuild_packages_catalog directly
    let probeScript = scratch / "probe.nim"
    let probeCode = "import std/[os, strutils]\n" &
      "import " & escape(CatalogModulePath.replace('\\', '/')) & "\n\n" &
      "let search = reprobuildPackagesSearch(\"rplockedfixture\", " & escape(consumer / "repro.nim") & ")\n" &
      "echo \"module=\" & search.module\n" &
      "echo \"probes=\" & $search.probes.len\n" &
      "for p in search.probes:\n" &
      "  echo \"probe:\" & p.origin & \":\" & p.root\n"
    writeFile(probeScript, probeCode)

    let (code, output) = run("nim c -r --hints:off " & quoteShell(probeScript), cwd = scratch)
    checkpoint(output)
    check code == 0
    check ("module=" & (interfaceDir / "repro")) in output
    check ("probe:locked at " & lockedSha) in output

  test "develop-mode sibling takes precedence over lock-pinned catalog":
    let scratch = createTempDir("repro-test-precedence-", "")
    defer: removeDir(scratch)
    let consumer = scratch / "consumer"
    createDir(consumer)
    writeFile(consumer / "repro.nim", ConsumerRecipe)

    let lockedSha = "1111222233334444555566667777888899990000"
    let lockBody = "schema = \"reprobuild.solved-graph-lock.v2\"\n\n" &
      "[lock]\nplatform = \"x86_64-linux\"\npackages = []\n" &
      "deps = [{ name = \"reprobuild-packages\", path = \"../reprobuild-packages\", " &
      "coord_kind = \"vcs\", url = \"https://example.invalid/reprobuild-packages.git\", " &
      "ref = \"\", revision = \"" & lockedSha & "\", " &
      "integrity = \"git-sha1:" & lockedSha & "\", " &
      "version = \"\", visibility = \"public\", participation = \"\", depends = \"\", tags = \"\" }]\n"
    writeFile(consumer / "repro.lock", lockBody)

    # Materialize lock-pinned catalog with FixtureInterfaceA
    let lockedCatalogRoot = consumer / ".repro" / "cross-repo-producers" /
      "reprobuild-packages" / lockedSha
    createDir(lockedCatalogRoot / "packages" / "interfaces" / "rplockedfixture")
    writeFile(lockedCatalogRoot / "packages" / "interfaces" / "rplockedfixture" / "repro.nim",
      FixtureInterfaceA)

    # Create develop-mode sibling with FixtureInterfaceB
    let siblingCatalogRoot = scratch / "reprobuild-packages"
    let siblingInterfaceDir = siblingCatalogRoot / "packages" / "interfaces" / "rplockedfixture"
    createDir(siblingInterfaceDir)
    writeFile(siblingInterfaceDir / "repro.nim", FixtureInterfaceB)

    # Probe
    let probeScript = scratch / "probe.nim"
    let probeCode = "import std/[os, strutils]\n" &
      "import " & escape(CatalogModulePath.replace('\\', '/')) & "\n\n" &
      "let search = reprobuildPackagesSearch(\"rplockedfixture\", " & escape(consumer / "repro.nim") & ")\n" &
      "echo \"module=\" & search.module\n"
    writeFile(probeScript, probeCode)

    let (code, output) = run("nim c -r --hints:off " & quoteShell(probeScript), cwd = scratch)
    checkpoint(output)
    check code == 0
    # Sibling MUST win over lock pin
    check ("module=" & (siblingInterfaceDir / "repro")) in output

  test "repro build materializes un-materialized lock-pinned catalog from git remote":
    require findExe("git").len > 0
    require fileExists(reproBinary)

    let scratch = createTempDir("repro-test-fetch-", "")
    defer: removeDir(scratch)

    # 1. Create a remote git repository for the catalog
    let catalogRemote = scratch / "catalog-remote.git"
    initGitRepo(catalogRemote, "https://example.invalid/metacraft-labs/reprobuild-packages.git")
    let ifaceDir = catalogRemote / "packages" / "interfaces" / "rplockedfixture"
    createDir(ifaceDir)
    writeFile(ifaceDir / "repro.nim", FixtureInterfaceA)
    discard git(catalogRemote, "add", ".")
    discard git(catalogRemote, "commit", "-q", "-m", "catalog commit")
    let catalogCommit = git(catalogRemote, "rev-parse", "HEAD")

    # 2. Create consumer checkout with repro.lock pinning catalogRemote at catalogCommit
    let consumer = scratch / "consumer"
    initGitRepo(consumer, "https://example.invalid/acme/consumer.git")
    writeFile(consumer / "repro.nim", ConsumerRecipe)
    discard git(consumer, "add", "repro.nim")
    discard git(consumer, "commit", "-q", "-m", "consumer commit")
    let consumerCommit = git(consumer, "rev-parse", "HEAD")

    let lockBody = "schema = \"reprobuild.solved-graph-lock.v2\"\n\n" &
      "[lock]\nplatform = \"arm64-macosx\"\noptimal = false\n" &
      "inputs_digest = \"fnv1a64:0000000000000000\"\nvariants = []\n" &
      "packages = [{ name = \"consumer\", version = \"0.1.0\", source = \"consumer\", selection = \"selected\" }, " &
      "{ name = \"rplockedfixture\", version = \"1.0.0\", source = \"rplockedfixture\", selection = \"selected\" }]\n" &
      "deps = [{ name = \"consumer\", path = \".\", coord_kind = \"vcs\", url = \"https://example.invalid/acme/consumer.git\", ref = \"\", revision = \"" & consumerCommit & "\", integrity = \"git-sha1:" & consumerCommit & "\", version = \"\", visibility = \"public\", participation = \"\", depends = \"reprobuild-packages\", tags = \"\" }, " &
      "{ name = \"reprobuild-packages\", path = \"../reprobuild-packages\", coord_kind = \"vcs\", url = \"" & catalogRemote & "\", ref = \"\", revision = \"" & catalogCommit & "\", integrity = \"git-sha1:" & catalogCommit & "\", version = \"\", visibility = \"public\", participation = \"\", depends = \"\", tags = \"\" }]\n"
    writeFile(consumer / "repro.lock", lockBody)

    # Confirm that .repro/cross-repo-producers does not exist yet
    let expectedMaterialized = consumer / ".repro" / "cross-repo-producers" /
      "reprobuild-packages" / catalogCommit
    check not dirExists(expectedMaterialized)

    # 3. Run repro build on consumer (with no sibling reprobuild-packages and no REPROBUILD_PACKAGES_ROOT)
    let buildRes = run(quoteShell(reproBinary) & " build " & quoteShell(consumer), cwd = scratch)
    checkpoint(buildRes.output)
    check buildRes.code == 0
    # Confirm catalog was materialized at the locked revision
    check dirExists(expectedMaterialized)
    check fileExists(expectedMaterialized / "packages" / "interfaces" / "rplockedfixture" / "repro.nim")

## Catalog preparation preserves workspace lookup for recipe-relative helpers.
## No mocks: owned directories provide sibling catalogs and real local Git
## repositories provide lock-only catalogs. No public network or provider/SDK
## build is needed. These exercise ensureLockPinnedCatalog itself; the existing
## provider integration program retains coverage of the isolated compile.
## Lookup prefers an explicit root, then a workspace ancestor sibling, then
## the consumer lock's verified catalog revision. Relative module spellings
## must preserve that order.

import std/[os, osproc, strtabs, strutils, tempfiles, unittest]
import repro_cli_support
import repro_test_support
import repro_test_support/process_fixtures

template withFixture(body: untyped) =
  block:
    let root {.inject.} = createTempDir("repro-catalog-anchor-", "")
    releaseDirAtProcessExit(root)
    let previousDir = getCurrentDir()
    var previous: seq[(string, string)] = @[]
    for key, value in envPairs():
      if key.startsWith("GIT_") or key == "REPROBUILD_PACKAGES_ROOT":
        previous.add((key, value))
    for (key, _) in previous: delEnv(key)
    let emptyConfig = root / "empty.gitconfig"
    writeFile(emptyConfig, "")
    putEnv("GIT_CONFIG_GLOBAL", emptyConfig)
    putEnv("GIT_CONFIG_NOSYSTEM", "1")
    try:
      body
    finally:
      setCurrentDir(previousDir)
      var selectedKeys: seq[string] = @[]
      for key, _ in envPairs():
        if key.startsWith("GIT_") or key == "REPROBUILD_PACKAGES_ROOT":
          selectedKeys.add(key)
      for key in selectedKeys: delEnv(key)
      for (key, value) in previous: putEnv(key, value)
      removeDir(root)

proc writeLock(consumer, url, revision: string; integrity = "") =
  createDir(consumer)
  writeFile(consumer / "repro.nim", "discard\n")
  let digest = if integrity.len > 0: integrity else: "git-sha1:" & revision
  writeFile(consumer / "repro.lock",
    "schema = \"reprobuild.solved-graph-lock.v2\"\n\n" &
    "[lock]\nplatform = \"x86_64-linux\"\npackages = []\n" &
    "deps = [{ name = \"reprobuild-packages\", path = \"../reprobuild-packages\", " &
    "coord_kind = \"vcs\", url = " & escape(url) &
    ", ref = \"\", revision = " & escape(revision) &
    ", integrity = " & escape(digest) &
    ", version = \"\", visibility = \"public\", participation = \"\", depends = \"\", tags = \"\" }]\n")

proc git(repo: string; args: varargs[string]): string =
  var command = quoteShell(findExe("git")) & " -C " & quoteShell(repo)
  for arg in args: command.add(" " & quoteShell(arg))
  let execution = execCmdEx(command, options = {poUsePath, poStdErrToStdOut})
  doAssert execution.exitCode == 0, command & "\n" & execution.output
  execution.output.strip()

suite "catalog preparation anchors":
  test "bare relative nested relative and absolute modules find the ancestor sibling":
    withFixture:
      let consumer = root / "consumer"
      let nested = consumer / "nested"
      let sibling = root / "reprobuild-packages"
      createDir(sibling)
      writeFile(sibling / "repro.nim", "discard\n")
      # A lost sibling lookup must fail against a real absent local remote,
      # rather than silently succeeding from a bundled catalog or network.
      writeLock(consumer, fileUrl(root / "absent-remote"), repeat('1', 40))
      createDir(nested)
      writeFile(nested / "repro.nim", "discard\n")
      setCurrentDir(consumer)
      for module in ["repro.nim", "nested" / "repro.nim", nested / "repro.nim"]:
        checkpoint(module)
        check ensureLockPinnedCatalog(module, consumer) == ""
        check not dirExists(consumer / ".repro" / "cross-repo-producers")

  test "relative consumer-root fallback keeps the same sibling precedence":
    withFixture:
      let consumer = root / "consumer" / "nested"
      createDir(root / "reprobuild-packages")
      writeLock(consumer, fileUrl(root / "absent-remote"), repeat('2', 40))
      setCurrentDir(root)
      check ensureLockPinnedCatalog("", "consumer" / "nested") == ""
      check not dirExists(consumer / ".repro" / "cross-repo-producers")

  test "lock-only local Git materialization and integrity refusal stay intact":
    withFixture:
      require findExe("git").len > 0
      let remote = root / "catalog-remote"
      let hooks = root / "empty-hooks"
      createDir(remote)
      createDir(hooks)
      discard git(remote, "init", "--quiet", "--initial-branch=main", "--object-format=sha1", "--template=")
      discard git(remote, "config", "core.hooksPath", hooks)
      discard git(remote, "config", "commit.gpgsign", "false")
      discard git(remote, "config", "user.name", "Catalog Fixture")
      discard git(remote, "config", "user.email", "fixture@example.invalid")
      writeFile(remote / "repro.nim", "discard\n")
      discard git(remote, "add", "repro.nim")
      discard git(remote, "commit", "--quiet", "-m", "catalog fixture")
      let revision = git(remote, "rev-parse", "HEAD")
      let consumer = root / "consumer"
      writeLock(consumer, fileUrl(remote), revision)
      setCurrentDir(consumer)
      let expected = consumer / ".repro" / "cross-repo-producers" / "reprobuild-packages" / revision
      check ensureLockPinnedCatalog("repro.nim", consumer) == expected
      check git(expected, "rev-parse", "HEAD") == revision
      check readFile(expected / "repro.nim") == "discard\n"
      writeLock(consumer, fileUrl(remote), revision, "git-sha1:" & repeat('0', 40))
      var diagnostic = ""
      try: discard ensureLockPinnedCatalog("repro.nim", consumer)
      except OSError as error: diagnostic = error.msg
      check "integrity check FAILED" in diagnostic
      check revision in diagnostic

  test "an explicit catalog remains exclusive before relative lookup":
    withFixture:
      let consumer = root / "consumer"
      let explicit = root / "explicit-catalog"
      createDir(explicit)
      writeLock(consumer, fileUrl(root / "absent-remote"), repeat('3', 40))
      putEnv("REPROBUILD_PACKAGES_ROOT", explicit)
      setCurrentDir(consumer)
      check ensureLockPinnedCatalog("repro.nim", consumer) == ""
      check not dirExists(consumer / ".repro" / "cross-repo-producers")

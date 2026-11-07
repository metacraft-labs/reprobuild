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
    ", revision = " & escape(revision) &
    ", integrity = " & escape(digest) &
    ", version = \"\", visibility = \"public\", participation = \"\", depends = \"\", tags = \"\" }]\n")

proc git(repo: string; args: varargs[string]): string =
  var command = quoteShell(findExe("git")) & " -C " & quoteShell(repo)
  for arg in args: command.add(" " & quoteShell(arg))
  let execution = execCmdEx(command, options = {poUsePath, poStdErrToStdOut})
  doAssert execution.exitCode == 0, command & "\n" & execution.output
  execution.output.strip()

proc initCatalogRemote(remote, hooks: string) =
  ## A catalog repository whose default branch is ``main`` and whose
  ## ``agents`` branch carries two further commits, so ``agents~1`` is a
  ## revision no default-branch fetch delivers and no ref tip advertises.
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
  discard git(remote, "checkout", "--quiet", "-b", "agents")
  writeFile(remote / "repro.nim", "agents\n")
  discard git(remote, "commit", "--quiet", "-am", "agents-only pin")
  writeFile(remote / "repro.nim", "agents tip\n")
  discard git(remote, "commit", "--quiet", "-am", "agents tip")
  discard git(remote, "checkout", "--quiet", "main")

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

  test "a half-materialized catalog checkout is rebuilt rather than refused":
    withFixture:
      require findExe("git").len > 0
      let remote = root / "catalog-remote"
      initCatalogRemote(remote, root / "empty-hooks")
      let revision = git(remote, "rev-parse", "main")
      let consumer = root / "consumer"
      writeLock(consumer, fileUrl(remote), revision)
      setCurrentDir(consumer)
      let expected = consumer / ".repro" / "cross-repo-producers" /
        "reprobuild-packages" / revision
      # The state an interrupted materialization leaves: a repository with
      # objects fetched but nothing checked out (HEAD on an unborn branch, no
      # worktree files), and the empty lock file kept beside it.
      createDir(expected)
      discard git(expected, "init", "--quiet", "--initial-branch=main")
      discard git(expected, "fetch", "--quiet", fileUrl(remote))
      writeFile(expected & ".materialize.lock", "")
      check ensureLockPinnedCatalog("repro.nim", consumer) == expected
      check git(expected, "rev-parse", "HEAD") == revision
      check readFile(expected / "repro.nim") == "discard\n"
      # A completed checkout whose HEAD was moved is still refused: only a
      # checkout that never reached any commit counts as unfinished.
      discard git(expected, "-c", "user.name=Moved", "-c",
        "user.email=moved@example.invalid", "commit", "--quiet",
        "--allow-empty", "-m", "move the cached HEAD")
      var diagnostic = ""
      try: discard ensureLockPinnedCatalog("repro.nim", consumer)
      except OSError as error: diagnostic = error.msg
      check "source revision mismatch" in diagnostic
      check dirExists(expected / ".git")

  test "a pin reachable only from a non-default branch is materialized":
    withFixture:
      require findExe("git").len > 0
      # Protocol v0 refuses a want for a commit no ref tip advertises, as a
      # server without uploadpack.allowReachableSHA1InWant does, so the
      # single-revision fetch fails and the whole-remote fallback must run.
      writeFile(root / "empty.gitconfig", "[protocol]\n\tversion = 0\n")
      let remote = root / "catalog-remote"
      initCatalogRemote(remote, root / "empty-hooks")
      let revision = git(remote, "rev-parse", "agents~1")
      let consumer = root / "consumer"
      writeLock(consumer, fileUrl(remote), revision)
      setCurrentDir(consumer)
      let expected = consumer / ".repro" / "cross-repo-producers" /
        "reprobuild-packages" / revision
      check ensureLockPinnedCatalog("repro.nim", consumer) == expected
      check git(expected, "rev-parse", "HEAD") == revision
      check readFile(expected / "repro.nim") == "agents\n"

  test "a fetch that does not deliver the pin fails and leaves no checkout":
    withFixture:
      require findExe("git").len > 0
      let remote = root / "catalog-remote"
      initCatalogRemote(remote, root / "empty-hooks")
      let revision = repeat('4', 40)
      let consumer = root / "consumer"
      writeLock(consumer, fileUrl(remote), revision)
      setCurrentDir(consumer)
      let expected = consumer / ".repro" / "cross-repo-producers" /
        "reprobuild-packages" / revision
      for attempt in 1 .. 2:
        checkpoint("attempt " & $attempt)
        var diagnostic = ""
        try: discard ensureLockPinnedCatalog("repro.nim", consumer)
        except OSError as error: diagnostic = error.msg
        check ("did not deliver the pinned revision " & revision) in diagnostic
        check fileUrl(remote) in diagnostic
        check "source revision mismatch" notin diagnostic
        check not dirExists(expected)

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

## Real git checkouts, locks and child processes; no mocks. Both actual fetch
## callers contend with another process for the unchanged 120-second default.
## Only two contenders run at once; the holder waits on an explicit release.
import std/[os, osproc, streams, strutils, tempfiles, unittest]
from repro_test_support/process_fixtures import releaseDirAtProcessExit
when defined(posix):
  from repro_test_support/process_fixtures import terminateAtProcessExit
import shared_clones
import git_actions
import repro_build_engine
import repro_cli_support

if paramCount() == 2 and paramStr(1) == "--hold-checkout":
  var held = acquireVcsFileLock(checkoutLockPath(paramStr(2)))
  doAssert held.acquired
  stdout.writeLine("locked")
  stdout.flushFile()
  discard stdin.readLine()
  releaseVcsFileLock(held)
  quit(0)

if paramCount() == 3 and paramStr(1) == "--fetch-contender":
  let checkout = paramStr(2)
  let receipt = paramStr(3)
  let gitBin = findExe("git")
  let identity = ensureGitToolResolvable(tpmPathOnly, gitBin.parentDir)
  let action = gitFetchAction("locked-fetch", identity, "origin", checkout, receipt)
  let res = executeBuiltinAction(action)
  doAssert res.status == asFailed
  doAssert res.reason == "fetch-lock-failed", res.reason & ": " & res.stderr
  doAssert not fileExists(receipt)
  quit(0)

proc git(args: varargs[string]) =
  var command = quoteShell(findExe("git"))
  for arg in args:
    command.add(" " & quoteShell(arg))
  let res = execCmdEx(command)
  doAssert res.exitCode == 0, res.output

suite "lock refusal preserves action and publication contracts":
  test "checkout fetch and publication probe refuse while another process owns lock":
    let root = genTempPath("vcs-lock-contract-", "")
    releaseDirAtProcessExit(root)
    createDir(root)
    defer: removeDir(root)
    let upstream = root / "upstream.git"
    let checkout = root / "checkout"
    let receipt = root / "fetch-receipt"
    git("init", "--bare", "--quiet", upstream)
    git("init", "--quiet", "-b", "main", checkout)
    git("-C", checkout, "-c", "user.name=Lock Test",
      "-c", "user.email=lock@example.invalid", "commit", "--quiet",
      "--allow-empty", "-m", "unpublished")
    git("-C", checkout, "remote", "add", "origin", upstream)
    let gitBin = findExe("git")
    let identity = ensureGitToolResolvable(tpmPathOnly, gitBin.parentDir)
    let before = headPublicationOf(identity, checkout, "origin", allowFetch = false)
    require before.status == hpsUnpublished
    let holder = startProcess(getAppFilename(), args = @["--hold-checkout", checkout],
      options = {poStdErrToStdOut})
    when defined(posix):
      terminateAtProcessExit(holder.processID)
    defer:
      holder.inputStream.writeLine("release")
      holder.inputStream.flush()
      discard holder.waitForExit()
      holder.close()
    require holder.outputStream.readLine() == "locked"
    let fetcher = startProcess(getAppFilename(),
      args = @["--fetch-contender", checkout, receipt], options = {poStdErrToStdOut})
    when defined(posix):
      terminateAtProcessExit(fetcher.processID)
    defer: fetcher.close()
    let publication = headPublicationOf(identity, checkout, "origin")
    check publication.status == hpsUnknown
    check publication.diagnostic.startsWith("could not lock checkout for publication fetch:")
    checkpoint(fetcher.outputStream.readAll())
    check fetcher.waitForExit() == 0
    check not fileExists(receipt)
    check not fileExists(checkout / ".git" / "FETCH_HEAD")
    check holder.running

  test "refresh action returns a structured failure before attempting git":
    let root = genTempPath("vcs-lock-action-", "")
    releaseDirAtProcessExit(root)
    createDir(root)
    defer: removeDir(root)
    let blocker = root / "file"
    writeFile(blocker, "not a directory")
    let receipt = root / "refresh-receipt"
    let gitBin = findExe("git")
    let identity = ensureGitToolResolvable(tpmPathOnly, gitBin.parentDir)
    let action = gitRefreshBareAction("locked-refresh", identity,
      "https://example.invalid/repo", blocker / "bare.git", receipt)
    let res = executeBuiltinAction(action)
    check res.status == asFailed
    check res.reason == "refresh-bare-lock-failed"
    check res.stderr.startsWith("could not lock shared bare:")
    check not fileExists(receipt)
    check readFile(blocker) == "not a directory"

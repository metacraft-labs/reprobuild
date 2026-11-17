## A reader that waits for the control API's ``http-ready.json`` and parses
## it at once never sees it empty or half-written.
##
## WHAT WENT WRONG. The control-API helper wrote ``http-ready.json`` with
## ``writeFile``: open with ``O_TRUNC``, write, close. Its readers --
## ``controlClientFor`` and the dev-session tests -- poll for the file's
## EXISTENCE and then parse it, so a reader that woke between the open and
## the write read an empty file and failed with ``{ expected``. The
## dev-session control-API test failed that way intermittently (reprobuild-pm
## ``issues/2026-11-16-dev-session-control-api-test-reads-http-ready-json-while-it-is-being-written.md``).
##
## WHAT THESE CASES ASSERT.
##
##   (a) ``publishJsonFile``, the writer the helper now uses, makes the file
##       appear only complete: a thread publishes a large document (so a
##       non-atomic write would stay visibly partial for many milliseconds)
##       while this thread polls for the path and, the moment it exists,
##       reads it and compares it with the full text. Repeated over several
##       fresh paths. With the previous ``writeFile`` this fails on the first
##       round: the poller sees the file before its content is complete.
##   (b) no staging file is left beside the published one;
##   (c) the staging file is created exclusively and never through a
##       symlink: ``writeNewFileExclusive`` refuses a symlink planted at its
##       path and leaves the link's target untouched (POSIX only; the
##       session directory's permissions are not guaranteed).
##
## MOCK POLICY: no mocks. The production writer writes real files in a real
## directory; the reader is this test, polling as the real readers do.

import std/[json, os, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip
import repro_cli_support/dev_session
import repro_cli_support/dev_session_access

const
  Rounds = 5
  Entries = 200_000
    ## About 20 MB of pretty-printed JSON: a write that takes long enough
    ## that a poller cannot miss a non-atomic one.

proc bigDocument(): JsonNode =
  result = newJArray()
  let filler = repeat('x', 80)
  for i in 0 ..< Entries:
    result.add(%(filler & $i))

proc publisher(path: string) {.thread.} =
  publishJsonFile(path, bigDocument())

suite "dev-session ready file is never seen partial":
  test "a poller that reads the file as soon as it exists reads it whole":
    let dir = createTempDir("ready-", "")
    defer: removeDir(dir)
    let expected = pretty(bigDocument()) & "\n"
    for round in 0 ..< Rounds:
      let path = dir / ("http-ready-" & $round & ".json")
      var worker: Thread[string]
      createThread(worker, publisher, path)
      var seen = ""
      while true:
        if fileExists(path):
          seen = readFile(path)
          break
        if not worker.running and not fileExists(path):
          break  # the publisher died without publishing; reported below
      joinThread(worker)
      checkpoint("round " & $round & ": read " & $seen.len & " of " &
        $expected.len & " bytes as soon as the file existed")
      check seen.len == expected.len
      check seen == expected

  test "no staging file is left beside the published one":
    let dir = createTempDir("ready-", "")
    defer: removeDir(dir)
    publishJsonFile(dir / "http-ready.json", %*{"pid": 1})
    var names: seq[string]
    for kind, entry in walkDir(dir):
      names.add(entry.extractFilename)
    check names == @["http-ready.json"]
    check parseJson(readFile(dir / "http-ready.json"))["pid"].getInt() == 1

  test "the staging file is never written through a planted symlink":
    when defined(posix):
      let dir = createTempDir("ready-", "")
      defer: removeDir(dir)
      let victim = dir / "victim.txt"
      writeFile(victim, "the user's own file\n")
      let planted = dir / ".http-ready.json.staging"
      createSymlink(victim, planted)
      var raised = false
      try:
        writeNewFileExclusive(planted, "{\"forged\": true}\n")
      except OSError:
        raised = true
      check raised
      check readFile(victim) == "the user's own file\n"
      check symlinkExists(planted)
    else:
      skip("O_NOFOLLOW is POSIX; on Windows the session directory is under the user profile")

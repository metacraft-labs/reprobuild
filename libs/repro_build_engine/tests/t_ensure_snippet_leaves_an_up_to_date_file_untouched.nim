## The built-in ``ensureSnippet`` action must not rewrite a file that already
## carries the wanted block.
##
## ``nimRepropathsConfig`` emits this action against a project's TRACKED
## ``config.nims``. When it rewrote an up-to-date file it appended one extra
## trailing newline on every build (the file's final line terminator made
## ``splitLines`` yield a trailing empty element, and the rejoin added another
## terminator after it), and it rewrote a CRLF file wholesale to LF. Either way
## every build dirtied a tracked file it had nothing to change in.
##
## Each case drives ``executeBuiltinAction`` -- the engine's real built-in
## dispatch -- on a real file in a scratch directory. Nothing is mocked: the
## contract is about the bytes and the mtime of a file on disk.

import std/[os, strutils, times, unittest]

import repro_build_engine

const
  openSentinel = "# >>> repro:project:demo:repro-paths-bootstrap:v1 >>>"
  closeSentinel = "# <<< repro:project:demo:repro-paths-bootstrap:v1 <<<"
  openSearch = "# >>> repro:project:demo:repro-paths-bootstrap:v"
  closeSearch = "# <<< repro:project:demo:repro-paths-bootstrap:v"
  snippet = "when withDir(thisDir(), system.fileExists(\"repro.paths\")):\n" &
    "  include \"repro.paths\""
  staleSnippet = "include \"old.paths\""
  # A fixed mtime well in the past: a write by the action moves it to "now",
  # so an unchanged mtime proves the action did not write.
  pinnedMtime = 1_000_000

proc wantedBlock(eol: string): string =
  (openSentinel & "\n" & snippet & "\n" & closeSentinel).replace("\n", eol)

proc staleBlock(eol: string): string =
  (openSentinel & "\n" & staleSnippet & "\n" & closeSentinel).replace("\n", eol)

proc scratchDir(name: string): string =
  result = getTempDir() / ("repro-ensure-snippet-" & name)
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc ensureSnippetAction(destination: string): BuildAction =
  BuildAction(
    governingLockIdentity: lockIdentityOutsideSolvedGraph(),
    kind: bakEnsureSnippet,
    id: "ensure-snippet-under-test",
    outputs: @[destination],
    builtinEntries: @[openSentinel, closeSentinel, openSearch, closeSearch,
      snippet],
    cacheable: false)

proc runAction(destination: string) =
  let actionResult = executeBuiltinAction(ensureSnippetAction(destination))
  require actionResult.status == asSucceeded

proc checkUntouchedAcrossRuns(name, content: string) =
  ## Seeds ``content``, pins its mtime, runs the action three times and checks
  ## that the bytes and the mtime never moved.
  let scratch = scratchDir(name)
  defer: removeDir(scratch)
  let destination = scratch / "config.nims"
  writeFile(destination, content)
  setLastModificationTime(destination, fromUnix(pinnedMtime))
  for run in 1 .. 3:
    runAction(destination)
    checkpoint name & ": run " & $run
    check readFile(destination) == content
    check getLastModificationTime(destination) == fromUnix(pinnedMtime)

suite "built-in ensureSnippet leaves an up-to-date file untouched":
  test "LF file, block in the middle":
    checkUntouchedAcrossRuns("lf-middle",
      "switch(\"a\")\n\n" & wantedBlock("\n") & "\n\nswitch(\"b\")\n")

  test "LF file, block at the end with a final newline":
    checkUntouchedAcrossRuns("lf-end",
      "switch(\"a\")\n\n" & wantedBlock("\n") & "\n")

  test "LF file, block at the end without a final newline":
    checkUntouchedAcrossRuns("lf-end-unterminated",
      "switch(\"a\")\n\n" & wantedBlock("\n"))

  test "LF file, several trailing newlines after the block":
    checkUntouchedAcrossRuns("lf-trailing-blank-lines",
      "switch(\"a\")\n" & wantedBlock("\n") & "\n\n\n")

  test "CRLF file, block in the middle":
    checkUntouchedAcrossRuns("crlf-middle",
      "switch(\"a\")\r\n\r\n" & wantedBlock("\r\n") &
      "\r\n\r\nswitch(\"b\")\r\n")

  test "CRLF file, block at the end without a final newline":
    checkUntouchedAcrossRuns("crlf-end-unterminated",
      "switch(\"a\")\r\n" & wantedBlock("\r\n"))

suite "built-in ensureSnippet replaces only a stale block":
  proc checkReplaced(name, prefix, suffix, eol: string) =
    let scratch = scratchDir(name)
    defer: removeDir(scratch)
    let destination = scratch / "config.nims"
    writeFile(destination, prefix & staleBlock(eol) & suffix)
    runAction(destination)
    let expected = prefix & wantedBlock(eol) & suffix
    check readFile(destination) == expected
    # Once replaced, the file is up to date: a second run must not touch it.
    setLastModificationTime(destination, fromUnix(pinnedMtime))
    runAction(destination)
    check readFile(destination) == expected
    check getLastModificationTime(destination) == fromUnix(pinnedMtime)

  test "LF file: bytes around the block, trailing newlines included, survive":
    checkReplaced("stale-lf", "switch(\"a\")\n\n",
      "\n\nswitch(\"b\")\n\n\n", "\n")

  test "LF file: an unterminated block at the end stays unterminated":
    checkReplaced("stale-lf-end", "switch(\"a\")\n", "", "\n")

  test "CRLF file: the replacement keeps CRLF and the rest is untouched":
    checkReplaced("stale-crlf", "switch(\"a\")\r\n",
      "\r\nswitch(\"b\")\r\n", "\r\n")

suite "built-in ensureSnippet inserts an absent block once":
  test "a file ending in a newline gets the block after a blank line":
    let scratch = scratchDir("insert-lf")
    defer: removeDir(scratch)
    let destination = scratch / "config.nims"
    let original = "switch(\"a\")\nswitch(\"b\")\n"
    writeFile(destination, original)
    runAction(destination)
    # The exact bytes the action has always produced for this shape. Every
    # repo that already received the block got these bytes, so they must not
    # move -- otherwise the fix itself would dirty those files once more.
    let expected = original & "\n" & wantedBlock("\n") & "\n"
    check readFile(destination) == expected
    setLastModificationTime(destination, fromUnix(pinnedMtime))
    runAction(destination)
    check readFile(destination) == expected
    check getLastModificationTime(destination) == fromUnix(pinnedMtime)

  test "a missing file is created holding the block":
    let scratch = scratchDir("insert-missing")
    defer: removeDir(scratch)
    let destination = scratch / "config.nims"
    runAction(destination)
    let expected = "\n" & wantedBlock("\n") & "\n"
    check readFile(destination) == expected
    setLastModificationTime(destination, fromUnix(pinnedMtime))
    runAction(destination)
    check readFile(destination) == expected
    check getLastModificationTime(destination) == fromUnix(pinnedMtime)

  test "an unterminated last line is closed before the blank separator":
    let scratch = scratchDir("insert-lf-unterminated")
    defer: removeDir(scratch)
    let destination = scratch / "config.nims"
    let original = "switch(\"a\")"
    writeFile(destination, original)
    runAction(destination)
    let expected = original & "\n\n" & wantedBlock("\n") & "\n"
    check readFile(destination) == expected
    setLastModificationTime(destination, fromUnix(pinnedMtime))
    runAction(destination)
    check readFile(destination) == expected
    check getLastModificationTime(destination) == fromUnix(pinnedMtime)

  test "a CRLF file gets a CRLF block and stays CRLF":
    let scratch = scratchDir("insert-crlf")
    defer: removeDir(scratch)
    let destination = scratch / "config.nims"
    let original = "switch(\"a\")\r\nswitch(\"b\")\r\n"
    writeFile(destination, original)
    runAction(destination)
    let expected = original & "\r\n" & wantedBlock("\r\n") & "\r\n"
    check readFile(destination) == expected
    setLastModificationTime(destination, fromUnix(pinnedMtime))
    runAction(destination)
    check readFile(destination) == expected
    check getLastModificationTime(destination) == fromUnix(pinnedMtime)

  test "an open sentinel without a close is not a block":
    # A dangling open line is left alone and a complete block is appended;
    # the next run finds that block and leaves the file as it is.
    let scratch = scratchDir("insert-dangling-open")
    defer: removeDir(scratch)
    let destination = scratch / "config.nims"
    let original = "switch(\"a\")\n" & openSentinel & "\nswitch(\"b\")\n"
    writeFile(destination, original)
    runAction(destination)
    let expected = original & "\n" & wantedBlock("\n") & "\n"
    check readFile(destination) == expected
    setLastModificationTime(destination, fromUnix(pinnedMtime))
    runAction(destination)
    check readFile(destination) == expected
    check getLastModificationTime(destination) == fromUnix(pinnedMtime)

suite "built-in ensureSnippet with more than one block":
  test "only the first block is refreshed; later bytes are untouched":
    let scratch = scratchDir("two-blocks")
    defer: removeDir(scratch)
    let destination = scratch / "config.nims"
    let tail = "\n\nswitch(\"b\")\n" & staleBlock("\n") & "\n\n"
    writeFile(destination, "switch(\"a\")\n" & staleBlock("\n") & tail)
    runAction(destination)
    let expected = "switch(\"a\")\n" & wantedBlock("\n") & tail
    check readFile(destination) == expected
    setLastModificationTime(destination, fromUnix(pinnedMtime))
    runAction(destination)
    check readFile(destination) == expected
    check getLastModificationTime(destination) == fromUnix(pinnedMtime)

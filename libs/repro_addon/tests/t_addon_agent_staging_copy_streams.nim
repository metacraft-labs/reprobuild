## The apply unit's copy of the fetch unit's staging area (spec §9.1;
## threat model T38, G33): it cannot be stalled by a FIFO the fetch unit
## swaps in, and it streams, so its memory does not grow with a staged
## file's size. Also the operator name the pause marker records (§9.3).
##
## Falsifying builds (scripts/run_addon_unit_mutation.sh):
##   agent-staging-open-blocks       the FIFO test blocks in open() and the
##                                   alarm kills the binary (red)
##   agent-staging-reads-whole-file  the streaming test's peak RSS grows by
##                                   the file's size (red)
##
## Mocks: none. Real files, a real FIFO (mkfifo), the real copy. The
## streaming test runs first, in its own binary, so the process's peak
## resident set (getrusage ru_maxrss) before it is this binary's baseline.

import std/[os, posix, strutils, unittest]

import repro_addon/agent_record
import repro_addon/agent_split

var ODirectoryFlag {.importc: "O_DIRECTORY", header: "<fcntl.h>".}: cint

proc peakRssKiB(): int64 =
  var ru: Rusage
  doAssert getrusage(RUSAGE_SELF, addr ru) == 0
  ru.ru_maxrss.int64

let root = getTempDir() / ("t_staging_copy_" & $getCurrentProcessId())
removeDir(root)
createDir(root)

suite "the staging copy streams":
  test "a 256 MiB staged file is copied without holding it in memory":
    const Size = 256 * 1024 * 1024
    let staging = root / "staging-big"
    createDir(staging / "s1" / "outputs")
    block:
      var f = open(staging / "s1" / "outputs" / "big.bin", fmWrite)
      var chunk = newString(1024 * 1024)
      for i in 0 ..< chunk.len: chunk[i] = char((i * 7) and 0xff)
      for _ in 0 ..< Size div chunk.len: f.write(chunk)
      f.close()
    setFilePermissions(staging / "s1" / "outputs" / "big.bin",
                       {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead})
    writeFile(staging / StagingLatestName, "s1\n")
    let before = peakRssKiB()
    check copyLatestStaging(staging, root / "copy-big") == "s1"
    let grown = peakRssKiB() - before
    checkpoint "peak RSS grew by " & $grown & " KiB"
    # One chunk plus allocator noise; holding the file would add 256 MiB.
    check grown < 32 * 1024
    let copied = root / "copy-big" / "outputs" / "big.bin"
    check getFileSize(copied) == Size
    check sameFileContent(copied, staging / "s1" / "outputs" / "big.bin")
    # The permission bits are kept (the archive digest covers them).
    check getFilePermissions(copied) ==
      {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead}
    removeDir(staging)
    removeDir(root / "copy-big")

suite "the staging copy cannot be stalled":
  test "a FIFO opened where a regular file was expected is refused at once":
    # The race the copy guards against: fstatat saw a regular file, then
    # the fetch unit swapped in a FIFO with no writer. A blocking open
    # would wait forever; the alarm turns that into a failure, not a hang.
    let d = root / "fifo"
    createDir(d)
    doAssert mkfifo((d / "out").cstring, 0o600) == 0
    let dfd = posix.open(d.cstring, O_RDONLY or ODirectoryFlag)
    doAssert dfd >= 0
    discard alarm(20)
    expect EAgentStaging:
      discard openStagedNoFollow(dfd, "out", dir = false)
    discard alarm(0)
    # The same name as a directory is refused by type too.
    expect EAgentStaging:
      discard openStagedNoFollow(dfd, "out", dir = true)
    discard posix.close(dfd)

  test "a FIFO as the latest pointer does not stall the copy":
    let staging = root / "staging-fifo"
    createDir(staging / "s1")
    writeFile(staging / "s1" / StagedManifestName, "x")
    doAssert mkfifo((staging / StagingLatestName).cstring, 0o600) == 0
    discard alarm(20)
    expect EAgentStaging:
      discard copyLatestStaging(staging, root / "copy-fifo")
    discard alarm(0)

suite "the operator a pause records":
  proc withEnv(vals: openArray[(string, string)]; body: proc(): string): string =
    var saved: seq[(string, string, bool)]
    for (k, v) in vals:
      saved.add((k, getEnv(k), existsEnv(k)))
      if v.len == 0: delEnv(k) else: putEnv(k, v)
    try: result = body()
    finally:
      for (k, v, had) in saved:
        if had: putEnv(k, v) else: delEnv(k)

  test "SUDO_USER, then LOGNAME, then USER; unsafe values are skipped":
    check withEnv([("SUDO_USER", "alice"), ("LOGNAME", "root"),
                   ("USER", "root")], currentOperator) == "alice"
    check withEnv([("SUDO_USER", ""), ("LOGNAME", "bob"),
                   ("USER", "carol")], currentOperator) == "bob"
    check withEnv([("SUDO_USER", "x\nat=forged"), ("LOGNAME", "a b"),
                   ("USER", "carol")], currentOperator) == "carol"
    check withEnv([("SUDO_USER", "op=1"), ("LOGNAME", repeat('a', 65)),
                   ("USER", "\x1b[31m")], currentOperator) == "uid " & $getuid()

removeDir(root)

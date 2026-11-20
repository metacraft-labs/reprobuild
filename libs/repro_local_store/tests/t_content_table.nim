## The per-host content table (`repro_local_store/content_table`) must never
## hand back a hash for bytes a file no longer holds.
##
## The table memoizes a content-checked input's local hash on the file's
## identity, size, modification time and file-system version (the NTFS USN,
## POSIX ctime), trusting an entry only for a file that was quiescent for two
## seconds before it was hashed. Every case compares what `observeFile`
## answers with the table on against a fresh hash with it off, after a
## mutation chosen to attack the key. The positive control tampers with an
## entry to show the table is consulted at all: a test that only checks
## "same answer" would pass with a table that is never read.
##
## No mocks: real files on a real file system. On a Windows volume without a
## change journal no version is available, nothing is memoized, and the
## "consulted" control is skipped with that reason.

import std/[os, strutils, tempfiles, times, unittest]
import repro_test_support/reasoned_skip
import repro_local_store

proc freshHash(path: string): FileFingerprint =
  let saved = contentTableRoot()
  setContentTableRoot("")
  result = observeFile(path, ffpHybrid)
  setContentTableRoot(saved)

proc entryFor(path: string): string =
  let v = contentVersion(path)
  if not v.known:
    return ""
  contentTableRoot() / toHex(v.volumeId, 8).toLowerAscii /
    (toHex(v.fileId, 16).toLowerAscii & ".cte")

proc quiesce(path: string) =
  ## Back-date the modification time past the racy window.
  setLastModificationTime(path, getTime() - initDuration(hours = 1))

let root = createTempDir("repro-content-table-", "")
setContentTableRoot(root / "table")

suite "content table":

  test "a quiescent file's hash is memoized and the table is consulted":
    let file = root / "tool.bin"
    writeFile(file, "the toolchain's bytes")
    quiesce(file)
    let first = observeFile(file, ffpHybrid)
    check first.hasLocalHash
    check first.localHash == freshHash(file).localHash
    let entry = entryFor(file)
    if entry.len == 0:
      skip("this volume offers no file-system version (no change journal)")
    else:
      check fileExists(entry)
      # Tamper with the recorded hash: if the table is consulted, the next
      # observation returns the tampered value. (Restored afterwards.)
      let original = readFile(entry)
      var lines = original.splitLines()
      let parts = lines[4].split(':')
      lines[4] = parts[0] & ":" & parts[1] & ":12345"
      writeFile(entry, lines.join("\n"))
      check observeFile(file, ffpHybrid).localHash.value == 12345'u64
      writeFile(entry, original)
      check observeFile(file, ffpHybrid).localHash == first.localHash

  test "a same-size rewrite with the old modification time is seen":
    let file = root / "rewritten.bin"
    writeFile(file, "AAAAAAAAAAAAAAAA")
    quiesce(file)
    let before = observeFile(file, ffpHybrid)
    let mtime = getLastModificationTime(file)
    writeFile(file, "BBBBBBBBBBBBBBBB")
    setLastModificationTime(file, mtime)
    let after = observeFile(file, ffpHybrid)
    check after.localHash == freshHash(file).localHash
    check after.localHash != before.localHash

  test "a rename-over at the same size and time is seen":
    let file = root / "renamed.bin"
    let other = root / "other.bin"
    writeFile(file, "1111111111111111")
    writeFile(other, "2222222222222222")
    quiesce(file)
    setLastModificationTime(other, getLastModificationTime(file))
    let before = observeFile(file, ffpHybrid)
    moveFile(other, file)
    let after = observeFile(file, ffpHybrid)
    check after.localHash == freshHash(file).localHash
    check after.localHash != before.localHash

  test "a file written within the racy window is not trusted":
    let file = root / "racy.bin"
    writeFile(file, "freshly written")
    let first = observeFile(file, ffpHybrid)
    let entry = entryFor(file)
    if entry.len > 0 and fileExists(entry):
      # An entry recorded for a file that had not been still for the window
      # is never served, even if it says something else.
      var lines = readFile(entry).splitLines()
      let parts = lines[4].split(':')
      lines[4] = parts[0] & ":" & parts[1] & ":12345"
      writeFile(entry, lines.join("\n"))
    check observeFile(file, ffpHybrid).localHash == first.localHash

  test "with no root nothing is recorded":
    let file = root / "unrecorded.bin"
    writeFile(file, "x")
    quiesce(file)
    setContentTableRoot(root / "table-off")
    let wouldBe = entryFor(file)
    setContentTableRoot("")
    discard observeFile(file, ffpHybrid)
    check not dirExists(root / "table-off")
    if wouldBe.len > 0:
      check not fileExists(wouldBe)
    setContentTableRoot(root / "table")

try:
  removeDir(root)
except OSError:
  discard

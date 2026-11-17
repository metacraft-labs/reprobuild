## The output bytes of a shareable portable record, stored on this host so
## that another checkout which resolves the record can put its outputs in
## place (Caching-Architecture.md, "Design for XPC-AREQ1", D6).
##
## A portable memo record (`portable_memo`) names each output by its logical
## path and its published content digest (`fileContentHex`: BLAKE3-256 under
## the published-digest domain). The record is metadata: before this module
## existed, a second checkout that found the record by its portable key had
## nothing on this host to restore from, and executed the action anyway.
##
## Layout, under `<action-cache root>/portable-outputs/`:
##
##   <root>/<first two hex digits>/<digest>
##
## one blob per distinct file content. A directory output is stored entry by
## entry: each file of its manifest under the digest the manifest states;
## its directories and symbolic links are recreated from the manifest itself,
## which the record carries. The record is the index (weak fingerprint ->
## path set -> strong fingerprint -> outputs and their digests), so the
## blobs need no index of their own.
##
## Writing. A blob is written to a temporary name in its shard directory
## (`.tmp-<pid>-<counter>-<digest>`), checked against the digest the record
## states, and renamed into place. An existing blob is never rewritten, so
## two builds storing the same content race only to the rename, and either
## winner leaves the same bytes. A crash leaves at most a temporary file,
## which is never read (the name is not a digest) and is reclaimed with the
## directory.
##
## Restoring. Every output is first staged beside its destination
## (`<dest>.repro-restore-<pid>-<counter>`) from its blob and checked against
## the record's digest; only when every output of the record has been staged
## and verified is any of them renamed over its destination. So a refused
## restore leaves the checkout as it was. A blob whose staged copy does not
## have the record's digest has been altered: it is removed, so the next
## build that produces those bytes stores them again, and the restore is
## refused naming the output (`<output>: digest mismatch`). A blob that is not
## there is refused the same way (`<output>: not stored`).
##
## Which records store bytes is the caller's decision (the build engine
## stores them for a record that may be served across checkouts: the
## publication rule allows it, the edge is not host-bound and no output
## embeds a root's physical path). This module stores and restores whatever
## record it is given.

import std/[options, os, strutils]

import repro_core/paths

import ./link_capability
import ./portable_fingerprint
import ./portable_memo

const
  PortableOutputsDirName* = "portable-outputs"
    ## The directory under the shared action-cache root (D6).

type
  PortableOutputStoreResult* = object
    ## What one `storePortableOutputs` call did.
    reason*: string
      ## "" when every output's bytes are stored (now or before); otherwise
      ## why not. Nothing is restorable from a record with a reason.
    blobsWritten*: int
      ## Blobs this call added.
    bytesWritten*: int64
      ## The bytes of the blobs this call added (logical size; a reflinked
      ## blob shares its extents with the output it was cloned from).
    blobsPresent*: int
      ## Blobs the record needed that were already stored.

var tempCounter {.threadvar.}: int

proc nextTempSuffix(): string =
  inc tempCounter
  $getCurrentProcessId() & "-" & $tempCounter

proc isDigestName(name: string): bool =
  name.len == 64 and name.allCharsInSet(HexDigits)

proc portableOutputBlobPath*(storeRoot, digest: string): string =
  ## Where the blob of `digest` lives under `storeRoot`
  ## (`<action-cache root>/portable-outputs`).
  storeRoot / digest[0 .. 1] / digest

proc removeQuietly(path: string) =
  try:
    let p = extendedPath(path)
    if symlinkExists(p) or fileExists(p):
      removeFile(p)
    elif dirExists(p):
      removeDir(p)
  except CatchableError:
    discard

proc cloneOrCopy(src, dst: string) =
  ## `dst` as a copy of `src`: a copy-on-write clone where the filesystem
  ## pair supports one (`attemptReflink`, which leaves no debris when it
  ## fails), the streaming copy otherwise. Either way `dst` is a fresh file
  ## with the mode a new file gets, never a link to `src`: an output a tool
  ## later rewrites in place must not rewrite the stored blob, and a blob
  ## must not change under a checkout that restored it.
  let attempt = attemptReflink(src, dst)
  if attempt.outcome != loOk:
    copyFile(extendedPath(src), extendedPath(dst))

proc setExecutable(path: string; executable: bool) =
  ## The record states one executable bit per file (`executableBit`: the
  ## owner's). Give the restored file the execute permission wherever it
  ## has the matching read permission, as a checkout of an executable is.
  when defined(posix):
    var perms = getFilePermissions(extendedPath(path))
    if executable:
      if fpUserRead in perms: perms.incl(fpUserExec)
      if fpGroupRead in perms: perms.incl(fpGroupExec)
      if fpOthersRead in perms: perms.incl(fpOthersExec)
    else:
      perms.excl({fpUserExec, fpGroupExec, fpOthersExec})
    setFilePermissions(extendedPath(path), perms)
  else:
    discard executable

proc storeBlob(storeRoot, source, digest: string;
               tally: var PortableOutputStoreResult): string =
  ## Store the bytes of `source` as the blob of `digest`; "" or why not.
  if not isDigestName(digest):
    return "not a content digest: " & digest
  let blob = portableOutputBlobPath(storeRoot, digest)
  if fileExists(extendedPath(blob)):
    inc tally.blobsPresent
    return ""
  let shard = blob.parentDir
  try:
    createDir(extendedPath(shard))
  except CatchableError as err:
    return "cannot create " & shard & ": " & err.msg
  let temp = shard / (".tmp-" & nextTempSuffix() & "-" & digest)
  try:
    cloneOrCopy(source, temp)
    # The record's digest was taken from the output a moment ago; an output
    # rewritten since then must not be stored under the old digest.
    let actual = fileContentHex(temp)
    if actual != digest:
      removeQuietly(temp)
      return source & " changed while its bytes were being stored"
    let size = getFileSize(extendedPath(temp))
    moveFile(extendedPath(temp), extendedPath(blob))
    inc tally.blobsWritten
    tally.bytesWritten += size
    ""
  except CatchableError as err:
    removeQuietly(temp)
    "cannot store " & source & ": " & err.msg

proc storePortableOutputs*(storeRoot: string; roots: openArray[LogicalRoot];
                           record: PortableMemoRecord):
    PortableOutputStoreResult =
  ## Store the bytes of every output `record` names, read from where THIS
  ## host's `roots` put them, under `storeRoot`. Outputs whose blobs are
  ## already stored cost one existence check each.
  for output in record.outputs:
    let physical = toPhysicalPath(roots, output.path)
    if physical.isNone:
      result.reason = "output " & output.path & " has no location on this host"
      return
    let p = physical.get()
    if output.directory:
      for entry in output.entries:
        if entry.kind != tekFile:
          continue
        let why = storeBlob(storeRoot, p / entry.rel, entry.identity, result)
        if why.len > 0:
          result.reason = "output " & output.path & ": " & why
          return
    else:
      let why = storeBlob(storeRoot, p, output.digest, result)
      if why.len > 0:
        result.reason = "output " & output.path & ": " & why
        return

proc portableOutputsStored*(storeRoot: string;
                            record: PortableMemoRecord): bool =
  ## Whether a blob is present for every file `record` names (presence only;
  ## a restore verifies the bytes).
  for output in record.outputs:
    if output.directory:
      for entry in output.entries:
        if entry.kind == tekFile and not fileExists(extendedPath(
            portableOutputBlobPath(storeRoot, entry.identity))):
          return false
    elif not isDigestName(output.digest) or not fileExists(extendedPath(
        portableOutputBlobPath(storeRoot, output.digest))):
      return false
  true

type
  StagedOutput = object
    temp: string
    destination: string
    directory: bool

proc stageFile(storeRoot, outputPath, digest: string; executable: bool;
               temp: string): string =
  ## Copy the blob of `digest` to `temp` and check it; "" or the refusal.
  ## An altered blob is removed.
  if not isDigestName(digest):
    return outputPath & ": not stored"
  let blob = portableOutputBlobPath(storeRoot, digest)
  if not fileExists(extendedPath(blob)):
    return outputPath & ": not stored"
  cloneOrCopy(blob, temp)
  if fileContentHex(temp) != digest:
    removeQuietly(temp)
    removeQuietly(blob)
    return outputPath & ": digest mismatch"
  setExecutable(temp, executable)
  ""

proc manifestEscape(output: PortableOutput): string =
  ## Why the manifest of a directory output cannot be rebuilt inside its
  ## staging directory, "" when it can. The tree digest is checked only
  ## after the tree has been written, so an entry that would be written
  ## outside the tree must be refused before anything is written: a `rel`
  ## that is empty, absolute, or has an empty, `.` or `..` component, and
  ## any entry below a symbolic-link entry (writing through the link would
  ## follow it, wherever it points). A manifest the engine recorded from a
  ## real directory has none of these.
  var links: seq[string] = @[]
  for entry in output.entries:
    if entry.kind in {tekLinkToFile, tekLinkToDir}:
      links.add entry.rel
  for entry in output.entries:
    let rel = entry.rel
    if rel.len == 0 or rel[0] == '/' or '\\' in rel or
        (rel.len >= 2 and rel[1] == ':'):
      return output.path & ": manifest entry '" & rel &
        "' is not a relative path"
    for part in rel.split('/'):
      if part.len == 0 or part == "." or part == "..":
        return output.path & ": manifest entry '" & rel &
          "' is not a relative path"
    for link in links:
      if rel.len > link.len and rel.startsWith(link) and rel[link.len] == '/':
        return output.path & ": manifest entry '" & rel &
          "' lies below the symbolic link '" & link & "'"
  ""

proc stageDirectory(storeRoot: string; output: PortableOutput;
                    temp: string): string =
  ## Rebuild a directory output at `temp` from its manifest and blobs, and
  ## check the result against the record's tree digest. A manifest with an
  ## entry that would land outside `temp` is refused before anything is
  ## written (`manifestEscape`).
  let escape = manifestEscape(output)
  if escape.len > 0:
    return escape
  createDir(extendedPath(temp))
  for entry in output.entries:
    let at = temp / entry.rel
    case entry.kind
    of tekDirectory:
      createDir(extendedPath(at))
    of tekFile:
      createDir(extendedPath(at.parentDir))
      let why = stageFile(storeRoot, output.path & "/" & entry.rel,
        entry.identity, entry.executable, at)
      if why.len > 0:
        return why
    of tekLinkToFile, tekLinkToDir:
      createDir(extendedPath(at.parentDir))
      createSymlink(entry.identity, extendedPath(at))
  if treeContentHex(temp) != output.digest:
    return output.path & ": digest mismatch"
  ""

proc restorePortableOutputs*(storeRoot: string; roots: openArray[LogicalRoot];
                             record: PortableMemoRecord): string =
  ## Put every output `record` names in place at the paths THIS host's
  ## `roots` give them, from the blobs under `storeRoot`, each verified
  ## against the record's digest before any destination is written. Returns
  ## "" or the reason nothing was put in place (see the module doc).
  var staged: seq[StagedOutput] = @[]
  proc discardStaged() =
    for s in staged:
      removeQuietly(s.temp)
  for output in record.outputs:
    let physical = toPhysicalPath(roots, output.path)
    if physical.isNone:
      discardStaged()
      return "output " & output.path & " has no location on this host"
    let destination = physical.get()
    let temp = destination & ".repro-restore-" & nextTempSuffix()
    staged.add(StagedOutput(temp: temp, destination: destination,
      directory: output.directory))
    let why =
      try:
        createDir(extendedPath(destination.parentDir))
        if output.directory:
          stageDirectory(storeRoot, output, temp)
        else:
          stageFile(storeRoot, output.path, output.digest, output.executable,
            temp)
      except CatchableError as err:
        output.path & ": cannot be staged: " & err.msg
    if why.len > 0:
      discardStaged()
      return why
  # Every output is staged and verified: replace the destinations.
  for i, s in staged:
    try:
      let dest = extendedPath(s.destination)
      if symlinkExists(dest) or (fileExists(dest) and not s.directory):
        removeFile(dest)
      elif dirExists(dest):
        removeDir(dest)
      elif fileExists(dest):
        removeFile(dest)
      if s.directory:
        moveDir(extendedPath(s.temp), dest)
      else:
        moveFile(extendedPath(s.temp), dest)
    except CatchableError as err:
      for rest in staged[i .. ^1]:
        removeQuietly(rest.temp)
      return "cannot put " & s.destination & " in place: " & err.msg
  ""

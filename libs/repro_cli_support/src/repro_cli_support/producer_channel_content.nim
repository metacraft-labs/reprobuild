## The CONTENT identity of the directories a cross-repo producer hands a
## consuming action (Cross-Repo-Source-Consumption §4.3, rule 2).
##
## Why it exists. A consumer action whose reads nothing observes — a
## recognised-format / depfile policy, ``readsAreKeyed`` false — is keyed only
## on its weak fingerprint plus what its report names. A report is what the
## tool chose to name, not what it read: ``-MMD`` omits every header found
## through ``-isystem``, which is how a producer's include directory is
## usually passed. So for such an action the producer's source has to be
## folded into the weak fingerprint, and the folded value has to change
## whenever a byte the action could read through those directories changes.
## The develop override's ``contentIdentity`` cannot do that: it names the
## override (package, state, absolute path), and an earlier scheme that added
## the root directory's mtime missed every edit below the root. A lock pin's
## revision + integrity cannot either: a placed sibling checkout verified
## against its pin can still carry uncommitted edits.
##
## What is digested. For each channel directory, tagged by its channel kind
## and its path, a Merkle-style digest of the tree beneath it: every entry in
## relative-path order; a regular file by its streamed BLAKE3 content digest
## (``fileContentHex``) and its owner-executable bit; a directory by its
## presence; a symbolic link by its target text AND by what it resolves to —
## a linked file's content, a linked directory's tree, descended with a cycle
## guard on the real path of each ancestor — because a compiler opening a
## header through a link reads the target. A dangling link is recorded as
## dangling, a missing channel directory as absent; both are deterministic
## states a compile observes as "not there". No mtime is used anywhere: an
## mtime is neither necessary (a same-length edit with the old mtime restored
## must still move the key) nor sufficient (a coarse-resolution timestamp can
## stay put across an edit).
##
## Entries named ``.git`` are skipped: VCS metadata no compiler, linker or
## ``pkg-config`` reads through a search path, and whose churn (an index
## refresh, a fetch) would otherwise miss every rule-2 consumer of a producer
## whose channel directory is a checkout root.
##
## Failing closed. When any entry cannot be listed, stat'ed or read, the
## digest would describe a tree that is not the one on disk, so the identity
## is reported incomplete and the caller must not key an action on it
## (``Failure-Semantics.md`` §"General Rules": ambiguous correctness failures
## fail closed). ``complete`` is false and ``failure`` names the first entry
## that could not be read.

import std/[algorithm, os]
when defined(posix):
  import std/posix
else:
  import std/strutils

import repro_core/paths
import repro_core/link_target
import repro_hash
import repro_local_store/portable_fingerprint

const ProducerChannelContentVersion* =
  "cross-repo-producer-channel-content.v1"
  ## Leads every payload; bumping it retires every key it keyed.

type
  ProducerChannelDir* = object
    ## One directory a producer hands a consumer: the channel kind it is
    ## handed on (``bin``, ``include``, ``lib``, ``pkgconfig``, ``cmake``,
    ## ``nimpath``) and its absolute path.
    channel*: string
    path*: string

  ProducerChannelContent* = object
    digest*: string
      ## Hex digest of every channel tree; meaningful only when ``complete``.
    complete*: bool
    failure*: string
      ## The first entry that could not be read, with the reason.

  ChannelWalk = object
    payload: string
    complete: bool
    failure: string
    ancestors: seq[string]
      ## Real paths of the directories on the current descent path: a
      ## directory link that resolves to one of them is a cycle.

proc fail(walk: var ChannelWalk; path, why: string) =
  if walk.complete:
    walk.failure = path & ": " & why
  walk.complete = false

proc record(walk: var ChannelWalk; parts: varargs[string]) =
  for part in parts:
    walk.payload.add(part)
    walk.payload.add('\x00')

proc walkDirTree(walk: var ChannelWalk; absDir, rel: string)

proc recordResolved(walk: var ChannelWalk; absPath, rel: string;
                    isDir, isRegular, executable: bool; specialKind: string) =
  ## Record what an entry IS once any link has been followed.
  if isDir:
    walk.record("dir", rel)
    walk.walkDirTree(absPath, rel)
  elif isRegular:
    # ``fileContentHex`` returns "" when the file cannot be opened, but a read
    # error after a successful open (EIO, a file truncated under us) surfaces
    # as an ``IOError`` from ``readBytes``. Both mean the bytes are unknown, so
    # both fail closed here instead of the second escaping the build's fold.
    let digest =
      try: fileContentHex(absPath)
      except CatchableError as err:
        walk.fail(absPath, "cannot be read: " & err.msg)
        return
    if digest.len == 0:
      walk.fail(absPath, "cannot be read")
      return
    walk.record("file", rel, (if executable: "x" else: "-"), digest)
  else:
    # A FIFO, socket or device: never opened (a FIFO would block), recorded by
    # kind so its appearance or disappearance still moves the key.
    walk.record("special", rel, specialKind)

when defined(posix):
  proc specialKindOf(mode: Mode): string =
    if S_ISFIFO(mode): "fifo"
    elif S_ISSOCK(mode): "socket"
    elif S_ISCHR(mode): "char-device"
    elif S_ISBLK(mode): "block-device"
    else: "other"

proc recordEntry(walk: var ChannelWalk; absPath, rel: string) =
  when defined(posix):
    var lst: Stat
    if lstat(absPath.cstring, lst) != 0:
      walk.fail(absPath, "cannot be stat'ed: " & $strerror(errno))
      return
    var st = lst
    if S_ISLNK(lst.st_mode):
      let target =
        try: readSymlinkTarget(absPath)
        except CatchableError as err:
          walk.fail(absPath, "link target cannot be read: " & err.msg)
          return
      walk.record("link", rel, target)
      if stat(absPath.cstring, st) != 0:
        let code = errno
        if code in [ENOENT, ENOTDIR, ELOOP]:
          # Resolves to nothing: what a compile observes is "not there".
          walk.record("dangling", rel)
          return
        walk.fail(absPath, "link cannot be resolved: " & $strerror(code))
        return
    walk.recordResolved(absPath, rel, S_ISDIR(st.st_mode),
      S_ISREG(st.st_mode), (int(st.st_mode) and 0o100) != 0,
      specialKindOf(st.st_mode))
  else:
    let path = extendedPath(absPath)
    let info =
      try: getFileInfo(path, followSymlink = false)
      except CatchableError as err:
        walk.fail(absPath, "cannot be stat'ed: " & err.msg)
        return
    var resolvedKind = info.kind
    if info.kind in {pcLinkToFile, pcLinkToDir}:
      let target =
        try: readSymlinkTarget(absPath)
        except CatchableError as err:
          walk.fail(absPath, "link target cannot be read: " & err.msg)
          return
      walk.record("link", rel, target.replace('\\', '/'))
      if not fileExists(path) and not dirExists(path):
        walk.record("dangling", rel)
        return
      resolvedKind = if dirExists(path): pcDir else: pcFile
    walk.recordResolved(absPath, rel, resolvedKind == pcDir,
      resolvedKind == pcFile, executableBit(absPath), "")

proc walkDirTree(walk: var ChannelWalk; absDir, rel: string) =
  let real =
    try: expandFilename(extendedPath(absDir))
    except CatchableError as err:
      walk.fail(absDir, "cannot be resolved: " & err.msg)
      return
  if real in walk.ancestors:
    walk.record("cycle", rel)
    return
  walk.ancestors.add(real)
  defer: walk.ancestors.setLen(walk.ancestors.len - 1)
  var names: seq[string] = @[]
  try:
    # ``checkDir`` raises on a directory that cannot be opened; the default
    # silently yields nothing, which would digest an unreadable directory as
    # an empty one.
    for _, name in walkDir(extendedPath(absDir), relative = true,
                           checkDir = true):
      names.add(name)
  except CatchableError as err:
    walk.fail(absDir, "cannot be listed: " & err.msg)
    return
  names.sort()
  for name in names:
    if name == ".git":
      continue
    let childRel = if rel.len == 0: name else: rel & "/" & name
    walk.recordEntry(absDir / name, childRel)

proc producerChannelContent*(selector: string;
                             dirs: openArray[ProducerChannelDir]):
    ProducerChannelContent =
  ## The content identity of ``dirs`` for producer ``selector`` (see the
  ## module note). Each directory is framed by its channel kind and path, so
  ## the same tree handed on another channel or from another place is a
  ## different identity. Deterministic for an unchanged tree.
  var walk = ChannelWalk(complete: true)
  walk.record(ProducerChannelContentVersion, selector)
  for dir in dirs:
    walk.record("channel", dir.channel, dir.path)
    let path = extendedPath(dir.path)
    var exists = false
    try:
      exists = dirExists(path) or fileExists(path) or symlinkExists(path)
    except CatchableError as err:
      walk.fail(dir.path, "cannot be stat'ed: " & err.msg)
    if not exists:
      walk.record("absent")
      continue
    walk.recordEntry(dir.path, "")
  result.complete = walk.complete
  result.failure = walk.failure
  if walk.complete:
    result.digest = toHex(blake3DomainDigest(
      walk.payload.toOpenArrayByte(0, walk.payload.high),
      hdActionFingerprint).bytes)

proc treeContentDigest*(label, dir: string): ProducerChannelContent =
  ## The same Merkle-style content identity as ``producerChannelContent``,
  ## for ONE tree framed by ``label`` instead of by its absolute path, so two
  ## copies of one tree in different places have one digest. The gitlink
  ## source composition (§4.2a.2a) uses it to bind the snapshot it took to
  ## the source it took it from: the source tree and its copy are digested
  ## under the same label and must agree, or the source changed underneath
  ## the snapshot. ``.git`` entries are skipped exactly as above.
  var walk = ChannelWalk(complete: true)
  walk.record(ProducerChannelContentVersion, "tree", label)
  let path = extendedPath(dir)
  var exists = false
  try:
    exists = dirExists(path) or fileExists(path) or symlinkExists(path)
  except CatchableError as err:
    walk.fail(dir, "cannot be stat'ed: " & err.msg)
  if not exists:
    walk.record("absent")
  else:
    walk.recordEntry(dir, "")
  result.complete = walk.complete
  result.failure = walk.failure
  if walk.complete:
    result.digest = toHex(blake3DomainDigest(
      walk.payload.toOpenArrayByte(0, walk.payload.high),
      hdActionFingerprint).bytes)

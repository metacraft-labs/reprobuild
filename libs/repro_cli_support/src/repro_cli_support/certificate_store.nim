## The standard per-user local certificate store (test-certificates
## ``Transport.md`` §2): where every certificate reprobuild issues is
## delivered, and where every client-side gate looks for one.
##
## This module knows about FILES, not about certificate records. It resolves
## the two roots (§2.1), lists one content directory in a root (§2.4), writes
## one record atomically (§2.3) and prunes a root (§2.5). Deriving a record's
## store path from its canonical payload, parsing what was read and deciding
## what a certificate covers stay in ``repro_cli_support``, which calls in
## here.
##
## The rules, as implemented
## -------------------------
## * **Roots (§2.1).** The USER root is ``$TEST_CERTIFICATES_DIR`` when it is
##   an absolute path, else the platform's per-user state directory. The
##   SYSTEM root is ``$TEST_CERTIFICATES_SYSTEM_DIR/<uid>`` when that is
##   absolute, else ``/var/lib/test-certificates/<uid>`` (and the macOS and
##   Windows equivalents). A relative value is ignored and the reason is kept,
##   so a user who set it can see why it had no effect. reprobuild's
##   ``repro test`` runs as the user, so it writes the user root and never the
##   system root, which belongs to a privileged producer.
## * **Writing (§2.3).** Directories this code creates are owner-only. The
##   record goes to a temporary name in the SAME directory that begins with
##   ``.`` and does not end in ``.toml``, is flushed to stable storage, and is
##   renamed onto its final name. When the final name exists, a SIGNED record
##   always replaces it (its signature was just made; the existing copy may be
##   unsigned or carry a signature that fails), and an UNSIGNED record keeps
##   it (the existing file is the same claim, or the same claim signed).
## * **Reading (§2.4).** A missing root or directory is "nothing found",
##   never an error. A directory that exists and cannot be listed is
##   UNREADABLE and is said so: ``walkDir`` is called with ``checkDir``,
##   because without it a directory it cannot open yields nothing at all and
##   an unreadable store would read as an empty one. Names beginning with
##   ``.`` are never records.
## * **Pruning (§2.5).** Whole content directories, keeping the ``keep`` most
##   recently written plus the protected ones (the current repository's
##   ``HEAD^{tree}`` directory, the one just written). A directory leaves the
##   store in ONE atomic step — renamed, within its parent, to a dot-name no
##   reader treats as a content directory — and is deleted only after that.
##   Deleting in place is not atomic: a writer whose first attempt it defeated
##   retries into the same, still-present directory, and the deletion goes on
##   to remove the retry's temporary file and the directory under it. A
##   directory a writer is in (modified a moment ago, or holding a fresh
##   temporary file) is left alone. A writer whose rename failed because a
##   prune took its directory (the temporary file vanished, or the directory
##   is gone or is no longer the one it wrote into) recreates it and retries
##   once; the retry's directory was created after the rename aside, so that
##   removal cannot reach it.
##
## Nothing here runs a program.

import std/[algorithm, atomics, os, strutils, times]

when defined(windows):
  import std/winlean
else:
  from std/posix import fsync, getuid
  proc c_rename(oldname, newname: cstring): cint {.
    importc: "rename", header: "<stdio.h>".}

const
  StoreDirName* = "test-certificates"
    ## The leaf of every per-user and machine-wide root (§2.1).
  LocalStoreLayout* = "v1"
    ## The layout version directory directly under a root (§2.2).
  DefaultStoreRetention* = 20
    ## The reference policy's number of content directories kept (§2.5).
  StaleTemporaryAge* = initDuration(hours = 1)
    ## A temporary file older than this belongs to a writer that died. Without
    ## an age, a crashed run would pin its content directory forever.
  FreshDirectoryAge* = initDuration(seconds = 10)
    ## A content directory modified more recently than this is treated as
    ## being written into: a writer creates the directory a moment BEFORE it
    ## opens its temporary file.
  TemporaryMarker* = ".tmp-"
    ## Part of every temporary name, after the leading ``.``.
  RemovalMarker* = ".removing-"
    ## Part of the name a content directory is renamed to while a prune
    ## deletes it: ``.<digest>.removing-<pid>-<n>``.

# ---------------------------------------------------------------------------
# Roots (§2.1)
# ---------------------------------------------------------------------------

type
  StoreRootPlatform* = enum
    srpUnix, srpMacos, srpWindows

  StoreEnvironment* = proc(name: string): string {.closure.}

  CertificateStoreRoots* = object
    user*: string
      ## The user root; "" when it could not be resolved.
    system*: string
      ## This user's partition of the system root; "" when unresolved.
    problems*: seq[string]
      ## Why a root is unresolved, or why a variable that was set was ignored.

proc storeRootPlatformFor*(osName: string): StoreRootPlatform =
  case osName
  of "macosx", "macos", "darwin": srpMacos
  of "windows": srpWindows
  else: srpUnix

proc isAbsoluteOn(platform: StoreRootPlatform; path: string): bool =
  case platform
  of srpWindows:
    (path.len >= 3 and path[0] in Letters and path[1] == ':' and
      path[2] in {'\\', '/'}) or path.startsWith("\\\\")
  else:
    path.startsWith("/")

proc joinOn(platform: StoreRootPlatform; parts: varargs[string]): string =
  let sep = if platform == srpWindows: '\\' else: '/'
  for part in parts:
    if result.len == 0:
      result = part
    elif result.endsWith(sep):
      result.add(part)
    else:
      result.add(sep)
      result.add(part)

proc absoluteVariable(platform: StoreRootPlatform; env: StoreEnvironment;
                      name: string; problems: var seq[string]): string =
  let value = env(name)
  if value.len == 0:
    return ""
  if not isAbsoluteOn(platform, value):
    problems.add("$" & name & " is set to the relative path '" & value &
      "', which is ignored: a store whose location depends on the current " &
      "directory would be a different store for each process")
    return ""
  value

proc resolveCertificateStoreRoots*(platform: StoreRootPlatform;
                                   env: StoreEnvironment;
                                   account: string): CertificateStoreRoots =
  ## Both roots per §2.1. ``account`` is the numeric uid on POSIX systems and
  ## the account SID on Windows; "" leaves the system root unresolved (a guess
  ## could name another user's partition).
  let explicitUser = absoluteVariable(platform, env, "TEST_CERTIFICATES_DIR",
    result.problems)
  if explicitUser.len > 0:
    result.user = explicitUser
  else:
    case platform
    of srpUnix:
      let stateHome = absoluteVariable(platform, env, "XDG_STATE_HOME",
        result.problems)
      if stateHome.len > 0:
        result.user = joinOn(platform, stateHome, StoreDirName)
      else:
        let home = absoluteVariable(platform, env, "HOME", result.problems)
        if home.len > 0:
          result.user = joinOn(platform, home, ".local", "state", StoreDirName)
        else:
          result.problems.add("the user root cannot be resolved: neither " &
            "$TEST_CERTIFICATES_DIR, $XDG_STATE_HOME nor $HOME is an " &
            "absolute path")
    of srpMacos:
      let home = absoluteVariable(platform, env, "HOME", result.problems)
      if home.len > 0:
        result.user = joinOn(platform, home, "Library", "Application Support",
          StoreDirName)
      else:
        result.problems.add("the user root cannot be resolved: neither " &
          "$TEST_CERTIFICATES_DIR nor $HOME is an absolute path")
    of srpWindows:
      let local = absoluteVariable(platform, env, "LOCALAPPDATA",
        result.problems)
      if local.len > 0:
        result.user = joinOn(platform, local, StoreDirName)
      else:
        result.problems.add("the user root cannot be resolved: neither " &
          "%TEST_CERTIFICATES_DIR% nor %LOCALAPPDATA% is an absolute path")

  let explicitSystem = absoluteVariable(platform, env,
    "TEST_CERTIFICATES_SYSTEM_DIR", result.problems)
  if account.len == 0:
    result.problems.add("the system root cannot be resolved: this process " &
      "does not know its account's " &
      (if platform == srpWindows: "SID" else: "uid"))
    return
  if explicitSystem.len > 0:
    result.system = joinOn(platform, explicitSystem, account)
  else:
    case platform
    of srpUnix:
      result.system = joinOn(platform, "/var/lib", StoreDirName, account)
    of srpMacos:
      result.system = joinOn(platform, "/Library/Application Support",
        StoreDirName, account)
    of srpWindows:
      let programData = absoluteVariable(platform, env, "ProgramData",
        result.problems)
      if programData.len > 0:
        result.system = joinOn(platform, programData, StoreDirName, account)
      else:
        result.problems.add("the system root cannot be resolved: " &
          "%ProgramData% is not an absolute path")

proc nativeStoreAccount*(): string =
  ## The uid on POSIX. On Windows the account SID, which this process has no
  ## binding to read yet: "" there, so the system root is left unresolved and
  ## the reason recorded rather than guessed.
  when defined(windows): ""
  else: $getuid()

proc nativeCertificateStoreRoots*(): CertificateStoreRoots =
  ## Both roots as this process resolves them now. The environment is read on
  ## every call, never frozen at start-up.
  resolveCertificateStoreRoots(storeRootPlatformFor(hostOS),
    proc(name: string): string = getEnv(name), nativeStoreAccount())

# ---------------------------------------------------------------------------
# Retention setting (§2.5, operator decision D4)
# ---------------------------------------------------------------------------

proc certificateStoreRetention*(env: StoreEnvironment):
    tuple[keep: int; problem: string] =
  ## How many content directories a prune keeps. A user-level setting:
  ##   1. ``REPRO_CERTIFICATE_STORE_KEEP``;
  ##   2. ``keep = <n>`` under ``[certificate_store]`` in
  ##      ``$XDG_CONFIG_HOME/reprobuild/config.toml`` (else
  ##      ``$HOME/.config/reprobuild/config.toml``);
  ##   3. ``DefaultStoreRetention``.
  ## A value that is not a positive integer is reported and the default used.
  proc parsed(text, source: string): tuple[ok: bool; keep: int;
                                           problem: string] =
    try:
      let n = parseInt(text.strip())
      if n >= 1:
        return (true, n, "")
    except ValueError:
      discard
    (false, DefaultStoreRetention, source & " is '" & text &
      "', not a positive integer; keeping the default of " &
      $DefaultStoreRetention)
  let fromEnv = env("REPRO_CERTIFICATE_STORE_KEEP")
  if fromEnv.len > 0:
    let p = parsed(fromEnv, "$REPRO_CERTIFICATE_STORE_KEEP")
    return (p.keep, p.problem)
  let xdg = env("XDG_CONFIG_HOME")
  let base =
    if xdg.len > 0 and xdg.isAbsolute: xdg
    elif env("HOME").len > 0: env("HOME") / ".config"
    else: ""
  if base.len > 0:
    let path = base / "reprobuild" / "config.toml"
    var body = ""
    try:
      if fileExists(path):
        body = readFile(path)
    except CatchableError:
      body = ""
    var inTable = false
    for rawLine in body.splitLines():
      var line = rawLine
      let hash = line.find('#')
      if hash >= 0:
        line = line[0 ..< hash]
      line = line.strip()
      if line.len == 0:
        continue
      if line.startsWith("[") and line.endsWith("]"):
        inTable = line[1 ..< ^1].strip() == "certificate_store"
        continue
      if not inTable:
        continue
      let eq = line.find('=')
      if eq < 0 or line[0 ..< eq].strip() != "keep":
        continue
      let p = parsed(line[eq + 1 .. ^1], "[certificate_store] keep in " & path)
      return (p.keep, p.problem)
  (DefaultStoreRetention, "")

# ---------------------------------------------------------------------------
# Layout (§2.2)
# ---------------------------------------------------------------------------

proc isSafeComponent(text: string): bool =
  ## One path component that names a directory inside its parent: non-empty,
  ## not dot-named (dot-names are never content directories), no separator.
  text.len > 0 and text[0] != '.' and '/' notin text and '\\' notin text and
    '\0' notin text and ':' notin text

proc storeContentDir*(contentId: string):
    tuple[ok: bool; relative, problem: string] =
  ## ``v1/<algorithm>/<digest>`` for a content id, split at its FIRST ``:``.
  ## Joined with ``/`` on every platform; the caller converts.
  let colon = contentId.find(':')
  if colon <= 0 or colon == contentId.high:
    return (false, "", "content id '" & contentId & "' has no '<algorithm>:" &
      "<digest>' form to name a store directory by")
  let algorithm = contentId[0 ..< colon]
  let digest = contentId[colon + 1 .. ^1]
  if not isSafeComponent(algorithm) or not isSafeComponent(digest):
    return (false, "", "content id '" & contentId & "' cannot name a store " &
      "directory")
  (true, LocalStoreLayout & "/" & algorithm & "/" & digest, "")

proc toNative(relative: string): string = relative.replace('/', DirSep)

proc isStoreRecordName*(name: string): bool =
  ## A file a reader evaluates: ends in ``.toml``, does not begin with ``.``.
  name.len > ".toml".len and name.endsWith(".toml") and not name.startsWith(".")

# ---------------------------------------------------------------------------
# Reading one content directory (§2.4)
# ---------------------------------------------------------------------------

type
  StoreListingStatus* = enum
    slsListed    ## the directory was listed (possibly empty)
    slsAbsent    ## no root, or no such directory: nothing found
    slsUnreadable  ## it exists and could not be listed — never "empty"

  StoreRecordFile* = object
    path*: string
    name*: string
    bytes*: string

  StoreListing* = object
    status*: StoreListingStatus
    files*: seq[StoreRecordFile]
      ## Sorted by name.
    problems*: seq[string]
      ## Why the directory could not be listed, or which file could not be
      ## read. A file that cannot be read is reported, never silently skipped.

proc listStoreContentDir*(root, relativeDir: string): StoreListing =
  ## The record files of ``<root>/<relativeDir>``.
  if root.len == 0:
    result.status = slsAbsent
    return
  let dir = root / toNative(relativeDir)
  if not dirExists(dir):
    # Absent — or inside a directory of the store that cannot be searched,
    # which makes everything below it look absent. Tell the two apart by
    # listing the nearest directory of the store, from the root down, that
    # exists.
    if not dirExists(root):
      result.status = slsAbsent
      return
    var probe = root
    for part in relativeDir.split('/'):
      let next = probe / part
      if not dirExists(next):
        break
      probe = next
    try:
      for _ in walkDir(probe, checkDir = true):
        break
    except OSError as err:
      result.status = slsUnreadable
      result.problems.add("'" & probe & "' could not be read: " & err.msg)
      return
    result.status = slsAbsent
    return
  var entries: seq[tuple[kind: PathComponent; path: string]]
  try:
    for kind, path in walkDir(dir, checkDir = true):
      entries.add((kind, path))
  except OSError as err:
    result.status = slsUnreadable
    result.problems.add("'" & dir & "' could not be listed: " & err.msg)
    return
  result.status = slsListed
  entries.sort(proc(a, b: tuple[kind: PathComponent; path: string]): int =
    cmp(a.path, b.path))
  for entry in entries:
    if entry.kind notin {pcFile, pcLinkToFile}:
      continue
    let name = entry.path.extractFilename
    if not isStoreRecordName(name):
      continue
    try:
      result.files.add(StoreRecordFile(path: entry.path, name: name,
        bytes: readFile(entry.path)))
    except CatchableError as err:
      result.problems.add("'" & entry.path & "' could not be read: " & err.msg)

# ---------------------------------------------------------------------------
# Writing (§2.3)
# ---------------------------------------------------------------------------

type
  PublishStepHook* = proc(attempt: int) {.closure.}
    ## A test seam: called with the attempt number (0, then 1 on the retry)
    ## once the temporary file is written and flushed, just before the rename.
    ## ``nil`` in production.

  StorePublish* = object
    path*: string
      ## The record's full path.
    kept*: bool
      ## An unsigned record found its name taken and left the file in place.
    retried*: bool
      ## The first attempt lost its directory to a concurrent prune.
    error*: string
      ## Why it could not be written; "" on success.

proc ownerOnly(): set[FilePermission] = {fpUserRead, fpUserWrite, fpUserExec}

proc createOwnerOnlyDirs(root, relativeDir: string) =
  ## Create ``root`` and each missing directory of ``relativeDir`` below it,
  ## owner-only. Parents of the root are created with the platform's default
  ## mode; an existing directory's mode is left as its owner set it.
  if not dirExists(root):
    try:
      createDir(root)
      setFilePermissions(root, ownerOnly())
    except OSError:
      if not dirExists(root):
        raise
  var current = root
  for part in relativeDir.split('/'):
    if part.len == 0:
      continue
    current = current / part
    if not dirExists(current):
      try:
        createDir(current)
        setFilePermissions(current, ownerOnly())
      except OSError:
        # A concurrent writer created it first: the same directory.
        if not dirExists(current):
          raise

var temporaryCounter: Atomic[int]

proc temporaryName(finalName: string): string =
  ## ``.<final>.tmp-<pid>-<n>-<ns>``: begins with ``.``, does not end in
  ## ``.toml``, unique across processes and calls.
  let now = getTime()
  "." & finalName & TemporaryMarker & $getCurrentProcessId() & "-" &
    $(temporaryCounter.fetchAdd(1) + 1) & "-" & $now.toUnix() &
    $now.nanosecond

proc writeFlushed(path, content: string) =
  var f: File
  if not open(f, path, fmWrite):
    raise newException(IOError, "cannot open '" & path & "' for writing: " &
      osErrorMsg(osLastError()))
  try:
    f.write(content)
    f.flushFile()
    when not defined(windows):
      if fsync(getFileHandle(f)) != 0:
        raise newException(IOError, "fsync of '" & path & "' failed: " &
          osErrorMsg(osLastError()))
  finally:
    f.close()

proc touchDirectory(dir: string) =
  ## Mark a content directory written now. A rename into it does this
  ## itself; a publish that KEPT an existing file has to, or a content that
  ## was just re-tested would look old to the pruner.
  try:
    setLastModificationTime(dir, getTime())
  except OSError:
    discard

proc directoryIdentity(dir: string): string =
  ## Device and file number of ``dir``, "" when there is none: tells the
  ## directory a write went into from one recreated at the same path.
  try:
    let info = getFileInfo(dir)
    $info.id.device & ":" & $info.id.file
  except OSError:
    ""

proc publishStoreRecord*(root, relative, bytes: string; signed: bool;
                         beforeRename: PublishStepHook = nil): StorePublish =
  ## Steps 1–3 of §2.3 for ``<root>/<relative>`` (``/``-separated, the record
  ## file's store-relative path), with the one retry §2.5 allows when a
  ## concurrent prune took the directory between its creation and the rename.
  ## No root resolution, no guard, no prune: the certificate-aware caller in
  ## ``repro_cli_support`` does those.
  result.path = root / toNative(relative)
  let slash = relative.rfind('/')
  if slash <= 0:
    result.error = "'" & relative & "' is not a store record path"
    return
  let contentDir = relative[0 ..< slash]
  let dir = result.path.parentDir
  for attempt in 0 .. 1:
    var temporaryVanished = false
    var identity = directoryIdentity(dir)
    try:
      createOwnerOnlyDirs(root, contentDir)
      identity = directoryIdentity(dir)
      if not signed and fileExists(result.path):
        touchDirectory(dir)
        result.kept = true
        result.retried = attempt > 0
        return
      let temporary = dir / temporaryName(result.path.extractFilename)
      var created = false
      try:
        writeFlushed(temporary, bytes)
        created = true
        if beforeRename != nil:
          beforeRename(attempt)
        # rename(2) on POSIX replaces an existing target atomically;
        # MoveFileEx with MOVEFILE_REPLACE_EXISTING on Windows.
        moveFile(temporary, result.path)
      except CatchableError:
        temporaryVanished = created and not fileExists(temporary)
        try: removeFile(temporary)
        except CatchableError: discard
        raise
      result.retried = attempt > 0
      return
    except CatchableError as err:
      let now = directoryIdentity(dir)
      if attempt == 0 and (temporaryVanished or now.len == 0 or
                           now != identity):
        continue
      result.retried = attempt > 0
      result.error = err.msg
      return
  result.retried = true
  result.error = "the content directory disappeared twice while it was " &
    "written"

# ---------------------------------------------------------------------------
# Pruning (§2.5)
# ---------------------------------------------------------------------------

type
  PruneStage* = enum
    psChosen    ## chosen for removal, nothing changed yet
    psDetached  ## renamed aside: out of the store, its tree not yet deleted

  PruneStepHook* = proc(stage: PruneStage; relative: string) {.closure.}
    ## A test seam that lets a writer be interleaved with one directory's
    ## removal at a named point. ``nil`` in production.

  PruneOutcome* = object
    removed*: seq[string]
      ## Content directories removed (``v1/<algorithm>/<digest>``).
    errors*: seq[string]
      ## What could not be removed, and why. Never fatal.

proc beingWritten(dir: string; now: Time): bool =
  try:
    if now - getLastModificationTime(dir) < FreshDirectoryAge:
      return true
  except OSError:
    return true
  try:
    for kind, path in walkDir(dir, checkDir = true):
      let name = path.extractFilename
      if name.startsWith(".") and TemporaryMarker in name:
        try:
          if now - getLastModificationTime(path) < StaleTemporaryAge:
            return true
        except OSError:
          return true   # renamed into place a moment ago: a write too
  except OSError:
    return true
  false

var removalCounter: Atomic[int]

proc removalName(digest: string): string =
  "." & digest & RemovalMarker & $getCurrentProcessId() & "-" &
    $(removalCounter.fetchAdd(1) + 1)

proc renameAside(path, aside: string) =
  ## ONE rename of a directory within its parent and nothing else. ``moveDir``
  ## falls back to copy-and-delete when the rename is refused, which is
  ## neither atomic nor wanted: Windows refuses exactly when a writer has a
  ## file open inside.
  when defined(windows):
    if moveFileExW(newWideCString(path), newWideCString(aside), 0'i32) == 0:
      raiseOSError(osLastError(), path)
  else:
    if c_rename(path.cstring, aside.cstring) != 0:
      raiseOSError(osLastError(), path)

proc pruneStoreRoot*(root: string; keep: int; protected: openArray[string];
                     onStep: PruneStepHook = nil;
                     now = getTime()): PruneOutcome =
  ## Remove whole content directories from one root, keeping the ``keep``
  ## most recently modified (ties broken by name) and every directory in
  ## ``protected`` (``v1/<algorithm>/<digest>``). ``now`` is the clock the
  ## being-written guards compare with. Leftovers of a prune that died after
  ## its rename aside are deleted too.
  let layout = root / LocalStoreLayout
  if root.len == 0 or not dirExists(layout):
    return
  var dirs: seq[tuple[relative: string; mtime: Time]]
  try:
    for algorithmKind, algorithmPath in walkDir(layout, checkDir = true):
      if algorithmKind != pcDir:
        continue
      for digestKind, digestPath in walkDir(algorithmPath, checkDir = true):
        if digestKind != pcDir:
          continue
        let name = digestPath.extractFilename
        if name.startsWith("."):
          # Never a content directory. Any pruner may delete it.
          try:
            removeDir(digestPath)
          except OSError as err:
            if dirExists(digestPath):
              result.errors.add("'" & digestPath &
                "' could not be removed: " & err.msg)
          continue
        var mtime: Time
        try:
          mtime = getLastModificationTime(digestPath)
        except OSError:
          continue                       # gone already
        dirs.add((LocalStoreLayout & "/" & algorithmPath.extractFilename &
          "/" & name, mtime))
  except OSError as err:
    result.errors.add("the store at '" & layout & "' could not be listed: " &
      err.msg)
    return
  dirs.sort(proc(a, b: tuple[relative: string; mtime: Time]): int =
    if a.mtime != b.mtime:
      return (if a.mtime > b.mtime: -1 else: 1)
    -cmp(a.relative, b.relative))
  for i, entry in dirs:
    if i < keep or entry.relative in protected:
      continue
    let path = root / toNative(entry.relative)
    if beingWritten(path, now):
      continue
    if onStep != nil:
      onStep(psChosen, entry.relative)
    let aside = path.parentDir / removalName(path.extractFilename)
    try:
      renameAside(path, aside)
    except OSError as err:
      if dirExists(path):
        result.errors.add("'" & path & "' could not be removed: " & err.msg)
      continue                           # else another prune took it
    result.removed.add(entry.relative)
    if onStep != nil:
      onStep(psDetached, entry.relative)
    try:
      removeDir(aside)
    except OSError as err:
      result.errors.add("'" & aside & "' could not be removed: " & err.msg)

# ---------------------------------------------------------------------------
# The working-tree guard
# ---------------------------------------------------------------------------

proc resolvedPath(p: string): string =
  ## ``p`` absolute and normalised, with symbolic links resolved in whatever
  ## prefix of it exists.
  var existing = absolutePath(p).normalizedPath
  var suffix: seq[string]
  while existing.len > 0 and not dirExists(existing) and
      not fileExists(existing):
    let parent = existing.parentDir
    if parent == existing or parent.len == 0:
      break
    suffix.insert(existing.extractFilename, 0)
    existing = parent
  try:
    existing = expandFilename(existing)
  except OSError:
    discard
  for part in suffix:
    existing = existing / part
  existing

proc pathIsInside*(path, ancestor: string): bool =
  ## Whether ``path`` is ``ancestor`` or below it, symbolic links resolved.
  if path.len == 0 or ancestor.len == 0:
    return false
  let p = resolvedPath(path)
  let a = resolvedPath(ancestor)
  p == a or p.startsWith(a & DirSep)

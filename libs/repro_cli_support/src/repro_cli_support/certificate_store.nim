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
## What is the reference library's and what is reprobuild's
## -------------------------------------------------------
## Root resolution (§2.1), the user-root ownership check (§2.3) and pruning
## (§2.5) are the ``test_certificates`` library's (test-certificates-tools),
## linked rather than re-implemented, so they cannot drift from the helper
## every other producer uses. The WRITER stays here: the library writes only
## as a RELAY (Tooling §1), and reprobuild's issuance is a SIGNING writer —
## it made the signature it delivers, and §2.3 lets exactly that writer
## replace an existing signed copy. Keeping one writer with both roles is
## smaller than wrapping the relay-only one.
##
## The rules, as implemented
## -------------------------
## * **Roots (§2.1).** The USER root is ``$TEST_CERTIFICATES_DIR`` when it is
##   an absolute path, else the platform's per-user state directory. The
##   SYSTEM root is ``$TEST_CERTIFICATES_SYSTEM_DIR/<uid>`` when that is
##   absolute, else ``/var/lib/test-certificates/<uid>`` (and the macOS and
##   Windows equivalents). A relative or empty value is ignored and the reason
##   is kept, so a user who set it can see why it had no effect; a root with
##   no usable value is UNRESOLVED, never guessed. reprobuild's ``repro test``
##   runs as the user, so it writes the user root and never the system root,
##   which belongs to a privileged producer.
## * **Writing (§2.3).** An existing user root must be owned by this process's
##   effective account; that is checked before ANY mutation, the
##   ``.write-lock`` included, and a foreign root is refused, never adopted
##   or repaired. New directories are owner-only (``0700``) and new record
##   files ``0600`` whatever the umask. Atomic, flushed record renames. Every
##   writer holds the root's persistent `.write-lock` through inspecting and
##   publishing. Unsigned copies keep an existing record; relayed signed
##   copies replace only a well-formed unsigned twin. Only a caller that made
##   the new signature can replace an existing signed copy.
## * **Reading (§2.4).** A missing root or directory is "nothing found",
##   never an error. A directory that exists and cannot be listed is
##   UNREADABLE and is said so: ``walkDir`` is called with ``checkDir``,
##   because without it a directory it cannot open yields nothing at all and
##   an unreadable store would read as an empty one. Names beginning with
##   ``.`` are never records.
## * **Pruning (§2.5).** ``test_certificates/prune``'s ``pruneRoot``: whole
##   content directories, keeping the ``keep`` most recently written plus the
##   protected ones, each renamed aside to a dot-name in ONE atomic step and
##   only then deleted, a directory being written into left alone, and an
##   existing root owned by another account refused before anything is
##   renamed or deleted. WHICH directories are protected is the caller's
##   (``repro_cli_support``): every ``HEAD`` content id the library's
##   ``pruneProtection`` computes — unscoped and in each declared scope, in
##   the native ``git-tree-*`` algorithm and ``manifest-v1-sha256`` — plus
##   the directory just written. A writer whose rename failed because a
##   prune took its directory (the temporary file vanished, or the directory
##   is gone or is no longer the one it wrote into) recreates it and retries
##   once; the retry's directory was created after the rename aside, so that
##   removal cannot reach it.
##
## Nothing here runs a program.

import std/[algorithm, atomics, os, strutils, times]

import repro_cli_support/content_id

# The reference library's modules, imported QUALIFIED ONLY: its names
# (``parseContentId``, ``PruneStage``, ``StoreRoots``…) overlap this
# engine's own, and an unqualified import would let an overload silently
# pick the other one.
from test_certificates/roots as tcroots import nil
from test_certificates/prune as tcprune import nil
from test_certificates/layout as tclayout import nil

when defined(windows):
  import std/winlean
  from test_certificates/windows_owner as tcowner import nil
else:
  import std/posix except Time
  var storeNoFollow {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint
  var storeOpenDirectory {.importc: "O_DIRECTORY", header: "<fcntl.h>".}: cint
  from test_certificates/permissions as tcperm import nil

const
  StoreDirName* = tcroots.StoreDirName
    ## The leaf of every per-user and machine-wide root (§2.1).
  LocalStoreLayout* = tclayout.LayoutVersion
    ## The layout version directory directly under a root (§2.2).
  DefaultStoreRetention* = tcprune.DefaultKeep
    ## The reference policy's number of content directories kept (§2.5).
  StaleTemporaryAge* = tcprune.StaleTemporaryAge
    ## A temporary file older than this belongs to a writer that died. Without
    ## an age, a crashed run would pin its content directory forever.
  FreshDirectoryAge* = tcprune.FreshDirectoryAge
    ## A content directory modified more recently than this is treated as
    ## being written into: a writer creates the directory a moment BEFORE it
    ## opens its temporary file.
  TemporaryMarker* = tclayout.TemporaryMarker
    ## Part of every temporary name, after the leading ``.``.
  RemovalMarker* = tclayout.RemovalMarker
    ## Part of the name a content directory is renamed to while a prune
    ## deletes it: ``.<digest>.removing-<pid>-<n>``.

# ---------------------------------------------------------------------------
# Roots (§2.1)
# ---------------------------------------------------------------------------
#
# Resolution is the reference library's (``test_certificates/roots``): the
# same pure function of (platform, environment, account) every conforming
# helper uses, so reprobuild cannot drift from the variables, fallbacks and
# "a relative or empty value is ignored and reported" rule of §2.1. What stays
# here is reprobuild's naming of the platform and of the result, which the
# rest of the engine and its tests already speak.

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

proc libraryPlatform(platform: StoreRootPlatform): tcroots.RootPlatform =
  case platform
  of srpUnix: tcroots.rpUnix
  of srpMacos: tcroots.rpMacos
  of srpWindows: tcroots.rpWindows

proc resolveCertificateStoreRoots*(platform: StoreRootPlatform;
                                   env: StoreEnvironment;
                                   account: string): CertificateStoreRoots =
  ## Both roots per §2.1. ``account`` is the numeric uid on POSIX systems and
  ## the account SID on Windows; "" leaves the system root unresolved (a guess
  ## could name another user's partition). Every variable read must be a
  ## non-empty ABSOLUTE path in ``platform``'s terms (a drive-relative
  ## ``C:state`` is relative); a relative one is reported and the next
  ## fallback is tried, and a root with no usable value is UNRESOLVED and
  ## reported, never resolved against the current directory.
  let resolved = tcroots.resolveRoots(libraryPlatform(platform), env, account)
  CertificateStoreRoots(user: resolved.user, system: resolved.system,
    problems: resolved.problems)

proc nativeStoreAccount*(): string =
  ## The uid on POSIX; on Windows the SID of this process token's user.
  ## "" when it cannot be read, which leaves the system root unresolved and
  ## the reason recorded rather than guessed.
  let account = tcroots.currentAccount()
  if account.ok: account.account else: ""

proc nativeCertificateStoreRoots*(): CertificateStoreRoots =
  ## Both roots as this process resolves them now. The environment is read on
  ## every call, never frozen at start-up.
  let account = tcroots.currentAccount()
  result = resolveCertificateStoreRoots(storeRootPlatformFor(hostOS),
    proc(name: string): string = getEnv(name), account.account)
  if not account.ok:
    result.problems.add(account.problem)

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

proc storeContentDir*(contentId: string):
    tuple[ok: bool; relative, problem: string] =
  ## ``v1/<algorithm>/<digest>`` for a well-formed content id, including an
  ## unknown algorithm. Joined with ``/`` on every platform.
  let parsed = parseContentId(contentId)
  if parsed.form == cifMalformed:
    return (false, "", "content id '" & contentId & "' cannot name a store " &
      "directory: " & parsed.problem)
  (true, LocalStoreLayout & "/" & parsed.algorithmName & "/" &
    parsed.digest, "")

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

const UserRecordFileMode = 0o600
  ## A record file in the user root (§2.3 step 1): readable and writable by
  ## its owner only, WHATEVER THE UMASK — so the mode is set explicitly with
  ## ``fchmod`` after creation rather than left to ``open``'s mode argument,
  ## which the umask can only narrow (a umask of ``0277`` would otherwise
  ## leave the owner unable to write) and a permissive one would leave as
  ## ``0644`` through ``std/syncio``'s ``0666`` default.

proc writeFlushed(path, content: string) =
  ## Create ``path`` (it must not exist: it is a fresh temporary name),
  ## write ``content``, flush it to disk. On POSIX the file is ``0600``
  ## before a byte of the record is written.
  when defined(windows):
    var f: File
    if not open(f, path, fmWrite):
      raise newException(IOError, "cannot open '" & path & "' for writing: " &
        osErrorMsg(osLastError()))
    try:
      f.write(content)
      f.flushFile()
    finally:
      f.close()
  else:
    let fd = posix.open(path.cstring, O_WRONLY or O_CREAT or O_EXCL or
      O_CLOEXEC or storeNoFollow, Mode(UserRecordFileMode))
    if fd < 0:
      raise newException(IOError, "cannot create '" & path & "': " &
        osErrorMsg(osLastError()))
    var f: File
    if not open(f, fd, fmWrite):
      discard posix.close(fd)
      raise newException(IOError, "cannot open '" & path & "' for writing: " &
        osErrorMsg(osLastError()))
    try:
      if fchmod(fd, Mode(UserRecordFileMode)) != 0:
        raise newException(IOError, "cannot make '" & path & "' owner-only: " &
          osErrorMsg(osLastError()))
      f.write(content)
      f.flushFile()
      if fsync(fd) != 0:
        raise newException(IOError, "fsync of '" & path & "' failed: " &
          osErrorMsg(osLastError()))
    finally:
      f.close()

proc userRootOwnerProblem*(root: string): string =
  ## "" when ``root`` does not exist yet or is owned by this process's
  ## EFFECTIVE account; otherwise why it must not be touched (Transport
  ## §2.3: "An existing user root MUST be owned by the writer's effective
  ## account … refuse and report a root owned by another account, even when
  ## that root is writable by the caller"). The check is the reference
  ## library's — ``fstat`` of the opened directory against ``geteuid`` on
  ## POSIX, the directory's owner SID against the effective token's user on
  ## Windows — so an unreadable owner is a refusal, never permission.
  if not dirExists(root) and not symlinkExists(root) and not fileExists(root):
    return ""
  when defined(windows):
    tcowner.checkUserRootOwner(root)
  else:
    let fd = posix.open(root.cstring, O_RDONLY or storeOpenDirectory or O_CLOEXEC)
    if fd < 0:
      return "could not open the store root '" & root & "' to check its " &
        "owner: " & osErrorMsg(osLastError())
    defer: discard posix.close(fd)
    tcperm.checkOwner(fd, root)

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

# Writers in every implementation share this persistent root lock (Transport
# §2.3). Never unlink it: another process may already hold its inode open.
when defined(windows):
  proc storeCreateFile(path: WideCString; access, share: uint32; security: pointer;
                       disposition, flags: uint32; templateFile: pointer): pointer
    {.stdcall, dynlib: "kernel32", importc: "CreateFileW".}
  proc storeCloseHandle(handle: pointer): int32
    {.stdcall, dynlib: "kernel32", importc: "CloseHandle".}
  proc storeLastError(): uint32
    {.stdcall, dynlib: "kernel32", importc: "GetLastError".}
  type StoreWriteLock = pointer
else:
  proc storeFlock(fd, operation: cint): cint
    {.importc: "flock", header: "<sys/file.h>".}
  type StoreWriteLock = cint

proc acquireStoreWriteLock(root: string): StoreWriteLock =
  let path = root / ".write-lock"
  when defined(windows):
    while true:
      result = storeCreateFile(newWideCString(path), 0xC0000000'u32, 0,
        nil, 4, 0x80, nil)
      if result != cast[pointer](-1): return
      let error = storeLastError()
      if error != 32: raiseOSError(OSErrorCode(error), path)
      sleep(10)
  else:
    result = posix.open(path.cstring, O_RDWR or O_CREAT or storeNoFollow or
      O_CLOEXEC, Mode(0o600))
    if result < 0: raiseOSError(osLastError(), path)
    while storeFlock(result, 2) != 0: # LOCK_EX
      if errno == EINTR: continue
      let error = osLastError()
      discard posix.close(result)
      raiseOSError(error, path)

proc releaseStoreWriteLock(lock: StoreWriteLock) =
  when defined(windows):
    discard storeCloseHandle(lock)
  else:
    discard posix.close(lock)

proc publishStoreRecord*(root, relative, bytes: string; signed: bool;
                         beforeRename: PublishStepHook = nil;
                         signatureMade = false;
                         existingUnsigned: proc(bytes: string): bool {.closure.} = nil): StorePublish =
  ## Steps 1–3 of §2.3 for ``<root>/<relative>`` (``/``-separated, the record
  ## file's store-relative path), with the one retry §2.5 allows when a
  ## concurrent prune took the directory between its creation and the rename.
  ## No root resolution, no guard, no prune: the certificate-aware caller in
  ## ``repro_cli_support`` does those.
  ## ``signatureMade`` is true only for the immediate signer. A relay must
  ## supply ``existingUnsigned`` to validate a same-name record and decide
  ## whether it is an unsigned twin; errors leave the stored bytes untouched.
  result.path = root / toNative(relative)
  let slash = relative.rfind('/')
  if slash <= 0:
    result.error = "'" & relative & "' is not a store record path"
    return
  let contentDir = relative[0 ..< slash]
  let dir = result.path.parentDir
  # Before ANY mutation — creating the root's ``.write-lock`` included — an
  # existing root must be this account's (§2.3). A foreign root is reported
  # and left exactly as it was; it is never adopted or repaired.
  let ownerProblem = userRootOwnerProblem(root)
  if ownerProblem.len > 0:
    result.error = "refusing to write the certificate store: " & ownerProblem
    return
  var writeLock: StoreWriteLock
  try:
    createOwnerOnlyDirs(root, "")
    writeLock = acquireStoreWriteLock(root)
  except CatchableError as err:
    result.error = err.msg
    return
  defer: releaseStoreWriteLock(writeLock)
  for attempt in 0 .. 1:
    var temporaryVanished = false
    var identity = directoryIdentity(dir)
    try:
      createOwnerOnlyDirs(root, contentDir)
      identity = directoryIdentity(dir)
      if symlinkExists(result.path) or dirExists(result.path):
        raise newException(IOError, "existing certificate is not a regular file")
      var keepExisting = false
      if fileExists(result.path):
        if not signatureMade:
          if existingUnsigned == nil:
            raise newException(IOError, "relay cannot inspect existing certificate")
          let unsignedTwin = existingUnsigned(readFile(result.path))
          keepExisting = not signed or not unsignedTwin
        elif not signed:
          keepExisting = true
      if keepExisting:
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

proc pruneStoreRoot*(root: string; keep: int; protected: openArray[string];
                     onStep: PruneStepHook = nil;
                     now = getTime()): PruneOutcome =
  ## Remove whole content directories from one root, keeping the ``keep``
  ## most recently modified (ties broken by name) and every directory in
  ## ``protected`` (``v1/<algorithm>/<digest>``). ``now`` is the clock the
  ## being-written guards compare with. Leftovers of a prune that died after
  ## its rename aside are deleted too. An existing root owned by another
  ## account is refused before anything is renamed or deleted (§2.5).
  ##
  ## The removal itself is the reference library's ``pruneRoot``; this
  ## wrapper only translates reprobuild's directory-shaped protection and
  ## step hook into the library's content-id-shaped ones. Deciding WHAT to
  ## protect — and refusing to prune at all when ``HEAD``'s ids cannot be
  ## computed — is the caller's (``publishCertificateToLocalStore``).
  if root.len == 0:
    return
  var ids: seq[string]
  for dir in protected:
    let parts = dir.split('/')
    if parts.len == 3 and parts[0] == LocalStoreLayout:
      ids.add(parts[1] & ":" & parts[2])
    else:
      # A protection that names no content directory protects nothing; say
      # so rather than prune as if it had been honoured.
      result.errors.add("'" & dir & "' is not a content directory " &
        "(v1/<algorithm>/<digest>); nothing was pruned")
      return
  let hook: tcprune.PruneStepHook =
    if onStep == nil: nil
    else:
      proc(stage: tcprune.PruneStage; relative: string) =
        # Spelled out rather than cast by ordinal: the two enums are
        # declared separately and must not be coupled by their order.
        onStep((case stage
          of tcprune.psChosen: psChosen
          of tcprune.psDetached: psDetached), relative)
  let pruned = tcprune.pruneRoot(root, max(keep, 0), ids, onStep = hook,
    now = now)
  result.removed = pruned.removed
  result.errors = pruned.errors


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

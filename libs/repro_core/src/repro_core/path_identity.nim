## Filesystem path IDENTITY — the one canonicalization the deleting consumers
## ask their containment question under.
##
## ## Why this module exists (W8-R1 / W8-R2)
##
## Every guard standing in front of an irreversible delete in this repository
## used to decide containment with `normalizedPath(absolutePath(x))` and a
## byte-wise `==` / `startsWith`. That is a LEXICAL fold: it rewrites a
## spelling, and it never asks the filesystem anything. Two consequences, both
## measured rather than argued:
##
##   * **W8-R1 — reparse points.** A directory junction or symlink named as an
##     accepted sibling (`path = "../sib"`, with `sib` a junction onto the
##     workspace) folds to `…\parent\sib`, compares disjoint from
##     `…\parent\workspace`, and is cleared for deletion. Measured on
##     `09324b61`: `repro develop --all --reset` reduced a workspace holding
##     `.git`, `PRECIOUS.txt`, `src\` and `repro.lock` to `.repro` alone and
##     EXITED 0. Both reparse tags do it — a junction (`IO_REPARSE_TAG_MOUNT_
##     POINT`) and a directory symlink (`IO_REPARSE_TAG_SYMLINK`).
##   * **W8-R2 — byte-wise compares.** `C:\…\W5CASE\ws` and `C:\…\w5case\ws`
##     are one directory on a case-insensitive volume and two unequal strings,
##     which downgrades "IS the workspace root" to "disjoint".
##
## ## The primitive, and why it is this one and not `expandFilename`
##
## An earlier note named `expandFilename`. It does not resolve a junction.
## Measured on this host, against the very junction above:
##
##   expandFilename(…\sib)  -> …\sib   (UNCHANGED)
##   expandSymlink(…\sib)   -> …\sib   (also unchanged)
##   symlinkExists(…\sib)   -> true    (the reparse point IS detectable)
##
## so it buys exactly what `absolutePath` + `normalizedPath` already buy. The
## primitives that DO answer are:
##
##   * Windows — `CreateFileW` with `FILE_FLAG_BACKUP_SEMANTICS` (which is
##     what makes a DIRECTORY openable at all) and no `FILE_FLAG_OPEN_REPARSE_
##     POINT` (so the open TRAVERSES the reparse point, whatever its tag),
##     then `GetFinalPathNameByHandleW` with `FILE_NAME_NORMALIZED |
##     VOLUME_NAME_DOS`. The result arrives in `\\?\` form and is stripped
##     back to the ordinary spelling. `FILE_NAME_NORMALIZED` is also what
##     answers W8-R2 on this platform: it returns each component in its
##     ON-DISK case, so two spellings of one directory come back as one
##     string. No case rule is guessed and no volume property is queried.
##   * POSIX — `realpath(3)`, which resolves every symlink and returns an
##     absolute path with no `.`/`..` left.
##
## A tag probe (`FSCTL_GET_REPARSE_POINT`) followed by a blanket refusal was
## rejected: it refuses a junction that points somewhere harmless, and a
## harmless junction into a checkout tree is a layout people really use. What
## is dangerous is not that the path is a reparse point, it is WHERE it lands
## — so the answer is to ask where it lands.
##
## ## Refuse-on-resolution-failure, stated per failure mode
##
## The recurring root defect this campaign keeps finding is an ERROR being
## collapsed into an ABSENCE. `resolveCanonicalPath` therefore returns three
## distinguishable outcomes, not two, and "absent" is a value rather than a
## silence:
##
##   * THE PATH DOES NOT EXIST YET — `ERROR_FILE_NOT_FOUND`,
##     `ERROR_PATH_NOT_FOUND`, `ENOENT`, `ENOTDIR`. NOT a failure: resolve the
##     deepest EXISTING ancestor and re-attach the missing tail lexically. A
##     clone target legitimately does not exist before the clone, so refusing
##     it would refuse every create. Sound, because a component that does not
##     exist cannot be a reparse point and every component that DOES exist has
##     been resolved. `missing` records how many segments were re-attached, so
##     a caller that needs a fully-filesystem-answered path can ask.
##   * PERMISSIONS — `ERROR_ACCESS_DENIED`, `EACCES`. REFUSE. Containment
##     cannot be PROVEN, and the thing on the other side of the question is an
##     unbounded recursive delete.
##   * A NETWORK PATH THAT WILL NOT ANSWER — `ERROR_BAD_NETPATH` (53),
##     `ERROR_BAD_NET_NAME` (67), `ERROR_NETWORK_UNREACHABLE`, `ETIMEDOUT`,
##     `EHOSTUNREACH`. REFUSE, for the same reason. A REACHABLE UNC path is
##     unaffected and resolves normally: measured, `\\127.0.0.1\C$` comes
##     back as itself, because `VOLUME_NAME_DOS` answers `\\?\UNC\host\share`
##     and that prefix is stripped. Only an UNREACHABLE one refuses.
##   * A HANDLE THAT WILL NOT OPEN — sharing violation, `EMFILE`, a device
##     that is not a file. REFUSE, same reason.
##   * NO EXISTING ANCESTOR AT ALL — REFUSE. A path whose own volume root
##     cannot be opened is not a path this process can reason about.
##
## "Refuse" is survivable at every one of the five call sites: the worst case
## is a directory left on disk and a diagnostic naming why. The alternative is
## an irreversible delete of something whose location was never established.
##
## ## TOCTOU
##
## Resolution and deletion are separate syscalls, so there is a window between
## `fsContainment` answering and the `removeDir` / `git clean -ffdx` running
## in which the reparse point can be re-pointed. That window is real and is
## NOT closed here. The judgement, stated so it can be disagreed with:
##
##   * The threat model these guards exist for is HOSTILE OR MISTAKEN DATA —
##     a `repro.lock` or a manifest fragment that crosses a trust boundary (a
##     cloned repo's lock, a pushed lock, a generator's output). That
##     adversary supplies BYTES. It does not have concurrent write access to
##     the directory the workspace lives in.
##   * An adversary who DOES have write access to the workspace's parent at
##     the moment `repro` runs can delete the workspace directly, with no
##     help from reprobuild and no race to win. The guard is not what stands
##     between them and the workspace.
##   * So the guard converts "one line in a committed lock file, remote,
##     persistent, silent, and it exits 0" into "win a race that you need
##     local write access to run at all". That is the reduction that matters,
##     and it is the whole of what a check-then-act guard can buy.
##
## THE SIZE OF THAT RACE IS NOT UNIFORM. An earlier draft of this note called
## it "a millisecond" everywhere, which is false at two of the five sites.
## What the code actually does, per site, narrowest first:
##
##   * `removeCloneTargetSafely` (`git_actions.nim`) — check, `dirExists`,
##     `removeDir`. Two syscalls wide, and it is the ONLY site that deletes
##     the RESOLVED path, so re-pointing the original spelling inside its
##     window buys the adversary nothing at all.
##   * `runWorkspaceDisableCommand` (`repro_cli_support.nim`) — check,
##     `dirExists`, `removeDir` on the ORIGINAL SPELLING. Two syscalls wide,
##     and here a re-point IS effective.
##   * `executeForceReset` (`git_actions.nim`) — check, `dirExists`, a whole
##     `git reset --hard` SUBPROCESS, and only then `git clean -ffdx` on the
##     original spelling. One git process wide: milliseconds on a small tree,
##     seconds on a large one.
##   * `developPlacementRejection` (`repro_cli_support.nim`) — check, an
##     override lookup, `dirExists`, a `git rev-parse HEAD` SUBPROCESS, then
##     `removeDir` on the original spelling. Also one git process wide.
##   * `executeRemove` (`repro_cli_support.nim`) — two routes, and they are
##     not comparable. The NAMED route refuses the verb before anything is
##     mutated, so it has NO window. The SWEPT route asks during PLAN
##     CONSTRUCTION and deletes after the preview is printed, after one
##     `git status` subprocess per clean candidate, after the project file is
##     rewritten — and, whenever any GC entry is dirty and `--force` was not
##     passed, after `confirmDestructive`, which blocks on `stdin.readLine()`
##     with NO timeout. That window is OPERATOR-PACED and unbounded. It is
##     the one an adversary would pick, and calling it millisecond-scale
##     would have been a bound the code does not have.
##
## Four of the five delete through the ORIGINAL SPELLING, which is what makes
## a re-point inside their windows effective at all. Deleting the resolved
## path instead would narrow every one of them without changing the question
## any site asks. It is not done here: `executeForceReset` has the resolved
## path in hand and ignores it, but `developPlacementRejection` and
## `resolvedOwnTreeRejection` both compute it and return only a diagnostic
## string, and the switch also changes what survives on disk in the one
## layout these guards PERMIT — a reparse point landing BENEATH the root,
## where the link today survives emptied and would then survive dangling.
## That is a behaviour change with its own consequences for a later
## `repro sync`, so it belongs with the remaining work below rather than
## alongside it.
##
## Closing the window properly means deleting THROUGH the handle the
## containment was proven on — `FILE_DISPOSITION_INFO` on Windows, an
## `openat`-relative recursive unlink on POSIX — which is a rewrite of the
## I/O at all five sites, not a change to the question they ask. Recorded as
## the shape of the remaining work rather than done here.

import std/[os, strutils]
# `extendedPath` ONLY. `repro_core/paths` also exports a `normalizedPath` of
# its own, and importing that module wholesale makes every `normalizedPath`
# call below ambiguous against `std/os`'s.
from paths import extendedPath

type
  PathResolutionStatus* = enum
    ## Deliberately three-valued rather than `ok: bool`. See the failure-mode
    ## table above: "could not resolve" must never be readable as "resolved to
    ## nothing in particular".
    prsResolved   ## the filesystem answered, in full or for a prefix
    prsFailed     ## the filesystem could not be asked — REFUSE

  PathResolution* = object
    status*: PathResolutionStatus
    path*: string     ## canonical existing prefix + any non-existent tail
    existing*: string ## the canonical DEEPEST EXISTING ancestor of `path`
    missing*: int     ## how many trailing segments do not exist (0 = `path`
                      ## itself exists and was resolved by the filesystem)
    reason*: string   ## non-empty exactly when `status == prsFailed`

  FsContainment* = enum
    ## Where a RESOLVED target sits relative to a RESOLVED root.
    fcSameDirectory   ## the target IS the root — the catastrophic verdict
    fcBeneath         ## strictly inside the root
    fcContainsRoot    ## the target is an ANCESTOR of the root
    fcDisjoint        ## outside, and not an ancestor — a sibling
    fcUnresolvable    ## the question could not be answered — REFUSE

  FsContainmentResult* = object
    verdict*: FsContainment
    root*: string     ## canonical root, or the input when unresolvable
    target*: string   ## canonical target, or the input when unresolvable
    reason*: string   ## non-empty exactly when `verdict == fcUnresolvable`

  FsObjectId = object
    ## A filesystem object's identity, as the filesystem states it. Immune to
    ## spelling, to case, and to how many reparse points were traversed on the
    ## way. `(volume serial, file id)` on Windows; `(st_dev, st_ino)` on POSIX.
    volume: uint64
    index: uint64

const identityWalkLimit = 256
  ## A bound on the ancestor walk below. A path deep enough to exceed this is
  ## a path this proc declines to reason about rather than loop over.

# ---------------------------------------------------------------------------
# Platform primitives
# ---------------------------------------------------------------------------

type
  RawResolveKind = enum
    rrkResolved
    rrkAbsent
    rrkFailed

  RawResolve = object
    kind: RawResolveKind
    value: string
    reason: string

when defined(windows):
  import std/winlean

  const
    fileNameNormalized = 0x0'i32
    volumeNameDos = 0x0'i32
    fileReadAttributes = 0x0080'i32
    errorFileNotFound = 2'i32
    errorPathNotFound = 3'i32
    errorInvalidName = 123'i32
    errorBadPathname = 161'i32
    errorDirectoryName = 267'i32

  proc getFinalPathNameByHandleW(hFile: Handle; lpszFilePath: WideCString;
                                 cchFilePath, dwFlags: DWORD): DWORD {.
    stdcall, dynlib: "kernel32", importc: "GetFinalPathNameByHandleW",
    sideEffect.}

  proc openForQuery(path: string): Handle =
    ## `FILE_FLAG_BACKUP_SEMANTICS` is what makes a DIRECTORY openable by
    ## `CreateFileW` at all. `FILE_FLAG_OPEN_REPARSE_POINT` is deliberately
    ## ABSENT: its presence would open the reparse point itself, which is the
    ## behaviour that produced the defect. Its absence is what makes the open
    ## traverse the junction or symlink and land on the real object.
    ##
    ## `FILE_READ_ATTRIBUTES` and the full share mode are the least the two
    ## queries below need — this must not fail because someone else has the
    ## directory open, and must not itself block anyone.
    createFileW(newWideCString(extendedPath(path)), fileReadAttributes.DWORD,
      (FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE).DWORD,
      nil, OPEN_EXISTING.DWORD, FILE_FLAG_BACKUP_SEMANTICS.DWORD, Handle(0))

  proc stripExtendedPrefix(value: string): string =
    ## `GetFinalPathNameByHandleW` answers in the `\\?\` namespace. That form
    ## must not be stored or compared (it is not what any other path in this
    ## process looks like), so it is stripped back here — including the
    ## `\\?\UNC\server\share` spelling, which becomes `\\server\share`.
    if value.startsWith(r"\\?\UNC\"):
      r"\\" & value[8 .. ^1]
    elif value.startsWith(r"\\?\"):
      value[4 .. ^1]
    else:
      value

  proc rawResolve(path: string): RawResolve =
    let handle = openForQuery(path)
    if handle == INVALID_HANDLE_VALUE:
      let code = int32(osLastError())
      if code in [errorFileNotFound, errorPathNotFound, errorInvalidName,
                  errorBadPathname, errorDirectoryName]:
        # ABSENT, not failed. `ERROR_INVALID_NAME` / `ERROR_BAD_PATHNAME` /
        # `ERROR_DIRECTORY_NAME_IS_INVALID` land here because a path whose
        # PARENT is a file (rather than a directory) reports them instead of
        # `ERROR_PATH_NOT_FOUND` — still an absence of the named directory,
        # and the ancestor walk resolves what does exist.
        return RawResolve(kind: rrkAbsent)
      return RawResolve(kind: rrkFailed,
        reason: "cannot open '" & path & "' to resolve it (" &
          osErrorMsg(OSErrorCode(code)).strip() & ", win32 error " & $code &
          ")")
    defer: discard closeHandle(handle)
    var buffer = newWideCString(1024)
    var needed = getFinalPathNameByHandleW(handle, buffer, 1024.DWORD,
      (fileNameNormalized or volumeNameDos).DWORD)
    if needed == 0:
      let code = int32(osLastError())
      return RawResolve(kind: rrkFailed,
        reason: "cannot resolve '" & path & "' to its final path (" &
          osErrorMsg(OSErrorCode(code)).strip() & ", win32 error " & $code &
          ")")
    if needed >= 1024.DWORD:
      # The documented two-call protocol: on overflow the return value is the
      # REQUIRED size INCLUDING the terminator, on success it EXCLUDES it.
      buffer = newWideCString(int(needed) + 1)
      needed = getFinalPathNameByHandleW(handle, buffer, needed + 1.DWORD,
        (fileNameNormalized or volumeNameDos).DWORD)
      if needed == 0:
        let code = int32(osLastError())
        return RawResolve(kind: rrkFailed,
          reason: "cannot resolve '" & path & "' to its final path (" &
            osErrorMsg(OSErrorCode(code)).strip() & ", win32 error " & $code &
            ")")
    RawResolve(kind: rrkResolved, value: stripExtendedPrefix($buffer))

  proc rawIdentity(path: string): tuple[ok: bool; id: FsObjectId;
      reason: string] =
    let handle = openForQuery(path)
    if handle == INVALID_HANDLE_VALUE:
      let code = int32(osLastError())
      return (false, FsObjectId(),
        "cannot open '" & path & "' to read its filesystem identity (" &
          osErrorMsg(OSErrorCode(code)).strip() & ", win32 error " & $code &
          ")")
    defer: discard closeHandle(handle)
    var info: BY_HANDLE_FILE_INFORMATION
    if getFileInformationByHandle(handle, addr info) == 0:
      let code = int32(osLastError())
      return (false, FsObjectId(),
        "cannot read the filesystem identity of '" & path & "' (" &
          osErrorMsg(OSErrorCode(code)).strip() & ", win32 error " & $code &
          ")")
    (true, FsObjectId(volume: uint64(info.dwVolumeSerialNumber),
                      index: (uint64(info.nFileIndexHigh) shl 32) or
                             uint64(info.nFileIndexLow)), "")

else:
  import std/posix

  proc c_free(p: pointer) {.importc: "free", header: "<stdlib.h>".}

  proc rawResolve(path: string): RawResolve =
    let resolved = realpath(path.cstring, nil)
    if resolved == nil:
      let code = errno
      if code == ENOENT or code == ENOTDIR:
        return RawResolve(kind: rrkAbsent)
      return RawResolve(kind: rrkFailed,
        reason: "cannot resolve '" & path & "' (" & $strerror(code) &
          ", errno " & $code & ")")
    result = RawResolve(kind: rrkResolved, value: $resolved)
    c_free(resolved)

  proc rawIdentity(path: string): tuple[ok: bool; id: FsObjectId;
      reason: string] =
    var st: Stat
    if stat(path.cstring, st) != 0:
      let code = errno
      return (false, FsObjectId(),
        "cannot read the filesystem identity of '" & path & "' (" &
          $strerror(code) & ", errno " & $code & ")")
    (true, FsObjectId(volume: uint64(st.st_dev), index: uint64(st.st_ino)), "")

# ---------------------------------------------------------------------------
# The canonicalization
# ---------------------------------------------------------------------------

proc withTrailingSep(path: string): string =
  ## `C:\` and `/` already end in a separator; appending a second one makes a
  ## prefix test that can never match.
  if path.len > 0 and path[^1] == DirSep: path else: path & DirSep

proc ancestorOf(path: string): string =
  ## The parent DIRECTORY of `path`, or "" when there is none.
  ##
  ## Not `parentDir` on its own, and the difference is not cosmetic: on
  ## Windows `parentDir(r"M:\w8probe")` returns `"M:"`, which is a
  ## DRIVE-RELATIVE spelling, not the volume root. Handed to `CreateFileW`
  ## through `extendedPath` it becomes `\\?\M:` — which opens the VOLUME
  ## DEVICE, whereupon `GetFileInformationByHandle` fails with
  ## `ERROR_INVALID_FUNCTION` and a perfectly ordinary sibling comes back
  ## `fcUnresolvable`. Measured exactly that way while building this. The
  ## volume root is `M:\`.
  if path.len == 0 or isRootDir(path):
    return ""
  when defined(windows):
    if path.len > 2 and path[0] == '\\' and path[1] == '\\':
      # `\\server\share` IS the root of a UNC path, and `isRootDir` does not
      # know that. Walking above it reaches `\\server`, which names a host
      # rather than a directory.
      var separators = 0
      for idx in 2 ..< path.len:
        if path[idx] == DirSep: inc separators
      if separators <= 1:
        return ""
  var parent = parentDir(path)
  if parent.len == 0 or parent == path:
    return ""
  when defined(windows):
    if parent.len == 2 and parent[1] == ':':
      parent.add(DirSep)
  if parent == path:
    return ""
  parent

proc failedResolution(path, reason: string): PathResolution =
  PathResolution(status: prsFailed, path: path, existing: "", missing: 0,
                 reason: reason)

proc resolveCanonicalPath*(path: string): PathResolution =
  ## The canonical spelling of `path` as the FILESYSTEM states it: every
  ## reparse point traversed, every component in its on-disk case (Windows),
  ## no `.` or `..` left. See the failure-mode table at the top of this module
  ## for what each way of not answering means.
  ##
  ## A path that does not exist is NOT a failure. The deepest existing
  ## ancestor is resolved and the missing tail re-attached, with `missing`
  ## recording how many segments were re-attached lexically — so a caller that
  ## needs to know whether it is holding a fully-filesystem-answered path can
  ## ask, rather than having to assume.
  if path.strip().len == 0:
    return failedResolution(path, "an empty path cannot be resolved")
  # `normalizedPath(absolutePath(...))` is the SPELLING fold, and it is kept:
  # it is what makes a relative path absolute and what gives the ancestor walk
  # below a well-formed starting point. It is not what answers the question —
  # `rawResolve` is — and everything this proc adds sits on top of it rather
  # than in place of it.
  #
  # It handles a UNC path correctly, which is worth recording because an
  # earlier round of this work believed otherwise on the strength of a probe
  # whose own source had lost a backslash. Measured directly against the
  # stdlib:
  #
  #   normalizedPath(absolutePath(r"\\server\share\x"))  -> \\server\share\x
  #   normalizedPath(absolutePath("//server/share/x"))   -> \\server\share\x
  var candidate =
    try: normalizedPath(absolutePath(path.strip()))
    except CatchableError as err:
      return failedResolution(path,
        "the path '" & path & "' cannot be made absolute: " & err.msg)
  # Nim's `normalizedPath` leaves a trailing separator on `C:\foo\`, which
  # would make the ancestor walk step onto an empty last component.
  while candidate.len > 3 and candidate[^1] == DirSep:
    candidate.setLen(candidate.len - 1)
  var tail: seq[string]
  for _ in 0 ..< identityWalkLimit:
    let raw = rawResolve(candidate)
    case raw.kind
    of rrkFailed:
      return failedResolution(path, raw.reason)
    of rrkResolved:
      var full = raw.value
      while full.len > 3 and full[^1] == DirSep:
        full.setLen(full.len - 1)
      result = PathResolution(status: prsResolved, path: full,
        existing: full, missing: tail.len, reason: "")
      for idx in countdown(tail.high, 0):
        result.path = result.path.withTrailingSep & tail[idx]
      return result
    of rrkAbsent:
      let parent = ancestorOf(candidate)
      if parent.len == 0:
        return failedResolution(path,
          "no existing ancestor of '" & path & "' could be resolved")
      tail.add(lastPathPart(candidate))
      candidate = parent
  failedResolution(path,
    "'" & path & "' is nested deeper than " & $identityWalkLimit &
      " levels; refusing to resolve it")

proc sameFsObject*(a, b: string): tuple[ok: bool; same: bool; reason: string] =
  ## Do two paths name ONE object on disk? This is the question that answers
  ## W8-R2 without guessing a case rule and without querying a volume
  ## property: an object's `(volume, id)` pair is what the filesystem itself
  ## says, so a case-insensitive volume, a mount point, a bind mount and a
  ## hard link all come out equal for the right reason.
  ##
  ## Both paths must EXIST — an identity is a property of an object, and a
  ## path that names nothing has none.
  let ia = rawIdentity(a)
  if not ia.ok: return (false, false, ia.reason)
  let ib = rawIdentity(b)
  if not ib.ok: return (false, false, ib.reason)
  (true, ia.id == ib.id, "")

proc fsContainment*(target, root: string): FsContainmentResult =
  ## Where `target` sits relative to `root`, decided on what the FILESYSTEM
  ## says rather than on the two spellings. This is the one canonicalization
  ## the five deleting consumers share; each maps the verdict to its own
  ## policy and its own diagnostic, because "what to do instead" differs per
  ## site and a shared remedy would be wrong at every one of them.
  ##
  ## Two layers, and the second one exists for a reason worth stating:
  ##
  ##   1. CANONICAL STRINGS. Both sides go through `resolveCanonicalPath`, so
  ##      reparse points are already traversed and (on Windows) case is
  ##      already on-disk-normalized. This layer decides every verdict on
  ##      every filesystem this product has been measured on.
  ##   2. FILESYSTEM IDENTITY, for the two verdicts that are CATASTROPHIC to
  ##      get wrong — "the target IS the root" and "the target CONTAINS the
  ##      root". Two ordinary things defeat layer 1. `realpath(3)` does NOT
  ##      case-fold, so on a case-insensitive Linux directory (ciopfs, a
  ##      `casefold` ext4 dir, a CIFS mount) two spellings survive as two
  ##      strings; and it does not fold a BIND MOUNT either, which is the one
  ##      that can be demonstrated on a stock kernel. Measured, with
  ##      `mount --bind /tmp/w8bind/ws /tmp/w8bind/bind`:
  ##
  ##        resolveCanonicalPath(ws)   -> /tmp/w8bind/ws
  ##        resolveCanonicalPath(bind) -> /tmp/w8bind/bind   (NOT folded)
  ##        sameFsObject(bind, ws)     -> ok, same
  ##        fsContainment(bind, ws)    -> fcSameDirectory    (LAYER 2)
  ##
  ##      Layer 2 asks `(st_dev, st_ino)` / `(volume serial, file id)`, which
  ##      is what the filesystem says and not what a `cmpIgnoreCase` would
  ##      guess. Deliberately NOT run for the `beneath` vs `disjoint`
  ##      distinction: every one of the five consumers permits both, so
  ##      paying for it there would buy nothing. The gap that leaves is real
  ##      and is stated rather than hidden — under the same bind mount,
  ##      `fsContainment(bind/inner, ws)` answers `fcDisjoint` even though
  ##      `bind/inner` IS `ws/inner`. It is harmless only because every
  ##      product caller derives BOTH sides from one root spelling, which is
  ##      also why no end-to-end case in the suite reaches this layer.
  if root.strip().len == 0:
    return FsContainmentResult(verdict: fcUnresolvable, root: root,
      target: target, reason: "there is no root to locate '" & target &
        "' within")
  let rr = resolveCanonicalPath(root)
  if rr.status == prsFailed:
    return FsContainmentResult(verdict: fcUnresolvable, root: root,
      target: target, reason: rr.reason)
  let tr = resolveCanonicalPath(target)
  if tr.status == prsFailed:
    return FsContainmentResult(verdict: fcUnresolvable, root: rr.path,
      target: target, reason: tr.reason)
  result = FsContainmentResult(verdict: fcDisjoint, root: rr.path,
    target: tr.path, reason: "")

  # Layer 1 — canonical strings.
  if tr.path == rr.path:
    result.verdict = fcSameDirectory
    return result
  if tr.path.startsWith(rr.path.withTrailingSep):
    result.verdict = fcBeneath
    return result
  if rr.path.startsWith(tr.path.withTrailingSep):
    result.verdict = fcContainsRoot
    return result

  # Layer 2 — filesystem identity, and only where a wrong answer deletes
  # something. A target with a missing tail has no identity of its own, and a
  # path that does not exist can neither BE an existing root nor CONTAIN one,
  # so there is nothing for this layer to add; likewise when the root itself
  # does not exist, since there is then nothing to protect.
  if tr.missing > 0 or rr.missing > 0:
    return result
  let targetId = rawIdentity(tr.path)
  if not targetId.ok:
    return FsContainmentResult(verdict: fcUnresolvable, root: rr.path,
      target: tr.path, reason: targetId.reason)
  # `root` and every ancestor of it, compared against the target. Walking the
  # ROOT's ancestors rather than the target's is deliberate: it is the bounded
  # side (a workspace root is a handful of levels deep), it is the side this
  # process can certainly stat (it is standing in it), and it is the side that
  # decides the two catastrophic verdicts.
  var cursor = rr.path
  for step in 0 ..< identityWalkLimit:
    let cursorId = rawIdentity(cursor)
    if not cursorId.ok:
      # Fail CLOSED. Reaching here means layer 1 said "disjoint" and layer 2
      # could not confirm it, which is exactly the state in which proceeding
      # would be acting on an unproven containment.
      return FsContainmentResult(verdict: fcUnresolvable, root: rr.path,
        target: tr.path, reason: cursorId.reason)
    if cursorId.id == targetId.id:
      result.verdict = if step == 0: fcSameDirectory else: fcContainsRoot
      return result
    let parent = ancestorOf(cursor)
    if parent.len == 0:
      return result
    cursor = parent
  return FsContainmentResult(verdict: fcUnresolvable, root: rr.path,
    target: tr.path,
    reason: "the ancestor chain of '" & rr.path & "' is deeper than " &
      $identityWalkLimit & " levels; refusing to decide containment")

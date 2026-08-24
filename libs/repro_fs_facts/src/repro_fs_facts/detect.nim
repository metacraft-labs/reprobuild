## Host filesystem identification — Platform-And-Filesystem-Facts **F1**.
##
## Answers "which table entry describes the filesystem holding this
## path?", and reports honestly when the answer is *none*.
##
## **This is a lookup, not a probe, and the distinction is the whole
## initiative.** ``repro_local_store/link_capability`` attempts an
## operation between two specific paths and caches what happened; this
## module reads the filesystem's NAME from the OS and finds the matching
## row. Neither can do the other's job:
##
## * a name cannot answer pair reachability — two directories on one
##   Btrfs filesystem may still refuse ``link()`` — so nothing here may
##   ever be read as a capability verdict;
## * a probe cannot answer anything about a filesystem this host does
##   not have, so it cannot inform a policy decision, a diagnostic, or a
##   design discussion.
##
## ``link_capability.filesystemName`` is documented DIAGNOSTIC ONLY for
## exactly this reason and stays that way. The name becomes usable here
## because what it selects is a table of DECLARED facts that F2's
## conformance suite checks against reality, not a decision.
##
## ``FilesystemObservation`` also carries the capabilities the OS
## *advertises* (Windows volume flags, POSIX ``pathconf`` limits). Those
## are an observation mechanism for the conformance suite, not an
## answer: an advertised capability whose operation then refuses is
## precisely the contradiction F2 exists to catch.

import std/strutils

import ./fact
import ./filesystems

when defined(windows):
  import std/winlean
elif defined(posix):
  import std/posix

type
  FilesystemObservation* = object
    ## What the OS says about the filesystem holding a path.
    queried*: bool
      ## ``false`` when the OS query itself failed (an unreachable path,
      ## a platform with no implementation here). Every other field is
      ## then meaningless, and a caller MUST NOT read a ``tnNo`` out of
      ## a failed query.
    path*: string
      ## The path the query was made for. Kept so a diagnostic can name
      ## it without the caller re-threading it.
    reportedName*: string
      ## The filesystem type exactly as the OS reported it.
    known*: bool
      ## ``true`` when ``reportedName`` matched a table entry. ``false``
      ## is the F4 case and MUST be reported, never silently defaulted.
    id*: FilesystemId
      ## Meaningful only when ``known``.
    volumeKey*: string
      ## A stable identity for the filesystem instance, used to tell one
      ## mounted filesystem from another when enumerating a host. Never
      ## an input to any capability decision.

    # -- Advertised capabilities and limits ---------------------------
    # Populated where the OS offers a query for them; left at
    # ``tnUnknown`` / -1 where it does not.
    advertisedHardLinks*: Ternary
    advertisedSparseFiles*: Ternary
    advertisedBlockRefcounting*: Ternary
      ## Windows ``FILE_SUPPORTS_BLOCK_REFCOUNTING`` — the volume flag
      ## for ReFS block cloning, i.e. the reflink fact, advertised.
    advertisedCasePreservedNames*: Ternary
    reportedMaxComponentLength*: int
      ## ``GetVolumeInformationW``'s ``lpMaximumComponentLength`` /
      ## ``pathconf(_PC_NAME_MAX)``; ``-1`` when unreported.
    reportedMaxPathLength*: int
      ## ``pathconf(_PC_PATH_MAX)``; ``-1`` when unreported (Windows has
      ## no per-volume query for it).
    reportedMaxLinks*: int
      ## ``pathconf(_PC_LINK_MAX)``; ``-1`` when unreported. This is the
      ## OS's own answer to ``maxNamesPerFile`` and is what turns
      ## several ``unknown`` entries in the filesystem table into
      ## something a POSIX host can fill in.

when defined(windows):
  const
    FileCasePreservedNames = 0x00000002'u32
    FileSupportsSparseFiles = 0x00000040'u32
    FileSupportsHardLinks = 0x00400000'u32
    FileSupportsBlockRefcounting = 0x08000000'u32

  proc getVolumePathNameW(lpszFileName: WideCString;
                          lpszVolumePathName: WideCString;
                          cchBufferLength: DWORD): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "GetVolumePathNameW".}

  proc getVolumeInformationW(lpRootPathName: WideCString;
                             lpVolumeNameBuffer: WideCString;
                             nVolumeNameSize: DWORD;
                             lpVolumeSerialNumber: ptr DWORD;
                             lpMaximumComponentLength: ptr DWORD;
                             lpFileSystemFlags: ptr DWORD;
                             lpFileSystemNameBuffer: WideCString;
                             nFileSystemNameSize: DWORD): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "GetVolumeInformationW".}

  proc volumeRootOf(path: string): string =
    var buf: array[512, Utf16Char]
    if getVolumePathNameW(newWideCString(path),
                          cast[WideCString](addr buf[0]),
                          DWORD(buf.len)) == 0:
      return ""
    $cast[WideCString](addr buf[0])

elif defined(macosx):
  type
    StatfsObj {.importc: "struct statfs", header: "<sys/mount.h>",
                bycopy.} = object
      f_fstypename {.importc: "f_fstypename".}: array[16, char]

  proc statfs(path: cstring; buf: var StatfsObj): cint
    {.importc: "statfs", header: "<sys/mount.h>".}

proc ternaryFromFlag(flags: uint32; bit: uint32): Ternary =
  if (flags and bit) != 0: tnYes else: tnNo

when defined(linux):
  proc unescapeMountField(field: string): string =
    ## ``/proc/self/mountinfo`` escapes space, tab, newline and backslash
    ## as ``\040`` ``\011`` ``\012`` ``\134``. A mount point containing a
    ## space is not exotic on a developer machine, and reading it
    ## unescaped would silently select the wrong mount.
    result = newStringOfCap(field.len)
    var i = 0
    while i < field.len:
      if field[i] == '\\' and i + 3 < field.len:
        var value = 0
        var ok = true
        for k in 1 .. 3:
          let ch = field[i + k]
          if ch < '0' or ch > '7':
            ok = false
            break
          value = value * 8 + (ord(ch) - ord('0'))
        if ok:
          result.add(chr(value))
          i += 4
          continue
      result.add(field[i])
      i.inc

  proc mountTypeOf(path: string): tuple[fsType, mountPoint: string] =
    ## The filesystem type of the longest mount point that prefixes
    ## ``path``. Reads ``/proc/self/mountinfo`` rather than
    ## ``/proc/mounts`` because mountinfo distinguishes two mounts of
    ## the same device and carries the type in a fixed position after
    ## the ``-`` separator.
    result = ("", "")
    var raw: string
    try:
      raw = readFile("/proc/self/mountinfo")
    except CatchableError:
      return
    let target = path
    for line in raw.splitLines:
      let fields = line.split(' ')
      if fields.len < 8:
        continue
      var sep = -1
      for i in 6 ..< fields.len:
        if fields[i] == "-":
          sep = i
          break
      if sep < 0 or sep + 1 >= fields.len:
        continue
      let mountPoint = unescapeMountField(fields[4])
      let fsType = unescapeMountField(fields[sep + 1])
      if mountPoint.len == 0:
        continue
      let isPrefix =
        target == mountPoint or
        (mountPoint == "/" and target.startsWith("/")) or
        target.startsWith(mountPoint & "/")
      if not isPrefix:
        continue
      if mountPoint.len >= result.mountPoint.len:
        result = (fsType, mountPoint)

proc observeFilesystem*(path: string): FilesystemObservation =
  ## Ask the OS what filesystem holds ``path``, and match it against the
  ## table.
  ##
  ## Never raises. A failed query yields ``queried = false``, which a
  ## caller MUST treat as "no information" — not as "no capability".
  result = FilesystemObservation(
    queried: false, path: path, known: false, id: fsNtfs,
    advertisedHardLinks: tnUnknown, advertisedSparseFiles: tnUnknown,
    advertisedBlockRefcounting: tnUnknown,
    advertisedCasePreservedNames: tnUnknown,
    reportedMaxComponentLength: -1, reportedMaxPathLength: -1,
    reportedMaxLinks: -1)
  if path.len == 0:
    return

  when defined(windows):
    let root = volumeRootOf(path)
    if root.len == 0:
      return
    var fsName: array[64, Utf16Char]
    var serial, maxComponent, flags: DWORD
    if getVolumeInformationW(newWideCString(root), nil, 0, addr serial,
                             addr maxComponent, addr flags,
                             cast[WideCString](addr fsName[0]),
                             DWORD(fsName.len)) == 0:
      return
    result.queried = true
    result.reportedName = $cast[WideCString](addr fsName[0])
    result.volumeKey = root.toLowerAscii & "#" & $uint32(serial)
    result.reportedMaxComponentLength = int(uint32(maxComponent))
    let f = uint32(flags)
    result.advertisedHardLinks = ternaryFromFlag(f, FileSupportsHardLinks)
    result.advertisedSparseFiles = ternaryFromFlag(f, FileSupportsSparseFiles)
    result.advertisedBlockRefcounting =
      ternaryFromFlag(f, FileSupportsBlockRefcounting)
    result.advertisedCasePreservedNames =
      ternaryFromFlag(f, FileCasePreservedNames)
  elif defined(linux):
    let (fsType, mountPoint) = mountTypeOf(path)
    if fsType.len == 0:
      return
    result.queried = true
    result.reportedName = fsType
    result.volumeKey = mountPoint
  elif defined(macosx):
    var buf: StatfsObj
    if statfs(cstring(path), buf) != 0:
      return
    var name = ""
    for ch in buf.f_fstypename:
      if ch == '\0': break
      name.add(ch)
    if name.len == 0:
      return
    result.queried = true
    result.reportedName = name
    result.volumeKey = name
  else:
    return

  when defined(posix):
    let links = pathconf(cstring(path), PC_LINK_MAX)
    if links > 0:
      result.reportedMaxLinks = int(links)
    let nameMax = pathconf(cstring(path), PC_NAME_MAX)
    if nameMax > 0:
      result.reportedMaxComponentLength = int(nameMax)
    let pathMax = pathconf(cstring(path), PC_PATH_MAX)
    if pathMax > 0:
      result.reportedMaxPathLength = int(pathMax)

  let match = filesystemIdForName(result.reportedName)
  result.known = match.found
  if match.found:
    result.id = match.id

proc describe*(obs: FilesystemObservation): string =
  ## One-line diagnostic. Safe to log; never parsed.
  if not obs.queried:
    return "filesystem=unqueried path=" & obs.path
  var parts = @["path=" & obs.path,
                "reported=" & obs.reportedName,
                "volume=" & obs.volumeKey]
  if obs.known:
    parts.add("table=" & $obs.id)
  else:
    parts.add("table=NO ENTRY")
  if obs.reportedMaxComponentLength >= 0:
    parts.add("nameMax=" & $obs.reportedMaxComponentLength)
  if obs.reportedMaxLinks >= 0:
    parts.add("linkMax=" & $obs.reportedMaxLinks)
  if obs.advertisedHardLinks != tnUnknown:
    parts.add("advertises hardlinks=" & $obs.advertisedHardLinks)
  if obs.advertisedBlockRefcounting != tnUnknown:
    parts.add("advertises blockRefcounting=" &
              $obs.advertisedBlockRefcounting)
  if obs.advertisedSparseFiles != tnUnknown:
    parts.add("advertises sparse=" & $obs.advertisedSparseFiles)
  parts.join(" ")

proc factsForPath*(path: string):
    tuple[known: bool; facts: FilesystemFacts;
          observation: FilesystemObservation] =
  ## The declared facts for the filesystem holding ``path``.
  ##
  ## ``known = false`` means one of two things, and the observation
  ## distinguishes them: the OS query failed (``observation.queried ==
  ## false``), or the filesystem has no table entry. Both are reportable
  ## conditions. A caller MUST NOT read ``facts`` when ``known`` is
  ## false — the value is the zeroth table row and describes nothing.
  let obs = observeFilesystem(path)
  if obs.queried and obs.known:
    (true, FilesystemTable[obs.id], obs)
  else:
    (false, FilesystemTable[fsNtfs], obs)

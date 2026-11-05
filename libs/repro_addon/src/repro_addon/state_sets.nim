## Declared state sets: what a conversion to ReproOS keeps or carries
## (ReproOS Add-On Mode §11.1 step 2).
##
## A ``systemd.systemUnit`` declares the directories that hold its
## service's state with ``stateDirectories = ["keep:<path>",
## "carry:<path>"]`` (``repro_infra/profile``). This module is what the
## declaration is for:
##
## - ``stateSetOf`` collects the set from a profile: each directory once,
##   with its disposition and every unit that names it.
## - ``treeDigest`` is the digest a state directory is verified by: every
##   entry below it (the directory itself included), in byte order of its
##   relative path, with its type, permission bits, numeric owner and
##   group, and its content (a file's SHA-256, a link's target). It never
##   follows a link. Timestamps are not part of it: a restore cannot keep a
##   directory's change time, and no service's correctness rests on them.
##   A device, FIFO or socket refuses: none of them can be carried.
## - ``backupStateSet`` runs on the add-on host before the conversion. It
##   refuses unless every unit of the set is confirmed stopped by its
##   control group (``unitAliveness``, which fails closed), holds each one
##   with a persistent drop-in whose assertion fails (``holdUnits``), so
##   that neither a timer, a socket, a dependency nor an operator's
##   ``start`` runs it again before the conversion, even across a reboot,
##   and
##   writes one archive per carried directory plus a manifest naming each
##   directory's digest, its archive's SHA-256 and its units. A kept
##   directory gets a digest and no archive.
## - ``verifyStateSet`` recomputes every directory's digest against a
##   manifest: on the source just before the conversion destroys it (so a
##   directory that changed after the backup stops the conversion), and on
##   the converted host for the kept ones.
## - ``restoreStateSet`` runs on the converted host before any unit of the
##   set first starts. It refuses while one of them runs; checks each
##   archive's SHA-256 before reading it; extracts into a staging
##   directory beside the target; verifies the staged tree's digest; and
##   only then renames it into place. A target that already holds exactly
##   the manifest's tree is left as it is (a restore that ran already); one
##   that holds anything else refuses. Each restored directory is recorded
##   in a receipt with the root it was restored under and the restored
##   directory's identity; what is still pending, and the apply's refusal,
##   are decided in ``repro_infra/carried_state``. Files are restored
##   sparse: a block of zeros is a hole.
##
## What this does not establish: the manifest's own authenticity (it
## travels with the conversion's payload, whose digest the conversion
## plan binds), and extended attributes or ACLs below a directory, which
## neither the digest nor the archive covers.

import std/[algorithm, json, os, posix, sequtils, sets, strutils, tables, times]

import repro_core/host_apply_lock
import repro_elevation
import repro_elevation/nofollow_write
import repro_infra

import ./host_exec
import ./mutations
import ./seams
import ./switch
import ./transitions

# ---------------------------------------------------------------------------
# Units.
# ---------------------------------------------------------------------------

type AlivenessFn* = proc (unit: string): UnitAliveness {.closure.}

proc defaultAliveness*(): AlivenessFn =
  result = proc (unit: string): UnitAliveness = unitAliveness(unit)

proc requireStopped(units: seq[string]; alive: AlivenessFn; what: string) =
  ## Every unit confirmed stopped by its control group; "unknown" is not
  ## stopped (fail closed).
  when mutated("state-units-not-checked"):
    return
  var running: seq[string]
  for u in units:
    let a = alive(u)
    if a != uaEmpty:
      running.add(u & " (" & $a & ")")
  if running.len > 0:
    raise newException(StateSetError, what & ": " & running.join(", ") &
      " not confirmed stopped; stop " &
      (if running.len == 1: "it" else: "them") & " first")

proc holdPath(unit: string): string =
  ## Where the hold of ``unit`` is written (``carried_state``'s path).
  when mutated("hold-runtime-only"):
    # FALSIFYING MUTATION: the hold in /run, gone at the next boot.
    "/run/systemd/system" / (unit & ".d") / HoldDropInName
  else:
    holdDropInPath(unit)

proc holdsNotLoaded*(units: seq[string]): seq[string] =
  ## The units whose hold systemd does not have loaded (removed, e.g. by
  ## ``systemctl revert``, or never written).
  for u in units:
    let s = runSystemctl(["show", "-p", "DropInPaths", "--value", "--", u])
    if s.exitCode != 0 or holdPath(u) notin s.output.splitWhitespace():
      result.add(u)

const
  HoldDropInText* = "# Written by `repro system addon state backup`: the\n" &
    "# unit's state is backed up for a conversion; it must not run again\n" &
    "# before it (spec §11.1). `repro system addon state release\n" &
    "# --profile <file>` lifts it.\n" &
    "[Unit]\nAssertPathExists=/run/repro/state-hold/never\n"
    ## A drop-in whose assertion always fails: every start of the unit --
    ## by an operator, a timer, a socket or a dependency -- fails before
    ## anything is executed
    ## (https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html#AssertArchitecture=).
    ## Not a runtime mask: a mask in ``/run/systemd/system`` does not hide
    ## a unit whose file is in ``/etc/systemd/system``, which takes
    ## precedence (measured on Debian 13: the masked unit still started).
    ## In ``/etc``, not ``/run``, so the hold survives a reboot of the
    ## source host before the conversion. While any hold exists every
    ## apply refuses (``carried_state.carriedStateRefusal``), so neither
    ## an operator nor the deploy agent changes the host under a backup.
    ## Residual: ``systemctl revert <unit>`` deletes drop-ins, the hold
    ## with them; ``repro system addon state verify --from`` checks every
    ## hold is still loaded (spec §11.1).

proc holdUnits*(units: seq[string]) =
  ## Hold each unit (``HoldDropInText``) and check, after the reload, that
  ## systemd loaded every hold (fail closed). Released by ``releaseUnits``.
  when mutated("state-units-not-held"):
    return
  for u in units:
    let err = systemdUnitNameError("held unit", u)
    if err.len > 0:
      raise newException(StateSetError, err)
    try:
      createDirsNoFollow(parentDir(holdPath(u)))
      writeFileNoFollow(holdPath(u), HoldDropInText, 0o644)
    except CatchableError as e:
      raise newException(StateSetError, "cannot hold " & u & ": " & e.msg)
  let r = runSystemctl(["daemon-reload"])
  if r.exitCode != 0:
    raise newException(StateSetError, "systemctl daemon-reload failed: " &
      r.output.strip())
  let missing = holdsNotLoaded(units)
  if missing.len > 0:
    raise newException(StateSetError, "the hold is not loaded for " &
      missing.join(", "))

proc releaseUnits*(units: seq[string]) =
  ## Lift the hold of ``holdUnits`` (an abandoned conversion).
  for u in units:
    let p = holdPath(u)
    if fileExists(p) or symlinkExists(p):
      try:
        discard removeLeafNoFollow(p)
        discard removeEmptyDirNoFollow(parentDir(p))
      except CatchableError as e:
        raise newException(StateSetError, "cannot release " & u & ": " & e.msg)
  let r = runSystemctl(["daemon-reload"])
  if r.exitCode != 0:
    raise newException(StateSetError, "systemctl daemon-reload failed: " &
      r.output.strip())

proc allUnits(entries: openArray[StateSetEntry]): seq[string] =
  for e in entries:
    for u in e.units:
      if u notin result: result.add(u)
  result.sort()

# ---------------------------------------------------------------------------
# Owners.
# ---------------------------------------------------------------------------

proc treeOwners(dir: string): (seq[int], seq[int]) =
  var uids, gids: seq[int]
  proc note(full: string) =
    var st: Stat
    if lstat(full.cstring, st) == 0:
      if int(st.st_uid) notin uids: uids.add(int(st.st_uid))
      if int(st.st_gid) notin gids: gids.add(int(st.st_gid))
  note(dir)
  for p in walkDirRec(dir, yieldFilter = {pcFile, pcDir, pcLinkToFile,
                                          pcLinkToDir}):
    note(p)
  uids.sort()
  gids.sort()
  (uids, gids)

proc ownersOf*(dir, root: string): seq[(string, string)] =
  ## The names the source host gives the tree's numeric owners; an id with
  ## no account is recorded as ``#<n>`` (nothing to check it against).
  let pw = accountTable(root, "passwd")
  let gr = accountTable(root, "group")
  let (uids, gids) = treeOwners(dir)
  for u in uids:
    result.add(("uid:" & $u, pw.getOrDefault("id:" & $u, "#" & $u)))
  for g in gids:
    result.add(("gid:" & $g, gr.getOrDefault("id:" & $g, "#" & $g)))

proc ownerConflicts*(e: ManifestEntry; root: string): seq[string] =
  ## Where the target host's accounts disagree with the ids the carried
  ## tree holds: an account of the recorded name with another id, or the
  ## recorded id held by another name. An account the host does not have
  ## yet is no conflict (it is created later, with the declared id).
  let pw = accountTable(root, "passwd")
  let gr = accountTable(root, "group")
  for (k, name) in e.owners:
    if name.startsWith("#"): continue
    let isUid = k.startsWith("uid:")
    let id = k[4 .. ^1]
    let t = if isUid: pw else: gr
    let what = if isUid: "user " else: "group "
    let haveId = t.getOrDefault("name:" & name)
    if haveId.len > 0 and haveId != id:
      result.add(what & name & " is " & haveId & " here but owns the " &
        "carried tree as " & id)
    let haveName = t.getOrDefault("id:" & id)
    if haveName.len > 0 and haveName != name:
      result.add(what & "id " & id & " is " & haveName & " here but " &
        name & " on the source host")

# ---------------------------------------------------------------------------
# Backup, verify, restore.
# ---------------------------------------------------------------------------

# The archive. Not tar: a carried directory's owners, groups and modes
# must come back exactly, the reader must be small enough to be checked
# line by line (it runs as root on a host that is being brought up), and
# neither side may depend on a tool the converted host might not ship.
# The format is the digest's walk, written out:
#
#   REPRO-STATE-ARCHIVE 1\n
#   then per entry, in ``treeLines`` order ("." first):
#   <d|f|l> <mode, 4 octal> <uid> <gid> <path bytes> <data bytes>\n
#   <path><data>
#
# where data is a file's content or a link's target (nothing for a
# directory). The reader refuses any path that is absolute, has an empty,
# "." or ".." segment, or whose parent is not a directory this archive
# created earlier, so nothing it writes can land outside the staging
# directory or through a link.

const ArchiveMagic = "REPRO-STATE-ARCHIVE 1\n"

var oNoFollow {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint

proc archiveNameFor(path: string): string =
  ## A stable, flat file name for a directory's archive.
  "carry-" & sha256Text(path)[0 ..< 16] & ".rsa"

proc archiveEntry(f: File; full, rel: string) =
  var st: Stat
  if lstat(full.cstring, st) != 0:
    raise newException(StateSetError, "cannot stat " & full & ": " &
      $strerror(errno))
  let head = toOct(int(st.st_mode) and 0o7777, 4) & " " & $st.st_uid & " " &
    $st.st_gid & " " & $rel.len
  if S_ISDIR(st.st_mode):
    f.write("d " & head & " 0\n" & rel)
  elif S_ISLNK(st.st_mode):
    let target = expandSymlink(full)
    f.write("l " & head & " " & $target.len & "\n" & rel & target)
  elif S_ISREG(st.st_mode):
    f.write("f " & head & " " & $st.st_size & "\n" & rel)
    var src: File
    if not open(src, full, fmRead):
      raise newException(StateSetError, "cannot open " & full)
    try:
      var buf = newString(65536)
      var left = int64(st.st_size)
      while left > 0:
        let n = src.readBuffer(addr buf[0], int(min(int64(buf.len), left)))
        if n <= 0:
          raise newException(StateSetError, full & " shrank while archived")
        discard f.writeBuffer(addr buf[0], n)
        left -= n
    finally:
      src.close()
  else:
    raise newException(StateSetError, full & " is a device, FIFO or " &
      "socket, which a state directory cannot carry")

proc archiveWalk(f: File; dir, rel: string) =
  var names: seq[string]
  for kind, path in walkDir(dir, relative = true, checkDir = true):
    names.add(path)
  names.sort(system.cmp)
  for n in names:
    let full = dir / n
    let r = (if rel.len == 0: n else: rel & "/" & n)
    archiveEntry(f, full, r)
    var st: Stat
    if lstat(full.cstring, st) == 0 and S_ISDIR(st.st_mode):
      archiveWalk(f, full, r)

proc writeStateArchive*(dir, dest: string) =
  ## Archive ``dir`` into ``dest`` (created 0600, must not exist).
  let fd = posix.open(dest.cstring, O_WRONLY or O_CREAT or O_EXCL or
                      oNoFollow or O_CLOEXEC, 0o600)
  if fd < 0:
    raise newException(StateSetError, "cannot create " & dest & ": " &
      $strerror(errno))
  var f: File
  if not open(f, fd, fmWrite):
    discard posix.close(fd)
    raise newException(StateSetError, "cannot open " & dest)
  try:
    f.write(ArchiveMagic)
    archiveEntry(f, dir, ".")
    archiveWalk(f, dir, "")
    f.flushFile()
    if fsync(fd) != 0:
      raise newException(StateSetError, "fsync " & dest & ": " &
        $strerror(errno))
  finally:
    f.close()

proc safeRelPath(rel: string): bool =
  if rel == ".": return true
  if rel.len == 0 or rel[0] == '/': return false
  for seg in rel.split('/'):
    if seg.len == 0 or seg == "." or seg == "..": return false
  for c in rel:
    if c == '\0': return false
  true

proc readExact(f: File; n: int64; what: string): string =
  if n < 0 or n > 1 shl 20:
    raise newException(StateSetError, "archive: " & what & " is too long")
  result = newString(int(n))
  if n > 0 and f.readBuffer(addr result[0], int(n)) != int(n):
    raise newException(StateSetError, "archive: truncated at " & what)

proc extractStateArchive*(archive, staging: string) =
  ## Extract into ``staging``, an empty directory this process created.
  ## Owners and modes are applied as recorded; a directory's own mode is
  ## applied last, so a read-only directory can still be filled.
  var f: File
  if not open(f, archive, fmRead):
    raise newException(StateSetError, "cannot open " & archive)
  defer: f.close()
  if readExact(f, ArchiveMagic.len, "the header") != ArchiveMagic:
    raise newException(StateSetError, "archive: not a state archive")
  var dirs: seq[(string, int, int, int)]     # created dirs, applied last
  var created = initHashSet[string]()
  var first = true
  var line = ""
  while f.readLine(line):
    let h = line.split(' ')
    if h.len != 6 or h[0] notin ["d", "f", "l"]:
      raise newException(StateSetError, "archive: malformed entry header")
    var mode, uid, gid: int
    var plen, dlen: int64
    try:
      mode = parseOctInt(h[1])
      uid = parseInt(h[2])
      gid = parseInt(h[3])
      plen = parseBiggestInt(h[4])
      dlen = parseBiggestInt(h[5])
    except ValueError:
      raise newException(StateSetError, "archive: malformed entry header")
    if mode notin 0 .. 0o7777 or uid < 0 or gid < 0 or dlen < 0:
      raise newException(StateSetError, "archive: malformed entry header")
    let rel = readExact(f, plen, "a path")
    if not safeRelPath(rel):
      raise newException(StateSetError, "archive: unsafe path " &
        escapeField(rel))
    if first != (rel == "."):
      raise newException(StateSetError,
        "archive: the first entry, and only it, is the directory itself")
    if not first:
      let parent = (let i = rel.rfind('/'); if i < 0: "." else: rel[0 ..< i])
      if parent notin created:
        raise newException(StateSetError, "archive: " & escapeField(rel) &
          " is not below a directory the archive created")
      if rel in created:
        raise newException(StateSetError, "archive: " & escapeField(rel) &
          " twice")
    let full = if rel == ".": staging else: staging / rel
    case h[0]
    of "d":
      if dlen != 0:
        raise newException(StateSetError, "archive: a directory with data")
      if rel != "." and mkdir(full.cstring, 0o700) != 0:
        raise newException(StateSetError, "mkdir " & full & ": " &
          $strerror(errno))
      created.incl(rel)
      dirs.add((full, mode, uid, gid))
    of "l":
      if first:
        raise newException(StateSetError, "archive: the root is a link")
      let target = readExact(f, dlen, "a link target")
      if symlink(target.cstring, full.cstring) != 0:
        raise newException(StateSetError, "symlink " & full & ": " &
          $strerror(errno))
      if lchown(full.cstring, Uid(uid), Gid(gid)) != 0 and getuid() == 0:
        raise newException(StateSetError, "lchown " & full & ": " &
          $strerror(errno))
    else:
      if first:
        raise newException(StateSetError, "archive: the root is a file")
      let fd = posix.open(full.cstring, O_WRONLY or O_CREAT or O_EXCL or
                          oNoFollow or O_CLOEXEC, 0o600)
      if fd < 0:
        raise newException(StateSetError, "create " & full & ": " &
          $strerror(errno))
      try:
        var buf = newString(65536)
        var left = dlen
        while left > 0:
          let n = f.readBuffer(addr buf[0], int(min(int64(buf.len), left)))
          if n <= 0:
            raise newException(StateSetError, "archive: truncated content")
          # A block of zeros becomes a hole (the file is restored sparse);
          # the size is fixed by the truncate below.
          var zero = true
          when not mutated("restore-writes-dense"):
            for i in 0 ..< n:
              if buf[i] != '\0':
                zero = false
                break
          else:
            zero = false
          if zero:
            if lseek(fd, Off(n), SEEK_CUR) < 0:
              raise newException(StateSetError, "seek " & full & ": " &
                $strerror(errno))
          elif posix.write(fd, addr buf[0], n) != n:
            raise newException(StateSetError, "write " & full & ": " &
              $strerror(errno))
          left -= n
        if ftruncate(fd, Off(dlen)) != 0:
          raise newException(StateSetError, "truncate " & full & ": " &
            $strerror(errno))
        # Owner first: chown clears set-id bits, so the mode follows it.
        if fchown(fd, Uid(uid), Gid(gid)) != 0 and getuid() == 0:
          raise newException(StateSetError, "fchown " & full & ": " &
            $strerror(errno))
        if fchmod(fd, Mode(mode)) != 0:
          raise newException(StateSetError, "fchmod " & full & ": " &
            $strerror(errno))
        if fsync(fd) != 0:
          raise newException(StateSetError, "fsync " & full & ": " &
            $strerror(errno))
      finally:
        discard posix.close(fd)
    first = false
  if first:
    raise newException(StateSetError, "archive: empty")
  # Deepest first, so a parent's restrictive mode is applied after its
  # children were written.
  for i in countdown(dirs.high, 0):
    let (full, mode, uid, gid) = dirs[i]
    if chown(full.cstring, Uid(uid), Gid(gid)) != 0 and getuid() == 0:
      raise newException(StateSetError, "chown " & full & ": " &
        $strerror(errno))
    if chmod(full.cstring, Mode(mode)) != 0:
      raise newException(StateSetError, "chmod " & full & ": " &
        $strerror(errno))

proc backupStateSet*(p: SystemProfile; outDir, host: string;
                     alive: AlivenessFn = defaultAliveness();
                     hold = true; root = "/"): StateManifest =
  ## Back up the profile's state set into ``outDir`` (created; must be
  ## empty or absent) and return the manifest written there. Refuses,
  ## writing nothing, when the set is empty, a directory is missing, or a
  ## unit of the set is not confirmed stopped.
  let set = stateSetOf(p)
  if set.len == 0:
    raise newException(StateSetError,
      "the profile declares no stateDirectories")
  # No apply may start a unit of the set while it is backed up: the backup
  # holds the host's apply lock (the one every apply takes,
  # ``repro_core/host_apply_lock``) from its first check to its manifest.
  var hostLock: HostApplyLock
  when not mutated("backup-without-host-lock"):
    try:
      hostLock = acquireHostApplyLock("state backup")
    except CatchableError as e:
      raise newException(StateSetError, "state backup: " & e.msg)
  defer: hostLock.release()
  requireStopped(allUnits(set), alive, "state backup")
  for e in set:
    if not dirExists(under(root, e.path)) or symlinkExists(under(root, e.path)):
      raise newException(StateSetError, e.path & " is not a directory " &
        "on this host")
  if dirExists(outDir):
    for _ in walkDir(outDir):
      raise newException(StateSetError, outDir & " is not empty")
  createDir(outDir)
  setFilePermissions(outDir, {fpUserRead, fpUserWrite, fpUserExec})
  # The hold comes before the archives: from here until the conversion
  # nothing may change what is being copied.
  if hold:
    holdUnits(allUnits(set))
  # Checked again with the hold in place: a unit started between the first
  # check and the hold (by something that is not an apply: an operator, a
  # timer, socket activation) is caught here, and the hold just written is
  # taken back so the refusal leaves the host as it found it.
  when not mutated("backup-without-host-lock"):
    try:
      requireStopped(allUnits(set), alive, "state backup (after the hold)")
    except StateSetError:
      if hold: releaseUnits(allUnits(set))
      removeDir(outDir)
      raise
  result.host = host
  result.createdAt = now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  for e in set:
    var m = ManifestEntry(path: e.path, disposition: e.disposition,
                          units: e.units,
                          digest: treeDigest(under(root, e.path)),
                          owners: ownersOf(under(root, e.path), root))
    if e.disposition == sdCarry:
      m.archive = archiveNameFor(e.path)
      let dest = outDir / m.archive
      writeStateArchive(under(root, e.path), dest)
      m.archiveSha256 = sha256File(dest)
      # The digest is taken again after the archive: a directory that
      # changed while it was read (a unit the hold did not cover, an
      # operator) is not a consistent backup.
      if treeDigest(under(root, e.path)) != m.digest:
        raise newException(StateSetError, e.path & " changed while it " &
          "was archived")
    result.entries.add(m)
  writeFile(outDir / ManifestFileName, $toJson(result) & "\n")

type VerifyResult* = object
  matched*: seq[string]
  differing*: seq[string]       ## "<path>: <why>"

proc verifyEntries*(m: StateManifest; root = "/";
                    only: set[StateDisposition] = {sdKeep, sdCarry}):
                    VerifyResult =
  ## Recompute each directory's digest under ``root`` against the manifest.
  for e in m.entries:
    if e.disposition notin only: continue
    let path = under(root, e.path)
    if not dirExists(path) or symlinkExists(path):
      result.differing.add(e.path & ": missing")
      continue
    let d = try: treeDigest(path)
            except StateSetError as x: "error: " & x.msg
    if d == e.digest: result.matched.add(e.path)
    else: result.differing.add(e.path & ": " & d & " (manifest " & e.digest & ")")

const RestoreSeamStateDir = "/var/lib/repro/system"
  ## Whose ``addon/`` holds the restore's seam control files (the add-on's
  ## state directory; a seam build only).

proc rootOf(root: string): string =
  if root.len == 0: "/" else: root

proc isEmptyDir(path: string): bool =
  for _ in walkDir(path): return false
  true

proc restoreStateSet*(dir: string; alive: AlivenessFn = defaultAliveness();
                      root = "/"): seq[string] =
  ## Restore every carried directory of the manifest in ``dir`` and return
  ## the paths restored now. Refuses while a unit of the set runs; checks
  ## each archive before reading it and each staged tree before it is
  ## renamed into place. Idempotent: a directory already holding the
  ## manifest's tree is recorded and left alone.
  let m = readStateManifest(dir)
  var units: seq[string]
  for e in m.entries:
    for u in e.units:
      if u notin units: units.add(u)
  requireStopped(units, alive, "state restore")
  var receipt = readReceipt(dir)
  for e in m.entries:
    if e.disposition != sdCarry: continue
    let archive = dir / e.archive
    let target = under(root, e.path)
    # Restored here before, into the very directory still in place: its
    # service has used it since, so its tree is no longer the manifest's,
    # and that is not a reason to refuse (the restore runs at every boot).
    if e.path in receipt:
      let rc = receipt[e.path]
      if rc.digest == e.digest and rootOf(rc.root) == rootOf(root) and
          sameDirectory(rc.id, dirIdentity(target)):
        continue
    if dirExists(target) and not symlinkExists(target) and
        not isEmptyDir(target):
      if treeDigest(target) == e.digest:
        receipt[e.path] = ReceiptEntry(digest: e.digest, root: rootOf(root),
                                       id: dirIdentity(target))
        continue
      raise newException(StateSetError, e.path & " already holds " &
        "something other than the carried state; refusing to replace it")
    if symlinkExists(target) or fileExists(target):
      raise newException(StateSetError, e.path & " exists and is not a " &
        "directory")
    let conflicts = ownerConflicts(e, root)
    if conflicts.len > 0:
      raise newException(StateSetError, "the carried tree of " & e.path &
        " would be owned by the wrong accounts: " & conflicts.join("; ") &
        " (declare the accounts with the source host's ids)")
    # Test seam (seam builds only, ``seams.nim``): the conversion gate holds
    # a restore here, before it reads an archive, to observe what systemd
    # does with the carried units while the restore is provably running.
    seamPause(under(root, RestoreSeamStateDir), "restore-before-archive")
    when not mutated("state-archive-unchecked"):
      if not fileExists(archive) or sha256File(archive) != e.archiveSha256:
        raise newException(StateSetError, "the archive of " & e.path &
          " does not match the manifest")
    let parent = parentDir(target)
    createDir(parent)
    # A restore that died left its staging directory behind (it is never
    # renamed into place unverified); any such leftover of this target is
    # removed before a new one is made.
    let stagingPrefix = ".repro-restore-" & extractFilename(target) & "-"
    when not mutated("restore-leaves-staging"):
      for kind, q in walkDir(parent, relative = true):
        if q.startsWith(stagingPrefix) and kind == pcDir:
          removeDir(parent / q)
    let staging = parent / (stagingPrefix & $getCurrentProcessId())
    if dirExists(staging): removeDir(staging)
    createDir(staging)
    try:
      extractStateArchive(archive, staging)
      let got = treeDigest(staging)
      when not mutated("state-restore-unverified"):
        if got != e.digest:
          raise newException(StateSetError, "the restored tree of " &
            e.path & " has digest " & got & ", not the manifest's " &
            e.digest)
      if dirExists(target): removeDir(target)   # an empty placeholder
      moveFile(staging, target)
    except CatchableError:
      if dirExists(staging): removeDir(staging)
      raise
    receipt[e.path] = ReceiptEntry(digest: e.digest, root: rootOf(root),
                                   id: dirIdentity(target))
    result.add(e.path)
  # Test seams (seam builds only): the hard-reset gate resets the host
  # inside the receipt's replacement (``receipt-before-rename``,
  # ``receipt-before-dir-fsync``) and requires a whole receipt after it.
  let seamDir = under(root, RestoreSeamStateDir)
  writeReceipt(dir, receipt, proc (point: string) = seamPause(seamDir, point))


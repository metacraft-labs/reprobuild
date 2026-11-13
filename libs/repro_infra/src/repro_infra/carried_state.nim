## Carried state on a converted host, and the one check every apply makes
## (ReproOS Add-On Mode §11.1, "The apply waits for it").
##
## A conversion to ReproOS carries a service's declared state directories
## (``stateDirectories = ["carry:<path>"]``) over in a manifest and one
## archive per directory, left under ``CarriedStateDir`` on the new host
## and restored there by a first-boot unit (``repro_addon/state_sets``).
## Until each carried directory is restored *on this host*, no apply may
## start anything that could use it: a validator started on an empty
## directory signs with no slashing-protection history.
##
## The check lives here, in the library every apply path reaches --
## ``runInfraApply`` (``repro infra apply``, ``repro system sync``,
## ``repro system rollback``, the engine's deploy agent) and the add-on's
## ``runAddonApply`` (operator applies, adopt, add-on rollback, the
## add-on agent) -- not in a command-line wrapper, so no entry point can
## bypass it.
##
## What it decides (``carriedStateRefusal``), failing closed throughout:
##
## - **pending** (``pendingCarriedState``): a carried directory is restored
##   only when the live directory under the host's root holds exactly the
##   manifest's tree (its digest), or when the restore receipt records a
##   restore *at this root* into the very directory now in place. "The very
##   directory" is its device and inode *and* something a new directory
##   cannot inherit: its creation time (``statx`` ``STATX_BTIME``) and, where
##   the file system keeps one, its inode generation (``FS_IOC_GETVERSION``).
##   A file system may hand a replaced directory the inode it just freed
##   (ext4 does), so device and inode alone do not identify it. When neither
##   discriminator is available on both sides the receipt is not trusted and
##   the live digest decides. A receipt written for another root
##   (``restore --root``) or for a directory since replaced does not count;
## - **reach** (``unitReach``): which carried directories a profile's units
##   can touch, decided from what systemd would give each unit -- its
##   declared state set, ``StateDirectory=``/``CacheDirectory=``/
##   ``LogsDirectory=``, ``ReadWritePaths=``, ``WorkingDirectory=``,
##   ``BindPaths=``/``BindReadOnlyPaths=`` sources and ``RootDirectory=``;
##   a unit that is not confined to those paths (no
##   ``ProtectSystem=strict``, no ``DynamicUser=yes``), a command run
##   outside the sandbox (an ``Exec*=`` prefix with ``+`` or ``!``,
##   ``PermissionsStartOnly=yes``), a path with a specifier, a unit type
##   that is not a service, timer, target, path or slice, a unit installed
##   as a drop-in over a distribution unit (``collision = "dropIn"``, or a
##   ``systemd.systemDropIn``), a unit that activates one the profile does
##   not define (``Wants=``, ``Requires=``, ``Requisite=``, ``BindsTo=``,
##   ``Upholds=``, ``PartOf=``, ``OnFailure=``, ``OnSuccess=``, a timer's
##   or a path unit's ``Unit=`` or its same-name service), and a
##   distribution unit the profile starts all reach everything: what cannot
##   be shown to stay away from a carried directory counts as reaching it.
##   The unit's name plays no part: a renamed unit that keeps the directory
##   is still held;
## - **owners**: a carried tree keeps its numeric owners (the digest covers
##   them), so every account it names must have the source host's id here:
##   the live account of that name, else the id the profile pins for it
##   (``linux.sysusersEntry`` ``id``, ``passwd.group`` ``gid``). An account
##   with another id, or one the profile creates without a pinned id (its
##   id would be chosen at creation), refuses;
## - **holds**: while a unit of a backed-up state set is held on this host
##   (``HoldDropInName``), nothing is applied.

import std/[algorithm, json, os, posix, sets, strutils, tables]

import nimcrypto/[hash, sha2]

import ./errors
import ./profile
import ./service_account
import ./service_floor
import ./systemd_values
import ./systemd_syntax
import ./privileged_daemons

const CarriedMutation {.strdefine: "reproAddonMutation".} = ""
  ## A falsifying build (``repro_addon/mutations``); never a product build.

type
  StateSetError* = object of CatchableError
    ## A state-set operation refused, or failed, before it changed the
    ## state it was asked to move.

  ECarriedStatePending* = object of EInfra
    ## An apply refused because carried state is not restored here, an
    ## owner would not match, or a backup holds the host.

  StateSetEntry* = object
    path*: string
    disposition*: StateDisposition
    units*: seq[string]          ## every unit naming the directory, sorted

  ManifestEntry* = object
    path*: string
    disposition*: StateDisposition
    units*: seq[string]
    digest*: string              ## ``treeDigest`` at backup time
    archive*: string             ## carry: the archive's file name, else ""
    archiveSha256*: string
    owners*: seq[(string, string)]
      ## ``("uid:<n>", name)`` and ``("gid:<n>", name)`` for every numeric
      ## owner and group in the tree, as the source host names them
      ## (``#<n>`` for an id with no account there).

  StateManifest* = object
    host*: string
    createdAt*: string
    entries*: seq[ManifestEntry]

  DirIdentity* = object
    ## What identifies a directory across a replacement in place. ``dev``
    ## and ``ino`` alone do not: a directory removed and made again can get
    ## the same inode. ``btime`` (creation time, ``statx`` ``STATX_BTIME``)
    ## and ``gen`` (the inode generation, ``FS_IOC_GETVERSION``) are new for
    ## every new inode, where the file system provides them.
    dev*, ino*: int64            ## -1 when the path is not a directory
    haveBtime*: bool
    btimeSec*, btimeNsec*: int64
    haveGen*: bool
    gen*: int64

  ReceiptEntry* = object
    digest*: string
    root*: string                ## the root the restore wrote under
    id*: DirIdentity             ## the restored directory's identity

const
  ManifestSchema* = "repro-state-set/1"
  ManifestFileName* = "state-set.json"
  CarriedStateDir* = "/var/lib/repro/system/carried"
    ## Where a conversion leaves the backup on the converted host (the
    ## manifest and the archives), for the restore.
  RestoredReceipt* = "restored.json"
  HoldDropInName* = "90-repro-state-hold.conf"
    ## The drop-in that holds a unit of a backed-up state set, in
    ## ``/etc/systemd/system/<unit>.d/`` (persistent across reboots).
  HoldUnitDir* = "/etc/systemd/system"
  CarriedRestoreUnit* = "repro-state-restore.service"
    ## The first-boot unit that restores carried state (``repro_addon/
    ## adoption_cli.installRestoreUnit`` installs it).
  RestoreRequiredDropIn* = "80-repro-state-restore.conf"
    ## The drop-in ``install-unit`` writes for each unit its manifest names.
  RequirementDropInName* = "state-restore"
    ## The generation's drop-in (``50-repro-<name>.conf``) that makes a
    ## unit reaching carried state require the restore
    ## (``withCarriedRequirements``).

proc restoreRequirementText*(): string =
  ## The ``[Unit]`` drop-in that makes a unit require the restore and start
  ## after it. Owned by the unit, not by the restore unit's ``[Install]``: a
  ## ``systemctl disable`` or ``preset`` of the restore unit removes links,
  ## and this drop-in is not a link, so the requirement stays and pulls the
  ## restore in at boot (systemd.unit(5)). ``Requires=`` fails the unit's
  ## start job when the restore failed; ``After=`` orders it behind the
  ## restore whatever its own default dependencies are.
  "[Unit]\n" &
    "# Carried state (ReproOS Add-On Mode §11.1): starts only after the\n" &
    "# first-boot restore of it succeeded.\n" &
    "Requires=" & CarriedRestoreUnit & "\n" &
    (when CarriedMutation == "restore-unordered": ""
     else: "After=" & CarriedRestoreUnit & "\n")

proc under*(root, path: string): string =
  ## ``path`` (absolute) as seen below ``root``.
  if root == "/" or root.len == 0: path else: root & path

proc stateSetOf*(p: SystemProfile): seq[StateSetEntry] =
  ## The profile's state set, ordered by path.
  var byPath = initOrderedTable[string, StateSetEntry]()
  for r in p.resources:
    if r.kind != srkSystemdSystemUnit: continue
    for d in r.suStateDirectories:
      if d.path notin byPath:
        byPath[d.path] = StateSetEntry(path: d.path,
                                       disposition: d.disposition)
      if r.suName notin byPath[d.path].units:
        byPath[d.path].units.add(r.suName)
  for _, e in byPath:
    var e2 = e
    e2.units.sort()
    result.add(e2)
  result.sort(proc (a, b: StateSetEntry): int = cmp(a.path, b.path))

# ---------------------------------------------------------------------------
# The tree digest.
# ---------------------------------------------------------------------------

proc escapeField*(s: string): string =
  for c in s:
    case c
    of '\\': result.add("\\\\")
    of '\t': result.add("\\t")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    else: result.add(c)

proc sha256Text*(data: string): string =
  toLowerAscii($sha256.digest(data))

proc sha256File*(path: string): string =
  var ctx: sha256
  ctx.init()
  var f: File
  if not open(f, path, fmRead):
    raise newException(StateSetError, "cannot open " & path)
  try:
    var buf = newString(65536)
    while true:
      let n = f.readBuffer(addr buf[0], buf.len)
      if n <= 0: break
      ctx.update(cast[ptr byte](addr buf[0]), uint(n))
  finally:
    f.close()
  result = toLowerAscii($ctx.finish())
  ctx.clear()

proc entryLine(full, rel: string; idMap: proc (isUid: bool; id: int): int): string =
  var st: Stat
  if lstat(full.cstring, st) != 0:
    raise newException(StateSetError, "cannot stat " & full & ": " &
      $strerror(errno))
  let perm = toOct(int(st.st_mode) and 0o7777, 4)
  var uid = int(st.st_uid)
  var gid = int(st.st_gid)
  if idMap != nil:
    uid = idMap(true, uid)
    gid = idMap(false, gid)
  let owner = $uid & ":" & $gid
  if S_ISDIR(st.st_mode):
    "d " & perm & " " & owner & " - " & rel
  elif S_ISREG(st.st_mode):
    # A file with more than one name: a digest over contents alone would
    # pass a tree whose link structure changed, and neither the archive
    # nor the restore keeps it. Refused, so it is never carried silently.
    when CarriedMutation != "hardlinks-unchecked":
      if st.st_nlink > 1:
        raise newException(StateSetError, full & " has " & $st.st_nlink &
          " hard links; a state directory with hard links cannot be " &
          "carried (break the links, or keep the directory instead)")
    "f " & perm & " " & owner & " " & $st.st_size & ":" &
      sha256File(full) & " " & rel
  elif S_ISLNK(st.st_mode):
    "l " & perm & " " & owner & " " & escapeField(expandSymlink(full)) &
      " " & rel
  else:
    raise newException(StateSetError, full & " is a device, FIFO or " &
      "socket, which a state directory cannot carry")

proc walkSorted(dir, rel: string; lines: var seq[string];
                idMap: proc (isUid: bool; id: int): int) =
  var names: seq[string]
  for kind, path in walkDir(dir, relative = true, checkDir = true):
    names.add(path)
  names.sort(system.cmp)
  for n in names:
    let full = dir / n
    let r = (if rel.len == 0: n else: rel & "/" & n)
    lines.add(entryLine(full, escapeField(r), idMap))
    var st: Stat
    if lstat(full.cstring, st) == 0 and S_ISDIR(st.st_mode):
      walkSorted(full, r, lines, idMap)

proc treeLines*(dir: string;
                idMap: proc (isUid: bool; id: int): int = nil): seq[string] =
  ## The digest's input, one line per entry. ``idMap`` reads each owner
  ## and group as another id (a tree restored under remapped ids).
  var st: Stat
  if lstat(dir.cstring, st) != 0 or not S_ISDIR(st.st_mode):
    raise newException(StateSetError, dir & " is not a directory")
  result.add(entryLine(dir, ".", idMap))
  walkSorted(dir, "", result, idMap)

proc treeDigest*(dir: string;
                 idMap: proc (isUid: bool; id: int): int = nil): string =
  "sha256:" & sha256Text(treeLines(dir, idMap).join("\n") & "\n")

# ---------------------------------------------------------------------------
# The manifest and the receipt.
# ---------------------------------------------------------------------------

proc toJson*(m: StateManifest): JsonNode =
  result = %*{"schema": ManifestSchema, "host": m.host,
              "createdAt": m.createdAt, "entries": newJArray()}
  for e in m.entries:
    result["entries"].add(%*{"path": e.path, "disposition": $e.disposition,
      "units": e.units, "digest": e.digest, "archive": e.archive,
      "archiveSha256": e.archiveSha256, "owners": newJObject()})
    for (k, v) in e.owners:
      result["entries"][^1]["owners"][k] = %v

proc parseStateManifest*(text: string): StateManifest =
  ## Refuses anything but this schema, and every entry whose path the
  ## profile parser would refuse (a manifest is input like a profile).
  let j = try: parseJson(text)
          except JsonParsingError, ValueError:
            raise newException(StateSetError, "the state manifest is not JSON")
  if j.kind != JObject or j{"schema"}.getStr() != ManifestSchema:
    raise newException(StateSetError, "not a " & ManifestSchema & " manifest")
  result.host = j{"host"}.getStr()
  result.createdAt = j{"createdAt"}.getStr()
  var seen = initHashSet[string]()
  for e in j{"entries"}.getElems():
    var m = ManifestEntry(path: e{"path"}.getStr(),
      digest: e{"digest"}.getStr(), archive: e{"archive"}.getStr(),
      archiveSha256: e{"archiveSha256"}.getStr())
    let err = stateDirectoryError(m.path)
    if err.len > 0:
      raise newException(StateSetError, "manifest: " & err)
    if m.path in seen:
      raise newException(StateSetError, "manifest names " & m.path & " twice")
    seen.incl(m.path)
    case e{"disposition"}.getStr()
    of $sdKeep: m.disposition = sdKeep
    of $sdCarry: m.disposition = sdCarry
    else:
      raise newException(StateSetError, "manifest: " & m.path &
        " has no keep/carry disposition")
    for u in e{"units"}.getElems(): m.units.add(u.getStr())
    for k, v in e{"owners"}.getFields():
      if not (k.startsWith("uid:") or k.startsWith("gid:")) or
          v.getStr().len == 0:
        raise newException(StateSetError, "manifest: " & m.path &
          " has a malformed owner " & k)
      try: discard parseInt(k[4 .. ^1])
      except ValueError:
        raise newException(StateSetError, "manifest: " & m.path &
          " has a malformed owner " & k)
      m.owners.add((k, v.getStr()))
    if not m.digest.startsWith("sha256:"):
      raise newException(StateSetError, "manifest: " & m.path &
        " has no digest")
    if m.disposition == sdCarry:
      if m.archive.len == 0 or m.archive != extractFilename(m.archive) or
          m.archive.startsWith(".") or m.archiveSha256.len != 64:
        raise newException(StateSetError, "manifest: " & m.path &
          " has no valid archive")
    result.entries.add(m)

proc readStateManifest*(dir: string): StateManifest =
  parseStateManifest(readFile(dir / ManifestFileName))

proc receiptPath*(dir: string): string = dir / RestoredReceipt

proc readReceipt*(dir: string): Table[string, ReceiptEntry] =
  ## The restores recorded beside the manifest. Raises on a malformed one.
  if not fileExists(receiptPath(dir)): return
  let j = try: parseJson(readFile(receiptPath(dir)))
          except JsonParsingError, ValueError:
            raise newException(StateSetError, "the restore receipt is not JSON")
  for k, v in j{"restored"}.getFields():
    if v.kind != JObject:
      raise newException(StateSetError, "the restore receipt is malformed")
    var id = DirIdentity(dev: v{"dev"}.getBiggestInt(-1),
                         ino: v{"ino"}.getBiggestInt(-1))
    if v.hasKey("btime") and v["btime"].kind == JArray and v["btime"].len == 2:
      id.haveBtime = true
      id.btimeSec = v["btime"][0].getBiggestInt()
      id.btimeNsec = v["btime"][1].getBiggestInt()
    if v.hasKey("generation") and v["generation"].kind == JInt:
      id.haveGen = true
      id.gen = v["generation"].getBiggestInt()
    result[k] = ReceiptEntry(digest: v{"digest"}.getStr(),
      root: v{"root"}.getStr(), id: id)

type ReceiptPause* = proc (point: string) {.closure.}
  ## Called at the two points of ``writeReceipt`` a crash-consistency gate
  ## resets the host at; the add-on passes its test seam
  ## (``repro_addon/seams``), which is empty outside the seam build.

proc writeReceipt*(dir: string; r: Table[string, ReceiptEntry];
                   pause: ReceiptPause = nil) =
  ## Replace the receipt in ``dir`` so that a crash at any moment leaves
  ## either the old receipt or the new one, each whole: the new bytes are
  ## written to a temporary file and fsync'd, renamed over the old receipt,
  ## and the directory fsync'd (https://man7.org/linux/man-pages/man2/fsync.2.html:
  ## the rename is durable once the directory is). Without the first fsync
  ## ext4 with delayed allocation can commit the rename before the data,
  ## leaving an empty receipt (https://docs.kernel.org/admin-guide/ext4.html,
  ## ``auto_da_alloc``, which papers over this only for some renames).
  ##
  ## ``pause`` points: ``receipt-before-rename`` (the temporary file
  ## written and fsync'd) and ``receipt-before-dir-fsync`` (renamed into
  ## place, the directory not yet fsync'd).
  var o = newJObject()
  var keys: seq[string]
  for k in r.keys: keys.add(k)
  keys.sort()
  for k in keys:
    let id = r[k].id
    var e = %*{"digest": r[k].digest, "root": r[k].root, "dev": id.dev,
               "ino": id.ino}
    if id.haveBtime: e["btime"] = %*[id.btimeSec, id.btimeNsec]
    if id.haveGen: e["generation"] = %id.gen
    o[k] = e
  const NoFsync = CarriedMutation == "receipt-no-fsync"
  let tmp = receiptPath(dir) & ".tmp"
  let data = $(%*{"restored": o}) & "\n"
  let fd = posix.open(tmp.cstring, O_WRONLY or O_CREAT or O_TRUNC, 0o600)
  if fd < 0:
    raise newException(StateSetError, "cannot write " & tmp & ": " &
      $strerror(errno))
  try:
    var off = 0
    while off < data.len:
      let n = posix.write(fd, unsafeAddr data[off], data.len - off)
      if n <= 0:
        raise newException(StateSetError, "cannot write " & tmp & ": " &
          $strerror(errno))
      off += n
    when not NoFsync:
      if fsync(fd) != 0:
        raise newException(StateSetError, "fsync " & tmp & ": " &
          $strerror(errno))
  finally:
    discard posix.close(fd)
  if pause != nil: pause("receipt-before-rename")
  moveFile(tmp, receiptPath(dir))
  if pause != nil: pause("receipt-before-dir-fsync")
  when not NoFsync:
    let dfd = posix.open(dir.cstring, O_RDONLY)
    if dfd < 0:
      raise newException(StateSetError, "cannot open " & dir & ": " &
        $strerror(errno))
    try:
      if fsync(dfd) != 0:
        raise newException(StateSetError, "fsync " & dir & ": " &
          $strerror(errno))
    finally:
      discard posix.close(dfd)

proc installedMarkerPath*(dir: string): string =
  ## Beside the carried directory (so removing the directory leaves it):
  ## written by ``install-unit``, it says carried state was installed here,
  ## so a manifest missing from ``dir`` later is an error, never "nothing to
  ## restore".
  let d = dir.strip(leading = false, chars = {'/'})
  d.parentDir / (d.extractFilename & ".installed")

# statx(2) by number: neither libc this links against (glibc, the add-on's
# static musl) is required to wrap it, and only the creation time is
# read, from the fixed layout of ``struct statx``
# (https://man7.org/linux/man-pages/man2/statx.2.html: stx_mask at 0,
# stx_btime -- tv_sec i64, tv_nsec u32 -- at 80).
const SysStatx =
  when defined(amd64): 332
  elif defined(arm64) or defined(riscv64): 291
  elif defined(arm): 397
  elif defined(i386): 383
  else: -1
const
  AtFdCwd = -100
  AtSymlinkNoFollow = 0x100
  StatxBtime = 0x800'u32
  # FS_IOC_GETVERSION = _IOR('v', 1, long)
  # (https://man7.org/linux/man-pages/man2/ioctl_iflags.2.html).
  FsIocGetVersion = (2'u64 shl 30) or (uint64(sizeof(clong)) shl 16) or
                    (uint64(ord('v')) shl 8) or 1'u64

proc c_syscall(n: clong): clong {.importc: "syscall", header: "<unistd.h>",
                                  varargs.}
proc c_ioctl(fd: cint; req: culong): cint {.importc: "ioctl",
  header: "<sys/ioctl.h>", varargs.}
var ODirectory {.importc: "O_DIRECTORY", header: "<fcntl.h>".}: cint
var ONoFollow {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint
var OCloexec {.importc: "O_CLOEXEC", header: "<fcntl.h>".}: cint

proc dirIdentity*(path: string): DirIdentity =
  ## The identity of a directory (``dev = -1`` when it is not one). The
  ## creation time and the inode generation are filled in where the kernel
  ## and the file system provide them.
  var st: Stat
  if lstat(path.cstring, st) != 0 or not S_ISDIR(st.st_mode):
    return DirIdentity(dev: -1, ino: -1)
  result = DirIdentity(dev: int64(st.st_dev), ino: int64(st.st_ino))
  when SysStatx > 0:
    var buf: array[256, byte]
    if c_syscall(clong(SysStatx), cint(AtFdCwd), path.cstring,
                 cint(AtSymlinkNoFollow), cuint(StatxBtime), addr buf) == 0:
      var mask: uint32
      copyMem(addr mask, addr buf[0], 4)
      if (mask and StatxBtime) != 0:
        var sec: int64
        var nsec: uint32
        copyMem(addr sec, addr buf[80], 8)
        copyMem(addr nsec, addr buf[88], 4)
        result.haveBtime = true
        result.btimeSec = sec
        result.btimeNsec = int64(nsec)
  let fd = posix.open(path.cstring, O_RDONLY or ODirectory or ONoFollow or
                      OCloexec)
  if fd >= 0:
    var v: clong
    if c_ioctl(fd, culong(FsIocGetVersion), addr v) == 0:
      result.haveGen = true
      result.gen = int64(v)
    discard posix.close(fd)

proc sameDirectory*(recorded, live: DirIdentity): bool =
  ## Whether ``live`` is the directory ``recorded`` names: the same device
  ## and inode, every discriminator both sides have equal, and at least one
  ## discriminator compared. Without one (a file system with neither a
  ## creation time nor a generation) nothing tells a replacement apart, so
  ## the answer is no and the caller decides on the contents instead.
  if recorded.dev < 0 or live.dev < 0: return false
  if recorded.dev != live.dev or recorded.ino != live.ino: return false
  when CarriedMutation == "receipt-trusts-inode":
    return true
  var compared = false
  if recorded.haveBtime and live.haveBtime:
    if recorded.btimeSec != live.btimeSec or
        recorded.btimeNsec != live.btimeNsec:
      return false
    compared = true
  if recorded.haveGen and live.haveGen:
    if recorded.gen != live.gen: return false
    compared = true
  compared

proc normalRoot(root: string): string =
  if root.len == 0: "/" else: root

proc pendingCarriedState*(dir = CarriedStateDir; root = "/"): seq[ManifestEntry] =
  ## The carried directories of the manifest in ``dir`` not restored under
  ## ``root``: the live directory neither holds the manifest's tree nor is
  ## the one a restore at this root recorded. Empty when there is no
  ## manifest. An unreadable manifest or receipt raises.
  if not fileExists(dir / ManifestFileName): return
  let m = readStateManifest(dir)
  let receipt = readReceipt(dir)
  let r = normalRoot(root)
  for e in m.entries:
    if e.disposition != sdCarry: continue
    let live = under(r, e.path)
    let id = dirIdentity(live)
    var restored = false
    when CarriedMutation == "pending-by-receipt-only":
      restored = e.path in receipt and receipt[e.path].digest == e.digest
    else:
      if e.path in receipt:
        let rc = receipt[e.path]
        restored = rc.digest == e.digest and normalRoot(rc.root) == r and
          sameDirectory(rc.id, id)
      if not restored and id.dev >= 0:
        try: restored = treeDigest(live) == e.digest
        except CatchableError: restored = false
    if not restored: result.add(e)

# ---------------------------------------------------------------------------
# Reach: default-deny. What a resource is shown to stay away from is the
# only thing that does not reach a carried directory; every resource kind,
# section, key, value form and command prefix this analysis does not
# positively understand counts as reaching everything.
# ---------------------------------------------------------------------------

type UnitReach* = object
  all*: bool                    ## the resource can reach any path
  why*: string                  ## why ``all``
  paths*: seq[string]           ## normalised absolute paths it can touch

proc allReach(why: string): UnitReach = UnitReach(all: true, why: why)

proc unitDirectivesOf(text: string): seq[(string, string, string)] =
  ## ``(section, key, value)`` in file order, as systemd reads a unit file:
  ## the logical lines of ``config_parse`` (``systemd_syntax``: comments,
  ## continuations only after an unescaped final backslash; A13 review
  ## round 6, finding 1), each stripped and split as ``parse_line`` does.
  var section = ""
  for line in systemdLogicalLines(text):
    let t = line.strip()
    if t.len == 0 or t[0] in {'#', ';'}: continue
    if t.startsWith("[") and t.endsWith("]"):
      section = t[1 ..< t.len - 1]
      continue
    let eq = t.find('=')
    if eq <= 0:
      result.add((section, t, "\0"))          # not a key=value line
      continue
    result.add((section, t[0 ..< eq].strip(), t[eq + 1 .. ^1].strip()))

proc confinementProblem*(protect: ProtectSystemMode; dynamic, noNewPrivileges: bool;
                         user, group, supplementaryGroups, unit: string;
                         lookup: AccountLookup; root = "/"): string =
  ## Why a service with these (effective) settings is not confined to the
  ## paths its unit names, or "" (spec §11.1; §13 decision 54). Confined
  ## only when all hold: its account (``service_account``: the one systemd
  ## will use) resolves, is not root and holds neither the root group nor
  ## any group on the floor's ``PrivilegedGroups`` list (the floor's own
  ## definition, matched by gid on this host); ``NoNewPrivileges=yes``, so
  ## no setuid program, file capability or ``sudo`` grant lifts it; and it
  ## runs as a dynamic user or under ``ProtectSystem=strict``. Shared by the
  ## static analysis (``serviceReach``) and the live cross-check
  ## (``liveConfinementProblem``). And no host polkit rule or D-Bus system
  ## policy under ``root`` names its account or any of its groups
  ## (``privileged_daemons``; §13 decision 58): a privileged daemon could
  ## act for it outside its sandbox.
  when CarriedMutation == "reach-default-allow":
    if dynamic or protect == psStrict: return ""
    return "not confined"
  let a = resolveServiceAccount(user, group, supplementaryGroups, dynamic,
                                unit, lookup)
  if not a.known:
    return "its account does not resolve: " & a.unknown.join("; ")
  if a.userIsRoot:
    return "runs as root (" & a.user & "): ProtectSystem=strict does not " &
      "hold root back (/proc/1/root)"
  if a.groupIsRoot:
    return "holds the root group (" & a.group & ")"
  when CarriedMutation != "confined-without-nnp-or-groups":
    var privileged: seq[(string, int)]
    for g in PrivilegedGroups:
      let gid = if g.allCharsInSet(Digits): parseInt(g) else: lookup.gidOf(g)
      if gid >= 0: privileged.add((g, gid))
    for gid in a.allGids:
      for (g, pg) in privileged:
        if gid == pg:
          return "holds the privileged group " & g & " (gid " & $gid & ")"
    if not noNewPrivileges:
      return "NoNewPrivileges= is not yes: a setuid program, a file " &
        "capability or a sudo grant lifts it out of its account"
  let daemon = privilegedDaemonGrant(AccountNames(user: a.user, uid: a.uid,
    gids: a.allGids, lookup: lookup), normalRoot(root))
  if daemon.len > 0:
    return "a privileged daemon may act for its account: " & daemon
  if not a.dynamicUser and protect != psStrict:
    return "not confined (no ProtectSystem=strict, and no dynamic user): " &
      "it can write anywhere"
  ""

proc unitWords*(value: string; ok: var bool): seq[string] =
  ## A unit value split into words the way systemd splits a list setting
  ## (``extract_first_word`` with quotes: systemd.syntax(7), "Quoting"):
  ## ``"…"`` and ``'…'`` group, whitespace separates. A backslash escape or
  ## an unterminated quote is not decoded here, so ``ok`` turns false and
  ## the caller fails closed.
  ok = true
  var cur = ""
  var inWord = false
  var q = '\0'
  for c in value:
    if q != '\0':
      if c == q: q = '\0'
      else: cur.add(c)
    elif c in {'"', '\''}:
      q = c
      inWord = true
    elif c == '\\':
      ok = false
      return
    elif c in Whitespace:
      if inWord:
        result.add(cur)
        cur = ""
        inWord = false
    else:
      cur.add(c)
      inWord = true
  if q != '\0':
    ok = false
    return
  if inWord: result.add(cur)

proc normalizeUnitPath*(raw: string; ok: var bool): string =
  ## ``raw`` as the absolute path systemd resolves it to: repeated ``/``
  ## and ``.`` segments dropped and a trailing ``/`` removed, as systemd's
  ## ``path_simplify`` does before it uses a sandboxing path
  ## (https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html,
  ## "Sandboxing": paths must be absolute). A relative path, a ``..``
  ## segment, a specifier (``%``), a variable (``$``) or a home (``~``)
  ## is not resolved here: ``ok`` turns false and the caller fails closed.
  ok = false
  if raw.len == 0 or raw[0] != '/': return
  when CarriedMutation == "reach-paths-as-text":
    ok = true
    return raw
  for c in raw:
    if c in {'%', '$', '~', '\0'}: return
  var parts: seq[string]
  for seg in raw.split('/'):
    if seg.len == 0 or seg == ".": continue
    if seg == "..": return
    parts.add(seg)
  ok = true
  "/" & parts.join("/")

proc reaches(p, d: string): bool =
  ## Whether a path a resource can touch, ``p``, is at, above or below the
  ## carried directory ``d`` (both normalised).
  var okA, okB: bool
  let a = normalizeUnitPath(p, okA)
  let b = normalizeUnitPath(d, okB)
  if not (okA and okB): return true
  a == b or a == "/" or (b & "/").startsWith(a & "/") or
    (a & "/").startsWith(b & "/")

const
  ListPathPrefixes = {'-', '+'}
    ## A sandboxing path list's per-entry prefixes: ``-`` (ignore if
    ## missing), ``+`` (relative to ``RootDirectory=``).
  WritePathKeys = (when CarriedMutation == "reach-paths-as-text":
                     @["ReadWritePaths"]
                   else: @["ReadWritePaths", "ReadWriteDirectories"])
    ## Paths made writable (``ReadWriteDirectories=`` is the old spelling
    ## systemd still reads).
  NarrowingPathKeys = ["ReadOnlyPaths", "ReadOnlyDirectories",
    "InaccessiblePaths", "InaccessibleDirectories", "NoExecPaths",
    "ExecPaths"]
    ## Paths a setting only takes away from the unit; they grant nothing.
  BindKeys = ["BindPaths", "BindReadOnlyPaths"]
    ## ``[-]source[:destination[:options]]``: both ends are touched.
  DirectoryKeys = [("StateDirectory", "/var/lib"), ("CacheDirectory", "/var/cache"),
    ("LogsDirectory", "/var/log"), ("RuntimeDirectory", "/run"),
    ("ConfigurationDirectory", "/etc")]
    ## Relative names below a fixed root, each ``name[:symlink]``.
  ReachAllServiceKeys = ["RootDirectory", "RootImage", "RootImageOptions",
    "RootEphemeral", "RootHash", "RootVerity", "MountImages",
    "ExtensionImages", "ExtensionDirectories", "JoinsNamespaceOf",
    "NetworkNamespacePath", "IPCNamespacePath", "PAMName", "TTYPath",
    "OpenFile", "BindsTo"]
    ## Another root, an image or a namespace shared with another unit, a
    ## PAM session, a file opened by the manager: not judged by path here.
  ExecKeys = ["ExecStart", "ExecStartPre", "ExecStartPost", "ExecReload",
    "ExecStop", "ExecStopPost", "ExecCondition"]
  StdioKeys = ["StandardInput", "StandardOutput", "StandardError"]
  SafeStdio = ["null", "tty", "tty-force", "tty-fail", "data", "socket",
    "journal", "kmsg", "journal+console", "kmsg+console", "inherit",
    "console", "syslog", "syslog+console"]
  SafeServiceKeys = ["Type", "ExitType", "Restart", "RestartSec",
    "RestartSteps", "RestartMaxDelaySec", "RestartPreventExitStatus",
    "RestartForceExitStatus", "SuccessExitStatus", "TimeoutSec",
    "TimeoutStartSec", "TimeoutStopSec", "TimeoutAbortSec", "RuntimeMaxSec",
    "RuntimeRandomizedExtraSec", "WatchdogSec", "RemainAfterExit",
    "GuessMainPID", "PIDFile", "BusName", "NotifyAccess", "KillMode",
    "KillSignal", "SendSIGKILL", "SendSIGHUP", "FinalKillSignal",
    "RestartKillSignal", "OOMPolicy", "FileDescriptorStoreMax",
    "Environment", "EnvironmentFile", "PassEnvironment", "UnsetEnvironment",
    "StateDirectoryMode", "RuntimeDirectoryMode", "CacheDirectoryMode",
    "LogsDirectoryMode", "ConfigurationDirectoryMode",
    "RuntimeDirectoryPreserve", "LoadCredential", "LoadCredentialEncrypted",
    "SetCredential", "SyslogIdentifier", "SyslogFacility", "SyslogLevel",
    "SyslogLevelPrefix", "LogLevelMax", "LogRateLimitIntervalSec",
    "LogRateLimitBurst", "LogExtraFields", "Nice", "OOMScoreAdjust",
    "IOSchedulingClass", "IOSchedulingPriority", "CPUSchedulingPolicy",
    "CPUSchedulingPriority", "CPUAffinity", "MemoryMax", "MemoryHigh",
    "MemoryLow", "MemoryMin", "MemorySwapMax", "MemoryAccounting",
    "CPUQuota", "CPUWeight", "IOWeight", "TasksMax", "CPUAccounting",
    "IOAccounting", "TasksAccounting", "IPAccounting", "IPAddressDeny",
    "IPAddressAllow", "Slice", "PrivateNetwork", "PrivateUsers",
    "PrivateIPC", "RemoveIPC", "KeyringMode", "ProcSubset", "DevicePolicy",
    "DeviceAllow", "RestrictFileSystems", "RestrictNetworkInterfaces",
    "SocketBindAllow", "SocketBindDeny", "SystemCallErrorNumber",
    "SystemCallLog", "SystemCallFilter", "SystemCallArchitectures",
    "RestrictAddressFamilies", "NoNewPrivileges", "ProtectHome",
    "PrivateTmp", "PrivateDevices", "ProtectKernelTunables",
    "ProtectKernelModules", "ProtectKernelLogs", "ProtectControlGroups",
    "ProtectClock", "ProtectHostname", "ProtectProc", "RestrictNamespaces",
    "RestrictRealtime", "RestrictSUIDSGID", "LockPersonality",
    "MemoryDenyWriteExecute", "CapabilityBoundingSet", "UMask",
    "LimitNOFILE", "LimitNPROC", "LimitCORE", "LimitMEMLOCK",
    "LimitSTACK", "LimitAS", "LimitDATA", "LimitFSIZE", "LimitCPU",
    "LimitRSS", "LimitLOCKS", "LimitSIGPENDING", "LimitMSGQUEUE",
    "LimitNICE", "LimitRTPRIO", "LimitRTTIME", "CoredumpFilter",
    "TimerSlackNSec", "Personality", "IgnoreSIGPIPE", "UtmpIdentifier",
    "UtmpMode", "StandardInputText", "StandardInputData",
    "ManagedOOMSwap", "ManagedOOMMemoryPressure",
    "ManagedOOMMemoryPressureLimit", "ManagedOOMPreference",
    "MemoryZSwapMax", "StartupCPUWeight", "StartupIOWeight",
    "AllowedCPUs", "AllowedMemoryNodes", "NUMAPolicy", "NUMAMask",
    "SecureBits", "Delegate", "TimeoutStartFailureMode",
    "TimeoutStopFailureMode", "ReloadSignal", "RootDirectoryStartOnly",
    "MountAPIVFS", "ProtectSystem", "DynamicUser", "User", "Group",
    "SupplementaryGroups", "AmbientCapabilities", "PermissionsStartOnly",
    "WorkingDirectory", "TemporaryFileSystem", "Sockets", "PrivateMounts",
    "MountFlags"]
    ## Every [Service] key this analysis understands. One not listed
    ## reaches everything; each of these is judged below or grants no path.
  UnitSectionSafe = ["Description", "Documentation", "After", "Before",
    "Conflicts", "PropagatesReloadTo", "ReloadPropagatedFrom",
    "PropagatesStopTo", "StopPropagatedFrom", "RequiresMountsFor",
    "WantsMountsFor", "StopWhenUnneeded", "RefuseManualStart",
    "RefuseManualStop", "DefaultDependencies", "IgnoreOnIsolate",
    "CollectMode", "StartLimitIntervalSec", "StartLimitBurst",
    "JobTimeoutSec", "JobRunningTimeoutSec", "OnFailureJobMode",
    "OnSuccessJobMode", "SourcePath"]
  UnitActivating = ["Wants", "Requires", "Requisite", "BindsTo", "Upholds",
    "PartOf", "OnFailure", "OnSuccess"]
    ## Units starting (or stopping) this one starts too.
  InstallSafe = ["WantedBy", "RequiredBy", "UpheldBy", "Alias",
    "DefaultInstance"]
  TimerSafe = ["OnActiveSec", "OnBootSec", "OnStartupSec", "OnUnitActiveSec",
    "OnUnitInactiveSec", "OnCalendar", "AccuracySec", "RandomizedDelaySec",
    "RandomizedOffsetSec", "FixedRandomDelay", "OnClockChange",
    "OnTimezoneChange", "Persistent", "WakeSystem", "RemainAfterElapse",
    "DeferReactivation"]
  PathWatchKeys = ["PathExists", "PathExistsGlob", "PathChanged",
    "PathModified", "DirectoryNotEmpty"]
    ## A path unit's watched paths (systemd.path(5)): each reached.
  PathSafe = ["PathExists", "PathExistsGlob", "PathChanged", "PathModified",
    "DirectoryNotEmpty", "MakeDirectory", "DirectoryMode", "TriggerLimitIntervalSec",
    "TriggerLimitBurst"]


proc execReach(key, value: string): string =
  ## Why a command line runs outside the unit's sandbox, or "". Every
  ## command of the line (``systemd_syntax.execCommands``: several commands
  ## separated by a lone ``;``, each word unquoted and unescaped; A13 review
  ## round 6, finding 2) and each one's prefix characters, in any order
  ## (systemd.service(5), "Command lines"): ``@``, ``-``, ``:``, ``+`` (full
  ## privileges, no namespacing), ``!``/``!!`` (no ``User=``), ``|``
  ## (through the shell, systemd ≥ 258). A line systemd would not read as
  ## written reaches everything.
  var ok: bool
  let cmds = execCommands(value, ok)
  if not ok:
    return key & "=" & value & " (a command line not read here)"
  for cmd in cmds:
    for c in cmd.prefix:
      if c in {'+', '!'}:
        when CarriedMutation != "reach-ignores-privileged-commands":
          return key & "=" & value & " (a privileged command, outside the sandbox)"
      elif c notin {'@', '-', ':', '|'}:
        return key & "=" & value & " (an unknown command prefix " & $c & ")"
    if cmd.path.len > 0 and cmd.path[0] notin {'/', 'a'..'z', 'A'..'Z',
        '0'..'9', '_', '.', '%', '$'}:
      return key & "=" & value & " (an unknown command prefix " &
        $cmd.path[0] & ")"
  ""

proc pathsOf(key, value: string; r: var UnitReach) =
  ## The paths a path-taking key grants, normalised; any form not
  ## understood makes ``r`` reach everything.
  var ok: bool
  let words = unitWords(value, ok)
  if not ok:
    r = allReach(key & "=" & value & " (quoting or an escape not decoded)")
    return
  for w0 in words:
    var w = w0
    if key in BindKeys or key == "TemporaryFileSystem" or key in WritePathKeys:
      # ``-`` makes a missing path not an error (systemd.exec(5),
      # "ReadWritePaths="); the path is granted all the same when it exists,
      # so it reaches exactly as the plain form does.
      when CarriedMutation == "optional-paths-ignored":
        if w.startsWith("-"): continue
      while w.len > 0 and w[0] in ListPathPrefixes: w = w[1 .. ^1]
    var ends: seq[string]
    if key in BindKeys:
      let parts = w.split(':')
      ends.add(parts[0])
      if parts.len >= 2 and parts[1].len > 0: ends.add(parts[1])
    elif key == "TemporaryFileSystem":
      ends.add(w.split(':')[0])
    else:
      ends.add(w)
    for e in ends:
      var okP: bool
      let n = normalizeUnitPath(e, okP)
      if not okP:
        r = allReach(key & "=" & w0 & " (a path not resolved here)")
        return
      r.paths.add(n)

proc serviceReach*(name: string; texts: seq[string];
                   lookup: AccountLookup; root = "/"): UnitReach =
  ## The paths a service can touch, from its unit file and its drop-ins in
  ## the order systemd applies them (``texts``: the file, then drop-ins by
  ## file name). Later assignments of a single-valued setting win, as in
  ## systemd; a list setting's paths only accumulate (an empty assignment
  ## that resets a list can only take reach away). The account is the one
  ## systemd will use (``service_account``), resolved through ``lookup``.
  var protect = psNo
  var dynamic = false
  var nnp = false
  var user = ""
  var group = ""
  var collected = UnitReach()
  for t in texts:
    for (section, key, value) in unitDirectivesOf(t):
      if value == "\0":
        return allReach("a line systemd would not read as a setting: " & key)
      when CarriedMutation == "reach-default-allow":
        # FALSIFYING MUTATION: what is not understood is allowed.
        if section notin ["Service"] or (key notin SafeServiceKeys and
            key notin WritePathKeys and key notin BindKeys and
            key notin ExecKeys and key notin StdioKeys): continue
      case section
      of "Unit":
        if key notin UnitSectionSafe and key notin UnitActivating and
            not key.startsWith("Condition") and not key.startsWith("Assert"):
          return allReach("[Unit] " & key & "= (not understood here)")
      of "Install":
        if key notin InstallSafe and key != "Also":
          return allReach("[Install] " & key & "= (not understood here)")
      of "Service":
        if key notin SafeServiceKeys and key notin WritePathKeys and
            key notin NarrowingPathKeys and key notin BindKeys and
            key notin ExecKeys and key notin StdioKeys and
            key notin ReachAllServiceKeys:
          var dir = false
          for (k, _) in DirectoryKeys:
            if k == key: dir = true
          if not dir:
            return allReach("[Service] " & key & "= (not understood here)")
        if key in ReachAllServiceKeys and value.len > 0:
          return allReach(key & "=" & value)
        case key
        # Read with systemd's grammar (``systemd_values``): a value systemd
        # ignores leaves the earlier assignment in place (A13 review round
        # 5, finding 1).
        of "ProtectSystem": discard parseProtectSystem(value, protect)
        of "DynamicUser":
          var b: bool
          if parseSystemdBoolean(value, b) == srValid: dynamic = b
        of "NoNewPrivileges":
          var b: bool
          if parseSystemdBoolean(value, b) == srValid: nnp = b
        of "User": user = value
        of "Group": group = value
        of "SupplementaryGroups":
          if value.len > 0:
            return allReach("SupplementaryGroups=" & value &
              " (a group's access is not judged here)")
        of "AmbientCapabilities":
          if value.len > 0:
            return allReach("AmbientCapabilities=" & value)
        of "PermissionsStartOnly":
          when CarriedMutation != "reach-ignores-privileged-commands":
            var b: bool
            if parseSystemdBoolean(value, b) == srValid and b:
              return allReach("PermissionsStartOnly=" & value & " (its " &
                "other commands run outside the sandbox)")
        of "WorkingDirectory":
          var w = value
          if w.startsWith("-"): w = w[1 .. ^1]
          if w.len > 0:
            var ok: bool
            let n = normalizeUnitPath(w, ok)
            if not ok: return allReach("WorkingDirectory=" & value)
            collected.paths.add(n)
        else:
          if key in ExecKeys:
            let why = execReach(key, value)
            if why.len > 0: return allReach(why)
          elif key in StdioKeys:
            let v = value
            let c = v.find(':')
            let kind = if c > 0: v[0 ..< c] else: v
            if kind in ["file", "append", "truncate"]:
              var ok: bool
              let n = normalizeUnitPath(v[c + 1 .. ^1], ok)
              if not ok: return allReach(key & "=" & v)
              collected.paths.add(n)
            elif kind != "fd" and v notin SafeStdio:
              return allReach(key & "=" & v & " (not understood here)")
          elif key in WritePathKeys or key in BindKeys or
              key == "TemporaryFileSystem":
            pathsOf(key, value, collected)
            if collected.all: return collected
          else:
            for (k, base) in DirectoryKeys:
              if k != key: continue
              var ok: bool
              let words = unitWords(value, ok)
              if not ok: return allReach(key & "=" & value)
              for w in words:
                for part in w.split(':'):
                  if part.len == 0: continue
                  var okP: bool
                  let n = normalizeUnitPath(base & "/" & part, okP)
                  if not okP or part.startsWith("/"):
                    return allReach(key & "=" & w)
                  collected.paths.add(n)
      of "Timer", "Path":
        discard                     # judged by unitReach for those types
      else:
        return allReach("[" & section & "] (a section not understood here)")
  # The account systemd will use (A13 review round 4, finding 1): its
  # specifiers expanded, a static account of the name winning over
  # DynamicUser=yes, uid aliases and group memberships resolved. What does
  # not resolve reaches everything.
  let why = confinementProblem(protect, dynamic, nnp, user, group, "", name,
                               lookup, root)
  if why.len > 0: return allReach(why)
  collected

const
  UnitSearchPath = ["/etc/systemd/system.control",
    "/run/systemd/system.control", "/run/systemd/transient",
    "/run/systemd/generator.early", "/etc/systemd/system",
    "/etc/systemd/system.attached", "/run/systemd/system",
    "/run/systemd/system.attached", "/run/systemd/generator",
    "/usr/local/lib/systemd/system", "/usr/lib/systemd/system",
    "/lib/systemd/system", "/run/systemd/generator.late"]
    ## The system manager's unit search path, highest priority first
    ## (systemd.unit(5), "Unit File Load Path"; ``systemd-analyze
    ## unit-paths``). ``/lib`` is a link to ``/usr/lib`` on a merged-/usr
    ## base and a directory of its own elsewhere; both are read.
  GenerationUnitDir = "/etc/systemd/system"
    ## Where a generation writes a profile's units and drop-ins.

proc dropInDirApplies(d, unit: string; dirSuffix = ".d"): bool =
  ## Whether systemd reads directory ``d`` (``<name><dirSuffix>``: ``.d``
  ## for drop-ins, ``.wants``/``.requires``/``.upholds`` for dependency
  ## links) for ``unit``, or -- ``unit`` a template ``foo@.service`` -- for
  ## any of its instances: the unit's own name, an instance's, the
  ## template's, a dashed prefix (``foo-.service``) and the type-wide
  ## ``service.d`` (systemd.unit(5), "Description"; ``unit_file_find_dirs()``
  ## and ``unit_file_find_dropin_paths()`` in ``src/shared/dropin.c``,
  ## https://github.com/systemd/systemd/blob/v257/src/shared/dropin.c, the
  ## same for every suffix).
  if not d.endsWith(dirSuffix): return false
  let n = d[0 ..< d.len - dirSuffix.len]
  let dot = unit.rfind('.')
  if dot <= 0: return false
  let typ = unit[dot + 1 .. ^1]
  if n == unit or n == typ: return true
  if not n.endsWith("." & typ): return false
  let nstem = n[0 ..< n.len - typ.len - 1]
  let ustem = unit[0 ..< dot]
  let at = ustem.find('@')
  let prefix = if at >= 0: ustem[0 ..< at] else: ustem
  if at >= 0:
    # The template's directory, and for a template any instance's.
    if nstem == prefix & "@": return true
    if ustem.len == at + 1 and nstem.startsWith(prefix & "@"): return true
  # Dashed prefixes: "a-b-c" reads "a-b-" and "a-".
  if nstem.endsWith("-") and nstem.len > 1 and prefix.startsWith(nstem):
    return true
  false

const AliasFollowMax = 32
  ## systemd's ``FOLLOW_MAX``: how deep ``unit_ids_map_get()`` follows an
  ## alias chain before it gives up.

proc unitNames(unit: string; texts: seq[string]; root: string): seq[string] =
  ## Every name systemd loads ``unit`` under (A13 review round 5, finding
  ## 2; round 6, finding 3): its own; each ``[Install] Alias=`` in
  ## ``texts`` (a link once the unit is enabled); and every link in the
  ## unit search path whose chain of links ends at the unit -- a link to
  ## the unit, a link to such a link, and so on, as
  ## ``unit_file_build_name_map()`` and ``unit_ids_map_get()`` resolve
  ## them (https://github.com/systemd/systemd/blob/v257/src/shared/unit-file.c;
  ## ``unit_find_dropin_paths()`` then reads the drop-ins of each name).
  ## The first directory of the search path that holds a name decides it.
  ## A chain of this unit's type that loops, or is longer than systemd
  ## follows, is reported as ``<unparsed ...>``: the unit reaches
  ## everything.
  result = @[unit]
  # FALSIFYING MUTATION: the unit's own name only (``-without-live-check``:
  # the conversion gate's build, with a full apply's live cross-check off).
  when CarriedMutation in ["reach-alias-dropins-unread",
                          "reach-alias-dropins-unread-without-live-check"]:
    return
  for t in texts:
    for (section, key, value) in unitDirectivesOf(t):
      if section == "Install" and key == "Alias":
        var ok: bool
        for w in unitWords(value, ok):
          if w notin result: result.add(w)
        if not ok: result.add("<unparsed Alias=" & value & ">")
  # name -> the file name its link points at, first directory first.
  var links = initOrderedTable[string, string]()
  var files = initHashSet[string]()
  for dir in UnitSearchPath:
    let full = under(normalRoot(root), dir)
    if not dirExists(full): continue
    for kind, e in walkDir(full, relative = true):
      if e in links or e in files: continue
      if kind == pcLinkToFile or kind == pcLinkToDir or
          (kind == pcFile and symlinkExists(full / e)):
        var target = ""
        try: target = expandSymlink(full / e)
        except OSError: continue
        links[e] = target.extractFilename
      elif kind == pcFile:
        files.incl(e)
      elif symlinkExists(full / e):
        # A dangling link: systemd records it too.
        var target = ""
        try: target = expandSymlink(full / e)
        except OSError: continue
        links[e] = target.extractFilename
  let dot = unit.rfind('.')
  let typ = if dot >= 0: unit[dot .. ^1] else: ""
  for name in links.keys:
    if name in result: continue
    var cur = name
    var hops = 0
    var seen = initHashSet[string]()
    when CarriedMutation == "alias-chain-first-link-only":
      if links[cur] == unit: result.add(name)
      continue
    while true:
      if cur in seen or hops > AliasFollowMax:
        if name.endsWith(typ):
          result.add("<unparsed alias chain from " & name & ">")
        break
      seen.incl(cur)
      let nxt = links.getOrDefault(cur, "")
      if nxt.len == 0: break
      if nxt == unit:
        result.add(name)
        break
      cur = nxt
      inc hops

const DependencyDirs* = [(".wants", "Wants"), (".requires", "Requires"),
                         (".upholds", "Upholds")]
  ## The dependency directories systemd reads for a unit
  ## (``unit_load_dropin()`` in ``src/core/load-dropin.c``,
  ## https://github.com/systemd/systemd/blob/v257/src/core/load-dropin.c):
  ## every link in ``<name>.wants/`` is a ``Wants=``, and so on.

proc dependencyLinks*(names: seq[string]; root: string): seq[string] =
  ## The units the host's dependency directories add to a unit known under
  ## ``names`` (``unitNames``): every link in a ``.wants/``, ``.requires/``
  ## or ``.upholds/`` directory of the unit search path that applies to one
  ## of them (its own, an alias's, the template's, a dashed prefix's, the
  ## type's), by the link's name, as ``process_deps()`` adds it. A link to
  ## ``/dev/null`` (masked) and an entry that is not a link are ignored, as
  ## systemd ignores them. One reader for every caller: the reach analysis
  ## (``triggersOutside``), the restore requirement and its closure (A13
  ## review round 6, finding 4).
  when CarriedMutation == "dependency-links-unread":
    return
  for dir in UnitSearchPath:
    let full = under(normalRoot(root), dir)
    if not dirExists(full): continue
    for kind, e in walkDir(full, relative = true):
      if kind notin {pcDir, pcLinkToDir}: continue
      for (suffix, _) in DependencyDirs:
        var applies = false
        for n in names:
          if dropInDirApplies(e, n, suffix): applies = true
        if not applies: continue
        for k2, f in walkDir(full / e, relative = true):
          if not symlinkExists(full / e / f): continue
          var target = ""
          try: target = expandSymlink(full / e / f)
          except OSError: continue
          if target == "/dev/null": continue
          if f notin result: result.add(f)

proc activatedUnits(name, suffix: string; texts: seq[string];
                    root = ""): seq[string] =
  ## The units starting this one also starts (``UnitActivating``, a
  ## service's ``Sockets=``, ``[Install] Also=``), for a timer or a path
  ## unit the unit it triggers (``Unit=``, else the service of its name),
  ## and -- ``root`` given -- the links of its dependency directories on
  ## the host under any of its names (``dependencyLinks``). The one
  ## dependency reader.
  var trigger = ""
  for t in texts:
    for (section, key, value) in unitDirectivesOf(t):
      if (section == "Unit" and key in UnitActivating) or
          (section == "Service" and key == "Sockets") or
          (section == "Install" and key == "Also"):
        var ok: bool
        for w in unitWords(value, ok):
          if w notin result: result.add(w)
        if not ok: result.add("<unparsed " & key & "=" & value & ">")
      elif section in ["Timer", "Path"] and key == "Unit":
        trigger = value.strip()
  if suffix in ["timer", "path"]:
    if trigger.len == 0:
      trigger = name[0 ..< name.len - suffix.len] & "service"
    if trigger notin result: result.add(trigger)
  if root.len > 0:
    let names = unitNames(name, texts, root)
    for n in names:
      if n.startsWith("<unparsed"):
        result.add(n)
        return
    for d in dependencyLinks(names, root):
      if d notin result: result.add(d)

proc unitTexts(unit, base: string; p: SystemProfile; root: string;
               why: var string; hostUnit = false;
               profileLeftOut = false): seq[string] =
  ## What systemd reads for ``unit``: ``base`` (the profile's file), then
  ## every drop-in that applies to it under any of its names
  ## (``unitNames``) -- the profile's own (written as
  ## ``50-repro-<name>.conf``) and the host's, from every directory of the
  ## unit search path (unit-specific, alias, template, dashed-prefix and
  ## type-wide directories, generators', ``/run`` and ``/usr/lib`` alike) --
  ## in one order by file name, a name in a higher-priority directory
  ## replacing the same name below it. Default-deny where the order is not
  ## certain: ``why`` is set (the unit reaches everything) when a unit file
  ## of the same name sits in a directory systemd reads before the
  ## generation's, when one drop-in name holds different bytes in two
  ## directories, or when an alias cannot be read.
  ##
  ## Left out, as the generation's own (A13 review round 5, finding 3), only
  ## what the generation being applied writes there: a host
  ## ``/etc/systemd/system/<name>.d/50-repro-<d>.conf`` the profile declares
  ## (its bytes are the profile's, judged above), the generation's restore
  ## requirement (``50-repro-state-restore.conf``) and ``install-unit``'s,
  ## each only when it holds exactly ``restoreRequirementText``. Any other
  ## ``50-repro-*.conf`` -- one an earlier generation declared, or one
  ## placed by hand -- is loaded by systemd and so is read like any drop-in.
  ##
  ## ``profileLeftOut``: the host's files alone (the boot closure, §13
  ## decision 60). The profile's drop-ins are neither added nor read from
  ## the host where a previous generation wrote them: their
  ## ``50-repro-<d>.conf`` files are the generation's, not the host's (A13
  ## review round 7, finding 2).
  result = @[base]
  var byName = initOrderedTable[string, string]()
  var seen = initTable[string, string]()
  var declared = initHashSet[string]()       # "<dir>.d/<file>"
  var texts0 = @[base]
  if not profileLeftOut:
    for d in p.resources:
      if d.kind == srkSystemdSystemDropIn and d.diUnit == unit:
        texts0.add(d.diContent)
  let names = unitNames(unit, texts0, root)
  for n in names:
    if n.startsWith("<unparsed"):
      why = "an alias that cannot be read (" & n & ")"
      return
  for d in p.resources:
    if d.kind == srkSystemdSystemDropIn and d.diUnit in names:
      let n = "50-repro-" & d.diName & ".conf"
      if not profileLeftOut:
        byName[n] = d.diContent
        seen[n] = d.diContent
      declared.incl(d.diUnit & ".d/" & n)
  when CarriedMutation != "reach-host-dropins-ignored":
    var higher = true
    for dir in UnitSearchPath:
      let full = under(normalRoot(root), dir)
      if dir == GenerationUnitDir: higher = false
      if not dirExists(full): continue
      if higher and not hostUnit and
          (fileExists(full / unit) or symlinkExists(full / unit)):
        why = "a unit file " & dir & "/" & unit & " takes precedence over " &
          "the generation's"
        return
      for kind, e in walkDir(full, relative = true):
        if kind notin {pcDir, pcLinkToDir}: continue
        var applies = false
        for n in names:
          if dropInDirApplies(e, n): applies = true
        if not applies: continue
        var files: seq[string]
        for k2, f in walkDir(full / e, relative = true):
          if f.endsWith(".conf"): files.add(f)
        files.sort()
        for f in files:
          let own = dir == GenerationUnitDir and f.startsWith("50-repro-")
          when CarriedMutation == "reach-stale-generation-dropins-skipped":
            # FALSIFYING MUTATION: round 4's reading -- every 50-repro-*.conf
            # in the unit's own directory is the generation's.
            if own and e == unit & ".d": continue
          else:
            if own and (e & "/" & f) in declared: continue
          var c = ""
          try: c = readFile(full / e / f)
          except IOError, OSError:
            why = "the drop-in " & dir & "/" & e & "/" & f & " cannot be read"
            return
          if c == restoreRequirementText() and (f == RestoreRequiredDropIn or
              (own and f == "50-repro-" & RequirementDropInName & ".conf")):
            continue
          if f in seen:
            if seen[f] != c:
              why = "the drop-in name " & f & " holds different bytes in " &
                "two directories (" & dir & "/" & e & ")"
              return
            continue
          seen[f] = c
          byName[f] = c
  var ordered: seq[string]
  for n in byName.keys: ordered.add(n)
  when CarriedMutation != "reach-default-allow":
    ordered.sort()
  for n in ordered: result.add(byName[n])

proc definedUnits(p: SystemProfile): HashSet[string] =
  ## The units whose whole definition is in the profile.
  for d in p.resources:
    case d.kind
    of srkSystemdSystemUnit:
      if d.suCollision != "dropIn": result.incl(d.suName)
    of srkSystemdSystemTimer: result.incl(d.stName)
    else: discard

proc triggersOutside(name, suffix: string; texts: seq[string];
                     p: SystemProfile; root: string): string =
  ## A unit it starts that the profile does not define, or "".
  when CarriedMutation == "reach-trigger-units-reach-nothing":
    return ""
  let defined = definedUnits(p)
  for u in activatedUnits(name, suffix, texts, normalRoot(root)):
    if u notin defined and not u.endsWith(".slice"):
      return "it starts " & u & ", which the profile does not define"
  ""

proc timerOrPathReach(name, suffix: string; texts: seq[string];
                      p: SystemProfile; root: string): UnitReach =
  ## A timer reaches no path itself. A path unit reaches every path it
  ## watches: with ``MakeDirectory=yes`` the manager creates them, as root,
  ## outside any sandbox (systemd.path(5)), and a list is cheaper to judge
  ## than that rule. A glob reaches the directory it is anchored in.
  for t in texts:
    for (section, key, value) in unitDirectivesOf(t):
      let ok = case section
        of "Unit": key in UnitSectionSafe or key in UnitActivating or
                   key.startsWith("Condition") or key.startsWith("Assert")
        of "Install": key in InstallSafe or key == "Also"
        of "Timer": suffix == "timer" and (key in TimerSafe or key == "Unit")
        of "Path": suffix == "path" and (key in PathSafe or key == "Unit")
        else: false
      if not ok or value == "\0":
        return allReach("[" & section & "] " & key & "= (not understood here)")
      when CarriedMutation != "reach-path-unit-paths-ignored":
        if section == "Path" and key in PathWatchKeys and value.len > 0:
          var v = value
          let g = v.find({'*', '?', '['})
          if g >= 0:
            let slash = v.rfind('/', 0, g)
            v = if slash > 0: v[0 ..< slash] else: "/"
          var okP: bool
          let n = normalizeUnitPath(v, okP)
          if not okP: return allReach(key & "=" & value)
          result.paths.add(n)
  let why = triggersOutside(name, suffix, texts, p, root)
  if why.len > 0: return allReach(why)

proc tmpfilesReach(content: string): UnitReach =
  ## Every path a tmpfiles.d line names (its path column and, for ``L``,
  ## ``C`` and the like, an absolute argument), normalised
  ## (https://www.freedesktop.org/software/systemd/man/latest/tmpfiles.d.html).
  ## A line not understood reaches everything.
  for raw in content.splitLines():
    let t = raw.strip()
    if t.len == 0 or t[0] == '#': continue
    var ok: bool
    let f = unitWords(t, ok)
    if not ok or f.len < 2:
      return allReach("tmpfiles line not understood: " & t)
    for i in [1, 6]:
      if i >= f.len: continue
      let v = f[i]
      if i == 6 and not v.startsWith("/"): continue
      var okP: bool
      let n = normalizeUnitPath(v, okP)
      if not okP: return allReach("tmpfiles path not resolved here: " & t)
      result.paths.add(n)

proc unitReach*(r: SystemResource; p: SystemProfile; lookup: AccountLookup;
                root = "/"): UnitReach =
  ## What a resource of the profile can reach (see the module header),
  ## reading the host under ``root`` for the drop-ins systemd will apply
  ## and resolving accounts through ``lookup`` (``hostAccountLookup``).
  ## Exhaustive over ``SystemResourceKind``, with no ``else``: a kind added
  ## later does not compile here until it is classified.
  when CarriedMutation == "reach-default-allow":
    # FALSIFYING MUTATION: round 2's dispatch, only units judged.
    if r.kind != srkSystemdSystemUnit: return UnitReach()
  case r.kind
  of srkSystemdSystemUnit:
    let ext = r.suName.rsplit('.', maxsplit = 1)
    let suffix = if ext.len == 2: ext[1] else: ""
    if suffix notin ["service", "timer", "target", "path", "slice"]:
      return allReach("a ." & suffix & " unit")
    when CarriedMutation != "reach-dropin-judged-alone":
      if r.suCollision == "dropIn":
        return allReach("a drop-in over the distribution unit " & r.suName)
    var base = ""
    try: base = renderedSystemUnitContent(r)
    except CatchableError as e:
      return allReach("unit cannot be rendered: " & e.msg)
    # Every drop-in systemd will apply, in its order (``unitTexts``).
    var why0 = ""
    let texts = unitTexts(r.suName, base, p, root, why0)
    if why0.len > 0: return allReach(why0)
    let why = triggersOutside(r.suName, suffix, texts, p, root)
    if why.len > 0: return allReach(why)
    case suffix
    of "service":
      result = serviceReach(r.suName, texts, lookup, root)
      if not result.all:
        for sd in r.suStateDirectories: result.paths.add(sd.path)
    of "timer", "path": result = timerOrPathReach(r.suName, suffix, texts, p, root)
    else:
      # A target or a slice runs nothing; what it starts was judged above,
      # and any setting beyond [Unit]/[Install] is not understood.
      for t in texts:
        for (section, key, value) in unitDirectivesOf(t):
          if section notin ["Unit", "Install"] or value == "\0":
            return allReach("[" & section & "] " & key & "=")
      result = UnitReach()
  of srkSystemdSystemTimer:
    # Read like any other unit file: its drop-ins too (A13 review round 4,
    # finding 2).
    var why0 = ""
    let texts = when CarriedMutation == "reach-timer-dropins-unread":
                  @[r.stContent]
                else: unitTexts(r.stName, r.stContent, p, root, why0)
    if why0.len > 0: return allReach(why0)
    result = timerOrPathReach(r.stName, "timer", texts, p, root)
  of srkSystemdSystemDropIn:
    # A drop-in for a unit the profile defines is judged with that unit;
    # one over a unit it does not define changes a file it cannot see.
    if r.diUnit notin definedUnits(p):
      result = allReach("a drop-in for " & r.diUnit &
        ", which the profile does not define")
  of srkSystemdUnitState:
    result = allReach("it enables, starts or stops " & r.usName &
      ", a unit the profile does not define")
  of srkFsSystemFile:
    var ok: bool
    let n = normalizeUnitPath(r.sfPath, ok)
    result = if ok: UnitReach(paths: @[n]) else: allReach("path " & r.sfPath)
  of srkFsSystemDirectory:
    var ok: bool
    let n = normalizeUnitPath(r.dirPath, ok)
    result = if ok: UnitReach(paths: @[n]) else: allReach("path " & r.dirPath)
  of srkPasswdUser:
    let home = if r.puHome.len > 0: r.puHome else: "/home/" & r.puName
    var ok: bool
    let n = normalizeUnitPath(home, ok)
    result = if ok: UnitReach(paths: @[n]) else: allReach("home " & home)
  of srkLinuxTmpfilesRule:
    result = tmpfilesReach(r.tmpfilesContent)
  of srkLinuxDpkgDiversion:
    var ok: bool
    let n = normalizeUnitPath(r.ddPath, ok)
    result = if ok: UnitReach(paths: @[n, n & ".distrib"])
             else: allReach("diversion " & r.ddPath)
  of srkLinuxSysusersEntry, srkOsTimezone, srkOsHostname, srkLinuxSysctl,
     srkLinuxFirewallRule, srkLinuxAddOnTool:
    # Each writes only its own fixed place: an account or group entry
    # (sysusers does not create a home), /etc/localtime, /etc/hostname, a
    # sysctl.d file, a firewall rule, a wrapper in /etc/repro/bin.
    result = UnitReach()
  of srkEnvSystemVariable, srkLinuxUdevRule, srkLinuxPolkitRule,
     srkLinuxSudoersRule, srkPasswdGroup, srkLinuxNixDaemonSetting,
     srkLinuxNixosSystemModule, srkLinuxFhsSandbox:
    # An environment every process inherits, a rule that runs commands as
    # root or grants privileges, a group membership, a daemon or a system
    # module: what they let run is not judged here.
    result = allReach("a " & $r.kind & " resource (what it lets run is " &
      "not judged here)")
  of srkWindowsRegistryValue, srkWindowsOptionalFeature, srkWindowsCapability,
     srkWindowsService, srkWindowsScheduledTask, srkWindowsVsInstaller,
     srkWindowsFirewallRule, srkWindowsAcl, srkMacosSystemDefault,
     srkLaunchdSystemDaemon, srkMacosDarwinSystemModule:
    result = allReach("a " & $r.kind & " resource on a Linux host")

# ---------------------------------------------------------------------------
# Owners.
# ---------------------------------------------------------------------------

proc accountTable*(root, file: string): Table[string, string] =
  ## ``<root>/etc/passwd`` or ``/etc/group`` as both ``"id:<n>" -> name``
  ## and ``"name:<name>" -> n``. A missing file is an empty table.
  let p = under(normalRoot(root), "/etc/" & file)
  if not fileExists(p): return
  for line in readFile(p).splitLines():
    if line.len == 0 or line[0] == '#': continue
    let f = line.split(':')
    if f.len < 3: continue
    result["id:" & f[2]] = f[0]
    result["name:" & f[0]] = f[2]

proc pinnedIds(p: SystemProfile): (Table[string, string], Table[string, string],
                                   HashSet[string]) =
  ## (users name->pinned id, groups name->pinned id, names created unpinned)
  var users, groups = initTable[string, string]()
  var unpinned = initHashSet[string]()
  for r in p.resources:
    case r.kind
    of srkLinuxSysusersEntry:
      if r.seId.len > 0:
        if r.seKind == "group": groups[r.seName] = r.seId
        else:
          users[r.seName] = r.seId
          groups[r.seName] = r.seId
      else: unpinned.incl(r.seName)
    of srkPasswdGroup:
      if r.pgGid.len > 0: groups[r.pgName] = r.pgGid
      else: unpinned.incl(r.pgName)
    of srkPasswdUser:
      unpinned.incl(r.puName)
    else: discard
  (users, groups, unpinned)

proc ownerMismatches*(e: ManifestEntry; p: SystemProfile; root = "/"): seq[string] =
  ## Where this host (or the profile that creates its accounts) would give
  ## a name the carried tree holds another id than the source host did.
  when CarriedMutation == "owner-ids-unchecked":
    return
  let pw = accountTable(root, "passwd")
  let gr = accountTable(root, "group")
  let (pu, pg, unpinned) = pinnedIds(p)
  for (k, name) in e.owners:
    if name.startsWith("#"): continue
    let isUid = k.startsWith("uid:")
    let src = k[4 .. ^1]
    let live = (if isUid: pw else: gr).getOrDefault("name:" & name)
    let what = (if isUid: "user " else: "group ") & name
    if live.len > 0:
      if live != src:
        result.add(what & " is " & live & " here but owns " & e.path &
          " as " & src)
      continue
    let pinned = (if isUid: pu else: pg).getOrDefault(name)
    if pinned.len > 0:
      if pinned != src:
        result.add(what & " is pinned to " & pinned & " by the profile but " &
          "owns " & e.path & " as " & src)
    elif name in unpinned:
      result.add(what & " is created by the profile without a pinned id; " &
        "pin it to " & src & " (it owns " & e.path & ")")
    else:
      result.add(what & " (owner of " & e.path & " as " & src & ") does " &
        "not exist here and the profile does not create it")
    # The id held by another account here.
    let holder = (if isUid: pw else: gr).getOrDefault("id:" & src)
    if holder.len > 0 and holder != name:
      result.add(what & ": id " & src & " belongs to " & holder & " here")

# ---------------------------------------------------------------------------
# Holds.
# ---------------------------------------------------------------------------

proc holdDropInPath*(unit: string; root = "/"): string =
  under(normalRoot(root), HoldUnitDir / (unit & ".d") / HoldDropInName)

proc heldUnits*(root = "/"): seq[string] =
  ## Units a backup holds on this host.
  let base = under(normalRoot(root), HoldUnitDir)
  if not dirExists(base): return
  for kind, d in walkDir(base, relative = true):
    if d.endsWith(".d") and fileExists(base / d / HoldDropInName):
      result.add(d[0 ..< d.len - 2])
  result.sort()

# ---------------------------------------------------------------------------
# The refusal.
# ---------------------------------------------------------------------------

proc reservedNameProblem*(p: SystemProfile): string =
  ## Why ``p`` declares the reserved requirement drop-in, or "" (A13 review
  ## round 6, finding 5): ``RequirementDropInName`` is the generation's own
  ## (``50-repro-state-restore.conf``, written by ``withCarriedRequirements``
  ## for every unit that reaches carried state), so a profile drop-in of that
  ## name holding anything else would take the requirement's place. The one
  ## form let through is the requirement itself, byte for byte: the text a
  ## generation was applied with, applied again (a rollback, a replay).
  when CarriedMutation == "requirement-name-not-reserved":
    return ""
  for r in p.resources:
    if r.kind == srkSystemdSystemDropIn and r.diName == RequirementDropInName and
        r.diContent != restoreRequirementText():
      return "ECarriedStatePending: " & r.address & " is a drop-in named " &
        RequirementDropInName & " for " & r.diUnit & "; the name is " &
        "reserved for the carried-state restore requirement (spec §11.1), " &
        "so rename it"
  ""

proc carriedStateRefusal*(p: SystemProfile; dir = CarriedStateDir;
                          root = "/"): string =
  ## Why an apply of ``p`` must not run here, or "" (see the module
  ## header). Fails closed: carried state that cannot be read refuses.
  when CarriedMutation == "apply-ignores-carried-state":
    return ""
  let reserved = reservedNameProblem(p)
  if reserved.len > 0: return reserved
  when CarriedMutation != "apply-ignores-hold":
    let held = heldUnits(root)
    if held.len > 0:
      return "ECarriedStatePending: a state backup holds " & held.join(", ") &
        " on this host (spec §11.1); nothing is applied until it is " &
        "released (`repro system addon state release --profile <file>`)"
  if not fileExists(dir / ManifestFileName):
    when CarriedMutation != "missing-manifest-allowed":
      if fileExists(installedMarkerPath(dir)):
        return "ECarriedStatePending: carried state was installed at " & dir &
          " (" & installedMarkerPath(dir) & "), but its manifest is " &
          "missing; nothing is applied until it is back"
    return ""
  var pending: seq[ManifestEntry]
  var m: StateManifest
  try:
    m = readStateManifest(dir)
    pending = pendingCarriedState(dir, root)
  except CatchableError as e:
    return "ECarriedStatePending: the carried state at " & dir &
      " cannot be read: " & e.msg
  var hits: seq[string]
  var reached = initHashSet[string]()
  let lookup = hostAccountLookup(root, p)
  for r in p.resources:
    let reach = unitReach(r, p, lookup, root)
    let label = r.address
    for e in m.entries:
      if e.disposition != sdCarry: continue
      var hit = false
      var why = ""
      when CarriedMutation == "carried-reach-by-unit-name":
        hit = r.kind == srkSystemdSystemUnit and r.suName in e.units
      else:
        if reach.all:
          hit = true
          why = reach.why
        else:
          for q in reach.paths:
            if reaches(q, e.path): hit = true
      if hit:
        reached.incl(e.path)
        var pend = false
        for x in pending:
          if x.path == e.path: pend = true
        if pend:
          hits.add(e.path & " (" & label &
            (if why.len > 0: ": " & why else: "") & ")")
  if hits.len > 0:
    return "ECarriedStatePending: carried state is not restored yet: " &
      hits.join(", ") & "; run `repro system state restore` (the " &
      "first-boot unit repro-state-restore.service does) before the first " &
      "apply"
  var owners: seq[string]
  for e in m.entries:
    if e.disposition == sdCarry and e.path in reached:
      owners.add(ownerMismatches(e, p, root))
  if owners.len > 0:
    return "ECarriedStatePending: the carried state's owners would not " &
      "match: " & owners.join("; ")
  ""

proc liveConfinementProblem*(unit: string;
                             prop: proc (key: string): string {.closure.};
                             lookup: AccountLookup; root = "/"): string =
  ## ``confinementProblem`` over the unit as systemd loaded it, from its
  ## ``systemctl show`` properties (``prop``): what a switch on a live host
  ## checks after daemon-reload and before any start, so that a value the
  ## static reading took one way and systemd another is decided by systemd
  ## (A13 review round 5, finding 1). ``systemctl show`` prints the
  ## effective values: ``ProtectSystem=no|yes|full|strict``,
  ## ``DynamicUser=``/``NoNewPrivileges=`` as ``yes``/``no``, and the
  ## account settings with specifiers expanded.
  when CarriedMutation == "live-reach-unchecked":
    return ""
  var protect = psNo
  if parseProtectSystem(prop("ProtectSystem"), protect) == srIgnored:
    return "systemd reports ProtectSystem=" & prop("ProtectSystem") &
      ", which this check does not read"
  var dynamic, nnp: bool
  if parseSystemdBoolean(prop("DynamicUser"), dynamic) != srValid:
    return "systemd reports DynamicUser=" & prop("DynamicUser")
  if parseSystemdBoolean(prop("NoNewPrivileges"), nnp) != srValid:
    return "systemd reports NoNewPrivileges=" & prop("NoNewPrivileges")
  confinementProblem(protect, dynamic, nnp, prop("User"), prop("Group"),
                     prop("SupplementaryGroups"), unit, lookup, root)

proc liveReachUnits*(p: SystemProfile; dir = CarriedStateDir;
                     root = "/"): seq[string] =
  ## The services of ``p`` the live cross-check judges again: each one the
  ## static analysis takes as confined (its reach is not everything), while
  ## carried state is on this host (a manifest at ``dir``, pending or
  ## restored), where a unit that is not confined reaches it. Shared by the
  ## add-on's switch and ``runInfraApply`` (§13 decision 59): both hold
  ## these units' starts, reload, and judge them with
  ## ``liveReachProblems`` before any of them runs.
  if not fileExists(dir / ManifestFileName): return
  let lookup = hostAccountLookup(root, p)
  for r in p.resources:
    if r.kind != srkSystemdSystemUnit or r.suCollision == "dropIn" or
        not r.suName.endsWith(".service"):
      continue
    if unitReach(r, p, lookup, root).all: continue   # refused or required
    result.add(r.suName)

proc liveReachProblems*(units: openArray[string]; p: SystemProfile;
                        show: proc (unit: string): Table[string, string] {.closure.};
                        root = "/"): seq[string] =
  ## ``liveConfinementProblem`` for each of ``units`` as systemd loaded
  ## it (``show``: its ``systemctl show`` properties, read after the
  ## switch's daemon-reload and before any start): one problem per unit
  ## that systemd loaded unconfined, or whose properties cannot be read.
  let lookup = hostAccountLookup(root, p)
  for u in units:
    var props: Table[string, string]
    try: props = show(u)
    except CatchableError as e:
      result.add("ECarriedStatePending: " & u & ": its loaded unit cannot " &
        "be read (" & e.msg & ")")
      continue
    let why = liveConfinementProblem(u,
      proc (k: string): string = props.getOrDefault(k), lookup, root)
    if why.len > 0:
      result.add("ECarriedStatePending: " & u & " as systemd loaded it is " &
        "not confined (" & why & "), though its unit text reads as confined")

proc carriedStateInstalled*(dir = CarriedStateDir): bool =
  ## Whether ``install-unit`` installed carried state at ``dir`` (its
  ## marker) and the manifest is there: when the generation's restore
  ## requirements apply.
  fileExists(installedMarkerPath(dir)) and fileExists(dir / ManifestFileName)

proc hostUnitTexts(unit: string; p: SystemProfile; root: string;
                   why: var string; profileLeftOut = false): seq[string] =
  ## A unit the profile does not define, as systemd reads it on the host:
  ## its file -- the first in the unit search path under its name, or its
  ## template's for an instance, links followed -- then its drop-ins
  ## (``unitTexts``, §13 decision 53), the profile's onto it included.
  ## ``why`` set when no file is found or one cannot be read. A masked
  ## unit (a link to ``/dev/null``, or an empty file) is empty: it starts
  ## nothing.
  var candidates = @[unit]
  let at = unit.find('@')
  let dot = unit.rfind('.')
  if at > 0 and dot > at + 1:
    candidates.add(unit[0 .. at] & unit[dot .. ^1])
  for c in candidates:
    for dir in UnitSearchPath:
      let f = under(normalRoot(root), dir) / c
      if not (fileExists(f) or symlinkExists(f)): continue
      if symlinkExists(f):
        var target = ""
        try: target = expandSymlink(f)
        except OSError: discard
        if target == "/dev/null": return @[]
      var base = ""
      try: base = readFile(f)
      except IOError, OSError:
        why = "the unit file " & dir & "/" & c & " cannot be read"
        return
      return unitTexts(unit, base, p, root, why, hostUnit = true,
                       profileLeftOut = profileLeftOut)
  why = "no unit file for " & unit & " in the unit search path"

proc unitClosure(starts: seq[string]; p: SystemProfile; root: string;
                 stopAt: HashSet[string]; uncertain: var seq[string];
                 profileLeftOut = false): HashSet[string] =
  ## Every unit reachable from ``starts`` through what each one starts
  ## (``activatedUnits`` over the host's unit files and drop-ins, as §13
  ## decision 53 reads them, and its dependency directories), not entering
  ## a unit in ``stopAt``. ``uncertain`` gets each unit whose own
  ## dependencies could not be read.
  var queue = starts
  while queue.len > 0:
    let u = queue.pop()
    if u in result or u in stopAt: continue
    result.incl(u)
    let ext = u.rsplit('.', maxsplit = 1)
    let suffix = if ext.len == 2: ext[1] else: ""
    var why = ""
    let texts = hostUnitTexts(u, p, root, why, profileLeftOut)
    if why.len > 0:
      uncertain.add(u)
      continue
    for a in activatedUnits(u, suffix, texts, normalRoot(root)):
      if a.startsWith("<unparsed"):
        uncertain.add(u)
        continue
      if a notin result and a notin stopAt and not a.endsWith(".slice"):
        queue.add(a)

proc bootClosure(p: SystemProfile; root: string): HashSet[string] =
  ## The units the host's boot starts whatever the profile does: the
  ## closure of ``default.target`` over the host's own files, not entering
  ## a unit the profile defines. Empty when the root has no
  ## ``default.target``. The profile's drop-ins are left out wherever they
  ## are: in the profile, and on the host as the ``50-repro-<d>.conf`` an
  ## earlier generation wrote (A13 review round 7, finding 2) -- a unit
  ## only a profile drop-in starts is not the boot's, from the second
  ## apply on as on the first.
  var none: seq[string]
  let defined = definedUnits(p)
  var found = false
  for dir in UnitSearchPath:
    let f = under(normalRoot(root), dir) / "default.target"
    if fileExists(f) or symlinkExists(f): found = true
  if not found: return
  when CarriedMutation == "boot-closure-reads-generation-dropins":
    # FALSIFYING MUTATION: round 6's reading -- an empty profile, so the
    # generation's own drop-ins on the host are read as the host's.
    unitClosure(@["default.target"], SystemProfile(), root, defined, none)
  else:
    unitClosure(@["default.target"], p, root, defined, none,
                profileLeftOut = true)

proc carriedRequirementUnits*(p: SystemProfile; dir = CarriedStateDir;
                              root = "/"): seq[string] =
  ## The units of ``p`` that must require the first-boot restore: while
  ## carried state is installed at ``dir`` (``install-unit`` left its marker
  ## and the manifest is there), every unit whose reach includes a carried
  ## directory -- by path or because it reaches everything -- whatever its
  ## name and whether or not the manifest names it (A13 review round 4,
  ## finding 4). Sorted; empty when no carried state is installed.
  when CarriedMutation == "restore-requirement-by-manifest-only":
    return
  if not carriedStateInstalled(dir):
    return
  let m = readStateManifest(dir)
  let lookup = hostAccountLookup(root, p)
  var units = initHashSet[string]()
  var dropInTargets: seq[string]
  for r in p.resources:
    let u = case r.kind
      of srkSystemdSystemUnit: r.suName
      of srkSystemdSystemTimer: r.stName
      of srkSystemdSystemDropIn:
        # A drop-in for a unit the profile does not define reaches
        # everything: that unit requires the restore through it.
        when CarriedMutation == "restore-requirement-skips-dropin-targets": ""
        else: r.diUnit
      else: ""
    if u.len == 0 or u == CarriedRestoreUnit: continue
    let reach = unitReach(r, p, lookup, root)
    for e in m.entries:
      if e.disposition != sdCarry: continue
      var hit = reach.all
      for q in reach.paths:
        if reaches(q, e.path): hit = true
      if hit:
        units.incl(u)
        if r.kind == srkSystemdSystemDropIn: dropInTargets.add(u)
  # What a profile unit starts that the profile does not define reaches
  # everything (``triggersOutside``), and a requirement on the starting
  # unit does not hold it back: ``Wants=`` and the rest -- written in its
  # file or a drop-in, or linked from a host dependency directory -- queue
  # it as a job of its own, which runs when the restore failed (A13 review
  # round 5, finding 5; round 6, finding 4). So each such unit gets the
  # requirement itself.
  var direct: seq[string]
  let defined = definedUnits(p)
  when CarriedMutation != "restore-requirement-skips-activated":
    for r in p.resources:
      var name, suffix, base: string
      case r.kind
      of srkSystemdSystemUnit:
        if r.suCollision == "dropIn": continue
        name = r.suName
        try: base = renderedSystemUnitContent(r)
        except CatchableError: continue      # reaches everything; above
      of srkSystemdSystemTimer:
        name = r.stName
        base = r.stContent
      else: continue
      let ext = name.rsplit('.', maxsplit = 1)
      suffix = if ext.len == 2: ext[1] else: ""
      var why = ""
      let texts = unitTexts(name, base, p, root, why)
      for a in activatedUnits(name, suffix, texts, normalRoot(root)):
        if a notin defined and not a.endsWith(".slice") and
            a != CarriedRestoreUnit and not a.startsWith("<unparsed"):
          units.incl(a)
          direct.add(a)
  # And what those start in turn (§13 decision 60): the closure through
  # the host's unit files and drop-ins, as decision 53 reads them, of every
  # unit above the profile does not define. A unit the host's boot starts
  # anyway (``bootClosure``) is the distribution's, not started through
  # the profile, and is neither given the requirement nor entered; a unit
  # whose own dependencies cannot be read keeps the requirement it has.
  when CarriedMutation != "restore-requirement-skips-closure":
    let boot = bootClosure(p, root)
    var stop = boot
    for d in defined: stop.incl(d)
    stop.incl(CarriedRestoreUnit)
    var uncertain: seq[string]
    var roots: seq[string]
    for u in direct & dropInTargets:
      if u notin roots: roots.add(u)
    # The roots are given the requirement above whatever ``boot`` says;
    # their own dependencies are followed from here.
    var next: seq[string]
    for u in roots:
      let ext = u.rsplit('.', maxsplit = 1)
      let suffix = if ext.len == 2: ext[1] else: ""
      var why = ""
      let texts = hostUnitTexts(u, p, root, why)
      if why.len > 0: continue
      for a in activatedUnits(u, suffix, texts, normalRoot(root)):
        if not a.startsWith("<unparsed") and not a.endsWith(".slice") and
            a notin stop:
          next.add(a)
    for u in unitClosure(next, p, root, stop, uncertain):
      units.incl(u)
  for u in units: result.add(u)
  result.sort()

proc carriedRequirementText*(p: SystemProfile; dir = CarriedStateDir;
                             root = "/"): string =
  ## The ``systemd.systemDropIn`` resources (profile text) a generation adds
  ## for ``carriedRequirementUnits``: ``RequirementDropInName``, holding
  ## ``restoreRequirementText``. Generation content like any other drop-in:
  ## written, recorded and removed by the switch, and judged by the add-on's
  ## effective-unit check. The name is reserved (``reservedNameProblem``):
  ## a unit whose profile already holds exactly this drop-in -- a stored
  ## generation's text, applied again -- is not given a second one.
  var declared = initHashSet[string]()
  for r in p.resources:
    if r.kind == srkSystemdSystemDropIn and r.diName == RequirementDropInName:
      let why = reservedNameProblem(p)
      if why.len > 0:
        raise newException(ECarriedStatePending, why)
      declared.incl(r.diUnit)
  for u in carriedRequirementUnits(p, dir, root):
    if u in declared: continue
    result.add("\nsystemd.systemDropIn {\n  unit = \"" & u & "\"\n" &
      "  name = \"" & RequirementDropInName & "\"\n" &
      "  content = \"" & restoreRequirementText() & "\"\n}\n")

proc withCarriedRequirements*(profileText: string; dir = CarriedStateDir;
                              root = "/"): string =
  ## ``profileText`` with ``carriedRequirementText`` appended: what every
  ## apply (``runInfraApply``, ``runAddonApply``) and ``repro infra plan``
  ## apply instead of the text they were given, so the boot guarantee of
  ## spec §11.1 follows reach at every apply rather than the names
  ## ``install-unit`` wrote once.
  if not carriedStateInstalled(dir): return profileText
  profileText & carriedRequirementText(parseSystemProfile(profileText), dir,
                                       root)

proc requireCarriedStateReady*(p: SystemProfile; dir = CarriedStateDir;
                               root = "/") =
  ## ``carriedStateRefusal`` as an exception (``ECarriedStatePending``).
  let why = carriedStateRefusal(p, dir, root)
  if why.len > 0:
    raise newException(ECarriedStatePending, why)

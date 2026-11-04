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

proc writeReceipt*(dir: string; r: Table[string, ReceiptEntry]) =
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
  let tmp = receiptPath(dir) & ".tmp"
  writeFile(tmp, $(%*{"restored": o}) & "\n")
  moveFile(tmp, receiptPath(dir))

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
# Reach.
# ---------------------------------------------------------------------------

type UnitReach* = object
  all*: bool                    ## the unit can reach any path
  why*: string                  ## why ``all``
  paths*: seq[string]

proc unitDirectivesOf(text: string): seq[(string, string, string)] =
  var section = ""
  var pending = ""
  for raw in text.splitLines():
    var line = raw
    if pending.len > 0:
      line = pending & " " & line.strip()
      pending = ""
    let t = line.strip()
    if t.len == 0 or t[0] in {'#', ';'}: continue
    if t.endsWith("\\"):
      pending = t[0 ..< t.len - 1].strip(leading = false)
      continue
    if t.startsWith("[") and t.endsWith("]"):
      section = t[1 ..< t.len - 1]
      continue
    let eq = t.find('=')
    if eq <= 0: continue
    result.add((section, t[0 ..< eq].strip(), t[eq + 1 .. ^1].strip()))

proc truthy(v: string): bool =
  v.toLowerAscii() in ["yes", "true", "1", "on"]

proc serviceReach*(name: string; texts: seq[string]): UnitReach =
  ## The paths a service unit can use, from its file and drop-ins.
  var strict = false
  var dynamic = false
  for t in texts:
    for (section, key, value) in unitDirectivesOf(t):
      if section != "Service": continue
      case key
      of "ProtectSystem": strict = value.toLowerAscii() == "strict"
      of "DynamicUser": dynamic = truthy(value)
      of "PermissionsStartOnly":
        # Deprecated, and it runs every ExecStartPre=/Post=/Reload=/Stop=
        # outside the sandbox (systemd.service(5)).
        when CarriedMutation != "reach-ignores-privileged-commands":
          if truthy(value):
            return UnitReach(all: true, why: "PermissionsStartOnly=yes " &
              "(its other commands run outside the sandbox)")
      of "ExecStart", "ExecStartPre", "ExecStartPost", "ExecReload",
         "ExecStop", "ExecStopPost", "ExecCondition":
        # A command whose prefix carries "+" runs with full privileges and
        # without the namespacing (ProtectSystem=, ReadWritePaths=, ...);
        # "!" drops User=/Group=. Neither is confined to the unit's paths
        # (systemd.service(5), "Table 1. Special executable prefixes").
        when CarriedMutation != "reach-ignores-privileged-commands":
          var i = 0
          while i < value.len and value[i] in {'@', '-', ':', '+', '!'}:
            if value[i] in {'+', '!'}:
              return UnitReach(all: true, why: key & "=" & value &
                " (a privileged command, outside the sandbox)")
            inc i
      of "RootDirectory", "RootImage":
        if value.len > 0:
          return UnitReach(all: true, why: key & "=")
      of "StateDirectory", "CacheDirectory", "LogsDirectory",
         "ReadWritePaths", "WorkingDirectory", "BindPaths",
         "BindReadOnlyPaths":
        for w in value.splitWhitespace():
          var p = w
          while p.len > 0 and p[0] in {'-', '+', '!'}: p = p[1 .. ^1]
          if key in ["BindPaths", "BindReadOnlyPaths", "ReadWritePaths",
                     "StateDirectory", "CacheDirectory", "LogsDirectory"]:
            let c = p.find(':')
            if c > 0: p = p[0 ..< c]
          if p.len == 0: continue
          if '%' in p or p.startsWith("~"):
            return UnitReach(all: true, why: key & "=" & w &
              " (a specifier: the path cannot be decided)")
          if not p.startsWith("/"):
            case key
            of "StateDirectory": p = "/var/lib/" & p
            of "CacheDirectory": p = "/var/cache/" & p
            of "LogsDirectory": p = "/var/log/" & p
            else:
              return UnitReach(all: true, why: key & "=" & w)
          result.paths.add(p)
      else: discard
  if not (strict or dynamic):
    return UnitReach(all: true, why: "not confined (no ProtectSystem=strict " &
      "or DynamicUser=yes): it can write anywhere")

proc activatedUnits(name, suffix: string; texts: seq[string]): seq[string] =
  ## The units starting this one also starts: its requirement and want
  ## dependencies, its failure and success handlers, and for a timer or a
  ## path unit the unit it triggers (``Unit=``, else the service of the
  ## same name). Ordering (``After=``/``Before=``) starts nothing.
  var trigger = ""
  for t in texts:
    for (section, key, value) in unitDirectivesOf(t):
      if section == "Unit" and key in ["Wants", "Requires", "Requisite",
          "BindsTo", "Upholds", "OnFailure", "OnSuccess", "PartOf"]:
        for w in value.splitWhitespace():
          if w notin result: result.add(w)
      elif section in ["Timer", "Path"] and key == "Unit":
        trigger = value.strip()
  if suffix in ["timer", "path"]:
    if trigger.len == 0:
      trigger = name[0 ..< name.len - suffix.len] & "service"
    if trigger notin result: result.add(trigger)

proc unitReach*(r: SystemResource; p: SystemProfile): UnitReach =
  ## What a resource of the profile can reach (see the module header).
  case r.kind
  of srkSystemdSystemUnit:
    let ext = r.suName.rsplit('.', maxsplit = 1)
    let suffix = if ext.len == 2: ext[1] else: ""
    if suffix notin ["service", "timer", "target", "path", "slice"]:
      return UnitReach(all: true, why: "a ." & suffix & " unit")
    when CarriedMutation != "reach-dropin-judged-alone":
      if r.suCollision == "dropIn":
        # Installed as a drop-in over a unit some package ships: the
        # unit's own file, which is not in the profile, still runs.
        return UnitReach(all: true, why: "a drop-in over the distribution " &
          "unit " & r.suName)
    var texts: seq[string]
    try: texts.add(renderedSystemUnitContent(r))
    except CatchableError as e:
      return UnitReach(all: true, why: "unit cannot be rendered: " & e.msg)
    for d in p.resources:
      if d.kind == srkSystemdSystemDropIn and d.diUnit == r.suName:
        texts.add(d.diContent)
    # Starting this unit starts what it activates: a unit the profile does
    # not define (a distribution unit, another package's) can reach
    # anything, whatever this one is confined to. One the profile defines
    # is judged on its own.
    when CarriedMutation != "reach-trigger-units-reach-nothing":
      var defined: HashSet[string]
      for d in p.resources:
        if d.kind == srkSystemdSystemUnit and d.suCollision != "dropIn":
          defined.incl(d.suName)
      for u in activatedUnits(r.suName, suffix, texts):
        if u notin defined and not u.endsWith(".slice"):
          return UnitReach(all: true, why: "it starts " & u &
            ", which the profile does not define")
    if suffix != "service":
      # A timer, target, path or slice runs nothing itself; what it
      # activates was judged above.
      return UnitReach()
    result = serviceReach(r.suName, texts)
    for sd in r.suStateDirectories: result.paths.add(sd.path)
  of srkSystemdSystemDropIn:
    # A drop-in over a distribution unit: the unit's own file is not in
    # the profile, so what it can reach is not known here.
    return UnitReach(all: true, why: "a drop-in for " & r.diUnit)
  of srkSystemdUnitState:
    if r.usRunning:
      return UnitReach(all: true, why: "a distribution unit started")
  else: discard

proc reaches(p, d: string): bool =
  let a = p.strip(leading = false, chars = {'/'})
  let b = d.strip(leading = false, chars = {'/'})
  a == b or (b & "/").startsWith(a & "/") or (a & "/").startsWith(b & "/")

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

proc carriedStateRefusal*(p: SystemProfile; dir = CarriedStateDir;
                          root = "/"): string =
  ## Why an apply of ``p`` must not run here, or "" (see the module
  ## header). Fails closed: carried state that cannot be read refuses.
  when CarriedMutation == "apply-ignores-carried-state":
    return ""
  when CarriedMutation != "apply-ignores-hold":
    let held = heldUnits(root)
    if held.len > 0:
      return "ECarriedStatePending: a state backup holds " & held.join(", ") &
        " on this host (spec §11.1); nothing is applied until it is " &
        "released (`repro system addon state release --profile <file>`)"
  if not fileExists(dir / ManifestFileName): return ""
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
  for r in p.resources:
    let reach = unitReach(r, p)
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

proc requireCarriedStateReady*(p: SystemProfile; dir = CarriedStateDir;
                               root = "/") =
  ## ``carriedStateRefusal`` as an exception (``ECarriedStatePending``).
  let why = carriedStateRefusal(p, dir, root)
  if why.len > 0:
    raise newException(ECarriedStatePending, why)

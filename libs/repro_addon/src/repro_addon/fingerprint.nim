## The base fingerprint of a distribution-managed host.
##
## Add-on mode's central promise is "do no harm": bootstrapping the add-on,
## applying generations and uninstalling it leaves the base exactly as it
## was, apart from an enumerated list of exceptions. That promise is only
## testable if "the base" is something a program can record and compare.
## This module records it.
##
## A fingerprint is a sorted set of ``(component, key, value)`` records.
## Each component is one observable aspect of the host:
##
## ==================  ====================================================
## ``dpkg-status``     one record per installed package (``name:arch``),
##                     valued by version and dpkg status
## ``etc``             one record per inode under ``/etc``: type, mode,
##                     owner and the SHA-256 of a file's bytes or a link's
##                     target. Modification times are deliberately not
##                     recorded: they change on every rewrite of identical
##                     bytes and say nothing about the base's behaviour.
## ``unit-files``      every unit file systemd knows, valued by its
##                     enablement state (``list-unit-files``)
## ``active-units``    every loaded unit whose ActiveState is ``active`` or
##                     ``failed``
## ``accounts``        ``/etc/passwd`` and ``/etc/group`` entries, parsed
## ``sysctl``          every readable value under ``/proc/sys``
## ``mounts``          ``/proc/self/mountinfo``, keyed by mount point
## ``diversions``      ``/var/lib/dpkg/diversions``
## ``listeners``       listening TCP and bound, unconnected UDP sockets
## ``addon-roots``     whether the add-on's own roots (``/repro``,
##                     ``/var/lib/repro``) exist, and what they are
## ==================  ====================================================
##
## *Determinism.* The same host in the same state produces byte-identical
## output: records are sorted bytewise, the text is locale-independent, and
## the few values the kernel or systemd change on their own between two
## reads (entropy counters, a per-read random UUID, the dentry cache size,
## on-demand mounts, …) are excluded by an explicit, enumerated list below,
## each entry with its reason. Nothing is excluded by pattern guesswork: a
## volatile value that is not on the list makes two baseline fingerprints
## differ, which the gates check first, so an incomplete list is a loud
## test-bed failure rather than a silently weakened comparison.
##
## *Read-only.* Collecting a fingerprint writes nothing: it reads files and
## ``/proc``, and runs ``systemctl list-unit-files`` / ``list-units``, both
## of which only query PID 1.

import std/[algorithm, os, posix, sets, strutils, tables]

import nimcrypto/[hash, sha2]

import ./host_exec
import ./linux_fs

type
  FingerprintComponent* = enum
    fcDpkgStatus = "dpkg-status"
    fcEtc = "etc"
    fcUnitFiles = "unit-files"
    fcActiveUnits = "active-units"
    fcAccounts = "accounts"
    fcSysctl = "sysctl"
    fcMounts = "mounts"
    fcDiversions = "diversions"
    fcListeners = "listeners"
    fcAddonRoots = "addon-roots"

  FingerprintRecord* = object
    component*: FingerprintComponent
    key*: string
    value*: string

  Fingerprint* = object
    ## Sorted by ``(component, key)``; keys are unique per component.
    records*: seq[FingerprintRecord]

  DiffOp* = enum
    doAdded = "+"
    doRemoved = "-"
    doChanged = "~"

  DiffEntry* = object
    op*: DiffOp
    component*: FingerprintComponent
    key*: string
    before*: string       ## "" for an added record
    after*: string        ## "" for a removed record

  Expectation* = object
    ## One record the caller expects in a diff (a ledger-derived delta).
    ## ``value`` is matched against the record's ``after`` value (for
    ## ``doAdded`` / ``doChanged``) or ``before`` (for ``doRemoved``);
    ## ``"*"`` matches any value. An ``optional`` expectation is one the
    ## diff MAY carry: it is never missing, and its ``key`` may be a glob
    ## (``net.ipv4.conf.*.forwarding``), so a side effect whose exact keys
    ## the add-on cannot enumerate (the kernel propagating a forwarding
    ## switch to every interface) is accounted for without being invented.
    op*: DiffOp
    component*: FingerprintComponent
    key*: string
    value*: string
    optional*: bool

  ExceptionRule* = object
    ## An enumerated, permitted difference: ``component`` plus a key glob
    ## (``*`` matches any run of characters, ``?`` one character).
    component*: FingerprintComponent
    keyGlob*: string

  FingerprintError* = object of CatchableError

  CollectOptions* = object
    ## ``root`` is prepended to every FILE the collector reads, so the
    ## file-backed components can be exercised against a fixture tree.
    ## The live components (units, sysctl, mounts, listeners) describe the
    ## running kernel and PID 1 and are collected only when ``live`` is
    ## true.
    root*: string
    live*: bool

const
  FingerprintHeader* = "# repro-addon-fingerprint v1"

  AddonRootPaths* = ["/repro", "/var/lib/repro", "/run/repro"]
    ## The add-on's own roots outside ``/etc`` (``/etc/repro`` is covered
    ## by the ``etc`` component).

  VolatileSysctlKeys* = [
    # Each of these changes between two reads on an idle host; none is
    # configuration. They are the only sysctl values excluded.
    "kernel.random.uuid",            # a fresh random UUID on every read
    "kernel.random.boot_id",         # differs per boot by definition
    "kernel.random.entropy_avail",   # entropy pool fill level
    "kernel.ns_last_pid",            # last PID allocated
    "kernel.pty.nr",                 # number of open ptys (each SSH session)
    "kernel.perf_event_max_sample_rate", # lowered by the kernel itself when
                                     # perf interrupts run long
    "fs.dentry-state",               # dentry cache occupancy
    "fs.inode-nr",                   # inode cache occupancy
    "fs.inode-state",                # inode cache occupancy
    "fs.file-nr",                    # open file handles
    "fs.aio-nr",                     # in-flight AIO requests
    "net.netfilter.nf_conntrack_count", # live connection-tracking entries
    "fs.quota.allocated_dquots", "fs.quota.cache_hits", "fs.quota.drops",
    "fs.quota.free_dquots", "fs.quota.lookups", "fs.quota.reads",
    "fs.quota.syncs", "fs.quota.writes", # quota statistics counters
  ]

  VolatileSysctlPrefixes* = [
    # ``/proc/sys/fs/binfmt_misc`` is an automount point: reading below it
    # mounts binfmt_misc, which would make the fingerprint change the
    # mount table it records.
    "fs.binfmt_misc",
    # The ZFS SPL allocator's live counters (kmem slab usage). They appear
    # wherever the kernel has the zfs module loaded -- inside a container on
    # a ZFS-backed host, for one -- and move with every allocation.
    "kernel.spl.kmem",
  ]

  VolatileMountPrefixes* = [
    # Per-login and per-service runtime mounts. Each SSH session gets
    # ``/run/user/<uid>``; each service started with credentials gets
    # ``/run/credentials/<unit>``. Neither is base configuration.
    "/run/user/", "/run/credentials/",
    # An automount trigger that becomes a real mount on first access.
    "/proc/sys/fs/binfmt_misc",
  ]

  VolatileUnitSuffixes* = [".scope", ".slice", ".device"]
    ## Runtime-only unit types: sessions, cgroup slices and udev devices
    ## come and go with logins and hardware, not with configuration.

  VolatileActiveUnits* = [
    # Started on demand (socket or D-Bus activation) and exiting by
    # themselves once idle, so whether one is active depends only on how
    # long ago something last asked it a question. Their unit-file state is
    # still recorded; only their ActiveState is not. A unit missing from
    # this list shows up as a determinism-guard failure, never as a
    # silently weaker comparison.
    "systemd-fsckd.service",       # fsck progress multiplexer (socket)
    "systemd-hostnamed.service",   # hostnamectl backend (D-Bus, idle exit)
    "systemd-timedated.service",   # timedatectl backend (D-Bus, idle exit)
    "systemd-localed.service",     # localectl backend (D-Bus, idle exit)
    "packagekit.service",          # PackageKit (Ubuntu; D-Bus, exits after
                                   # five idle minutes)
  ]

  VolatileUnitPrefixes* = [
    # Per-login units created by logind for every session, including the
    # SSH sessions the test bed itself opens.
    "user@", "user-runtime-dir@",
    # Mount units for the volatile mount points above.
    "run-user-", "run-credentials-",
    "proc-sys-fs-binfmt_misc",
  ]

# ---------------------------------------------------------------------------
# Escaping: one record per line, three tab-separated fields.
# ---------------------------------------------------------------------------

proc escapeField*(s: string): string =
  ## Make ``s`` safe as one tab-separated field on one line. Only the
  ## three characters that would break the framing are escaped.
  for c in s:
    case c
    of '\\': result.add("\\\\")
    of '\t': result.add("\\t")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    else: result.add(c)

proc unescapeField*(s: string): string =
  var i = 0
  while i < s.len:
    if s[i] == '\\' and i + 1 < s.len:
      case s[i + 1]
      of '\\': result.add('\\')
      of 't': result.add('\t')
      of 'n': result.add('\n')
      of 'r': result.add('\r')
      else:
        raise newException(FingerprintError,
          "invalid escape '\\" & s[i + 1] & "' in fingerprint field")
      i += 2
    else:
      result.add(s[i])
      inc i

proc componentFromString*(s: string): FingerprintComponent =
  for c in FingerprintComponent:
    if $c == s:
      return c
  raise newException(FingerprintError, "unknown fingerprint component: " & s)

# ---------------------------------------------------------------------------
# Building a fingerprint.
# ---------------------------------------------------------------------------

proc cmpRecord(a, b: FingerprintRecord): int =
  result = cmp(ord(a.component), ord(b.component))
  if result == 0:
    result = cmp(a.key, b.key)

proc add*(fp: var Fingerprint; component: FingerprintComponent;
          key, value: string) =
  fp.records.add(FingerprintRecord(component: component, key: key,
                                   value: value))

proc normalise*(fp: var Fingerprint) =
  ## Sort, and refuse duplicate keys: a duplicate means a parser produced
  ## an ambiguous key, which would make the diff depend on record order.
  fp.records.sort(cmpRecord)
  for i in 1 ..< fp.records.len:
    if fp.records[i].component == fp.records[i - 1].component and
        fp.records[i].key == fp.records[i - 1].key:
      raise newException(FingerprintError,
        "duplicate fingerprint key " & $fp.records[i].component & " " &
        fp.records[i].key)

proc render*(fp: Fingerprint): string =
  ## The canonical text form. Byte-identical for equal fingerprints.
  result = FingerprintHeader & "\n"
  for r in fp.records:
    result.add($r.component)
    result.add('\t')
    result.add(escapeField(r.key))
    result.add('\t')
    result.add(escapeField(r.value))
    result.add('\n')

proc parseFingerprint*(text: string): Fingerprint =
  ## Inverse of ``render``. Strict: a wrong header, a malformed line or a
  ## duplicate key is an error, never a silently dropped record.
  let lines = text.splitLines()
  if lines.len == 0 or lines[0] != FingerprintHeader:
    raise newException(FingerprintError,
      "not a repro-addon fingerprint (expected header '" &
      FingerprintHeader & "')")
  for i in 1 ..< lines.len:
    let line = lines[i]
    if line.len == 0:
      continue
    let parts = line.split('\t')
    if parts.len != 3:
      raise newException(FingerprintError,
        "malformed fingerprint line " & $(i + 1) & ": expected 3 fields")
    result.add(componentFromString(parts[0]), unescapeField(parts[1]),
               unescapeField(parts[2]))
  result.normalise()

proc sha256Hex*(data: string): string =
  toLowerAscii($sha256.digest(data))

proc sha256OfFile*(path: string): string =
  ## Streamed, so a large file under /etc does not have to fit in memory.
  var ctx: sha256
  ctx.init()
  var f: File
  if not open(f, path, fmRead):
    raise newException(IOError, "cannot open " & path)
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

# ---------------------------------------------------------------------------
# Pure parsers (unit-tested against captured fixtures).
# ---------------------------------------------------------------------------

proc parseDpkgStatus*(text: string): seq[tuple[key, value: string]] =
  ## One entry per stanza of ``/var/lib/dpkg/status``: key
  ## ``<Package>:<Architecture>``, value ``<Version> <Status>``. A stanza
  ## without a Package field is malformed and raises.
  var pkg, arch, version, status = ""
  var inStanza = false
  proc flush(res: var seq[tuple[key, value: string]]) =
    if not inStanza: return
    if pkg.len == 0:
      raise newException(FingerprintError,
        "dpkg status stanza without a Package field")
    res.add((key: pkg & ":" & (if arch.len > 0: arch else: "-"),
             value: (if version.len > 0: version else: "-") & " " & status))
    pkg = ""; arch = ""; version = ""; status = ""
    inStanza = false
  for line in text.splitLines():
    if line.strip().len == 0:
      flush(result)
      continue
    inStanza = true
    if line[0] in {' ', '\t'}:
      continue                      # continuation of a multi-line field
    let colon = line.find(':')
    if colon <= 0: continue
    let field = line[0 ..< colon]
    let value = line[colon + 1 .. ^1].strip()
    case field
    of "Package": pkg = value
    of "Architecture": arch = value
    of "Version": version = value
    of "Status": status = value
    else: discard
  flush(result)

proc parseDiversions*(text: string): seq[tuple[key, value: string]] =
  ## ``/var/lib/dpkg/diversions`` is a sequence of line triples:
  ## original path, diverted-to path, diverting package (``:`` for a
  ## local diversion).
  let lines = text.splitLines()
  var ls: seq[string]
  for l in lines:
    if l.len > 0: ls.add(l)
  if ls.len mod 3 != 0:
    raise newException(FingerprintError,
      "dpkg diversions file has " & $ls.len &
      " non-empty lines, not a multiple of 3")
  var i = 0
  while i < ls.len:
    result.add((key: ls[i], value: ls[i + 1] & " " & ls[i + 2]))
    i += 3

proc parsePasswd*(text: string): seq[tuple[key, value: string]] =
  ## ``/etc/passwd``: key ``user:<name>``, value
  ## ``<uid>:<gid>:<gecos>:<home>:<shell>``. The password field is not
  ## recorded (it is ``x`` on every shadow-using host).
  for line in text.splitLines():
    if line.len == 0 or line[0] == '#': continue
    let f = line.split(':')
    if f.len < 7:
      raise newException(FingerprintError, "malformed passwd line: " & line)
    result.add((key: "user:" & f[0],
                value: f[2] & ":" & f[3] & ":" & f[4] & ":" & f[5] & ":" & f[6]))

proc parseGroup*(text: string): seq[tuple[key, value: string]] =
  ## ``/etc/group``: key ``group:<name>``, value ``<gid>:<members>``.
  for line in text.splitLines():
    if line.len == 0 or line[0] == '#': continue
    let f = line.split(':')
    if f.len < 4:
      raise newException(FingerprintError, "malformed group line: " & line)
    result.add((key: "group:" & f[0], value: f[2] & ":" & f[3]))

proc unescapeMountField(s: string): string =
  ## mountinfo escapes space, tab, newline and backslash as ``\ooo``.
  var i = 0
  while i < s.len:
    if s[i] == '\\' and i + 3 < s.len and s[i + 1] in {'0'..'7'}:
      try:
        result.add(char(parseOctInt(s[i + 1 .. i + 3])))
        i += 4
        continue
      except ValueError:
        discard
    result.add(s[i])
    inc i

proc isVolatileMount*(mountPoint: string): bool =
  for p in VolatileMountPrefixes:
    if mountPoint == p.strip(leading = false, chars = {'/'}) or
        mountPoint.startsWith(p):
      return true
  false

proc parseMountinfo*(text: string): seq[tuple[key, value: string]] =
  ## ``/proc/self/mountinfo``. Key: the mount point, with ``#<n>`` appended
  ## to the second and later mounts stacked on the same point (in table
  ## order, which is mount order). Value: filesystem type, source, the
  ## per-mount options and the superblock options. Mount and parent ids are
  ## left out: they are allocation order, not configuration.
  var seen = initCountTable[string]()
  for line in text.splitLines():
    if line.len == 0: continue
    let sep = line.find(" - ")
    if sep < 0:
      raise newException(FingerprintError, "malformed mountinfo line: " & line)
    let pre = line[0 ..< sep].splitWhitespace()
    let post = line[sep + 3 .. ^1].splitWhitespace()
    if pre.len < 6 or post.len < 3:
      raise newException(FingerprintError, "malformed mountinfo line: " & line)
    let mountPoint = unescapeMountField(pre[4])
    if isVolatileMount(mountPoint):
      continue
    let mountOpts = pre[5]
    let fstype = post[0]
    let source = unescapeMountField(post[1])
    let superOpts = post[2]
    seen.inc(mountPoint)
    let n = seen[mountPoint]
    let key = if n == 1: mountPoint else: mountPoint & "#" & $n
    result.add((key: key,
                value: fstype & " " & source & " " & mountOpts & " " & superOpts))

proc hexToAddress(hex: string; v6: bool): string =
  ## ``/proc/net/{tcp,udp}{,6}`` addresses are hex in host byte order,
  ## 32-bit word by 32-bit word. Every architecture in the add-on's base
  ## matrix (amd64, arm64, armhf) is little-endian, which ``wordBytes``
  ## assumes.
  proc wordBytes(w: string): array[4, int] =
    # little-endian host: the word's bytes appear reversed
    let v = parseHexInt(w)
    [v and 0xFF, (v shr 8) and 0xFF, (v shr 16) and 0xFF, (v shr 24) and 0xFF]
  if not v6:
    let b = wordBytes(hex)
    return $b[0] & "." & $b[1] & "." & $b[2] & "." & $b[3]
  var bytes: seq[int]
  for i in 0 ..< 4:
    let b = wordBytes(hex[i * 8 ..< i * 8 + 8])
    for x in b: bytes.add(x)
  var groups: seq[string]
  for i in 0 ..< 8:
    groups.add(toHex(bytes[2 * i] * 256 + bytes[2 * i + 1], 4).toLowerAscii())
  "[" & groups.join(":") & "]"

proc parseProcNet*(text, proto: string;
                   ephemeralLo = 0, ephemeralHi = 0): seq[tuple[key, value: string]] =
  ## Listening sockets from one ``/proc/net/<proto>`` table. TCP: state
  ## ``0A`` (LISTEN). UDP: state ``07`` with a zero remote address, i.e.
  ## bound and unconnected -- a server socket, not an in-flight query --
  ## except one bound inside the kernel's ephemeral range
  ## ``[ephemeralLo, ephemeralHi]`` (``net.ipv4.ip_local_port_range``): a
  ## resolver or DHCP client that bound an unconnected UDP socket to a
  ## port the kernel chose is a transient client, and the port it got is
  ## what makes two reads differ. A server listens on a port it chose.
  ## Key ``<proto> <addr>:<port>``; repeated binds (SO_REUSEPORT) are
  ## counted in the value.
  let v6 = proto.endsWith("6")
  var counts = initCountTable[string]()
  var order: seq[string]
  var first = true
  for line in text.splitLines():
    if first:
      first = false
      continue
    let f = line.splitWhitespace()
    if f.len < 4: continue
    let local = f[1].split(':')
    let remote = f[2].split(':')
    let state = f[3]
    if local.len != 2 or remote.len != 2: continue
    let port = parseHexInt(local[1])
    let listening =
      if proto.startsWith("tcp"): state == "0A"
      else: state == "07" and remote[1] == "0000" and
            remote[0].allCharsInSet({'0'}) and
            not (ephemeralHi > 0 and port >= ephemeralLo and port <= ephemeralHi)
    if not listening: continue
    let key = proto & " " & hexToAddress(local[0], v6) & ":" & $port
    if key notin counts: order.add(key)
    counts.inc(key)
  for k in order:
    result.add((key: k, value: "x" & $counts[k]))

proc isVolatileUnit*(name: string): bool =
  for s in VolatileUnitSuffixes:
    if name.endsWith(s): return true
  for p in VolatileUnitPrefixes:
    if name.startsWith(p): return true
  false

proc parseListUnitFiles*(text: string): seq[tuple[key, value: string]] =
  ## ``systemctl list-unit-files --no-legend --no-pager --full``:
  ## ``<unit> <state> [<preset>]``.
  for line in text.splitLines():
    let f = line.splitWhitespace()
    if f.len < 2: continue
    if isVolatileUnit(f[0]): continue
    result.add((key: f[0], value: f[1]))

proc parseListUnits*(text: string): seq[tuple[key, value: string]] =
  ## ``systemctl list-units --all --plain --no-legend --no-pager --full``:
  ## ``<unit> <load> <active> <sub> <description…>``. Only units that are
  ## ``active`` or ``failed`` are recorded: inactive units are loaded and
  ## unloaded by systemd's garbage collector as they are referenced, and
  ## transitional states (``activating`` / ``deactivating``) are by
  ## definition between two observations.
  for line in text.splitLines():
    var l = line.strip()
    # Failed units are prefixed with a marker in some systemd versions.
    if l.startsWith("●") : l = l["●".len .. ^1].strip()
    if l.startsWith("*"): l = l[1 .. ^1].strip()
    let f = l.splitWhitespace()
    if f.len < 4: continue
    if isVolatileUnit(f[0]) or f[0] in VolatileActiveUnits: continue
    if f[2] in ["active", "failed"]:
      result.add((key: f[0], value: f[2]))

proc isVolatileSysctl*(key: string): bool =
  if key in VolatileSysctlKeys: return true
  for p in VolatileSysctlPrefixes:
    if key == p or key.startsWith(p & "."): return true
  false

# ---------------------------------------------------------------------------
# Collection.
# ---------------------------------------------------------------------------

proc rootPath(opts: CollectOptions; path: string): string =
  if opts.root.len == 0 or opts.root == "/": path
  else: opts.root & path

proc modeString(m: Mode): string =
  toOct(int(m) and 0o7777, 4)

proc etcEntryValue*(path: string): string =
  ## ``<type> <mode> <uid>:<gid> <payload>``: ``f`` files carry
  ## ``sha256:<hex>``, ``l`` links their target, ``d`` directories and
  ## other inode types nothing.
  var st: Stat
  if lstat(path.cstring, st) != 0:
    raise newException(OSError, "lstat failed: " & path)
  let owner = $st.st_uid & ":" & $st.st_gid
  if S_ISLNK(st.st_mode):
    "l " & modeString(st.st_mode) & " " & owner & " -> " & expandSymlink(path)
  elif S_ISDIR(st.st_mode):
    "d " & modeString(st.st_mode) & " " & owner
  elif S_ISREG(st.st_mode):
    "f " & modeString(st.st_mode) & " " & owner & " sha256:" & sha256OfFile(path)
  else:
    "o " & modeString(st.st_mode) & " " & owner

proc collectEtc(fp: var Fingerprint; opts: CollectOptions) =
  let etc = rootPath(opts, "/etc")
  if not dirExists(etc):
    raise newException(FingerprintError, "no /etc at " & etc)
  fp.add(fcEtc, "/etc", etcEntryValue(etc))
  # walkDirRec does not follow directory symlinks with this filter: a
  # symlink to a directory is recorded as a link, never descended.
  for path in walkDirRec(etc, yieldFilter = {pcFile, pcLinkToFile, pcDir,
                                             pcLinkToDir},
                         followFilter = {pcDir}, relative = true,
                         skipSpecial = false):
    let abs = etc / path
    fp.add(fcEtc, "/etc/" & path, etcEntryValue(abs))

proc collectFileComponent(fp: var Fingerprint; comp: FingerprintComponent;
                          entries: seq[tuple[key, value: string]]) =
  for e in entries:
    fp.add(comp, e.key, e.value)

proc collectSysctl(fp: var Fingerprint) =
  ## Walk ``/proc/sys``; record every value root can read. Unreadable
  ## entries (write-only knobs, ``stable_secret`` before it is set) are
  ## skipped, as are the enumerated volatile keys.
  proc walk(fp: var Fingerprint; dir, keyPrefix: string) =
    var entries: seq[(PathComponent, string)]
    for kind, path in walkDir(dir, relative = true):
      entries.add((kind, path))
    entries.sort(proc(a, b: (PathComponent, string)): int = cmp(a[1], b[1]))
    for (kind, name) in entries:
      let key = if keyPrefix.len == 0: name else: keyPrefix & "." & name
      if isVolatileSysctl(key): continue
      let abs = dir / name
      if kind == pcDir:
        walk(fp, abs, key)
      elif kind == pcFile:
        var st: Stat
        if stat(abs.cstring, st) != 0: continue
        if (int(st.st_mode) and 0o400) == 0: continue
        var value = ""
        try:
          value = readFile(abs)
        except IOError, OSError:
          continue
        fp.add(fcSysctl, key, value.splitWhitespace().join(" "))
  walk(fp, "/proc/sys", "")

proc collectUnits(fp: var Fingerprint) =
  let files = runSystemctl(["list-unit-files", "--no-legend", "--no-pager",
                            "--full"])
  if files.exitCode != 0:
    raise newException(FingerprintError,
      "systemctl list-unit-files failed: " & files.output.strip())
  for e in parseListUnitFiles(files.output):
    fp.add(fcUnitFiles, e.key, e.value)
  let units = runSystemctl(["list-units", "--all", "--plain", "--no-legend",
                            "--no-pager", "--full"])
  if units.exitCode != 0:
    raise newException(FingerprintError,
      "systemctl list-units failed: " & units.output.strip())
  for e in parseListUnits(units.output):
    fp.add(fcActiveUnits, e.key, e.value)

proc addonRootValue*(path: string): string =
  ## The ``addon-roots`` record value of ``path``: ``absent``, or the
  ## directory's kind, mode and owner. Bootstrap records it for a root it
  ## takes over (spec §6.1), so the ledger's base value is the fingerprint's.
  var st: Stat
  if lstat(path.cstring, st) != 0:
    return "absent"
  if S_ISDIR(st.st_mode):
    var kind = "dir"
    if isBtrfs(path):
      # Inode 256 is the root of a btrfs subvolume.
      kind = if isBtrfsSubvolume(path): "btrfs-subvolume" else: "btrfs-dir"
    return kind & " " & modeString(st.st_mode) & " " & $st.st_uid & ":" &
           $st.st_gid
  "other " & modeString(st.st_mode)

proc collectFingerprint*(opts = CollectOptions(root: "/", live: true)):
    Fingerprint =
  ## Record the host. Raises ``FingerprintError`` when a source the
  ## fingerprint promises cannot be read -- a fingerprint with a silently
  ## missing component would compare equal to anything.
  collectEtc(result, opts)
  let status = rootPath(opts, "/var/lib/dpkg/status")
  if fileExists(status):
    collectFileComponent(result, fcDpkgStatus, parseDpkgStatus(readFile(status)))
  let diversions = rootPath(opts, "/var/lib/dpkg/diversions")
  if fileExists(diversions):
    collectFileComponent(result, fcDiversions,
                         parseDiversions(readFile(diversions)))
  let passwd = rootPath(opts, "/etc/passwd")
  if not fileExists(passwd):
    raise newException(FingerprintError, "no /etc/passwd at " & passwd)
  collectFileComponent(result, fcAccounts, parsePasswd(readFile(passwd)))
  let group = rootPath(opts, "/etc/group")
  if not fileExists(group):
    raise newException(FingerprintError, "no /etc/group at " & group)
  collectFileComponent(result, fcAccounts, parseGroup(readFile(group)))
  for p in AddonRootPaths:
    result.add(fcAddonRoots, p, addonRootValue(rootPath(opts, p)))
  if opts.live:
    collectUnits(result)
    collectSysctl(result)
    collectFileComponent(result, fcMounts,
                         parseMountinfo(readFile("/proc/self/mountinfo")))
    var ephLo, ephHi = 0
    try:
      let r = readFile("/proc/sys/net/ipv4/ip_local_port_range").splitWhitespace()
      if r.len == 2:
        ephLo = parseInt(r[0]); ephHi = parseInt(r[1])
    except IOError, OSError, ValueError:
      discard
    for proto in ["tcp", "tcp6", "udp", "udp6"]:
      let p = "/proc/net/" & proto
      if fileExists(p):
        collectFileComponent(result, fcListeners,
                             parseProcNet(readFile(p), proto, ephLo, ephHi))
  result.normalise()

# ---------------------------------------------------------------------------
# Diff, exceptions and expectations.
# ---------------------------------------------------------------------------

proc diff*(before, after: Fingerprint): seq[DiffEntry] =
  ## Every record added, removed or changed, sorted by component and key.
  var a = initTable[(FingerprintComponent, string), string]()
  var b = initTable[(FingerprintComponent, string), string]()
  for r in before.records: a[(r.component, r.key)] = r.value
  for r in after.records: b[(r.component, r.key)] = r.value
  for r in before.records:
    let k = (r.component, r.key)
    if k notin b:
      result.add(DiffEntry(op: doRemoved, component: r.component, key: r.key,
                           before: r.value))
    elif b[k] != r.value:
      result.add(DiffEntry(op: doChanged, component: r.component, key: r.key,
                           before: r.value, after: b[k]))
  for r in after.records:
    if (r.component, r.key) notin a:
      result.add(DiffEntry(op: doAdded, component: r.component, key: r.key,
                           after: r.value))
  result.sort(proc(x, y: DiffEntry): int =
    result = cmp(ord(x.component), ord(y.component))
    if result == 0: result = cmp(x.key, y.key))

proc renderDiff*(entries: seq[DiffEntry]): string =
  for e in entries:
    case e.op
    of doAdded:
      result.add("+ " & $e.component & "\t" & escapeField(e.key) & "\t" &
                 escapeField(e.after) & "\n")
    of doRemoved:
      result.add("- " & $e.component & "\t" & escapeField(e.key) & "\t" &
                 escapeField(e.before) & "\n")
    of doChanged:
      result.add("~ " & $e.component & "\t" & escapeField(e.key) & "\t" &
                 escapeField(e.before) & " => " & escapeField(e.after) & "\n")

proc globMatch*(pattern, s: string): bool =
  ## ``*`` and ``?`` only; no character classes. Iterative with
  ## backtracking to the last star, so it is linear in practice.
  var p, i = 0
  var starP = -1
  var starI = 0
  while i < s.len:
    if p < pattern.len and (pattern[p] == '?' or pattern[p] == s[i]):
      inc p; inc i
    elif p < pattern.len and pattern[p] == '*':
      starP = p; starI = i; inc p
    elif starP >= 0:
      p = starP + 1; inc starI; i = starI
    else:
      return false
  while p < pattern.len and pattern[p] == '*': inc p
  p == pattern.len

proc parseExceptionRule*(spec: string): ExceptionRule =
  ## ``<component>:<key glob>``, e.g. ``accounts:user:systemd-*``.
  let colon = spec.find(':')
  if colon <= 0:
    raise newException(FingerprintError,
      "exception must be '<component>:<key glob>': " & spec)
  ExceptionRule(component: componentFromString(spec[0 ..< colon]),
                keyGlob: spec[colon + 1 .. ^1])

proc applyExceptions*(entries: seq[DiffEntry];
                      rules: openArray[ExceptionRule]): seq[DiffEntry] =
  ## Drop every entry an enumerated exception permits.
  for e in entries:
    var permitted = false
    for r in rules:
      if r.component == e.component and globMatch(r.keyGlob, e.key):
        permitted = true
        break
    if not permitted:
      result.add(e)

proc renderExpectation*(e: Expectation): string =
  ## ``<op>[?] <component>\t<key>\t<value>``; ``?`` marks an optional one.
  $e.op & (if e.optional: "? " else: " ") & $e.component & "\t" &
    escapeField(e.key) & "\t" & escapeField(e.value)

proc parseExpectations*(text: string): seq[Expectation] =
  ## One expectation per line: ``<op> <component>\t<key>\t<value>``.
  for raw in text.splitLines():
    if raw.len == 0 or raw.startsWith("#"): continue
    let optional = raw.len > 2 and raw[1] == '?'
    let head = if optional: 3 else: 2
    if raw.len < head + 1 or raw[head - 1] != ' ':
      raise newException(FingerprintError, "malformed expectation: " & raw)
    let op = case raw[0]
      of '+': doAdded
      of '-': doRemoved
      of '~': doChanged
      else:
        raise newException(FingerprintError, "malformed expectation op: " & raw)
    let parts = raw[head .. ^1].split('\t')
    if parts.len != 3:
      raise newException(FingerprintError, "malformed expectation: " & raw)
    result.add(Expectation(op: op, component: componentFromString(parts[0]),
                           key: unescapeField(parts[1]),
                           value: unescapeField(parts[2]), optional: optional))

type
  ExpectationReport* = object
    unexpected*: seq[DiffEntry]       ## in the diff, not expected
    missing*: seq[Expectation]        ## expected, not in the diff
    mismatched*: seq[tuple[expected: Expectation; actual: DiffEntry]]

proc ok*(r: ExpectationReport): bool =
  r.unexpected.len == 0 and r.missing.len == 0 and r.mismatched.len == 0

proc matchExpectations*(entries: seq[DiffEntry];
                        expected: seq[Expectation]): ExpectationReport =
  ## The diff must equal the expectation set exactly: every expected record
  ## present with the expected op and value, and nothing else.
  var byKey = initTable[(FingerprintComponent, string), DiffEntry]()
  for e in entries: byKey[(e.component, e.key)] = e
  var used = initHashSet[(FingerprintComponent, string)]()
  var optionals: seq[Expectation]
  for x in expected:
    if x.optional:
      optionals.add(x)        # matched against what is left, by glob
      continue
    let k = (x.component, x.key)
    if k notin byKey:
      result.missing.add(x)
      continue
    let actual = byKey[k]
    used.incl(k)
    let value = if x.op == doRemoved: actual.before else: actual.after
    if actual.op != x.op or (x.value != "*" and x.value != value):
      result.mismatched.add((expected: x, actual: actual))
  for e in entries:
    if (e.component, e.key) in used: continue
    var accepted = false
    for x in optionals:
      let value = if x.op == doRemoved: e.before else: e.after
      if x.component == e.component and globMatch(x.key, e.key) and
          (x.op == e.op or x.value == "*") and
          (x.value == "*" or x.value == value):
        accepted = true
        break
    if not accepted:
      result.unexpected.add(e)

proc renderExpectationReport*(r: ExpectationReport): string =
  for e in r.unexpected:
    result.add("unexpected: " & renderDiff(@[e]))
  for x in r.missing:
    result.add("missing:    " & renderExpectation(x) & "\n")
  for m in r.mismatched:
    result.add("mismatched: expected " & renderExpectation(m.expected) &
               " got " & renderDiff(@[m.actual]))

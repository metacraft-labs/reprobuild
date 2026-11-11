## ``serviceFloor``: the hardening a ``systemd.systemUnit`` gets by default
## on an add-on host, and on any host whose profile asks for it with
## ``hardening = "serviceFloor"``.
##
## The floor is the service-confinement baseline of the deployment security
## policy (``ProtectSystem=strict``, private ``/tmp`` and devices, no new
## privileges, the kernel and clock protections, a ``@system-service``
## syscall filter without ``@privileged``, no capabilities, no
## write-and-execute memory, a private umask), plus one control specific to
## a host whose ``/usr`` belongs to the distribution: **execution is confined
## to the unit's closure**. ``NoExecPaths=/`` makes every mount in the unit's
## namespace ``noexec``; ``ExecPaths=`` names the only paths it may execute
## from -- every store prefix the unit's ``[Service]`` section names (its
## command lines, their arguments, a launcher's target, a bind's source) and,
## when an apt closure is bound over ``/usr``, that ``/usr``. A root process
## outside the add-on that drops a binary anywhere else cannot have an
## add-on service execute it from a file. ``MemoryDenyWriteExecute=yes``
## stops the service making new code in an anonymous mapping, and the
## filter denies ``memfd_create``, the one way left to execute bytes that
## are on no mount (``memfd_create`` then ``execveat(fd, "", AT_EMPTY_PATH)``,
## which ``ExecPaths=`` cannot see: a memfd lives on the kernel's internal
## mount). Together they are the compensating control for the add-on's one
## detection gap: the distribution's own ``/usr`` is outside every closure
## the add-on can enumerate. Code that runs inside an allowed path -- an
## interpreter of the closure fed a script -- is not stopped; the floor
## bounds which binaries and libraries run, not what they are told.
##
## systemd semantics relied on (systemd.exec(5),
## https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html):
##
## * ``NoExecPaths=`` / ``ExecPaths=``: "``ExecPaths=`` takes precedence over
##   ``NoExecPaths=``"; both apply to every command line of the unit.
## * ``SystemCallFilter=``: the first line decides the mode (an allow-list);
##   a later ``~`` line removes from it, a later plain line adds to it. The
##   floor's lines come last in the section, after anything the unit wrote.
## * A ``+`` command prefix runs that command "with full privileges",
##   outside every sandboxing setting; ``!`` / ``!!`` run it without the
##   user change.
## * A drop-in is read after the unit file: a list setting it assigns adds
##   to (or, assigned empty, resets) what the floor wrote, a scalar one
##   overrides it. So a drop-in of a floored unit is held to the same rules
##   as the unit itself (``dropInFloorRefusal``).
##
## **Weakening is a named exception, never a silent override.** A unit (or
## a drop-in of it) that sets one of the floor's settings to anything else,
## runs a command outside its closure, or loosens what the floor depends on
## (a writable or re-mounted path over the closure, another root, the root
## account, a privileged group) is refused unless the resource lists the
## setting in ``floorExceptions`` with a reason. Two forms:
##
## * ``"<Setting>: <reason>"`` waives that one setting: the floor does not
##   render it and the unit may set it as it needs;
## * ``"<Setting>+<value> ...: <reason>"`` keeps the floor's setting and
##   adds to it, for ``SystemCallFilter`` (groups or calls added back after
##   the deny line), ``CapabilityBoundingSet`` and ``AmbientCapabilities``
##   (the capabilities named), and ``ExecPaths`` (absolute paths).
##
## ``"serviceFloor: <reason>"`` waives the whole floor and the unit is
## rendered exactly as written. Every exception is printed in every plan
## (``floorExceptionLines``).
##
## The rendered lines are appended at the end of the unit's ``[Service]``
## section; the unit's own text is never rewritten.
##
## **Floor version 3** (A9 review round 2) closes what versions 1 and 2
## left open, each measured on systemd 252, 255, 257 and 259:
##
## * ``NoExecPaths=/`` does not reach the mounts systemd creates for the
##   unit after it (``PrivateTmp=``'s ``/tmp`` and ``/var/tmp``,
##   ``PrivateDevices=``'s ``/dev/shm``, ``/dev/hugepages``,
##   ``/dev/mqueue``, and -- on systemd 259 -- ``/run`` and a
##   ``RuntimeDirectory=``), so
##   a service could write a binary there and run it. The floor names each
##   of them in a second ``NoExecPaths=`` line (``-`` prefixed: a missing
##   one is skipped), with every ``RuntimeDirectory=``, ``StateDirectory=``,
##   ``CacheDirectory=``, ``LogsDirectory=`` and ``ConfigurationDirectory=``
##   path the unit declares (``floorNoExecMounts``).
## * ``MemoryDenyWriteExecute=yes`` is the kernel's MDWE ``prctl`` from
##   systemd 255 on, which does not cover ``shmat(..., SHM_EXEC)``: a SysV
##   shared-memory segment written through one mapping executes through
##   another. The filter denies ``shmget``, ``shmat``, ``shmdt`` and
##   ``shmctl`` (a service that needs SysV shared memory names
##   ``"SystemCallFilter+shmget shmat shmdt shmctl: <why>"``).
## * A write to ``/proc/self/mem`` patches the process's own code whatever
##   the page protection (the kernel writes through ``FOLL_FORCE``).
##   ``ReadOnlyPaths=/proc`` makes the ``open(O_RDWR)`` fail with ``EROFS``;
##   no per-unit setting stops the write otherwise on these kernels
##   (``proc_mem.force_override=`` is a boot parameter, 6.12+ only).
## * Paths are compared the way systemd reads them: ``.`` components,
##   repeated and trailing ``/`` removed, the merged-``/usr`` aliases
##   (``/bin`` is ``/usr/bin`` ...) folded, and a ``..`` component or a
##   specifier refused (``normalisedPath``).
## * ``MountImages=``, ``ExtensionImages=`` and ``ExtensionDirectories=``
##   put another file system's contents into the unit's namespace and are
##   refused unless an exception names them.
##
## A stored generation keeps the floor version it was rendered with
## (``floorVersion`` in the stored profile, ``FloorVersion`` today); the
## frozen ``service_floor_v1`` and ``service_floor_v2`` render the units
## the engines of those versions stored, byte for byte.

import std/[algorithm, sequtils, strutils, tables]

const FloorMutation {.strdefine: "reproAddonMutation".} = ""
  ## The falsifying builds of the A9 gates (``repro_addon/mutations``):
  ## never set in a product build.

const Round5Off = FloorMutation in ["floor-round5-static-off",
  "floor-static-r3-disabled", "floor-unchecked"]
  ## Falsifying build (A9 review round 5): the parse-time rules round 5
  ## added -- environment files, activators, realtime scheduling -- off.

const ExceptionsLiftRoot = FloorMutation == "exception-lifts-root"
  ## Falsifying build (A9 review round 4, finding 4): round 3's rule, under
  ## which a ``User``, ``DynamicUser`` or ``SupplementaryGroups`` exception
  ## let a floored unit run as root or with a privileged group, and any
  ## systemd key could be named as an exception.

const StaticRound3Off = FloorMutation in ["floor-static-r3-disabled",
                                          "floor-unchecked"]
  ## The falsifying builds of review round 3's structural requirement: the
  ## static half (the allowlist and the round-3 parse-time refusals and
  ## noexec mounts) off, so the effective-unit check alone has to catch a
  ## weakened unit (``floor-static-r3-disabled``), or both off
  ## (``floor-unchecked``).

type FloorHalf* = enum
  ## Which half of the floor applies a rule (spec §10.1, A9 review round 7,
  ## finding 5): the parse-time half (``fhParse``), over a profile, or the
  ## effective-unit check (``fhEffective``), over the files systemd loaded.
  ## The effective half is the authority and applies every rule the
  ## parse-time half does; the falsifying builds that switch the parse-time
  ## half off (``floor-static-r3-disabled``, ``floor-round5-static-off``)
  ## switch off only the parse-time calls, so the effective half alone must
  ## refuse what they let through.
  fhParse, fhEffective

template off3(h: FloorHalf): bool =
  ## Round 3's parse-time refusals are off in this half.
  StaticRound3Off and h == fhParse

template off5(h: FloorHalf): bool =
  ## Round 5's parse-time refusals are off in this half.
  Round5Off and h == fhParse

const
  FloorVersion* = "4"
    ## The floor version this module renders (see the header). A stored
    ## generation records the version it was rendered with; 1 and 2 are
    ## the frozen ``service_floor_v1`` / ``service_floor_v2``.
  ServiceFloorHardening* = "serviceFloor"
    ## The one value of the ``hardening`` field.
  WholeFloorException* = "serviceFloor"
    ## The exception key that waives the whole floor.
  FloorStorePrefixRoot* = "/repro/store/prefixes/"
    ## Where a closure's store prefixes live (``<root><name>/<version>``).
  FloorDefaultAddressFamilies* = "AF_UNIX AF_INET AF_INET6"
    ## ``RestrictAddressFamilies=`` when the unit names none.

  FloorFixed*: seq[tuple[key, value: string]] = @[
    ("NoNewPrivileges", "yes"),
    ("ProtectSystem", "strict"),
    ("ProtectHome", "yes"),
    ("PrivateTmp", "yes"),
    ("PrivateDevices", "yes"),
    ("ProtectKernelTunables", "yes"),
    ("ProtectKernelModules", "yes"),
    ("ProtectKernelLogs", "yes"),
    ("ProtectControlGroups", "yes"),
    ("ProtectClock", "yes"),
    ("ProtectHostname", "yes"),
    ("ProtectProc", "invisible"),
    ("RestrictNamespaces", "yes"),
    ("RestrictRealtime", "yes"),
    ("RestrictSUIDSGID", "yes"),
    ("LockPersonality", "yes"),
    ("MemoryDenyWriteExecute", "yes"),
    ("SystemCallArchitectures", "native"),
    ("SystemCallFilter", "@system-service"),
    ("SystemCallFilter", "~@privileged @obsolete memfd_create shmget " &
                         "shmat shmdt shmctl"),
    ("CapabilityBoundingSet", ""),
    ("AmbientCapabilities", ""),
    ("UMask", "0077")]
    ## The settings the floor renders verbatim, in this order. Left to the
    ## unit, because only the service knows them: ``IPAddressDeny=`` /
    ## ``IPAddressAllow=`` (its egress), ``ReadWritePaths=`` /
    ## ``StateDirectory=`` (its state, within the limits below),
    ## ``ProcSubset=pid`` and ``~@resources`` (common runtimes read
    ## ``/proc/meminfo`` and raise their own ``RLIMIT_NOFILE`` at start; a
    ## Go service that cannot is killed).

  FloorAdditiveKeys* = ["SystemCallFilter", "CapabilityBoundingSet",
                        "AmbientCapabilities", "ExecPaths"]
    ## The settings an exception may add to (``"<Setting>+<value>: ..."``).

  FloorExecKeys* = ["ExecCondition", "ExecStartPre", "ExecStart",
                    "ExecStartPost", "ExecReload", "ExecStop", "ExecStopPost"]
    ## The command lines whose executables must be inside the closure.

  ExecConfinementException* = "NoExecPaths"
    ## The exception key that lifts the exec confinement (``NoExecPaths=``
    ## and ``ExecPaths=``).

  FloorGuardedKeys* = ["RestrictAddressFamilies", "DynamicUser", "User",
                       "SupplementaryGroups", "ReadWritePaths",
                       "RootDirectory", "MountImages", "ExtensionImages",
                       "ExtensionDirectories", "ReadOnlyPaths"]
    ## Settings the floor does not render but whose weakening values need a
    ## named exception: an all-but-a-few address family list; running as
    ## root (``User=root``, ``DynamicUser=no`` without an account, a ``!``
    ## command, ``Group=root``); a privileged supplementary group; a
    ## writable path over the closure or the system; another root; an
    ## image or extension mounted into the namespace; a drop-in's reset of
    ## ``ReadOnlyPaths=`` (which would drop the floor's ``/proc``).

  FloorPrivateMounts* = ["/tmp", "/var/tmp", "/dev/shm", "/dev/hugepages",
                         "/dev/mqueue", "/run"]
    ## The mounts systemd makes for the unit after ``NoExecPaths=/`` applies
    ## (``PrivateTmp=``, ``PrivateDevices=``; and ``/run`` itself, which
    ## systemd 259 leaves executable in the unit's namespace), each made
    ## ``noexec`` by name.

  FloorDirectoryKeys* = [("RuntimeDirectory", "/run"),
                         ("StateDirectory", "/var/lib"),
                         ("CacheDirectory", "/var/cache"),
                         ("LogsDirectory", "/var/log"),
                         ("ConfigurationDirectory", "/etc")]
    ## The directories systemd creates (and, under ``DynamicUser=``, binds)
    ## for the unit, and where each lives.

  ProcReadOnly* = "/proc"
  KernelTrees* = ["/proc", "/sys"]
    ## No writable path or bind destination may lie in either: they hold the
    ## process's own memory and the kernel's knobs.
    ## The floor's ``ReadOnlyPaths=`` (``/proc/self/mem`` writes; header).

  MergedUsrAliases* = [("/bin", "/usr/bin"), ("/sbin", "/usr/sbin"),
                       ("/lib", "/usr/lib"), ("/lib64", "/usr/lib64"),
                       ("/lib32", "/usr/lib32"), ("/libx32", "/usr/libx32")]
    ## Debian 12+ and Ubuntu are merged-``/usr``: each is a link into
    ## ``/usr``, so ``/bin/x`` and ``/usr/bin/x`` name one file.

  PrivilegedGroups* = ["root", "0", "sudo", "wheel", "adm", "admin", "disk",
    "shadow", "kmem", "docker", "lxd", "incus", "incus-admin", "libvirt",
    "kvm", "systemd-journal", "systemd-network", "plugdev", "staff",
    "ssl-cert", "netdev", "lpadmin", "tty"]
    ## Supplementary groups that grant administrative reach on a Debian or
    ## Ubuntu base: root's own, sudo/wheel/admin (privilege), adm and
    ## systemd-journal (every log), disk and kmem (raw devices), shadow
    ## (password hashes), docker/lxd/incus/libvirt/kvm (root-equivalent
    ## container and VM control), systemd-network, plugdev and staff
    ## (device and /usr/local write access); ssl-cert (private TLS keys),
    ## netdev (network configuration through the desktop daemons), lpadmin
    ## (printer administration, which runs filters as root) and tty (write
    ## to every terminal) (A9 review round 5, finding 4). Matched by gid at
    ## run time: a second name for one of these gids is the same group.

  ProtectedRoots* = ["/usr", "/etc", "/boot", "/repro", "/bin", "/sbin",
                     "/lib", "/lib64", "/var/lib/repro", "/run/repro"]
    ## Paths a unit under the floor may never make writable, nor any
    ## ancestor of them: the system ``ProtectSystem=strict`` protects, the
    ## store, and the add-on's own state and secrets.

type
  EServiceFloor* = object of ValueError
    ## A unit the floor cannot be applied to as written.

  FloorException* = object
    setting*: string
    adds*: seq[string]   ## the values of a ``Setting+value`` exception
    reason*: string

proc floorExceptionKeys*(): seq[string] =
  ## Every key a ``floorExceptions`` entry may name.
  for (k, _) in FloorFixed:
    if k notin result: result.add(k)
  for k in @[ExecConfinementException] & @FloorGuardedKeys &
           @[WholeFloorException]:
    if k notin result: result.add(k)

proc raiseFloor(unitName, msg: string) {.noreturn.} =
  raise newException(EServiceFloor, "systemd.systemUnit '" & unitName &
    "': " & msg)

proc validAdd(key, v: string): bool =
  case key
  of "SystemCallFilter":
    v.len > 0 and v[0] != '~' and
      v.allCharsInSet({'a'..'z', '0'..'9', '_', '-', '@'})
  of "CapabilityBoundingSet", "AmbientCapabilities":
    v.startsWith("CAP_") and v.allCharsInSet({'A'..'Z', '0'..'9', '_'})
  of "ExecPaths":
    v.startsWith("/") and not v.contains("..") and
      v.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '_', '-', '.', '/', '+'})
  else: false

proc parseFloorExceptions*(unitName: string;
                           entries: openArray[string]): seq[FloorException] =
  ## ``"<Setting>: <reason>"`` or ``"<Setting>+<value> ...: <reason>"``
  ## entries, each naming a key of ``floorExceptionKeys`` once, with a
  ## non-empty reason; the additive form only for ``FloorAdditiveKeys``.
  let keys = floorExceptionKeys()
  for e in entries:
    let colon = e.find(':')
    if colon <= 0:
      raiseFloor(unitName, "floor exception '" & e & "' must read " &
        "'<Setting>: <reason>' or '<Setting>+<value>: <reason>'")
    let head = e[0 ..< colon].strip()
    let why = e[colon + 1 .. ^1].strip()
    var k = head
    var adds: seq[string]
    let plus = head.find('+')
    if plus > 0:
      k = head[0 ..< plus].strip()
      if k notin FloorAdditiveKeys:
        raiseFloor(unitName, "floor exception '" & head & "': only " &
          FloorAdditiveKeys.join(", ") & " can be added to")
      adds = head[plus + 1 .. ^1].splitWhitespace()
      if adds.len == 0:
        raiseFloor(unitName, "floor exception '" & head & "' adds nothing")
      for v in adds:
        if not validAdd(k, v):
          raiseFloor(unitName, "floor exception '" & head & "': '" & v &
            "' is not a value " & k & " can be added")
    if k == "PAMName":
      raiseFloor(unitName, "floor exception 'PAMName': PAMName= is refused " &
        "under the floor, with or without an exception")
    let systemdKey = k.len > 0 and k[0] in {'A'..'Z'} and
      k.allCharsInSet({'A'..'Z', 'a'..'z', '0'..'9'})
    if k notin keys and (not ExceptionsLiftRoot or StaticRound3Off or
                         not systemdKey):
      raiseFloor(unitName, "floor exception '" & k & "' names no " &
        "serviceFloor setting (one of " & keys.join(", ") & ") or systemd " &
        "unit setting")
    if why.len == 0:
      raiseFloor(unitName, "floor exception '" & k & "' gives no reason; " &
        "an exception to the floor must say why")
    for prior in result:
      if prior.setting == k:
        raiseFloor(unitName, "floor exception '" & k & "' is named twice")
    result.add(FloorException(setting: k, adds: adds, reason: why))

proc floorExceptionLines*(unitName: string;
                          entries: openArray[string]): seq[string] =
  ## The plan lines of a unit's exceptions:
  ## ``<unit>: <Setting>[+<values>]: <reason>``.
  for e in parseFloorExceptions(unitName, entries):
    let head = if e.adds.len > 0: e.setting & "+" & e.adds.join(" ")
               else: e.setting
    result.add(unitName & ": " & head & ": " & e.reason)

proc waived(ex: openArray[FloorException]; key: string): bool =
  ## The setting is waived outright (not merely added to).
  for e in ex:
    if e.setting == WholeFloorException: return true
    if e.setting == key and e.adds.len == 0: return true

proc additions(ex: openArray[FloorException]; key: string): seq[string] =
  for e in ex:
    if e.setting == key: result.add(e.adds)

proc logicalLines(content: string): seq[string] =
  ## Physical lines joined across trailing backslashes, as systemd does
  ## (systemd.syntax(7)); comment lines inside a continuation are dropped.
  var cur = ""
  var continuing = false
  for raw in content.split('\n'):
    let line = raw.strip(leading = false, trailing = true, chars = {'\r'})
    if continuing:
      let t = line.strip()
      if t.len > 0 and t[0] in {'#', ';'}: continue
    if line.endsWith("\\"):
      cur.add(line[0 ..< line.len - 1] & " ")
      continuing = true
      continue
    cur.add(line)
    result.add(cur)
    cur = ""
    continuing = false
  if continuing: result.add(cur)

proc sectionDirectives*(content: string; sections: openArray[string] = []):
    seq[tuple[section, key, value: string]] =
  ## The ``key=value`` directives of ``content``, with their section, in
  ## order, comments skipped; only ``sections`` when it is not empty.
  var section = ""
  for l0 in logicalLines(content):
    let l = l0.strip()
    if l.len == 0 or l[0] in {'#', ';'}: continue
    if l.startsWith("[") and l.endsWith("]"):
      section = l[1 .. ^2]
      continue
    if sections.len > 0 and section notin sections: continue
    let eq = l.find('=')
    if eq <= 0: continue
    result.add((section: section, key: l[0 ..< eq].strip(),
                value: l[eq + 1 .. ^1].strip()))

proc serviceDirectives*(content: string): seq[tuple[key, value: string]] =
  ## The ``key=value`` directives of the unit's ``[Service]`` section.
  for d in sectionDirectives(content, ["Service"]):
    result.add((key: d.key, value: d.value))

proc hasServiceSection*(content: string): bool =
  for l in logicalLines(content):
    if l.strip() == "[Service]": return true

proc hasExecLines*(content: string): bool =
  ## Whether any section carries a command line (a ``.socket``'s
  ## ``ExecStartPre=`` runs commands too).
  for d in sectionDirectives(content):
    if d.key in FloorExecKeys or d.key.startsWith("Exec"): return true

proc commandWords(value: string): seq[string] =
  ## A command line split into words the way systemd does for the purposes
  ## here: whitespace separates, single and double quotes group, ``\;``
  ## stays a literal word.
  var cur = ""
  var quote = '\0'
  var inWord = false
  for c in value:
    if quote != '\0':
      if c == quote: quote = '\0'
      else: cur.add(c)
    elif c in {'"', '\''}:
      quote = c
      inWord = true
    elif c in {' ', '\t'}:
      if inWord or cur.len > 0:
        result.add(cur)
        cur = ""
        inWord = false
    else:
      cur.add(c)
      inWord = true
  if inWord or cur.len > 0: result.add(cur)

proc commands*(value: string): seq[tuple[path, prefixes: string]] =
  ## Every command of a command line: systemd separates several with a
  ## lone ``;`` word (systemd.service(5) "Command lines"). Each with its
  ## executable and its special prefixes (``@-:+!|``); an empty assignment
  ## (a reset) has none.
  var words = commandWords(value)
  var start = true
  for w in words:
    if w == ";":
      start = true
      continue
    if not start: continue
    start = false
    var i = 0
    while i < w.len and w[i] in {'@', '-', ':', '+', '!', '|'}: inc i
    var path = w[i .. ^1]
    var prefixes = w[0 ..< i]
    if path.len == 0:
      # The prefixes stood alone (`- /bin/x` is not systemd syntax, but a
      # lone prefix word means the next word is the executable).
      start = true
      continue
    result.add((path: path, prefixes: prefixes))

proc hasDotDot*(path: string): bool =
  ## Whether ``path`` has a ``..`` component: systemd resolves it against
  ## the file system at run time, so its lexical form says nothing about
  ## where it leads (a link below it moves it).
  for c in path.split('/'):
    if c == "..": return true

proc normalisedPath*(path: string): string =
  ## ``path`` as systemd reads a path setting: repeated ``/`` collapsed,
  ## ``.`` components and a trailing ``/`` removed (systemd's
  ## ``path_simplify``, https://github.com/systemd/systemd/blob/v257/src/basic/path-util.c),
  ## and the merged-``/usr`` aliases folded into ``/usr`` (``/bin/x`` is
  ## ``/usr/bin/x``). A relative path is returned as it is; callers refuse
  ## a ``..`` component first (``hasDotDot``).
  if not path.startsWith("/"): return path
  when FloorMutation == "floor-paths-unnormalised":
    # Falsifying build: versions 1 and 2 compared the string, trailing
    # slashes trimmed, nothing else.
    result = path
    while result.len > 1 and result.endsWith("/"): result.setLen(result.len - 1)
    return
  var parts: seq[string]
  for c in path.split('/'):
    if c.len == 0 or c == ".": continue
    parts.add(c)
  result = "/" & parts.join("/")
  for (alias, real) in MergedUsrAliases:
    if result == alias or result.startsWith(alias & "/"):
      result = real & result[alias.len .. ^1]
      break

proc storeObjectOf*(path: string): string =
  ## The store prefix directory ``/repro/store/prefixes/<name>/<version>``
  ## that ``path`` lies in, or "" when it is not inside one.
  if not path.startsWith(FloorStorePrefixRoot): return ""
  let rest = path[FloorStorePrefixRoot.len .. ^1].split('/')
  if rest.len < 2 or rest[0].len == 0 or rest[1].len == 0: return ""
  if rest[0] in [".", ".."] or rest[1] in [".", ".."]: return ""
  FloorStorePrefixRoot & rest[0] & "/" & rest[1]

proc referencedStoreObjects*(content: string): seq[string] =
  ## Every store prefix any directive of ``content`` names, anywhere in its
  ## value: a command, an argument, a launcher started through a shell, an
  ## environment value, a bind source. The unit's closure as far as its
  ## text says. Each path is read the way systemd reads it
  ## (``normalisedPath``: ``/repro//store`` and ``/repro/./store`` are the
  ## store too; A9 review round 3, finding 7). Sorted.
  for d in sectionDirectives(content):
    var tok = ""
    proc take(tok: var string; acc: var seq[string]) =
      let i = tok.find("/repro")
      if i >= 0:
        let p = tok[i .. ^1]
        let obj = storeObjectOf(
          when FloorMutation == "store-objects-by-string": p
          else: normalisedPath(p))
        if obj.len > 0 and obj notin acc: acc.add(obj)
      tok = ""
    for c in d.value & " ":
      if c in {' ', '\t', '\'', '"', ';', ':', '=', ','}:
        take(tok, result)
      else:
        tok.add(c)
  result.sort()

proc commandStoreObjects*(content: string): seq[string] =
  ## The store prefixes ``content`` names (``referencedStoreObjects``): what
  ## the switch re-verifies before its flip.
  referencedStoreObjects(content)

proc bindEntries(value: string): seq[tuple[optional: bool; src, dst: string]] =
  for tok in value.splitWhitespace():
    var t = tok
    var optional = false
    while t.len > 0 and t[0] in {'-', '+'}:
      if t[0] == '-': optional = true
      t = t[1 .. ^1]
    let parts = t.split(':')
    if parts.len == 0 or parts[0].len == 0: continue
    result.add((optional: optional, src: parts[0],
                dst: (if parts.len >= 2 and parts[1].len > 0: parts[1]
                      else: parts[0])))

proc isClosureUsrBind(b: tuple[optional: bool; src, dst: string]): bool =
  ## The renderer's own ``BindReadOnlyPaths=<closure>/usr:/usr`` (spec §8.3
  ## item 5): a required (not ``-``) bind of a store prefix's ``usr``.
  not b.optional and b.dst == "/usr" and b.src.endsWith("/usr") and
    storeObjectOf(b.src).len > 0 and
    b.src == storeObjectOf(b.src) & "/usr"

proc closureBindsUsr(directives: openArray[tuple[key, value: string]]): bool =
  for (k, v) in directives:
    if k == "BindReadOnlyPaths":
      for b in bindEntries(v):
        if isClosureUsrBind(b): return true

proc insideBoundUsr(path: string): bool =
  ## A command path that resolves into the unit's ``/usr``: ``/usr/...``
  ## itself, the merged-``/usr`` links ``/bin``, ``/sbin``, ``/lib*``, or a
  ## bare name (systemd searches its fixed ``PATH``, all of which is under
  ## ``/usr`` on a merged-``/usr`` base).
  if '/' notin path: return true
  normalisedPath(path).startsWith("/usr/")

proc under(path, root: string): bool =
  ## ``path`` is ``root`` or below it, both as systemd reads them
  ## (``normalisedPath``).
  let p = normalisedPath(path)
  let r = normalisedPath(root)
  r == "/" or p == r or p.startsWith(r & "/")

proc overlaps(a, b: string): bool = under(a, b) or under(b, a)

proc floorExecPaths*(unitName, content: string;
                     ex: openArray[FloorException]): seq[string] =
  ## The ``ExecPaths=`` the floor renders for ``content``: every store
  ## prefix the unit names (``referencedStoreObjects``), ``/usr`` when an
  ## apt closure is bound there, and the paths an ``ExecPaths+`` exception
  ## adds. Every command's executable must be inside them: a command
  ## outside is refused (``EServiceFloor``) unless the exec confinement is
  ## waived.
  let directives = serviceDirectives(content)
  let usrBound = closureBindsUsr(directives)
  result = referencedStoreObjects(content)
  if usrBound: result.add("/usr")
  for a in additions(ex, "ExecPaths"):
    if a notin result: result.add(a)
  result.sort()
  if waived(ex, ExecConfinementException): return
  for (k, v) in directives:
    if k notin FloorExecKeys: continue
    for c in commands(v):
      let path = c.path
      if '%' in path or '$' in path:
        raiseFloor(unitName, k & " runs '" & path & "', which names a " &
          "specifier or variable: the floor cannot tell whether it is " &
          "inside the unit's closure (name the exception \"" &
          ExecConfinementException & ": <why>\")")
      when FloorMutation != "floor-paths-unnormalised":
        if hasDotDot(path):
          raiseFloor(unitName, k & " runs '" & path & "', which has a " &
            "'..' component: where it leads depends on the file system, " &
            "not on the closure (name the exception \"" &
            ExecConfinementException & ": <why>\")")
      var inside = usrBound and insideBoundUsr(path)
      for p in result:
        if path.startsWith("/") and under(path, p): inside = true
      if not inside:
        raiseFloor(unitName, k & " runs " & path & ", outside the unit's " &
          "closure: serviceFloor confines execution to the store prefixes " &
          "a unit names and to an apt closure bound over /usr. Run it " &
          "from the store (or bind its package's closure with " &
          "aptClosureLock), or name the exception \"" &
          ExecConfinementException & ": <why>\"")

# ---------------------------------------------------------------------------
# The allowlist (floor version 4; A9 review round 3's structural answer).
# Three rounds found a weakening the refusals above did not predict: a
# spelling, a key, a drop-in rule, a default. Under the floor a unit may
# carry only the keys below, each in the value form its validator accepts;
# anything else is refused unless the unit names the key in
# ``floorExceptions`` (the effective-unit check at the switch,
# ``repro_addon/effective_floor``, is the other half: systemd's own reading
# of the unit is compared with the floor before anything starts).
# ---------------------------------------------------------------------------

type ValueForm = enum
  vfAny          ## free text (a description, an environment assignment)
  vfUnitNames    ## unit names, space-separated
  vfPaths        ## absolute literal paths; ``-`` / ``+`` prefixes
  vfBinds        ## ``[-]src[:dst[:opts]]`` literal paths
  vfTmpfs        ## ``path[:mode=NNNN]`` literal
  vfDirNames     ## relative literal directory names (``a``, ``a/b``)
  vfAccount      ## one account name, never root
  vfGroups       ## account group names
  vfBool         ## ``yes`` / ``no``
  vfYes          ## ``yes`` only
  vfPrivate      ## ``private`` only
  vfToken        ## one word of letters, digits, ``-_.:+``
  vfTokens       ## words of letters, digits, ``-_.:+@%~``
  vfNumber       ## a number, a size, a duration, ``infinity``
  vfCommand      ## a command line (judged by ``floorExecPaths`` / refusals)
  vfFloor        ## a floor setting (judged by ``floorRefusal``)

const
  QuoteOrSpecifier = {'\'', '"', '%', '$', '\\', '`'}
    ## No path the floor judges may be quoted, escaped or carry a
    ## specifier or a variable: systemd would read it otherwise than the
    ## floor does (A9 review round 3, finding 3).

  UnitSectionKeys = [
    ("Description", vfAny), ("Documentation", vfAny),
    ("After", vfUnitNames), ("Before", vfUnitNames),
    ("Wants", vfUnitNames), ("Requires", vfUnitNames),
    ("Requisite", vfUnitNames), ("BindsTo", vfUnitNames),
    ("PartOf", vfUnitNames), ("Upholds", vfUnitNames),
    ("Conflicts", vfUnitNames), ("OnFailure", vfUnitNames),
    ("OnSuccess", vfUnitNames), ("PropagatesReloadTo", vfUnitNames),
    ("ReloadPropagatedFrom", vfUnitNames), ("RequiresMountsFor", vfPaths),
    ("WantsMountsFor", vfPaths), ("StopWhenUnneeded", vfBool),
    ("RefuseManualStart", vfBool), ("RefuseManualStop", vfBool),
    ("DefaultDependencies", vfBool), ("IgnoreOnIsolate", vfBool),
    ("CollectMode", vfToken), ("StartLimitIntervalSec", vfNumber),
    ("StartLimitBurst", vfNumber), ("JobTimeoutSec", vfNumber),
    ("ConditionPathExists", vfPaths), ("ConditionPathIsDirectory", vfPaths),
    ("ConditionFileNotEmpty", vfPaths), ("ConditionVirtualization", vfToken),
    ("ConditionArchitecture", vfToken), ("ConditionHost", vfToken),
    ("AssertPathExists", vfPaths)]
    ## Ordering, dependencies on units the profile or the base defines,
    ## and the conditions that read paths. Not here: ``JoinsNamespaceOf=``
    ## (another unit's /tmp and network), ``StartLimitAction=`` /
    ## ``FailureAction=`` / ``SuccessAction=`` (reboot), ``AllowIsolate=``.

  InstallSectionKeys = [("WantedBy", vfUnitNames), ("RequiredBy", vfUnitNames),
                        ("UpheldBy", vfUnitNames), ("Alias", vfUnitNames)]

  ServiceSectionKeys = [
    ("Type", vfToken), ("ExitType", vfToken),
    ("ExecCondition", vfCommand), ("ExecStartPre", vfCommand),
    ("ExecStart", vfCommand), ("ExecStartPost", vfCommand),
    ("ExecReload", vfCommand), ("ExecStop", vfCommand),
    ("ExecStopPost", vfCommand),
    ("Restart", vfToken), ("RestartSec", vfNumber), ("RestartSteps", vfNumber),
    ("RestartMaxDelaySec", vfNumber), ("RestartPreventExitStatus", vfTokens),
    ("RestartForceExitStatus", vfTokens), ("SuccessExitStatus", vfTokens),
    ("TimeoutSec", vfNumber), ("TimeoutStartSec", vfNumber),
    ("TimeoutStopSec", vfNumber), ("TimeoutAbortSec", vfNumber),
    ("RuntimeMaxSec", vfNumber), ("WatchdogSec", vfNumber),
    ("RemainAfterExit", vfBool), ("GuessMainPID", vfBool),
    ("PIDFile", vfPaths), ("BusName", vfToken), ("NotifyAccess", vfToken),
    ("KillMode", vfToken), ("KillSignal", vfToken), ("SendSIGKILL", vfBool),
    ("SendSIGHUP", vfBool), ("FinalKillSignal", vfToken),
    ("RestartKillSignal", vfToken), ("OOMPolicy", vfToken),
    ("FileDescriptorStoreMax", vfNumber), ("Sockets", vfUnitNames),
    ("Environment", vfAny), ("EnvironmentFile", vfPaths),
    ("PassEnvironment", vfTokens), ("UnsetEnvironment", vfTokens),
    ("WorkingDirectory", vfPaths),
    ("User", vfAccount), ("Group", vfAccount), ("DynamicUser", vfFloor),
    ("SupplementaryGroups", vfGroups),
    ("StateDirectory", vfDirNames), ("RuntimeDirectory", vfDirNames),
    ("CacheDirectory", vfDirNames), ("LogsDirectory", vfDirNames),
    ("ConfigurationDirectory", vfDirNames),
    ("StateDirectoryMode", vfNumber), ("RuntimeDirectoryMode", vfNumber),
    ("CacheDirectoryMode", vfNumber), ("LogsDirectoryMode", vfNumber),
    ("ConfigurationDirectoryMode", vfNumber),
    ("RuntimeDirectoryPreserve", vfToken),
    ("ReadWritePaths", vfFloor), ("ReadOnlyPaths", vfPaths),
    ("InaccessiblePaths", vfPaths), ("BindPaths", vfFloor),
    ("BindReadOnlyPaths", vfFloor), ("TemporaryFileSystem", vfFloor),
    ("LoadCredential", vfTokens),
    ("StandardInput", vfToken), ("StandardOutput", vfToken),
    ("StandardError", vfToken), ("SyslogIdentifier", vfToken),
    ("SyslogFacility", vfToken), ("SyslogLevel", vfToken),
    ("SyslogLevelPrefix", vfBool), ("LogLevelMax", vfToken),
    ("LogRateLimitIntervalSec", vfNumber), ("LogRateLimitBurst", vfNumber),
    ("Nice", vfNumber), ("OOMScoreAdjust", vfNumber),
    ("IOSchedulingClass", vfToken), ("IOSchedulingPriority", vfNumber),
    ("CPUSchedulingPolicy", vfToken), ("CPUSchedulingPriority", vfNumber),
    ("MemoryMax", vfNumber), ("MemoryHigh", vfNumber), ("MemoryLow", vfNumber),
    ("MemoryMin", vfNumber), ("MemorySwapMax", vfNumber),
    ("MemoryAccounting", vfBool), ("CPUQuota", vfToken),
    ("CPUWeight", vfNumber), ("IOWeight", vfNumber), ("TasksMax", vfNumber),
    ("CPUAccounting", vfBool), ("IOAccounting", vfBool),
    ("TasksAccounting", vfBool), ("IPAccounting", vfBool),
    ("IPAddressDeny", vfTokens), ("IPAddressAllow", vfTokens),
    ("Slice", vfUnitNames),
    ("PrivateNetwork", vfYes), ("PrivateUsers", vfYes), ("PrivateIPC", vfYes),
    ("RemoveIPC", vfYes), ("KeyringMode", vfPrivate), ("ProcSubset", vfToken),
    ("DevicePolicy", vfToken), ("RestrictFileSystems", vfTokens),
    ("RestrictNetworkInterfaces", vfTokens), ("SocketBindAllow", vfTokens),
    ("SocketBindDeny", vfTokens), ("SystemCallErrorNumber", vfToken),
    ("SystemCallLog", vfTokens), ("RestrictAddressFamilies", vfFloor),
    ("ExecPaths", vfFloor), ("NoExecPaths", vfFloor)]
    ## Plus every floor setting (``FloorFixed``), judged by ``floorRefusal``.

  DropInKeys = ["Description", "Documentation", "After", "Before", "Wants",
    "Requires", "PartOf", "Environment", "UnsetEnvironment", "Restart",
    "RestartSec", "TimeoutSec", "TimeoutStartSec", "TimeoutStopSec",
    "WatchdogSec", "RuntimeMaxSec", "Nice", "OOMScoreAdjust", "MemoryMax",
    "MemoryHigh", "MemoryLow", "MemorySwapMax", "CPUQuota", "CPUWeight",
    "IOWeight", "TasksMax", "SyslogIdentifier", "StandardOutput",
    "StandardError", "LogLevelMax", "ExecCondition", "ExecStartPre",
    "ExecStart", "ExecStartPost", "ExecReload", "ExecStop", "ExecStopPost"]
    ## What a drop-in of a floored unit may set: no account, no directory,
    ## no mount, no path (each needs the unit's own floor to cover it).
    ## Its command lines are judged against the unit's closure.

const FloorJudgedKeys = ["NoExecPaths", "ExecPaths", "RestrictAddressFamilies",
  "DynamicUser", "User", "Group", "SupplementaryGroups", "ReadWritePaths",
  "TemporaryFileSystem", "BindPaths", "BindReadOnlyPaths", "RootDirectory",
  "RootImage", "RootEphemeral", "RootImageOptions", "MountImages",
  "ExtensionImages", "ExtensionDirectories", "ReadOnlyPaths"]
  ## Keys ``floorRefusal`` judges itself, with its own message and
  ## exception, in a unit and in a drop-in.

proc allowedForm(section, key: string; dropIn: bool): (bool, ValueForm) =
  ## Whether ``key`` may appear in ``section`` of a floored unit (or of a
  ## drop-in of one), and the value form it takes.
  for (k, _) in FloorFixed:
    if k == key: return (section == "Service", vfFloor)
  if key in FloorJudgedKeys and section == "Service":
    return (true, vfFloor)
  if dropIn and key notin DropInKeys: return (false, vfAny)
  case section
  of "Unit":
    for (k, f) in UnitSectionKeys:
      if k == key: return (true, f)
  of "Install":
    for (k, f) in InstallSectionKeys:
      if k == key: return (true, f)
  of "Service":
    for (k, f) in ServiceSectionKeys:
      if k == key: return (true, f)
  else: discard
  (false, vfAny)

proc floorKnowsKey*(section, key: string; dropIn: bool): bool =
  ## Whether a floored unit (or a drop-in of one) may carry ``key`` in
  ## ``section`` at all: the allowlist's keys, independent of the value
  ## forms. The effective-unit check holds the files systemd loaded to it
  ## (``repro_addon/effective_floor``), for the settings systemd does not
  ## report back (``PermissionsStartOnly=``).
  allowedForm(section, key, dropIn)[0]

proc isAccountName*(v: string): bool =
  ## A literal account name systemd resolves as written: lower-case
  ## letters, digits, ``_``, ``-``, not starting with a digit or ``-``.
  v.len in 1 .. 32 and v[0] in {'a'..'z', '_'} and
    v.allCharsInSet({'a'..'z', '0'..'9', '_', '-'})

proc safeUnitName(v: string): bool =
  v.len > 0 and v.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', ':', '-', '_',
                                 '.', '@'})

proc formRefusal(key, value: string; f: ValueForm): string =
  ## Why ``value`` is not in form ``f``, or "".
  proc literalPath(p: string): bool =
    let q = p.strip(leading = true, trailing = false, chars = {'-', '+'})
    q.startsWith("/") and not q.anyIt(it in QuoteOrSpecifier) and
      not hasDotDot(q) and not q.anyIt(it in {' ', '\t'})
  case f
  of vfAny, vfCommand, vfFloor:
    ""
  of vfUnitNames:
    for t in value.splitWhitespace():
      if not safeUnitName(t): return "'" & t & "' is not a unit name"
    ""
  of vfPaths:
    for t in value.splitWhitespace():
      if not literalPath(t):
        return "'" & t & "' is not a literal absolute path (no quote, " &
          "escape, specifier, variable or '..')"
    ""
  of vfBinds, vfTmpfs:
    ""   # judged with the floor's mounts (``floorRefusal``)
  of vfDirNames:
    # `name` or, from systemd 254, `name:link` (a link to it).
    for t in value.splitWhitespace():
      let parts = t.split(':')
      if parts.len > 2: return "'" & t & "' is not a literal directory name"
      for q in parts:
        if q.len == 0 or q.startsWith("/") or hasDotDot(q) or
            not q.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '.', '_', '-',
                                  '/'}):
          return "'" & t & "' is not a literal directory name"
    ""
  of vfAccount:
    if not isAccountName(value):
      return "'" & value & "' is not a literal account name (an empty " &
        "value, a number or a specifier makes systemd run the service as " &
        "root or not at all)"
    ""
  of vfGroups:
    for t in value.splitWhitespace():
      if not isAccountName(t): return "'" & t & "' is not a group name"
    ""
  of vfBool:
    if value notin ["yes", "no"]: return "'" & value & "' is not yes or no"
    ""
  of vfYes:
    if value != "yes": return "'" & value & "' is not yes"
    ""
  of vfPrivate:
    if value != "private": return "'" & value & "' is not private"
    ""
  of vfToken:
    if value.len == 0 or not value.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9',
                                                  '-', '_', '.', ':', '+'}):
      return "'" & value & "' is not one plain word"
    ""
  of vfTokens:
    for t in value.splitWhitespace():
      if not t.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.',
                              ':', '+', '@', '~', '/', '='}):
        return "'" & t & "' is not a plain word"
    ""
  of vfNumber:
    if value.len == 0 or not value.allCharsInSet({'0'..'9', 'a'..'z',
                                                  'A'..'Z', '.', '%', ' '}):
      return "'" & value & "' is not a number, size or duration"
    ""

const
  SystemStateTargets* = ["reboot.target", "poweroff.target",
  "halt.target", "kexec.target", "emergency.target", "rescue.target",
  "exit.target", "soft-reboot.target", "ctrl-alt-del.target",
  "shutdown.target", "final.target", "umount.target", "sleep.target",
  "suspend.target", "hibernate.target", "hybrid-sleep.target",
  "suspend-then-hibernate.target", "factory-reset.target",
  "initrd-switch-root.target", "runlevel0.target", "runlevel1.target",
  "runlevel6.target",
  "systemd-reboot.service", "systemd-poweroff.service",
  "systemd-halt.service", "systemd-kexec.service", "systemd-exit.service",
  "systemd-soft-reboot.service", "systemd-suspend.service",
  "systemd-hibernate.service", "systemd-hybrid-sleep.service",
  "systemd-suspend-then-hibernate.service", "initrd-switch-root.service",
  "emergency.service", "rescue.service"]
  ## Units that change the whole system's state: stop it, suspend it, or
  ## replace what runs (systemd.special(7)). Round 3 left
  ## ``FailureAction=``, ``SuccessAction=`` and ``StartLimitAction=`` off
  ## the allowlist for that reason; a dependency that starts one of these,
  ## directly or through any other unit, is the same action (A9 review
  ## rounds 6 and 7; §13 decision 49). ``shutdown.target`` and
  ## ``umount.target`` stop every unit with default dependencies and unmount
  ## the file systems; the sleep targets suspend the host. The ``-force``
  ## forms are actions, not units, and are covered by the ``*Action=`` keys.
  StartingDependencyKeys* = ["OnFailure", "OnSuccess", "Wants", "Requires",
    "Requisite", "BindsTo", "Upholds"]
    ## The ``[Unit]`` keys whose units start with, or because of, this one.
  BaseReachKeys* = ["Wants", "Requires", "Requisite", "BindsTo", "Upholds"]
    ## The keys followed through a unit the base defines: what starting it
    ## starts. A base unit's own ``OnFailure=`` (``local-fs.target``'s
    ## ``emergency.target``) is the base's behaviour, not something a
    ## floored unit makes happen, so it is not followed there; it is
    ## followed through every unit of the generation.
  JobModeKeys* = ["OnFailureJobMode", "OnSuccessJobMode"]
    ## How a unit's ``OnFailure=``/``OnSuccess=`` units are queued.
  SafeJobModes* = ["replace", "fail"]
    ## The job modes that start only what is named. ``isolate`` stops every
    ## unit the target does not want, ``replace-irreversibly`` cannot be
    ## undone, ``flush`` and ``ignore-*`` cancel or bypass other jobs
    ## (systemd.unit(5), ``OnFailureJobMode=``): each changes the system's
    ## state beyond the unit.
  RouteLimit* = 4096
    ## A closure larger than this is not judged: refused (default deny).

proc walkReach*(roots: openArray[string];
                depsOf: proc (u: string): seq[string] {.closure.};
                visit: proc (u, parent: string): bool {.closure.};
                limit = RouteLimit): bool =
  ## The one reach of the floor (§13 decisions 49 and 55; A9 review round
  ## 9, finding 2): breadth first from ``roots`` through ``depsOf`` (what a
  ## unit starts -- the profile's units at parse time, systemd's report in
  ## the effective check), calling ``visit`` once per reached unit (not the
  ## roots) with the unit it was reached from; ``visit`` returns ``false``
  ## to stop. Units the generation does not install are walked through like
  ## any other. Returns ``false`` when more than ``limit`` units were
  ## reached (not judged: the callers refuse).
  var parent = initTable[string, string]()
  var queue: seq[string]
  for r in roots:
    if r notin parent:
      parent[r] = ""
      queue.add(r)
  var i = 0
  while i < queue.len:
    let u = queue[i]
    inc i
    for d in depsOf(u):
      if d.len == 0 or d in parent: continue
      parent[d] = u
      if parent.len > limit: return false
      if not visit(d, u): return true
      queue.add(d)
  true

proc reachedUnits*(roots: openArray[string];
                   depsOf: proc (u: string): seq[string] {.closure.};
                   limit = RouteLimit): tuple[units: seq[string]; complete: bool] =
  ## Every unit ``walkReach`` reaches from ``roots``, in order.
  var acc: seq[string]
  let complete = walkReach(roots, depsOf,
    proc (u, parent: string): bool =
      acc.add(u)
      true, limit)
  (acc, complete)

proc systemStateRoute*(roots: openArray[string];
                       depsOf: proc (u: string): seq[string] {.closure.};
                       limit = RouteLimit): seq[string] =
  ## The chain of units from one of ``roots`` (not itself checked) to a
  ## system-state unit (``SystemStateTargets``), by ``walkReach``, or
  ## ``@[]`` when none is reachable. A closure of more than ``limit`` units
  ## returns the one-element chain ``@["(more than <limit> units)"]``: not
  ## judged, so refused.
  when FloorMutation == "state-routes-direct-only":
    # Falsifying build: round 6's rule, the roots' direct dependencies only.
    for r in roots:
      for d in depsOf(r):
        if d in SystemStateTargets: return @[r, d]
    return @[]
  var parents = initTable[string, string]()
  for r in roots: parents[r] = ""
  var found = ""
  let complete = walkReach(roots, depsOf,
    proc (u, parent: string): bool =
      parents[u] = parent
      if u in SystemStateTargets:
        found = u
        return false
      true, limit)
  if not complete: return @["(more than " & $limit & " units)"]
  if found.len == 0: return @[]
  var chain = @[found]
  var c = parents[found]
  while c.len > 0:
    chain.insert(c, 0)
    c = parents.getOrDefault(c, "")
  chain

proc unitStem*(unitName: string): string =
  ## ``a.socket`` -> ``a``; ``a@.socket`` and ``a@x.socket`` -> ``a``.
  let dot = unitName.rfind('.')
  result = if dot > 0: unitName[0 ..< dot] else: unitName
  let at = result.find('@')
  if at >= 0: result = result[0 ..< at]

proc ownNamed*(stem, name: string): bool =
  ## ``name`` is named for a unit of stem ``stem``: exactly the stem (§13
  ## decision 67). A longer name -- ``foo-bar``, ``foo.bar``, ``foo_bar`` for
  ## ``foo`` -- is another unit's name as much as this one's (the stem of
  ## ``foo-bar.service``), so a unit names only its own; what it needs
  ## more of goes below it (``foo/bar``).
  when FloorMutation == "own-names-by-prefix":
    name == stem or name.startsWith(stem & ".") or name.startsWith(stem & "-") or
      name.startsWith(stem & "_")
  else:
    name == stem

const
  AddOnOwnedRoots* = ["/repro", "/run/repro", "/var/lib/repro",
    "/var/cache/repro", "/var/log/repro", "/etc/repro"]
    ## The add-on's own trees: its store, its run, state, cache and log
    ## directories, its configuration. No floored unit, and no unit that
    ## activates one, may make the service manager create anything here (a
    ## listener, a ``*Directory=`` or its link, a ``Symlinks=`` link, a
    ## ``MakeDirectory=``): the manager does that as root, and the add-on's
    ## own decisions read these trees (A9 review round 7, finding 2).
  AddOnReservedNames* = ["repro-agent", "repro-addon", "reprobuild"]
    ## Name prefixes the add-on's own units use directly under ``/run``,
    ## ``/var/lib``, ``/var/cache`` and ``/var/log`` (``repro-agent-fetch``,
    ## ``repro-addon-test-seam``).
  ManagerDirectoryRoots* = [("StateDirectory", "/var/lib"),
    ("RuntimeDirectory", "/run"), ("CacheDirectory", "/var/cache"),
    ("LogsDirectory", "/var/log"), ("ConfigurationDirectory", "/etc")]
    ## Where systemd creates each ``*Directory=`` (systemd.exec(5)).

proc inAddOnTree*(path: string): bool =
  ## ``path`` (absolute) lies in one of the add-on's own trees, or is named
  ## like one of its own units' directories.
  if hasDotDot(path): return true
  let np = normalisedPath(path)
  for r in AddOnOwnedRoots:
    if under(np, r): return true
  for root in ["/run", "/var/lib", "/var/cache", "/var/log", "/etc"]:
    if np.startsWith(root & "/"):
      let first = np[root.len + 1 .. ^1].split('/')[0]
      for n in AddOnReservedNames:
        if first.startsWith(n): return true

proc managerCreatedPaths*(directives: openArray[tuple[key, value: string]]):
    seq[tuple[key, path: string]] =
  ## Every path the service manager creates, as root, for a unit's
  ## ``[Service]`` lines: each ``*Directory=`` and each of its links
  ## (``a:b`` creates ``<root>/a`` and the link ``<root>/b``), normalised.
  for (k, v) in directives:
    for (dk, root) in ManagerDirectoryRoots:
      if k != dk: continue
      for t in v.splitWhitespace():
        let c = t.find(':')
        let dir = if c >= 0: t[0 ..< c] else: t
        result.add((k, normalisedPath(root & "/" & dir)))
        if c >= 0:
          result.add((k & "Symlink", normalisedPath(root & "/" & t[c + 1 .. ^1])))

const BaseSystemTreeNames* = [
    "ModemManager", "NetworkManager", "PackageKit", "README", "X11",
    "adduser", "adduser.conf", "agetty.reload", "alternatives",
    "alternatives.log", "app-info", "apparmor", "apparmor.d", "apport",
    "apport.log", "apt", "auth.log", "bash.bashrc", "bash_completion",
    "bash_completion.d", "bindresvport.blacklist", "binfmt.d", "blkid",
    "boltd", "btmp", "byobu", "ca-certificates", "ca-certificates.conf",
    "ca-certificates.conf.dpkg-old", "chrony", "cloud", "cloud-init",
    "cloud-init-output.log", "cloud-init.log", "cloud-release",
    "command-not-found", "console-setup", "credentials", "credstore",
    "credstore.encrypted", "cron.d", "cron.daily", "cron.hourly",
    "cron.monthly", "cron.weekly", "cron.yearly", "crond.pid",
    "crond.reboot", "crontab", "cryptsetup", "cryptsetup-initramfs",
    "crypttab", "dbus", "dbus-1", "debconf", "debconf.conf",
    "debian_version", "debuginfod", "default", "deluser.conf", "depmod.d",
    "dhcp", "dhcpcd", "dhcpcd.conf", "dist-upgrade", "dmesg",
    "dmeventd-client", "dmeventd-server", "dpkg", "dpkg.log", "dracut",
    "dracut.conf", "dracut.conf.d", "e2scrub.conf", "ec2_version",
    "environment", "ethertypes", "faillog", "fonts", "fsck", "fstab",
    "fuse.conf", "fwupd", "gai.conf", "git", "gnutls", "gprofng.rc", "groff",
    "group", "group-", "grub", "grub.d", "gshadow", "gshadow-", "gss",
    "hdparm.conf", "host.conf", "hostname", "hosts", "hosts.allow",
    "hosts.deny", "ieee-data", "init.d", "initctl", "initramfs",
    "initramfs-tools", "inputrc", "iproute2", "iscsi", "issue", "issue.net",
    "journal", "kern.log", "kernel", "kernel-img.conf", "landscape",
    "lastlog", "ld.so.cache", "ld.so.conf", "ld.so.conf.d", "ldap",
    "ldconfig", "legal", "libaudit.conf", "libblockdev", "libibverbs.d",
    "libnl-3", "libuuid", "locale.alias", "locale.conf", "locale.gen",
    "localtime", "lock", "log", "logcheck", "login.defs", "logrotate",
    "logrotate.conf", "logrotate.d", "lsb-release", "lvm",
    "lxd-installer.socket", "machine-id", "magic", "magic.mime", "man",
    "man-db", "manpath.config", "mdadm", "media", "mime.types", "misc",
    "mke2fs.conf", "modprobe.d", "modules", "modules-load.d", "motd",
    "motd-news", "motd.dynamic", "mount", "mtab", "multipath",
    "multipath.conf", "multipathd.pid", "multipathd.socket", "nanorc",
    "needrestart", "netconfig", "netplan", "network", "networkd-dispatcher",
    "networks", "newt", "nftables.conf", "nsswitch.conf", "opt", "os-prober",
    "os-release", "overlayroot.conf", "overlayroot.local.conf", "pam",
    "pam.conf", "pam.d", "passwd", "passwd-", "perl", "pki", "plymouth",
    "pm", "polkit", "polkit-1", "pollinate", "ppp", "private", "profile",
    "profile.d", "protocols", "python", "python3", "python3.11",
    "python3.12", "python3.13", "python3.14", "rc0.d", "rc1.d", "rc2.d",
    "rc3.d", "rc4.d", "rc5.d", "rc6.d", "rcS.d", "reportbug.conf",
    "resolv.conf", "rmt", "rpc", "rsyslog.conf", "rsyslog.d", "runit",
    "screen", "screenrc", "security", "selinux", "sendsigs.omit.d",
    "sensors.d", "sensors3.conf", "services", "setrans", "sgml", "sgml-base",
    "shadow", "shadow-", "shells", "shells.state", "shim-signed", "shm",
    "skel", "snapd", "snapd-snap.socket", "snapd.socket", "sos", "ssh",
    "ssh-unix-local", "sshd", "sshd.pid", "ssl", "subgid", "subgid-",
    "subuid", "subuid-", "sudo", "sudo.conf", "sudo_logsrvd.conf", "sudoers",
    "sudoers.d", "supercat", "sv", "swcatalog", "sysctl.conf", "sysctl.d",
    "syslog", "sysstat", "systemd", "terminfo", "timezone", "tmpfiles.d",
    "tpm", "tpm2-tss", "ubuntu-advantage", "ubuntu-release-upgrader", "ucf",
    "ucf.conf", "udev", "udisks2", "ufw", "unattended-upgrades",
    "unattended-upgrades.lock", "update-manager", "update-motd.d",
    "update-notifier", "usb_modeswitch", "usb_modeswitch.conf",
    "usb_modeswitch.d", "user", "utmp", "uuidd", "vconsole.conf", "vim",
    "vmware-tools", "vtrgb", "wgetrc", "wtmp", "wtmpdb", "xattr.conf", "xdg",
    "xfsprogs", "xml", "xml-core", "zsh_command_not_found"]
  ## Every name the base system has directly under ``/etc``, ``/run``,
  ## ``/var/lib``, ``/var/cache`` and ``/var/log`` on the supported bases
  ## (debian-12, debian-13, ubuntu-24.04, ubuntu-26.04 as the test bed
  ## prepares them; measured 2026-11-07, ``tests/fixtures/base_trees`` in
  ## ``repro_addon``; dot-files left out). §13 decision 57: a floored unit
  ## named like one of these, or a directory of its whose first component
  ## is one, is refused even before the tree exists on the host.

proc baseTreeUnitRefusal*(unitName: string): string =
  ## Why a floored unit may not have this name, or "": its stem is a tree
  ## the base system owns (``BaseSystemTreeNames``), whatever directories
  ## it declares (§13 decisions 57 and 70). The name alone would make every
  ## directory it may own a base tree's.
  # ``base-tree-names-allowed`` falsifies the whole list (round 9's
  # falsifier; round 10 made the unit's name the place it bites first);
  # ``base-tree-units-by-directory`` only the refusal by the name.
  when FloorMutation in ["base-tree-units-by-directory", "base-tree-names-allowed"]:
    return ""
  let stem = unitStem(unitName)
  if stem in BaseSystemTreeNames:
    return unitName & " is named after " & stem & ", a tree the base system " &
      "owns under /etc, /run, /var/lib, /var/cache or /var/log; a floored " &
      "unit is never named after one (§13 decisions 57 and 70)"
  ""

proc managerDirectoryRefusal*(unitName, key, token: string): string =
  ## Why one ``*Directory=`` value (``dir`` or ``dir:link``) of
  ## ``unitName`` names a place the floor does not allow, or "" (A9 review
  ## round 8, finding 1). Default deny by shape: every component of the
  ## directory and of its link is a plain name (letters, digits, ``.``,
  ## ``-``, ``_``; never ``.`` or ``..``), the link is one name, and the
  ## first component of each is named for the unit (``ownNamed``: exactly
  ## its stem, §13 decision 67). So the directory the manager creates and
  ## hands to the unit is the unit's own, directly under its base (``/run``,
  ## ``/var/lib``, ...), or below its own one; never
  ## in another program's tree (``systemd/system/x.service.d`` is a drop-in
  ## directory for any unit, ``udev/rules.d`` is udev's rules).
  when FloorMutation == "directory-names-unchecked":
    return ""
  let stem = unitStem(unitName)
  let c = token.find(':')
  let dir = if c >= 0: token[0 ..< c] else: token
  let link = if c >= 0: token[c + 1 .. ^1] else: ""
  proc plain(n: string): bool =
    n.len > 0 and n notin [".", ".."] and
      n.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '.', '-', '_'})
  let parts = dir.split('/')
  for p in parts:
    if not plain(p):
      return key & "=" & token & ": each component is a plain name"
  if not ownNamed(stem, parts[0]):
    return key & "=" & token & ": the directory is the unit's own, named " &
      "for it (" & stem & ", or below " & stem & "/); " & parts[0] & " is not"
  # §13 decision 57: never a tree the base system owns, whatever the unit
  # is called (``systemd.service`` with ``systemd/system/...``).
  when FloorMutation != "base-tree-names-allowed":
    if stem in BaseSystemTreeNames or parts[0] in BaseSystemTreeNames:
      return key & "=" & token & ": " & parts[0] & " is a tree the base " &
        "system owns (" & (if stem in BaseSystemTreeNames: "the unit is named " &
        "after it" else: "its first component") & "); a floored unit's " &
        "directories are its own, never an existing tree (§13 decision 57)"
  if c >= 0 and link.len > 0:          # "dir:" (systemd's report): no link
    if '/' in link or not plain(link):
      return key & "=" & token & ": a directory's link is one plain name"
    if not ownNamed(stem, link):
      return key & "=" & token & ": the link is named for the unit (" & stem &
        "); " & link & " is not"
  ""

proc managerPathRefusal*(directives: openArray[tuple[key, value: string]];
                         unitName = ""): string =
  ## Why a path the manager would create for these lines is not one a
  ## floored unit may have created (A9 review round 7, finding 2): one of
  ## the add-on's own trees (``inAddOnTree``), or a link with more than one
  ## component, which the manager creates, as root, inside a tree other
  ## software reads (``RuntimeDirectory=a:systemd/system/x.service.d`` is a
  ## drop-in directory for any unit). "" when none is.
  when FloorMutation == "manager-paths-unchecked":
    return ""
  if unitName.len > 0:
    for (k, v) in directives:
      for (dk, _) in ManagerDirectoryRoots:
        if k != dk: continue
        for t in v.splitWhitespace():
          let why = managerDirectoryRefusal(unitName, k, t)
          if why.len > 0: return why
  for (k, v) in directives:
    for (dk, _) in ManagerDirectoryRoots:
      if k != dk: continue
      for t in v.splitWhitespace():
        let c = t.find(':')
        if c >= 0 and ('/' in t[c + 1 .. ^1] or t[c + 1 .. ^1] in ["", ".", ".."]):
          return k & "=" & t & ": a directory's link is one name in " &
            "the directory's root; the manager creates it as root"
  for (k, p) in managerCreatedPaths(directives):
    if inAddOnTree(p):
      return k & " creates " & p & ", in the add-on's own tree; the " &
        "manager creates it as root"
  ""

proc conflictsRefusal*(unitName, content: string;
                       isOwn: proc (unit: string): bool;
                       half = fhParse): string =
  ## Why a ``[Unit]`` ``Conflicts=`` of a floored unit, or of a unit that
  ## activates one, is refused, or "" (§13 decision 55): it may name only
  ## units the profile defines (``isOwn``, a template's instances
  ## included). Starting the unit stops every unit it conflicts with, so
  ## naming a base target (``multi-user.target``) or another package's
  ## service would stop it -- the same class of action as decision 49. The
  ## exception for an exclusive successor's predecessor was withdrawn by the
  ## owner (A9 review round 8): it rested on the unit's own Conflicts=.
  if off3(half) or FloorMutation == "conflicts-unchecked":
    return ""
  for d in sectionDirectives(content, ["Unit"]):
    if d.key != "Conflicts": continue
    for t in d.value.splitWhitespace():
      if not isOwn(t):
        return "[Unit] Conflicts=" & t & " names a unit the profile does " &
          "not define; starting " & unitName & " would stop it (only the " &
          "profile's own units may be named)"
  ""

proc isSafeSecretComponent*(s: string): bool =
  ## One path segment of `[A-Za-z0-9._-]`, at most 64 bytes, not starting
  ## with `.` (so never `.`, `..`, or the materialiser's hidden temporary
  ## names): a secret's service and name both become a path component
  ## under `/run/repro/secrets` and part of a `LoadCredential=` line.
  if s.len == 0 or s.len > 64 or s[0] == '.':
    return false
  for c in s:
    if c notin {'A'..'Z', 'a'..'z', '0'..'9', '.', '-', '_'}:
      return false
  true

proc credentialServiceOf*(unitName: string): string =
  ## The secrets service of a unit: its name without `.service`, or "" when
  ## the unit cannot load credentials (not a `.service`, a template
  ## instance, or a name that is not a safe component).
  if not unitName.endsWith(".service"):
    return ""
  let stem = unitName[0 ..< unitName.len - ".service".len]
  if isSafeSecretComponent(stem): stem else: ""

const
  CredentialRunRoot* = "/run/repro/secrets"
    ## Where a service's own secrets are materialised
    ## (``/run/repro/secrets/<service>/<name>``, spec §10.3).
  FloorStoreRoot* = "/repro/store"
    ## The add-on's store.

proc environmentFileRefusal*(unitName, value: string;
                             ownFiles: openArray[string]): string =
  ## Why one ``EnvironmentFile=`` value of the floored unit ``unitName`` may
  ## not be read for it, by its written form, or "" (§13 decision 50; A9
  ## review round 7, finding 1). The service manager reads the file as root
  ## and gives its assignments to the service, so it may name only (a) a
  ## store path -- which the effective-unit check then requires to resolve
  ## into a store object the generation owns and has a digest for -- or a
  ## file the profile itself installs (``ownFiles``: the ``fs.systemFile``
  ## paths, which the add-on puts in place as links into its store); or (b)
  ## a file under the service's own ``/run/repro/secrets/<service>/``.
  ## Anything else is refused whatever its owner or mode: another service's
  ## secrets, ``/etc``, a host file. No wildcard, quoting, specifier or
  ## ``..``: the manager expands them, as root, after any check.
  when FloorMutation == "environment-files-by-mode":
    # Falsifying build: round 5's form rule (no wildcard, not under a
    # writable root), which accepted a host file by its owner and mode.
    let q0 = value.strip(leading = true, trailing = false, chars = {'-'})
    if q0.anyIt(it in {'*', '?', '['}): return "a wildcard"
    return ""
  let q = value.strip().strip(leading = true, trailing = false, chars = {'-'})
  if q.anyIt(it in {'*', '?', '['}):
    return "a wildcard is expanded by the manager, as root, after any " &
      "check; name the file"
  if not q.startsWith("/") or q.anyIt(it in QuoteOrSpecifier) or hasDotDot(q):
    return q & " is not a literal absolute path without `..`"
  let np = normalisedPath(q)
  let svc = credentialServiceOf(unitName)
  if svc.len > 0 and np.startsWith(CredentialRunRoot & "/" & svc & "/"):
    return ""
  if np.startsWith(FloorStoreRoot & "/"):
    return ""
  for f in ownFiles:
    if normalisedPath(f) == np: return ""
  np & " is neither in the add-on's store, nor a file this profile " &
    "installs, nor under the service's own secrets directory " &
    (if svc.len > 0: "(" & CredentialRunRoot & "/" & svc & "/)" else:
     "(it has none: not a plain .service)") & "; the manager reads it " &
    "as root and hands its contents to the service"

proc allowlistRefusal*(unitName, content: string;
                       ex: openArray[FloorException]; dropIn: bool;
                       half = fhParse): string =
  ## The first line of ``content`` (a floored unit, or a drop-in of one)
  ## outside the floor's allowlist that no exception names, or "". A key
  ## named in ``floorExceptions`` is accepted as written (and still held
  ## to the floor by the effective-unit check). ``PAMName=`` is refused
  ## with or without an exception: it opens a login session, starts the
  ## account's user manager outside the floor and can move the process out
  ## of the unit's control group (A9 review round 3, finding 6).
  if off3(half):
    return ""
  for d in sectionDirectives(content):
    let what = (if dropIn: "a drop-in's " else: "") & "[" & d.section &
               "] " & d.key & "=" & d.value
    if d.key == "PAMName":
      return what & " opens a login session outside the floor; it is " &
        "refused under the floor, with or without an exception"
    when FloorMutation != "state-targets-allowed":
      if d.section == "Unit" and d.key in StartingDependencyKeys:
        for t in d.value.splitWhitespace():
          if t in SystemStateTargets:
            return what & " starts " & t & ", which changes the whole " &
              "system's state (the floor refuses it as it refuses " &
              "FailureAction=)"
    if d.section notin ["Unit", "Service", "Install"]:
      if ExceptionsLiftRoot and waived(ex, d.key): continue
      return what & ": the section is not one a floored unit may carry " &
        "(only \"serviceFloor: <why>\" allows it)"
    let (ok, form) = allowedForm(d.section, d.key, dropIn)
    if not ok:
      # Only the keys floorExceptionKeys lists can be waived (round 4,
      # finding 4); a key off the allowlist is not one of them.
      if (ExceptionsLiftRoot or d.key in floorExceptionKeys()) and
          waived(ex, d.key): continue
      return what & " is not on the floor's allowlist" &
        (if dropIn: " for a drop-in" else: "") & "; it is refused under " &
        "the floor (only \"serviceFloor: <why>\" allows it)"
    if waived(ex, d.key): continue
    let why = formRefusal(d.key, d.value, form)
    if why.len > 0: return what & ": " & why
  ""

proc pathCannotBeJudged(path: string): bool =
  ## A path whose place the floor cannot decide from its text: a ``..``
  ## component, a specifier (``%``) or a variable (``$``).
  when FloorMutation == "floor-paths-unnormalised":
    false
  else:
    hasDotDot(path) or '%' in path or '$' in path

proc floorNoExecMounts*(directives: openArray[tuple[key, value: string]]):
    seq[string] =
  ## The mounts the floor's second ``NoExecPaths=`` names (``-`` prefixed):
  ## systemd's own (``FloorPrivateMounts``) and every directory the unit
  ## asks systemd to create (``FloorDirectoryKeys``). A directory value is
  ## ``name`` or, from systemd 254, ``name:link``; the first part is the
  ## directory.
  for m in FloorPrivateMounts: result.add("-" & m)
  # Every writable place the unit sets up itself is noexec too (round 3,
  # finding 2): a ReadWritePaths= entry, a bind's destination, a tmpfs.
  when not StaticRound3Off:
    for (k, v) in directives:
      case k
      of "ReadWritePaths":
        for tok in v.splitWhitespace():
          let q = tok.strip(leading = true, trailing = false, chars = {'-', '+'})
          if q.startsWith("/") and ("-" & q) notin result: result.add("-" & q)
      of "BindPaths", "BindReadOnlyPaths":
        for b in bindEntries(v):
          if isClosureUsrBind(b): continue
          if ("-" & b.dst) notin result: result.add("-" & b.dst)
      of "TemporaryFileSystem":
        for tok in v.splitWhitespace():
          let q = tok.split(':')[0]
          if q.startsWith("/") and ("-" & q) notin result: result.add("-" & q)
      else: discard
  for (k, v) in directives:
    for (dk, root) in FloorDirectoryKeys:
      if k != dk: continue
      for tok in v.splitWhitespace():
        let name = tok.split(':')[0]
        if name.len == 0 or hasDotDot(name): continue
        let p = "-" & root & "/" & name
        if p notin result: result.add(p)

proc floorWritablePlaces*(directives: openArray[tuple[key, value: string]]):
    seq[string] =
  ## Every place the unit's ``[Service]`` lines make writable for it, as
  ## normalised paths: ``ReadWritePaths=``, each writable bind's
  ## destination, each tmpfs, each ``*Directory=`` under its root.
  const roots = [("StateDirectory", "/var/lib"), ("RuntimeDirectory", "/run"),
                 ("CacheDirectory", "/var/cache"), ("LogsDirectory", "/var/log"),
                 ("ConfigurationDirectory", "/etc")]
  for (k, v) in directives:
    case k
    of "ReadWritePaths":
      for t in v.splitWhitespace():
        let q = t.strip(leading = true, trailing = false, chars = {'-', '+'})
        if q.startsWith("/"): result.add(normalisedPath(q))
    of "BindPaths":
      for t in v.splitWhitespace():
        let parts = t.strip(leading = true, trailing = false,
                            chars = {'-', '+'}).split(':')
        let d = if parts.len >= 2: parts[1] else: parts[0]
        if d.startsWith("/"): result.add(normalisedPath(d))
    of "TemporaryFileSystem":
      for t in v.splitWhitespace():
        let d = t.split(':')[0]
        if d.startsWith("/"): result.add(normalisedPath(d))
    else:
      for (dk, root) in roots:
        if k == dk:
          for t in v.splitWhitespace():
            result.add(normalisedPath(root & "/" & t.split(':')[0]))

type SocketOptionRule* = enum
  ## How the floor judges one ``[Socket]`` option of a unit that activates
  ## a floored service (systemd.socket(5)).
  sorListener   ## a network address, or a unix socket named for the unit
  sorBool       ## ``yes`` / ``no``
  sorNumber     ## a number, a size or a duration
  sorToken      ## one word
  sorUnit       ## a unit name
  sorAccount    ## one account name, never root
  sorMode       ## an octal mode
  sorPriority   ## ``SO_PRIORITY`` 0-6 (above 6 needs ``CAP_NET_ADMIN``)

const
  SocketOptionRules* = [
    ("ListenStream", sorListener), ("ListenDatagram", sorListener),
    ("ListenSequentialPacket", sorListener),
    ("Accept", sorBool), ("Service", sorUnit), ("BindIPv6Only", sorToken),
    ("Backlog", sorNumber), ("SocketUser", sorAccount),
    ("SocketGroup", sorAccount), ("SocketMode", sorMode),
    ("DirectoryMode", sorMode), ("MaxConnections", sorNumber),
    ("MaxConnectionsPerSource", sorNumber), ("KeepAlive", sorBool),
    ("KeepAliveTimeSec", sorNumber), ("KeepAliveIntervalSec", sorNumber),
    ("KeepAliveProbes", sorNumber), ("NoDelay", sorBool),
    ("Priority", sorPriority), ("DeferAcceptSec", sorNumber),
    ("IPTOS", sorToken), ("IPTTL", sorNumber), ("Broadcast", sorBool),
    ("PassCredentials", sorBool), ("PassPIDFD", sorBool),
    ("AcceptFileDescriptors", sorBool), ("PassPacketInfo", sorBool),
    ("Timestamping", sorToken), ("RemoveOnStop", sorBool),
    ("FileDescriptorName", sorToken), ("TriggerLimitIntervalSec", sorNumber),
    ("TriggerLimitBurst", sorNumber), ("PollLimitIntervalSec", sorNumber),
    ("PollLimitBurst", sorNumber), ("SocketProtocol", sorToken),
    ("FlushPending", sorBool), ("DeferTrigger", sorToken),
    ("DeferTriggerMaxSec", sorNumber), ("TimeoutSec", sorNumber)]
    ## Every ``[Socket]`` option a floored service's activator may carry,
    ## each with its rule (A9 review round 7, finding 3). Each is applied by
    ## the manager, as root, to the socket it hands the service, so only an
    ## option the service's own account could have applied is here. Any
    ## other option is refused (``SocketOptionsRefused`` says why for the
    ## ones systemd.socket(5) documents). ``SocketUser=``, ``SocketGroup=``,
    ## ``SocketMode=``, ``DirectoryMode=`` and ``RemoveOnStop=`` act on the
    ## unit's own listener paths only, since a unix listener must be named
    ## for the unit (``listenerRefusal``).
  SocketOptionsRefused* = [
    ("Mark", "SO_MARK sets the firewall and routing mark and needs CAP_NET_ADMIN (socket(7))"),
    ("Transparent", "IP_TRANSPARENT needs CAP_NET_ADMIN or CAP_NET_RAW (ip(7))"),
    ("BindToDevice", "SO_BINDTODEVICE needed CAP_NET_RAW before Linux 5.7 (socket(7))"),
    ("FreeBind", "IP_FREEBIND binds an address the host does not hold; no service needs the manager to do it"),
    ("PassSecurity", "SCM_SECURITY hands the service peer security labels; not reviewed for the floor"),
    ("ReusePort", "SO_REUSEPORT lets the socket share a port with another socket of the same owner, root (socket(7))"),
    ("ReceiveBuffer", "the manager forces it past the system limit with SO_RCVBUFFORCE, which needs CAP_NET_ADMIN (socket(7))"),
    ("SendBuffer", "the manager forces it past the system limit with SO_SNDBUFFORCE, which needs CAP_NET_ADMIN (socket(7))"),
    ("TCPCongestion", "a congestion algorithm outside tcp_allowed_congestion_control needs CAP_NET_ADMIN (tcp(7))"),
    ("SmackLabel", "a security label set as root"),
    ("SmackLabelIPIn", "a security label set as root"),
    ("SmackLabelIPOut", "a security label set as root"),
    ("SELinuxContextFromNet", "a security context taken as root"),
    ("Symlinks", "the manager creates links to the socket, as root, where the unit names"),
    ("Writable", "it applies only to the refused ListenSpecial=/ListenFIFO="),
    ("PipeSize", "it applies only to the refused ListenFIFO="),
    ("MessageQueueMaxMessages", "it applies only to the refused ListenMessageQueue="),
    ("MessageQueueMessageSize", "it applies only to the refused ListenMessageQueue="),
    ("PassFileDescriptorsToExec", "it applies only to the refused command lines"),
    ("ListenFIFO", "a FIFO is created and opened by the manager as root"),
    ("ListenSpecial", "a special file is opened by the manager as root"),
    ("ListenNetlink", "a netlink socket is opened by the manager as root"),
    ("ListenMessageQueue", "a message queue is created by the manager as root"),
    ("ListenUSBFunction", "a USB function is opened by the manager as root")]
  TimerKeys = ["OnActiveSec", "OnBootSec", "OnStartupSec", "OnUnitActiveSec",
    "OnUnitInactiveSec", "OnCalendar", "AccuracySec", "RandomizedDelaySec",
    "RandomizedOffsetSec", "FixedRandomDelay", "OnClockChange",
    "OnTimezoneChange", "Unit", "Persistent", "RemainAfterElapse"]
    ## Not here: ``WakeSystem=`` (resumes a suspended host).
  PathKeys = ["PathExists", "PathExistsGlob", "PathChanged", "PathModified",
    "DirectoryNotEmpty", "Unit", "TriggerLimitIntervalSec",
    "TriggerLimitBurst"]
    ## Path units watch; ``MakeDirectory=`` and its ``DirectoryMode=``
    ## (creating as root) are refused.
  OldSocketKeys = ["ListenStream", "ListenDatagram", "ListenSequentialPacket",
    "Accept", "Service", "BindIPv6Only", "Backlog", "BindToDevice",
    "SocketUser", "SocketGroup", "SocketMode", "DirectoryMode",
    "MaxConnections", "MaxConnectionsPerSource", "KeepAlive", "KeepAliveTimeSec",
    "KeepAliveIntervalSec", "KeepAliveProbes", "NoDelay", "Priority",
    "DeferAcceptSec", "ReceiveBuffer", "SendBuffer", "IPTOS", "IPTTL", "Mark",
    "ReusePort", "FreeBind", "Transparent", "Broadcast", "PassCredentials",
    "PassSecurity", "PassPacketInfo", "Timestamping", "TCPCongestion",
    "RemoveOnStop", "FileDescriptorName", "TriggerLimitIntervalSec",
    "TriggerLimitBurst", "PollLimitIntervalSec", "PollLimitBurst",
    "SocketProtocol", "FlushPending", "Writable"]
    ## Round 5's list, kept for the falsifying build ``socket-options-by-list``.

proc listenerRefusal*(unitName, value: string; service = ""): string =
  ## Why a ``ListenStream=``/``ListenDatagram=``/``ListenSequentialPacket=``
  ## value of an activator is not one the floor allows, or "": a network
  ## address (``port``, ``addr:port``, ``[addr]:port``, ``vsock:cid:port``),
  ## an abstract socket named for the unit (``@<stem>`` or below it), or a
  ## unix socket named for the unit under ``/run`` (``/run/<stem>`` or below
  ## ``/run/<stem>/``; §13 decision 67: exactly the stem), so
  ## that the manager creates and removes, as root, only the unit's own
  ## path, never another service's socket or the add-on's own tree (A9
  ## review rounds 5 and 7, findings 2 and 3).
  let v = value.strip()
  if v.len == 0: return ""   # a reset
  # §13 decision 78: named for the service the activator starts, not for
  # the activator, whose own name a profile chooses freely (``udev.socket``
  # with ``Service=a.service``). Without a known service, the activator's.
  let named =
    when FloorMutation == "listener-named-for-socket": unitName
    else: (if service.len > 0: service else: unitName)
  let stem = unitStem(named)
  proc ownName(n: string): bool = ownNamed(stem, n)
  when FloorMutation != "base-tree-activators-allowed":
    let firstName =
      if v.startsWith("/run/"): normalisedPath(v)["/run/".len .. ^1].split('/')[0]
      elif v.startsWith("@"): v[1 .. ^1].split('/')[0]
      else: ""
    if firstName in BaseSystemTreeNames:
      return v & " is inside " & firstName & ", a tree the base system owns; " &
        "the manager would unlink and replace that tree's socket as root " &
        "(§13 decision 78)"
  if v.startsWith("/"):
    if v.anyIt(it in QuoteOrSpecifier) or hasDotDot(v):
      return "a unix socket path is a literal path without `..`"
    let np = normalisedPath(v)
    if not np.startsWith("/run/"):
      return "a unix socket of a floored service lives under /run (the " &
        "manager creates it, as root)"
    when FloorMutation != "listeners-anywhere-under-run":
      if inAddOnTree(np):
        return np & " is in the add-on's own tree"
      let first = np["/run/".len .. ^1].split('/')[0]
      if not ownName(first):
        return np & " is not named for the unit (/run/" & stem & " or below " &
          "/run/" & stem & "/, so " &
          "the manager never creates, chowns or removes another's path)"
    return ""
  if v.startsWith("@"):
    if not ownName(v[1 .. ^1].split('/')[0]):
      return "an abstract socket is named for the unit (@" & stem & " or below it)"
    return ""
  if not v.allCharsInSet({'0'..'9', '.', ':', '[', ']', 'a'..'f', 'A'..'F',
                          'v', 's', 'o', 'c', 'k'}):
    return "not a network address or a unix socket path"
  ""

proc socketOptionRefusal*(unitName, key, value: string; service = ""): string =
  ## Why one ``[Socket]`` option of an activator is refused, or ""
  ## (``SocketOptionRules``).
  when FloorMutation == "socket-options-by-list":
    if key notin OldSocketKeys: return "not on round 5's list"
    if key in ["ListenStream", "ListenDatagram", "ListenSequentialPacket"]:
      let v = value.strip()
      if v.startsWith("/") and not normalisedPath(v).startsWith("/run/"):
        return "a unix socket lives under /run"
    return ""
  for (k, why) in SocketOptionsRefused:
    if k == key: return why
  for (k, rule) in SocketOptionRules:
    if k != key: continue
    let v = value.strip()
    case rule
    of sorListener: return listenerRefusal(unitName, v, service)
    of sorBool:
      if v.toLowerAscii() notin ["yes", "no", "true", "false", "1", "0", "on", "off"]:
        return "not a boolean"
    of sorNumber:
      if not v.allCharsInSet({'0'..'9', '.', 'a'..'z', 'A'..'Z', ' '}) or
          v.len == 0 or v[0] notin {'0'..'9'} and v != "infinity":
        return "not a number, size or duration"
    of sorToken:
      if not v.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.', ':'}):
        return "not one word"
    of sorUnit:
      if not safeUnitName(v): return "not a unit name"
    of sorAccount:
      if not isAccountName(v) or v == "root": return "not a literal non-root account"
    of sorMode:
      if not (v.len in 3 .. 4 and v.allCharsInSet({'0'..'7'})): return "not an octal mode"
    of sorPriority:
      let n = (try: parseInt(v) except ValueError: -2)
      if n notin 0 .. 6:
        return "SO_PRIORITY above 6 needs CAP_NET_ADMIN (socket(7)); 0-6 only"
    return ""
  "is not an option the floor reviewed for a unit that activates a " &
    "floored service (systemd.socket(5))"

proc baseTreeActivatorRefusal*(unitName: string): string =
  ## Why a unit that activates a floored service may not have this name,
  ## or "": its stem is a tree the base system owns (§13 decision 78), as
  ## for the floored unit itself (decision 70). ``udev.socket`` would be
  ## the base's own socket name.
  when FloorMutation == "base-tree-activators-allowed":
    return ""
  let stem = unitStem(unitName)
  if stem in BaseSystemTreeNames:
    return unitName & " activates a floored service and is named after " & stem &
      ", a tree the base system owns; such a unit is never named after one " &
      "(§13 decision 78)"
  ""

proc activatorRefusal*(unitName, content: string; dropIn: bool;
                       half = fhParse; service = ""): string =
  ## A socket, timer or path unit that activates a floored service, or a
  ## drop-in onto one (A9 review rounds 5 and 7): the manager opens a
  ## socket's listeners as root and hands them to the service, applies its
  ## options as root, and runs its commands as root. No command line; in
  ## its own section, each option by its rule (``socketOptionRefusal``, the
  ## timer and path keys); ``[Unit]`` and ``[Install]`` as for a floored
  ## service. Its dependencies are judged with the floored units'
  ## (``systemStateRoute``).
  if off5(half) or FloorMutation == "activator-options-unchecked":
    return ""
  let dot = unitName.rfind('.')
  let typ = if dot >= 0: unitName[dot + 1 .. ^1] else: ""
  let section = case typ
    of "socket": "Socket"
    of "timer": "Timer"
    of "path": "Path"
    else: ""
  if section.len == 0: return ""
  # Its name, at parse time only: the effective half has its own rule for
  # it (``unit-name``), so the rerun does not report it twice.
  if half == fhParse and not dropIn:
    let bn = baseTreeActivatorRefusal(unitName)
    if bn.len > 0: return bn
  for d in sectionDirectives(content):
    let what = (if dropIn: "a drop-in's " else: "") & "[" & d.section & "] " &
               d.key & "=" & d.value
    if d.key.startsWith("Exec"):
      return what & ": a command line on a unit that activates a floored " &
        "service runs as root, outside the floor"
    if d.section == section:
      let why = case typ
        of "socket": socketOptionRefusal(unitName, d.key, d.value, service)
        of "timer": (if d.key in TimerKeys: "" else: "is not a timer setting the floor allows")
        else: (if d.key in PathKeys: "" else: "is not a path-unit setting the floor allows (MakeDirectory= creates, as root)")
      if why.len > 0:
        return what & ": " & why
    elif d.section in ["Unit", "Install"]:
      if not allowedForm(d.section, d.key, dropIn)[0]:
        return what & " is not on the floor's allowlist"
      when FloorMutation != "state-targets-allowed":
        if d.section == "Unit" and d.key in StartingDependencyKeys:
          for t in d.value.splitWhitespace():
            if t in SystemStateTargets:
              return what & " starts " & t & ", which changes the whole " &
                "system's state"
    else:
      return what & ": the section is not one such a unit may carry"
  ""

proc floorRefusal*(unitName: string;
                   directives: openArray[tuple[key, value: string]];
                   ex: openArray[FloorException]; execPaths: seq[string];
                   dropIn: bool; half = fhParse): string =
  ## The first weakening in ``directives`` (a unit's ``[Service]`` section,
  ## or a drop-in's, ``dropIn``) that no exception names, or "". The rules
  ## of the module header; a drop-in is read after the floor's own lines,
  ## so every floor setting it assigns -- even empty -- is a change.
  var floorValues = initTable[string, seq[string]]()
  for (k, v) in FloorFixed: floorValues.mgetOrPut(k, @[]).add(v)
  # systemd keeps the last assignment of a scalar: `User=a` then `User=`
  # is no account at all (A9 review round 3, finding 1).
  var lastUser = ""
  for (k, v) in directives:
    if k == "User":
      lastUser = v
  let hasAccount = isAccountName(lastUser) and lastUser notin ["root"]
  # The paths the manager creates for the unit, as root (A9 review round 7,
  # finding 2): never in the add-on's own trees, and a directory's link is
  # one name.
  # The unit's name, at parse time only: the effective half has its own
  # rule for it (``unit-name``), so the rerun does not report it twice.
  if half == fhParse and not off3(half):
    let bn = baseTreeUnitRefusal(unitName)
    if bn.len > 0: return bn
  if not off3(half):
    let mp = managerPathRefusal(directives, unitName)
    if mp.len > 0:
      return (if dropIn: "a drop-in's " else: "") & mp
  for (k, v) in directives:
    let what = (if dropIn: "a drop-in's " else: "") & k & "=" & v
    case k
    of "NoExecPaths", "ExecPaths":
      if not waived(ex, ExecConfinementException):
        return what & " would change the floor's exec confinement, which " &
          "derives ExecPaths= from the unit's closure (name the exception " &
          "\"" & ExecConfinementException & ": <why>\", or add paths with " &
          "\"ExecPaths+<path>: <why>\")"
    of "RestrictAddressFamilies":
      if not waived(ex, k) and (v.len == 0 or v.startsWith("~")):
        return what & " allows every address family but a few; the floor " &
          "wants the families the service uses (or name the exception " &
          "\"RestrictAddressFamilies: <why>\")"
    of "User", "Group":
      # Root, and a privileged group, are refused under the floor whatever
      # it names (round 4, finding 4): only the whole-floor waiver, under
      # which the unit has no floor, lets a service run as root.
      if v in ["root", "0"] and (not ExceptionsLiftRoot or not waived(ex, "User")):
        return what & " runs the service as root; a floored unit may not " &
          "(only the whole-floor waiver \"serviceFloor: <why>\" allows it)"
      if k == "Group" and v in PrivilegedGroups and not ExceptionsLiftRoot and
          not off3(half):
        return what & " runs the service in the privileged group " & v &
          "; a floored unit may not (only \"serviceFloor: <why>\" allows it)"
      if not off3(half):
        if not isAccountName(v) and not waived(ex, "User"):
          return what & ": an empty value, a number or a specifier is not " &
            "a literal account, and systemd may run the service as root; " &
            "name the exception \"User: <why>\""
        if dropIn and not waived(ex, "User"):
          return what & " changes the account of a floored unit; a " &
            "drop-in may not (name the exception \"User: <why>\")"
    of "DynamicUser":
      if off3(half):
        if v.toLowerAscii() in ["no", "false", "0", "off"] and
            not hasAccount and not waived(ex, "DynamicUser"):
          return what & " without a User= runs the service as root; name " &
            "the exception \"DynamicUser: <why>\""
      else:
        if not waived(ex, "DynamicUser"):
          if v notin ["yes", "no"]:
            return what & ": the floor reads only yes or no here; name " &
              "the exception \"DynamicUser: <why>\""
          if v == "no" and not hasAccount:
            return what & " without a literal User= runs the service as " &
              "root; a floored unit may not (only \"serviceFloor: <why>\" " &
              "allows it)"
          if dropIn:
            return what & " changes the account of a floored unit; a " &
              "drop-in may not (name the exception \"DynamicUser: <why>\")"
        elif v.toLowerAscii() in ["no", "false", "0", "off"] and
            not hasAccount and not ExceptionsLiftRoot:
          # Round 4, finding 4: a DynamicUser exception lifts the spelling
          # rules, never root.
          return what & " without a literal User= runs the service as " &
            "root, which a DynamicUser exception does not allow (only " &
            "\"serviceFloor: <why>\" does)"
    of "EnvironmentFile":
      # The manager reads it as root and hands its contents to the service:
      # default-deny (§13 decision 50, A9 review round 7, finding 1). Here
      # its form; what it may name is decided over the profile
      # (``environmentFileRefusal``, ``profile.checkFloorActivators``) and,
      # where it resolves, by the effective-unit check.
      if not off5(half):
        for t in v.splitWhitespace():
          let q = t.strip(leading = true, trailing = false, chars = {'-'})
          if q.anyIt(it in {'*', '?', '['}):
            return what & ": a wildcard is expanded by the manager, as " &
              "root, after any check; name the file"
          if not q.startsWith("/") or q.anyIt(it in QuoteOrSpecifier) or
              hasDotDot(q):
            return what & ": not a literal absolute path without `..`"
    of "CPUSchedulingPolicy", "IOSchedulingClass":
      # A realtime policy is what RestrictRealtime= forbids (A9 review
      # round 5, finding 3); the manager sets it before the sandbox.
      if not off5(half):
        if v.toLowerAscii() in ["fifo", "rr", "realtime", "1", "2"] and
            (k == "CPUSchedulingPolicy" or v.toLowerAscii() in ["realtime", "1"]) and
            not waived(ex, "RestrictRealtime"):
          return what & " is realtime scheduling, which the floor's " &
            "RestrictRealtime=yes forbids (name the exception " &
            "\"RestrictRealtime: <why>\")"
    of "SupplementaryGroups":
      for gname in v.splitWhitespace():
        if gname in PrivilegedGroups and
            (not ExceptionsLiftRoot or not waived(ex, k)):
          return what & " adds the privileged group " & gname &
            "; a floored unit may not (only \"serviceFloor: <why>\" allows it)"
    of "ReadWritePaths":
      if not off3(half):
        if dropIn and v.len > 0 and not waived(ex, k):
          return what & " makes a path writable that the unit's own noexec " &
            "line does not cover; a drop-in may not (name the exception " &
            "\"ReadWritePaths: <why>\")"
      if not waived(ex, k):
        for tok in v.splitWhitespace():
          let p = tok.strip(leading = true, trailing = false,
                            chars = {'-', '+'})
          if p.len == 0: continue
          if pathCannotBeJudged(p) or
              (not off3(half) and p.anyIt(it in QuoteOrSpecifier)):
            return what & " names " & p & ", which the floor cannot place " &
              "(a '..' component or a specifier); name the exception " &
              "\"ReadWritePaths: <why>\""
          if not off3(half):
            for kt in KernelTrees:
              if under(p, kt) or under(kt, p):
                return what & " makes " & p & " writable, in or over the " &
                  "kernel's " & kt & "; name the exception \"ReadWritePaths: <why>\""
          for root in @ProtectedRoots & execPaths:
            if under(root, p) or (root in execPaths and under(p, root)):
              return what & " makes " & p & " writable, which " &
                (if root in execPaths: "overlaps the executable path " & root
                 else: "contains " & root) &
                "; name the exception \"ReadWritePaths: <why>\""
    of "TemporaryFileSystem", "BindPaths", "BindReadOnlyPaths":
      if not off3(half):
        if dropIn and v.len > 0 and not waived(ex, ExecConfinementException):
          return what & " sets up a writable place the unit's own noexec " &
            "line does not cover; a drop-in may not (name the exception \"" &
            ExecConfinementException & ": <why>\")"
      if not waived(ex, ExecConfinementException):
        if v.len == 0 and k != "TemporaryFileSystem":
          continue   # an empty bind list is apt_closure's refusal to make
        let entries = if k == "TemporaryFileSystem":
                        (block:
                          var s: seq[tuple[optional: bool; src, dst: string]]
                          for tok in v.splitWhitespace():
                            let p = tok.split(':')[0]
                            s.add((optional: false, src: p, dst: p))
                          s)
                      else: bindEntries(v)
        if not off3(half):
          if k == "TemporaryFileSystem":
            # Only a mode may be set: `exec`, `suid`, `dev` and the rest
            # undo what the floor's noexec line does (round 3, finding 2).
            for tok in v.splitWhitespace():
              let c = tok.find(':')
              if c >= 0:
                for o in tok[c + 1 .. ^1].split(','):
                  if not (o.startsWith("mode=") and
                          o[5 .. ^1].allCharsInSet({'0'..'7'})):
                    return what & ": the floor allows only mode= as a " &
                      "TemporaryFileSystem= option; name the exception \"" &
                      ExecConfinementException & ": <why>\""
          for tok in v.splitWhitespace():
            if tok.anyIt(it in QuoteOrSpecifier):
              return what & ": a quoted, escaped or specifier path is not " &
                "one the floor can place; name the exception \"" &
                ExecConfinementException & ": <why>\""
        for b in entries:
          if k == "BindReadOnlyPaths" and isClosureUsrBind(b): continue
          if not off3(half):
            if k != "BindReadOnlyPaths":
              for kt in KernelTrees:
                if under(b.dst, kt) or under(kt, b.dst):
                  return what & " mounts over " & b.dst & ", in or over the " &
                    "kernel's " & kt & "; name the exception \"" &
                    ExecConfinementException & ": <why>\""
          if pathCannotBeJudged(b.dst):
            return what & " mounts over " & b.dst & ", which the floor " &
              "cannot place (a '..' component or a specifier); name the " &
              "exception \"" & ExecConfinementException & ": <why>\""
          for x in execPaths:
            if overlaps(b.dst, x):
              return what & " mounts over " & b.dst & ", which overlaps the " &
                "executable path " & x & "; name the exception \"" &
                ExecConfinementException & ": <why>\""
    of "MountImages", "ExtensionImages", "ExtensionDirectories":
      when FloorMutation != "floor-allows-images":
        if v.len > 0 and not waived(ex, k):
          return what & " mounts another file system's contents into the " &
            "unit's namespace, which the floor's paths do not describe; " &
            "name the exception \"" & k & ": <why>\""
    of "ReadOnlyPaths":
      if not off3(half):
        if not waived(ex, k) and v.anyIt(it in QuoteOrSpecifier):
          return what & ": a quoted, escaped or specifier path is not one " &
            "the floor can place; name the exception \"ReadOnlyPaths: <why>\""
        if not waived(ex, k):
          for tok in v.splitWhitespace():
            let q = tok.strip(leading = true, trailing = false, chars = {'-', '+'})
            if not q.startsWith("/"):
              return what & ": '" & tok & "' is not an absolute path; name " &
                "the exception \"ReadOnlyPaths: <why>\""
      if dropIn and v.len == 0 and not waived(ex, k):
        return what & " (empty) resets ReadOnlyPaths=, dropping the " &
          "floor's read-only " & ProcReadOnly & "; name the exception " &
          "\"ReadOnlyPaths: <why>\""
    of "RootDirectory", "RootImage", "RootEphemeral", "RootImageOptions":
      if not waived(ex, "RootDirectory"):
        return what & " runs the service in another root, where the " &
          "floor's paths mean something else; name the exception " &
          "\"RootDirectory: <why>\""
    else:
      # A unit line equal to the floor's is not a weakening; a drop-in's
      # assignment of a floor setting always is (it overrides, appends to
      # or -- empty -- resets the floor's line).
      if k in floorValues and not waived(ex, k) and
          (dropIn or v notin floorValues[k]):
        return what & " differs from the floor's " & k & "=" &
          floorValues[k].join(" / ") & "; name the exception \"" & k &
          ": <why>\"" & (if k in FloorAdditiveKeys:
            " or add to it with \"" & k & "+<value>: <why>\"" else: "")
      if k in FloorExecKeys:
        for c in commands(v):
          if '+' in c.prefixes and not waived(ex, WholeFloorException):
            return what & " runs with the '+' prefix, outside every " &
              "sandboxing setting (name the exception \"serviceFloor: <why>\")"
          if '!' in c.prefixes and
              (not ExceptionsLiftRoot or not waived(ex, "User")):
            return what & " runs with the '!' prefix, without the user " &
              "change (as root); a floored unit may not (only " &
              "\"serviceFloor: <why>\" allows it)"
          if dropIn and not waived(ex, ExecConfinementException) and
              c.path.len > 0:
            if pathCannotBeJudged(c.path):
              return what & " runs " & c.path & ", which the floor cannot " &
                "place (a '..' component, a specifier or a variable); name " &
                "the exception \"" & ExecConfinementException & ": <why>\""
            var inside = false
            for p in execPaths:
              if c.path.startsWith("/") and under(c.path, p): inside = true
            if "/usr" in execPaths and insideBoundUsr(c.path): inside = true
            if not inside:
              return what & " runs " & c.path & ", outside the unit's " &
                "closure (" & execPaths.join(" ") & "); name the exception " &
                "\"" & ExecConfinementException & ": <why>\""
  ""

proc renderServiceFloorLines*(unitName, content: string;
                              ex: openArray[FloorException];
                              dropExec = false; dropMdwe = false;
                              allowMemfd = false): seq[string] =
  ## The lines the floor appends to ``content``'s ``[Service]`` section.
  ## Refuses (``EServiceFloor``) a unit that weakens the floor without
  ## naming the exception (``floorRefusal``). ``dropExec``, ``dropMdwe`` and
  ## ``allowMemfd`` exist for the falsifying builds of the exec gate only.
  if waived(ex, WholeFloorException): return @[]
  let directives = serviceDirectives(content)
  let execPaths = floorExecPaths(unitName, content, ex)
  let allowed = allowlistRefusal(unitName, content, ex, dropIn = false)
  if allowed.len > 0: raiseFloor(unitName, allowed)
  let why = floorRefusal(unitName, directives, ex, execPaths, dropIn = false)
  if why.len > 0: raiseFloor(unitName, why)
  var hasUser, hasFamilies = false
  var lastUser, lastDyn = ""
  for (k, v) in directives:
    if k == "User": lastUser = v
    if k == "DynamicUser": lastDyn = v
    if k == "RestrictAddressFamilies": hasFamilies = true
  when StaticRound3Off:
    for (k, v) in directives:
      if k in ["User", "DynamicUser"]: hasUser = true
  else:
    # An account systemd will use, by the last assignment: a literal
    # User= (DynamicUser=no) or DynamicUser=yes. Anything else gets a
    # dynamic user (round 3, finding 1).
    hasUser = (isAccountName(lastUser) and lastDyn != "yes") or
              lastDyn == "yes"
  result.add("# serviceFloor (ReproOS add-on hardening default)")
  for (k, v) in FloorFixed:
    if waived(ex, k): continue
    if dropMdwe and k == "MemoryDenyWriteExecute": continue
    var value = v
    if allowMemfd and k == "SystemCallFilter" and v.startsWith("~"):
      value = value.replace(" memfd_create", "")
    when FloorMutation == "floor-allows-sysv-shm":
      if k == "SystemCallFilter" and v.startsWith("~"):
        value = value.replace(" shmget shmat shmdt shmctl", "")
    if k in ["CapabilityBoundingSet", "AmbientCapabilities"]:
      value = additions(ex, k).join(" ")
    result.add(k & "=" & value)
    if k == "SystemCallFilter" and v.startsWith("~"):
      let adds = additions(ex, k)
      if adds.len > 0: result.add("SystemCallFilter=" & adds.join(" "))
  if not hasFamilies and not waived(ex, "RestrictAddressFamilies"):
    result.add("RestrictAddressFamilies=" & FloorDefaultAddressFamilies)
  if not hasUser and not waived(ex, "DynamicUser"):
    result.add("DynamicUser=yes")
  elif not hasUser and not ExceptionsLiftRoot:
    # A DynamicUser exception and no account: systemd runs it as root.
    raiseFloor(unitName, "the exception \"DynamicUser\" with no literal " &
      "User= runs the service as root, which a floored unit may not (name " &
      "an account, or \"serviceFloor: <why>\")")
  if not waived(ex, ExecConfinementException) and not dropExec:
    result.add("NoExecPaths=/")
    when FloorMutation != "floor-private-mounts-exec":
      result.add("NoExecPaths=" & floorNoExecMounts(directives).join(" "))
    if execPaths.len > 0:
      result.add("ExecPaths=" & execPaths.join(" "))
  when FloorMutation != "floor-proc-writable":
    if not waived(ex, "ReadOnlyPaths"):
      result.add("ReadOnlyPaths=" & ProcReadOnly)
  for e in ex:
    let head = if e.adds.len > 0: e.setting & "+" & e.adds.join(" ")
               else: e.setting
    result.add("# serviceFloor exception: " & head & ": " & e.reason)

proc dropInFloorRefusal*(unitName, unitContent, dropInContent: string;
                         ex: openArray[FloorException];
                         half = fhParse): string =
  ## The first weakening a drop-in of a floored unit makes to the unit's
  ## effective configuration, or "" (spec §10.1): every floor setting it
  ## assigns, a command outside the unit's closure, and the guarded
  ## settings of ``floorRefusal``. Its non-``[Service]`` sections may not
  ## carry command lines either.
  if waived(ex, WholeFloorException): return ""
  for d in sectionDirectives(dropInContent):
    if d.section != "Service" and (d.key in FloorExecKeys or
                                   d.key.startsWith("Exec")):
      return "a drop-in's [" & d.section & "] " & d.key & "= runs a " &
        "command outside the floored [Service] section"
  let allowed = allowlistRefusal(unitName, dropInContent, ex, dropIn = true,
                                 half = half)
  if allowed.len > 0: return allowed
  let execPaths = floorExecPaths(unitName, unitContent, ex)
  floorRefusal(unitName, serviceDirectives(dropInContent), ex, execPaths,
               dropIn = true, half = half)

proc appendToServiceSection*(content: string; lines: seq[string]): string =
  ## ``content`` with ``lines`` at the end of its ``[Service]`` section
  ## (before the next section header; trailing blank lines stay after
  ## them). ``content`` is returned unchanged when ``lines`` is empty. A
  ## section whose last line ends in a backslash continues onto the next
  ## line (systemd.syntax(7)), so an empty line is put between it and the
  ## appended lines: otherwise the first of them would be joined to the
  ## unit's last value.
  if lines.len == 0: return content
  var outLines: seq[string]
  var inService = false
  var done = false
  proc flush(outLines: var seq[string]) =
    var tail: seq[string]
    while outLines.len > 0 and outLines[^1].strip().len == 0:
      tail.add(outLines.pop())
    if outLines.len > 0 and outLines[^1].strip(leading = false).endsWith("\\"):
      outLines.add("")
    outLines.add(lines)
    for i in countdown(tail.high, 0): outLines.add(tail[i])
  for l in content.split('\n'):
    let t = l.strip()
    if t.startsWith("[") and t.endsWith("]"):
      if inService and not done:
        flush(outLines)
        done = true
      inService = t == "[Service]"
    outLines.add(l)
  if inService and not done:
    # The [Service] section runs to the end of the file. A file that ends
    # in a newline splits into a last empty element; keep it last.
    var trailingNewline = false
    if outLines.len > 0 and outLines[^1].len == 0:
      discard outLines.pop()
      trailingNewline = true
    flush(outLines)
    if trailingNewline: outLines.add("")
  outLines.join("\n")

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

import std/[algorithm, strutils, tables]

const FloorMutation {.strdefine: "reproAddonMutation".} = ""
  ## The falsifying builds of the A9 gates (``repro_addon/mutations``):
  ## never set in a product build.

const
  FloorVersion* = "3"
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
    ## The floor's ``ReadOnlyPaths=`` (``/proc/self/mem`` writes; header).

  MergedUsrAliases* = [("/bin", "/usr/bin"), ("/sbin", "/usr/sbin"),
                       ("/lib", "/usr/lib"), ("/lib64", "/usr/lib64"),
                       ("/lib32", "/usr/lib32"), ("/libx32", "/usr/libx32")]
    ## Debian 12+ and Ubuntu are merged-``/usr``: each is a link into
    ## ``/usr``, so ``/bin/x`` and ``/usr/bin/x`` name one file.

  PrivilegedGroups* = ["root", "0", "sudo", "wheel", "adm", "admin", "disk",
    "shadow", "kmem", "docker", "lxd", "incus", "incus-admin", "libvirt",
    "kvm", "systemd-journal", "systemd-network", "plugdev", "staff"]
    ## Supplementary groups that grant administrative reach on a Debian or
    ## Ubuntu base: root's own, sudo/wheel/admin (privilege), adm and
    ## systemd-journal (every log), disk and kmem (raw devices), shadow
    ## (password hashes), docker/lxd/incus/libvirt/kvm (root-equivalent
    ## container and VM control), systemd-network, plugdev and staff
    ## (device and /usr/local write access).

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
    if k notin keys:
      raiseFloor(unitName, "floor exception '" & k & "' names no " &
        "serviceFloor setting (one of " & keys.join(", ") & ")")
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
  ## text says. Sorted.
  for d in sectionDirectives(content):
    var i = d.value.find(FloorStorePrefixRoot)
    while i >= 0:
      var j = i
      while j < d.value.len and d.value[j] notin {' ', '\t', '\'', '"', ';',
                                                  ':', '=', ','}:
        inc j
      let obj = storeObjectOf(d.value[i ..< j])
      if obj.len > 0 and obj notin result: result.add(obj)
      i = d.value.find(FloorStorePrefixRoot, j)
  result.sort()

proc commandStoreObjects*(content: string): seq[string] =
  ## The store prefixes ``content`` names (``referencedStoreObjects``): what
  ## the switch re-verifies before its flip.
  referencedStoreObjects(content)

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
  for (k, v) in directives:
    for (dk, root) in FloorDirectoryKeys:
      if k != dk: continue
      for tok in v.splitWhitespace():
        let name = tok.split(':')[0]
        if name.len == 0 or hasDotDot(name): continue
        let p = "-" & root & "/" & name
        if p notin result: result.add(p)

proc floorRefusal*(unitName: string;
                   directives: openArray[tuple[key, value: string]];
                   ex: openArray[FloorException]; execPaths: seq[string];
                   dropIn: bool): string =
  ## The first weakening in ``directives`` (a unit's ``[Service]`` section,
  ## or a drop-in's, ``dropIn``) that no exception names, or "". The rules
  ## of the module header; a drop-in is read after the floor's own lines,
  ## so every floor setting it assigns -- even empty -- is a change.
  var floorValues = initTable[string, seq[string]]()
  for (k, v) in FloorFixed: floorValues.mgetOrPut(k, @[]).add(v)
  var hasAccount = false
  for (k, v) in directives:
    if k == "User" and v.len > 0 and v notin ["root", "0"]: hasAccount = true
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
      if v in ["root", "0"] and not waived(ex, "User"):
        return what & " runs the service as root; name the exception " &
          "\"User: <why>\""
    of "DynamicUser":
      if v.toLowerAscii() in ["no", "false", "0", "off"] and
          not hasAccount and not waived(ex, "DynamicUser"):
        return what & " without a User= runs the service as root; name " &
          "the exception \"DynamicUser: <why>\""
    of "SupplementaryGroups":
      for gname in v.splitWhitespace():
        if gname in PrivilegedGroups and not waived(ex, k):
          return what & " adds the privileged group " & gname &
            "; name the exception \"SupplementaryGroups: <why>\""
    of "ReadWritePaths":
      if not waived(ex, k):
        for tok in v.splitWhitespace():
          let p = tok.strip(leading = true, trailing = false,
                            chars = {'-', '+'})
          if p.len == 0: continue
          if pathCannotBeJudged(p):
            return what & " names " & p & ", which the floor cannot place " &
              "(a '..' component or a specifier); name the exception " &
              "\"ReadWritePaths: <why>\""
          for root in @ProtectedRoots & execPaths:
            if under(root, p) or (root in execPaths and under(p, root)):
              return what & " makes " & p & " writable, which " &
                (if root in execPaths: "overlaps the executable path " & root
                 else: "contains " & root) &
                "; name the exception \"ReadWritePaths: <why>\""
    of "TemporaryFileSystem", "BindPaths", "BindReadOnlyPaths":
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
        for b in entries:
          if k == "BindReadOnlyPaths" and isClosureUsrBind(b): continue
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
          if '!' in c.prefixes and not waived(ex, "User"):
            return what & " runs with the '!' prefix, without the user " &
              "change; name the exception \"User: <why>\""
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
  let why = floorRefusal(unitName, directives, ex, execPaths, dropIn = false)
  if why.len > 0: raiseFloor(unitName, why)
  var hasUser, hasFamilies = false
  for (k, v) in directives:
    if k in ["User", "DynamicUser"]: hasUser = true
    if k == "RestrictAddressFamilies": hasFamilies = true
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
                         ex: openArray[FloorException]): string =
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
  let execPaths = floorExecPaths(unitName, unitContent, ex)
  floorRefusal(unitName, serviceDirectives(dropInContent), ex, execPaths,
               dropIn = true)

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

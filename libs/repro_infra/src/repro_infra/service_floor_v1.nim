## FROZEN: the serviceFloor renderer as reprobuild 1a598170c0 shipped it (floor
## version 1). Do not edit: a generation that engine stored names no
## floor version, and the add-on re-renders its units with exactly this
## code to restore them byte for byte (spec §10.1, *Stored generations
## and floor versions*; `profile.renderedSystemUnitContent`).
## Generated with `git show 1a598170c0:libs/repro_infra/src/repro_infra/service_floor.nim`.
##
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
## namespace ``noexec``, and ``ExecPaths=`` names the only paths it may
## execute from -- the store prefixes its command lines run from and, when an
## apt closure is bound over ``/usr``, that ``/usr``. A root process outside
## the add-on that drops a binary anywhere else on the host cannot have an
## add-on service execute it, and ``MemoryDenyWriteExecute=yes`` stops the
## service making new code in memory instead. That is the compensating
## control for the add-on's one detection gap: the distribution's own
## ``/usr`` is outside every closure the add-on can enumerate.
##
## systemd semantics relied on (systemd.exec(5),
## https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html):
##
## * ``NoExecPaths=`` / ``ExecPaths=``: "``ExecPaths=`` takes precedence over
##   ``NoExecPaths=``"; both apply to every command line of the unit
##   (``ExecStartPre=`` included) and to everything those execute.
## * ``SystemCallFilter=``: the first line decides the mode (an allow-list);
##   a later ``~`` line removes from it, a later plain line adds to it. The
##   floor's deny line therefore comes last in the section, after anything
##   the unit wrote.
## * A ``+`` command prefix runs that command "with full privileges",
##   outside every sandboxing setting, so the floor refuses it.
##
## **Weakening is a named exception, never a silent override.** A unit that
## sets one of the floor's settings to anything else, or that the floor
## would confine in a way it cannot run under (a binary outside its
## closure), is refused unless the resource lists the setting in
## ``floorExceptions`` with a reason: ``"MemoryDenyWriteExecute: the JVM
## needs a JIT"``. ``"serviceFloor: <reason>"`` waives the whole floor, and
## the unit is then rendered exactly as written. Every exception is printed
## in every plan (``floorExceptionLines``).
##
## The rendered lines are appended at the end of the unit's ``[Service]``
## section; the unit's own text is never rewritten.

import std/[algorithm, strutils, tables]

const
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
    ("SystemCallFilter", "~@privileged @obsolete"),
    ("CapabilityBoundingSet", ""),
    ("AmbientCapabilities", ""),
    ("UMask", "0077")]
    ## The settings the floor renders verbatim, in this order. Left to the
    ## unit, because only the service knows them: ``IPAddressDeny=`` /
    ## ``IPAddressAllow=`` (its egress), ``ReadWritePaths=`` /
    ## ``StateDirectory=`` (its state), ``ProcSubset=pid`` and ``~@resources``
    ## (common runtimes read ``/proc/meminfo`` and raise their own
    ## ``RLIMIT_NOFILE`` at start; a Go service that cannot is killed).

  FloorExecKeys* = ["ExecCondition", "ExecStartPre", "ExecStart",
                    "ExecStartPost", "ExecReload", "ExecStop", "ExecStopPost"]
    ## The command lines whose executable must be inside the closure.

  ExecConfinementException* = "NoExecPaths"
    ## The exception key that lifts the exec confinement (``NoExecPaths=``
    ## and ``ExecPaths=``).

type
  EServiceFloor* = object of ValueError
    ## A unit the floor cannot be applied to as written.

  FloorException* = object
    setting*: string
    reason*: string

proc floorExceptionKeys*(): seq[string] =
  ## Every key a ``floorExceptions`` entry may name.
  for (k, _) in FloorFixed:
    if k notin result: result.add(k)
  for k in [ExecConfinementException, "RestrictAddressFamilies",
            "DynamicUser", WholeFloorException]:
    if k notin result: result.add(k)

proc raiseFloor(unitName, msg: string) {.noreturn.} =
  raise newException(EServiceFloor, "systemd.systemUnit '" & unitName &
    "': " & msg)

proc parseFloorExceptions*(unitName: string;
                           entries: openArray[string]): seq[FloorException] =
  ## ``"<Setting>: <reason>"`` entries, each naming a key of
  ## ``floorExceptionKeys`` once, with a non-empty reason.
  let keys = floorExceptionKeys()
  for e in entries:
    let colon = e.find(':')
    if colon <= 0:
      raiseFloor(unitName, "floor exception '" & e & "' must read " &
        "'<Setting>: <reason>'")
    let k = e[0 ..< colon].strip()
    let why = e[colon + 1 .. ^1].strip()
    if k notin keys:
      raiseFloor(unitName, "floor exception '" & k & "' names no " &
        "serviceFloor setting (one of " & keys.join(", ") & ")")
    if why.len == 0:
      raiseFloor(unitName, "floor exception '" & k & "' gives no reason; " &
        "an exception to the floor must say why")
    for prior in result:
      if prior.setting == k:
        raiseFloor(unitName, "floor exception '" & k & "' is named twice")
    result.add(FloorException(setting: k, reason: why))

proc floorExceptionLines*(unitName: string;
                          entries: openArray[string]): seq[string] =
  ## The plan lines of a unit's exceptions: ``<unit>: <Setting>: <reason>``.
  for e in parseFloorExceptions(unitName, entries):
    result.add(unitName & ": " & e.setting & ": " & e.reason)

proc excepted(ex: openArray[FloorException]; key: string): bool =
  for e in ex:
    if e.setting == key or e.setting == WholeFloorException: return true

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

proc serviceDirectives*(content: string): seq[tuple[key, value: string]] =
  ## The ``key=value`` directives of the unit's ``[Service]`` section, in
  ## order, comments skipped.
  var inService = false
  for l0 in logicalLines(content):
    let l = l0.strip()
    if l.len == 0 or l[0] in {'#', ';'}: continue
    if l.startsWith("[") and l.endsWith("]"):
      inService = l == "[Service]"
      continue
    if not inService: continue
    let eq = l.find('=')
    if eq <= 0: continue
    result.add((key: l[0 ..< eq].strip(), value: l[eq + 1 .. ^1].strip()))

proc hasServiceSection*(content: string): bool =
  for l in logicalLines(content):
    if l.strip() == "[Service]": return true

proc commandExecutable(value: string): tuple[path: string; prefixes: string] =
  ## The executable a command line runs and its special prefixes
  ## (``@-:+!|``, systemd.service(5) "Command lines"). "" for an empty
  ## assignment (a reset).
  var v = value.strip()
  var i = 0
  while i < v.len and v[i] in {'@', '-', ':', '+', '!', '|'}: inc i
  result.prefixes = v[0 ..< i]
  v = v[i .. ^1].strip()
  if v.len == 0: return
  if v[0] in {'"', '\''}:
    let q = v[0]
    let close = v.find(q, 1)
    result.path = if close > 0: v[1 ..< close] else: v[1 .. ^1]
  else:
    let sp = v.find({' ', '\t'})
    result.path = if sp > 0: v[0 ..< sp] else: v

proc storeObjectOf*(path: string): string =
  ## The store prefix directory ``/repro/store/prefixes/<name>/<version>``
  ## that ``path`` lies in, or "" when it is not inside one.
  if not path.startsWith(FloorStorePrefixRoot): return ""
  let rest = path[FloorStorePrefixRoot.len .. ^1].split('/')
  if rest.len < 2 or rest[0].len == 0 or rest[1].len == 0: return ""
  if rest[0] in [".", ".."] or rest[1] in [".", ".."]: return ""
  FloorStorePrefixRoot & rest[0] & "/" & rest[1]

proc commandStoreObjects*(content: string): seq[string] =
  ## The store prefixes the command lines of ``content``'s ``[Service]``
  ## section run from (``storeObjectOf`` of each executable), sorted; no
  ## refusal. What the switch re-verifies before its flip.
  for (k, v) in serviceDirectives(content):
    if k notin FloorExecKeys: continue
    let obj = storeObjectOf(commandExecutable(v).path)
    if obj.len > 0 and obj notin result: result.add(obj)
  result.sort()

proc closureBindsUsr(directives: openArray[tuple[key, value: string]]): bool =
  ## Whether an apt closure is bound over ``/usr`` (the renderer's
  ## ``BindReadOnlyPaths=<closure>/usr:/usr``, spec §8.3 item 5).
  for (k, v) in directives:
    if k == "BindReadOnlyPaths":
      for tok in v.splitWhitespace():
        let parts = tok.strip(chars = {'-', '+'}).split(':')
        if parts.len >= 2 and parts[1] == "/usr" and
            storeObjectOf(parts[0]).len > 0:
          return true

proc insideBoundUsr(path: string): bool =
  ## A command path that resolves into the unit's ``/usr``: ``/usr/...``
  ## itself, the merged-``/usr`` links ``/bin``, ``/sbin``, ``/lib*``, or a
  ## bare name (systemd searches its fixed ``PATH``, all of which is under
  ## ``/usr`` on a merged-``/usr`` base).
  if '/' notin path: return true
  for p in ["/usr/", "/bin/", "/sbin/", "/lib/", "/lib64/", "/lib32/"]:
    if path.startsWith(p): return true

proc floorExecPaths*(unitName, content: string;
                     ex: openArray[FloorException]): seq[string] =
  ## The ``ExecPaths=`` the floor renders for ``content``: the store prefix
  ## of each command line's executable, and ``/usr`` when an apt closure is
  ## bound there. A command outside both is refused (``EServiceFloor``)
  ## unless the exec confinement is an exception.
  let directives = serviceDirectives(content)
  let usrBound = closureBindsUsr(directives)
  let confine = not excepted(ex, ExecConfinementException)
  for (k, v) in directives:
    if k notin FloorExecKeys: continue
    let (path, prefixes) = commandExecutable(v)
    if path.len == 0: continue
    if '+' in prefixes and not excepted(ex, WholeFloorException):
      raiseFloor(unitName, k & "=" & v & " runs with the '+' prefix, " &
        "outside every sandboxing setting; the floor cannot hold for it " &
        "(name the exception \"serviceFloor: <why>\" to run it unconfined)")
    if not confine: continue
    if '%' in path or '$' in path:
      raiseFloor(unitName, k & " runs '" & path & "', which names a " &
        "specifier or variable: the floor cannot tell whether it is " &
        "inside the unit's closure (name the exception \"" &
        ExecConfinementException & ": <why>\")")
    let obj = storeObjectOf(path)
    if obj.len > 0:
      if obj notin result: result.add(obj)
    elif usrBound and insideBoundUsr(path):
      if "/usr" notin result: result.add("/usr")
    else:
      raiseFloor(unitName, k & " runs " & path & ", outside the unit's " &
        "closure: serviceFloor confines execution to the store prefixes " &
        "a unit's command lines name and to an apt closure bound over " &
        "/usr. Run it from the store (or bind its package's closure with " &
        "aptClosureLock), or name the exception \"" &
        ExecConfinementException & ": <why>\"")
  result.sort()

proc renderServiceFloorLines*(unitName, content: string;
                              ex: openArray[FloorException];
                              dropExec = false; dropMdwe = false):
    seq[string] =
  ## The lines the floor appends to ``content``'s ``[Service]`` section.
  ## Refuses (``EServiceFloor``) a unit that sets a floor setting to
  ## another value without naming it as an exception. ``dropExec`` and
  ## ``dropMdwe`` exist for the falsifying builds of the exec gate only.
  if excepted(ex, WholeFloorException): return @[]
  let directives = serviceDirectives(content)
  var floorValues = initTable[string, seq[string]]()
  for (k, v) in FloorFixed: floorValues.mgetOrPut(k, @[]).add(v)
  var hasUser, hasFamilies = false
  for (k, v) in directives:
    case k
    of "User", "DynamicUser": hasUser = true
    of "RestrictAddressFamilies":
      hasFamilies = true
      if not excepted(ex, "RestrictAddressFamilies") and
          (v.len == 0 or v.startsWith("~")):
        raiseFloor(unitName, "RestrictAddressFamilies=" & v & " allows " &
          "every address family but a few; the floor wants the families " &
          "the service uses (or name the exception " &
          "\"RestrictAddressFamilies: <why>\")")
    of "NoExecPaths", "ExecPaths":
      if not excepted(ex, ExecConfinementException):
        raiseFloor(unitName, k & "=" & v & " would change the floor's exec " &
          "confinement, which derives ExecPaths= from the unit's closure " &
          "(name the exception \"" & ExecConfinementException & ": <why>\")")
    else:
      if k in floorValues and not excepted(ex, k) and
          v notin floorValues[k]:
        raiseFloor(unitName, k & "=" & v & " differs from the floor's " &
          k & "=" & floorValues[k].join(" / ") & "; name the exception \"" &
          k & ": <why>\" to weaken it")
  let execPaths = floorExecPaths(unitName, content, ex)
  result.add("# serviceFloor (ReproOS add-on hardening default)")
  for (k, v) in FloorFixed:
    if excepted(ex, k): continue
    if dropMdwe and k == "MemoryDenyWriteExecute": continue
    result.add(k & "=" & v)
  if not hasFamilies and not excepted(ex, "RestrictAddressFamilies"):
    result.add("RestrictAddressFamilies=" & FloorDefaultAddressFamilies)
  if not hasUser and not excepted(ex, "DynamicUser"):
    result.add("DynamicUser=yes")
  if not excepted(ex, ExecConfinementException) and not dropExec:
    result.add("NoExecPaths=/")
    if execPaths.len > 0:
      result.add("ExecPaths=" & execPaths.join(" "))
  for e in ex:
    result.add("# serviceFloor exception: " & e.setting & ": " & e.reason)

proc appendToServiceSection*(content: string; lines: seq[string]): string =
  ## ``content`` with ``lines`` at the end of its ``[Service]`` section
  ## (before the next section header; trailing blank lines stay after
  ## them). ``content`` is returned unchanged when ``lines`` is empty.
  if lines.len == 0: return content
  var outLines: seq[string]
  var inService = false
  var done = false
  proc flush(outLines: var seq[string]) =
    var tail: seq[string]
    while outLines.len > 0 and outLines[^1].strip().len == 0:
      tail.add(outLines.pop())
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

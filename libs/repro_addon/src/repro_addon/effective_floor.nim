## The effective-unit check of the hardening floor (ReproOS Add-On Mode
## spec §10.1, amended by A9's review round 3).
##
## The floor's parse-time checks (``repro_infra/service_floor``) predict
## how systemd will read a unit and its drop-ins. Three review rounds
## found a spelling, a key, a drop-in rule or a default they predicted
## wrong. This module makes systemd's own parser the authority: after the
## switch's ``daemon-reload`` and before step 7 starts anything (at apply,
## revert, rollback and replay alike), each floored unit's effective
## properties are read with ``systemctl show`` and compared with the floor
## the unit was rendered under -- the floor block the add-on wrote into its
## unit file (``floorBlock``), minus the unit's named exceptions. A unit
## that does not hold its floor, by its own lines, a drop-in, a host's
## drop-in or a default, is a problem of the switch: nothing starts, and
## the switch reverts (``EAddOnFloorNotEffective``).
##
## What is compared, per floor version (the floor the unit was stored
## under, never today's):
##
## * every version: each setting of the floor block (``NoNewPrivileges``,
##   ``ProtectSystem``, ``MemoryDenyWriteExecute`` ... as systemd shows
##   them), its ``NoExecPaths`` entries present, its ``ExecPaths`` exactly,
##   its ``ReadOnlyPaths`` present, an allow-list ``SystemCallFilter`` that
##   holds none of the floor's denied calls (the caller expands the deny
##   line with the base's own ``systemd-analyze syscall-filter``), its
##   capability sets, address families and ``DynamicUser=yes``; and no
##   drop-in the add-on did not install, outside the distribution's own
##   ``/usr/lib/systemd`` (``DropInPaths``);
## * from version 2 (which refused root): the service does not run as
##   root -- ``DynamicUser=yes`` or a ``User=`` that resolves to a non-zero
##   uid, ``Group=`` not root, no privileged supplementary group -- and no
##   other root;
## * from version 4: no ``PAMName=``, no image or extension mounted in,
##   and every writable place the unit has (``ReadWritePaths=``,
##   ``BindPaths=`` destinations, ``TemporaryFileSystem=``, each
##   ``*Directory=``) named in ``NoExecPaths=`` and not over an
##   ``ExecPaths=`` entry.
##
## The value forms are what ``systemctl show`` prints on systemd 252, 255,
## 257 and 259 (measured identical: A9 review round 3's experiment), e.g.
## ``BindPaths=/var/lib/x:/srv/y:rbind``, ``TemporaryFileSystem=/srv/t:mode=1777``,
## ``User=`` (empty) with ``DynamicUser=no`` for a unit that runs as root.
## systemd will not show a template (``foo@.service``); the caller checks
## the instances the generation names.

import std/[algorithm, sets, strutils, tables]

import ./host_exec

import repro_infra/service_floor

type
  ShowProps* = Table[string, string]
    ## ``systemctl show -p ...`` as key -> value.

const
  FloorMarker* = "# serviceFloor (ReproOS add-on hardening default)"
  EffectiveProps* = ["LoadState", "User", "Group", "DynamicUser",
    "SupplementaryGroups", "PAMName", "NoNewPrivileges", "ProtectSystem",
    "ProtectHome", "PrivateTmp", "PrivateDevices", "ProtectKernelTunables",
    "ProtectKernelModules", "ProtectKernelLogs", "ProtectControlGroups",
    "ProtectClock", "ProtectHostname", "ProtectProc", "RestrictNamespaces",
    "RestrictRealtime", "RestrictSUIDSGID", "LockPersonality",
    "MemoryDenyWriteExecute", "SystemCallArchitectures", "SystemCallFilter",
    "CapabilityBoundingSet", "AmbientCapabilities", "UMask",
    "RestrictAddressFamilies", "NoExecPaths", "ExecPaths", "ReadOnlyPaths",
    "ReadWritePaths", "BindPaths", "BindReadOnlyPaths",
    "TemporaryFileSystem", "StateDirectory", "RuntimeDirectory",
    "CacheDirectory", "LogsDirectory", "ConfigurationDirectory",
    "RootDirectory", "RootImage", "MountImages", "ExtensionImages",
    "ExtensionDirectories", "DropInPaths"]
  ScalarFloorKeys = ["NoNewPrivileges", "ProtectSystem", "ProtectHome",
    "PrivateTmp", "PrivateDevices", "ProtectKernelTunables",
    "ProtectKernelModules", "ProtectKernelLogs", "ProtectControlGroups",
    "ProtectClock", "ProtectHostname", "ProtectProc", "RestrictNamespaces",
    "RestrictRealtime", "RestrictSUIDSGID", "LockPersonality",
    "MemoryDenyWriteExecute", "SystemCallArchitectures", "UMask"]
  DirectoryRoots = [("StateDirectory", "/var/lib"),
                    ("RuntimeDirectory", "/run"),
                    ("CacheDirectory", "/var/cache"),
                    ("LogsDirectory", "/var/log"),
                    ("ConfigurationDirectory", "/etc")]
  DistributionDropInRoots = ["/usr/lib/systemd/", "/lib/systemd/"]

proc parseShow*(text: string): ShowProps =
  ## ``key=value`` lines (the order differs between systemd versions).
  for l in text.splitLines():
    let eq = l.find('=')
    if eq > 0: result[l[0 ..< eq]] = l[eq + 1 .. ^1]

proc showUnit*(unit: string): ShowProps =
  ## systemd's effective properties of ``unit`` (raises when systemd will
  ## not show it).
  ## Run through ``host_exec`` (the distribution's systemctl by absolute
  ## path, a fixed environment).
  let r = runSystemctl(["show", "--no-pager", "-p", EffectiveProps.join(","),
                        "--", unit])
  if r.exitCode != 0:
    raise newException(OSError, "systemctl show " & unit & ": " &
                       r.output.strip())
  parseShow(r.output)

proc floorBlock*(rendered: string): Table[string, seq[string]] =
  ## The settings of the floor block the add-on rendered into a unit file:
  ## every ``key=value`` line from ``FloorMarker`` to the end of its
  ## ``[Service]`` section, comments skipped; a key's lines in order.
  var inBlock = false
  for raw in rendered.splitLines():
    let l = raw.strip()
    if l == FloorMarker:
      inBlock = true
      continue
    if not inBlock: continue
    if l.startsWith("[") and l.endsWith("]"): break
    if l.len == 0 or l[0] in {'#', ';'}: continue
    let eq = l.find('=')
    if eq <= 0: continue
    result.mgetOrPut(l[0 ..< eq], @[]).add(l[eq + 1 .. ^1])

proc exceptionKeys*(exceptions: openArray[string]): HashSet[string] =
  ## The settings ``floorExceptions`` names (``Setting: why`` /
  ## ``Setting+values: why``).
  for e in exceptions:
    var k = e.split(':', 1)[0].strip()
    let plus = k.find('+')
    if plus > 0: k = k[0 ..< plus].strip()
    result.incl(k)

proc words(v: string): seq[string] = v.splitWhitespace()

proc pathSet(v: string): HashSet[string] =
  for t in words(v):
    let q = t.strip(leading = true, trailing = false, chars = {'-', '+'})
    if q.len > 0: result.incl(normalisedPath(q))

proc versionNumber(version: string): int =
  ## ``1``, ``2`` / ``2-prekeep``, ``3``, ``4``; "" is today's.
  let v = if version.len == 0: FloorVersion else: version
  try: parseInt(v.split('-')[0]) except ValueError: 0

proc writablePlaces*(show: ShowProps): seq[string] =
  ## Every place the unit can write that systemd sets up for it, as
  ## systemd shows them: ``ReadWritePaths=``, each bind's destination
  ## (``[-]src:dst:opts``), each tmpfs (``path:opts``), each
  ## ``*Directory=`` under its root.
  for t in words(show.getOrDefault("ReadWritePaths")):
    result.add(t.strip(leading = true, trailing = false, chars = {'-', '+'}))
  for k in ["BindPaths", "BindReadOnlyPaths"]:
    for t in words(show.getOrDefault(k)):
      let parts = t.strip(leading = true, trailing = false,
                          chars = {'-', '+'}).split(':')
      result.add(if parts.len >= 2: parts[1] else: parts[0])
  for t in words(show.getOrDefault("TemporaryFileSystem")):
    result.add(t.split(':')[0])
  for (k, root) in DirectoryRoots:
    for t in words(show.getOrDefault(k)):
      result.add(root & "/" & t.split(':')[0])

proc effectiveFloorProblems*(unit, rendered, version: string;
                             exceptions: openArray[string];
                             show: ShowProps;
                             ownDropIns: openArray[string];
                             denied: HashSet[string];
                             uidOf: proc (name: string): int): seq[string] =
  ## Where ``unit``'s effective configuration (``show``) does not hold the
  ## floor it was rendered under (``rendered``, ``version``, minus
  ## ``exceptions``): one line each, empty when it holds. ``ownDropIns``
  ## are the drop-ins the add-on installed for it, ``denied`` the calls the
  ## floor's deny line names (expanded, add-backs removed), ``uidOf`` an
  ## account's uid (-1 when unknown).
  let fb = floorBlock(rendered)
  let ex = exceptionKeys(exceptions)
  let v = versionNumber(version)
  template problem(s: string) = result.add(unit & ": " & s)
  if show.getOrDefault("LoadState") != "loaded":
    problem("LoadState=" & show.getOrDefault("LoadState") & ", not loaded")
  for k in ScalarFloorKeys:
    if k in fb:
      let want = fb[k][^1]
      if show.getOrDefault(k) != want:
        problem(k & "=" & show.getOrDefault(k) & ", the floor's is " & want)
  for k in ["CapabilityBoundingSet", "AmbientCapabilities"]:
    if k in fb:
      var want, got: HashSet[string]
      for t in words(fb[k][^1]): want.incl(t.toLowerAscii())
      for t in words(show.getOrDefault(k)): got.incl(t.toLowerAscii())
      if want != got:
        problem(k & "=" & show.getOrDefault(k) & ", the floor's is " &
                fb[k][^1])
  if "RestrictAddressFamilies" in fb:
    var want, got: HashSet[string]
    for t in words(fb["RestrictAddressFamilies"][^1]): want.incl(t)
    for t in words(show.getOrDefault("RestrictAddressFamilies")): got.incl(t)
    if want != got:
      problem("RestrictAddressFamilies=" &
        show.getOrDefault("RestrictAddressFamilies") & ", the floor's is " &
        fb["RestrictAddressFamilies"][^1])
  if "DynamicUser" in fb and show.getOrDefault("DynamicUser") != "yes":
    problem("DynamicUser=" & show.getOrDefault("DynamicUser") &
            ", the floor's is yes")
  let noExec = pathSet(show.getOrDefault("NoExecPaths"))
  if "NoExecPaths" in fb:
    for line in fb["NoExecPaths"]:
      for p in pathSet(line):
        if p notin noExec:
          problem("NoExecPaths= lacks " & p & ", which the floor names")
  let execPaths = pathSet(show.getOrDefault("ExecPaths"))
  if "ExecPaths" in fb:
    var want: HashSet[string]
    for line in fb["ExecPaths"]:
      for p in pathSet(line): want.incl(p)
    if want != execPaths:
      problem("ExecPaths=" & show.getOrDefault("ExecPaths") &
              ", the floor's is " & fb["ExecPaths"].join(" "))
  elif "NoExecPaths" in fb and execPaths.len > 0:
    problem("ExecPaths=" & show.getOrDefault("ExecPaths") &
            ", the floor renders none")
  if "ReadOnlyPaths" in fb:
    let ro = pathSet(show.getOrDefault("ReadOnlyPaths"))
    for line in fb["ReadOnlyPaths"]:
      for p in pathSet(line):
        if p notin ro: problem("ReadOnlyPaths= lacks " & p)
  if "SystemCallFilter" in fb:
    let f = show.getOrDefault("SystemCallFilter")
    if f.startsWith("~"):
      problem("SystemCallFilter is a deny list, the floor's an allow list")
    else:
      var bad: seq[string]
      for t in words(f):
        if t in denied: bad.add(t)
      if bad.len > 0:
        bad.sort()
        problem("SystemCallFilter allows " & bad.join(" ") &
                ", which the floor denies")
  for d in words(show.getOrDefault("DropInPaths")):
    var ok = d in ownDropIns
    for root in DistributionDropInRoots:
      if d.startsWith(root): ok = true
    if not ok:
      problem("the drop-in " & d & " is not one the add-on installed")
  if v >= 2:
    if "User" notin ex and "DynamicUser" notin ex and
        show.getOrDefault("DynamicUser") != "yes":
      let u = show.getOrDefault("User")
      if u.len == 0 or u in ["root", "0"] or uidOf(u) == 0:
        problem("runs as root (User=" & u & ", DynamicUser=" &
                show.getOrDefault("DynamicUser") & ")")
    if "User" notin ex and show.getOrDefault("Group") in ["root", "0"]:
      problem("Group=" & show.getOrDefault("Group"))
    if "SupplementaryGroups" notin ex:
      for g in words(show.getOrDefault("SupplementaryGroups")):
        if g in PrivilegedGroups:
          problem("SupplementaryGroups= adds the privileged group " & g)
    if "RootDirectory" notin ex:
      for k in ["RootDirectory", "RootImage"]:
        if show.getOrDefault(k).len > 0:
          problem(k & "=" & show.getOrDefault(k))
  if v >= 4:
    if show.getOrDefault("PAMName").len > 0:
      problem("PAMName=" & show.getOrDefault("PAMName"))
    for k in ["MountImages", "ExtensionImages", "ExtensionDirectories"]:
      if k notin ex and show.getOrDefault(k).len > 0:
        problem(k & "=" & show.getOrDefault(k))
    if ExecConfinementException notin ex:
      for w in writablePlaces(show):
        let p = normalisedPath(w)
        for kt in KernelTrees:
          if p == kt or p.startsWith(kt & "/") or kt.startsWith(p & "/"):
            problem("the writable place " & p & " is in or over " & kt)
        if p notin noExec:
          problem("the writable place " & p & " is not in NoExecPaths=")
        for x in execPaths:
          if p == x or p.startsWith(x & "/") or x.startsWith(p & "/"):
            problem("the writable place " & p & " overlaps ExecPaths= " & x)

# ---------------------------------------------------------------------------
# The deny line, expanded with the base's own systemd.
# ---------------------------------------------------------------------------

proc withoutEscapes(s: string): string =
  var i = 0
  while i < s.len:
    if s[i] == '\e' and i + 1 < s.len and s[i + 1] == '[':
      var j = i + 2
      while j < s.len and s[j] notin {'A'..'Z', 'a'..'z'}: inc j
      i = j + 1
    else:
      result.add(s[i])
      inc i

proc parseSyscallGroups*(text: string): Table[string, seq[string]] =
  ## ``systemd-analyze syscall-filter`` (escape sequences removed: systemd
  ## 255 writes one before each nested group even with no terminal).
  var cur = ""
  for raw0 in text.splitLines():
    let raw = withoutEscapes(raw0)
    let l = raw.strip()
    if l.len == 0 or l.startsWith("#"): continue
    if not raw.startsWith(" ") and l.startsWith("@"):
      cur = l
      result[cur] = @[]
    elif cur.len > 0:
      result[cur].add(l)

proc expandCalls*(groups: Table[string, seq[string]];
                  items: openArray[string]): HashSet[string] =
  proc go(item: string; acc: var HashSet[string]) =
    if item.startsWith("@"):
      if item in groups:
        for m in groups[item]: go(m, acc)
    else: acc.incl(item)
  for i in items: go(i, result)

proc deniedCalls*(rendered: string;
                  groups: Table[string, seq[string]]): HashSet[string] =
  ## The calls the floor block's ``~`` line denies, less what a later
  ## ``SystemCallFilter=`` line (an exception's add-back) allows again.
  let fb = floorBlock(rendered)
  if "SystemCallFilter" notin fb: return
  var deny, back: seq[string]
  var seenDeny = false
  for line in fb["SystemCallFilter"]:
    if line.startsWith("~"):
      seenDeny = true
      deny.add(words(line[1 .. ^1]))
    elif seenDeny:
      back.add(words(line))
  result = expandCalls(groups, deny) - expandCalls(groups, back)

proc baseSyscallGroups*(): Table[string, seq[string]] =
  ## The base's own syscall groups, from its ``systemd-analyze`` (by
  ## absolute path; ``host_exec``).
  let exe = resolveHostTool(SystemdAnalyzeCandidates)
  if exe.len == 0:
    raise newException(HostToolMissing, "systemd-analyze not found at " &
                       SystemdAnalyzeCandidates.join(" or "))
  let r = runHostTool([exe, "syscall-filter", "--no-pager"])
  if r.exitCode != 0:
    raise newException(OSError, "systemd-analyze syscall-filter: " &
                       r.output.strip())
  parseSyscallGroups(r.output)

proc systemUid*(name: string): int =
  ## The uid ``getent passwd`` gives ``name``, -1 when it gives none.
  let exe = resolveHostTool(GetentCandidates)
  if exe.len == 0: return -1
  let r = runHostTool([exe, "passwd", "--", name], mergeStderr = false)
  if r.exitCode != 0: return -1
  let f = r.output.strip().split(':')
  if f.len < 3: return -1
  try: parseInt(f[2]) except ValueError: -1

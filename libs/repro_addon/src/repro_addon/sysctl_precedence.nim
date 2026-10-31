## Which sysctl fragment wins at boot (ReproOS Add-On Mode §4.3, §7.2
## step 6).
##
## The add-on applies a ``linux.sysctl`` resource by running the host's
## ``systemd-sysctl`` on its own fragment, ``/etc/sysctl.d/90-repro-*.conf``.
## That sets the key now. At boot, though, ``systemd-sysctl.service``
## applies every fragment in one pass, ordered by file name across the
## sysctl.d directories, and a later assignment of the same key wins
## (https://www.freedesktop.org/software/systemd/man/latest/sysctl.d.html,
## "Configuration Directories and Precedence"). A base fragment that sorts
## after the add-on's -- ``99-sysctl.conf``, which Debian and Ubuntu link
## to ``/etc/sysctl.conf``, or any ``9x-`` file a package ships -- would
## silently put its own value back at every boot, so the host's value
## would follow the base, not the ledger. procps' ``sysctl --system``
## reads ``/etc/sysctl.conf`` last of all, so that file counts as later
## too.
##
## This module finds those later assignments so the plan can refuse the
## resource instead (§4.3: a collision is refused with the observation
## that justifies it). Pure over a root directory, so the unit tests run
## it on a fixture tree.

import std/[algorithm, os, sets, strutils]

import ./host_exec

const
  SysctlDirs* = ["/etc/sysctl.d", "/run/sysctl.d", "/usr/local/lib/sysctl.d",
                 "/usr/lib/sysctl.d", "/lib/sysctl.d"]
    ## In systemd's precedence order: a file name in an earlier directory
    ## hides the same name in a later one.
  SysctlConf* = "/etc/sysctl.conf"

type
  LaterAssignment* = object
    file*: string      ## the fragment as found, with `` -> <target>``
                       ## when it is a link
    pattern*: string   ## the key or glob as written
    value*: string     ## the value it assigns, whitespace-normalised

proc normaliseKey*(key: string): string =
  ## The key in systemd's normal (slash-separated) form
  ## (``host_exec.sysctlNormalize``), so ``net.ipv4.ip_forward`` and
  ## ``net/ipv4/ip_forward`` compare equal and ``net.ipv4.conf.eth0/100.x``
  ## keeps its interface name ``eth0.100``.
  sysctlNormalize(key.strip())

proc normaliseValue*(value: string): string =
  value.splitWhitespace().join(" ")

proc keyMatches(pattern, key: string): bool =
  ## Does a later assignment override the add-on's explicit one? Only an
  ## explicit assignment of the same key: systemd applies a glob
  ## (``net.ipv4.conf.*.rp_filter``) to every matching key EXCEPT those
  ## set explicitly anywhere, whatever the order (sysctl.d(5)), and the
  ## add-on's fragment sets its key explicitly.
  if pattern.contains({'*', '?', '['}): return false
  normaliseKey(pattern) == key

proc assignmentsIn*(text: string): seq[tuple[pattern, value: string]] =
  ## ``key = value`` lines (comments ``#`` / ``;``, a leading ``-`` that
  ## only silences errors).
  for raw in text.splitLines():
    var line = raw.strip()
    if line.len == 0 or line[0] in {'#', ';'}: continue
    if line[0] == '-': line = line[1 .. ^1].strip()
    let eq = line.find('=')
    if eq <= 0: continue
    result.add((line[0 ..< eq].strip(), normaliseValue(line[eq + 1 .. ^1])))

proc laterAssignments*(key, ownFragment: string; root = "/"):
    seq[LaterAssignment] =
  ## Every assignment of ``key`` that systemd (or procps) applies AFTER
  ## ``ownFragment`` (a path in ``/etc/sysctl.d``): fragments whose name
  ## sorts after it, and ``/etc/sysctl.conf``. Only the add-on's own
  ## fragment is skipped, by its exact name (it never sorts after
  ## itself); every other file counts, whatever it is called. ``root``
  ## relocates the directories for tests.
  let wanted = normaliseKey(key)
  let own = extractFilename(ownFragment)
  var seen = initHashSet[string]()
  var files: seq[tuple[name, path: string]]
  for d in SysctlDirs:
    let dir = if root == "/": d else: root / d
    if not dirExists(dir): continue
    for kind, path in walkDir(dir):
      let name = extractFilename(path)
      if not name.endsWith(".conf") or name in seen: continue
      if kind notin {pcFile, pcLinkToFile}: continue
      seen.incl(name)
      files.add((name, path))
  files.sort(proc(a, b: tuple[name, path: string]): int = cmp(a.name, b.name))
  var later: seq[string]
  for f in files:
    if f.name > own:
      later.add(f.path)
  let conf = if root == "/": SysctlConf else: root / SysctlConf
  if fileExists(conf): later.add(conf)
  var read = initHashSet[string]()
  for path in later:
    # Debian and Ubuntu link /etc/sysctl.d/99-sysctl.conf to
    # /etc/sysctl.conf: one file, reported once.
    let real = try: expandFilename(path) except OSError: path
    if real in read: continue
    read.incl(real)
    var text: string
    try:
      text = readFile(path)
    except IOError, OSError:
      continue
    for (pattern, value) in assignmentsIn(text):
      if keyMatches(pattern, wanted):
        result.add(LaterAssignment(
          file: (if real != path: path & " -> " & real else: path),
          pattern: pattern, value: value))

proc sysctlPrecedenceRefusal*(key, value, ownFragment: string;
                              root = "/"): string =
  ## "" unless a base fragment applied after the add-on's assigns ``key``
  ## a different value: then why the resource is refused. The same value
  ## is no collision -- the boot-time value is the ledger's either way.
  let want = normaliseValue(value)
  var clashes: seq[string]
  for a in laterAssignments(key, ownFragment, root):
    if a.value != want:
      clashes.add(a.file & " sets " & a.pattern & " = " & a.value)
  if clashes.len == 0: return ""
  "the base assigns " & key & " after the add-on's fragment " & ownFragment &
    " (" & clashes.join("; ") & "), so every boot would put that value " &
    "back over the ledger's " & want & "; remove or change the base's " &
    "assignment, or leave the key to the base"

# ---------------------------------------------------------------------------
# Runtime writers: systemd-networkd.
# ---------------------------------------------------------------------------

const
  NetworkdDirs* = ["/etc/systemd/network", "/run/systemd/network",
                   "/usr/local/lib/systemd/network",
                   "/usr/lib/systemd/network", "/lib/systemd/network"]
  NetworkdConfs* = ["/etc/systemd/networkd.conf", "/run/systemd/networkd.conf",
                    "/usr/lib/systemd/networkd.conf"]
  NetworkdForwardingKeys* = ["IPForward", "IPv4Forwarding", "IPv6Forwarding",
                             "IPMasquerade"]
    ## systemd.network(5) / networkd.conf(5) ``[Network]`` settings with
    ## which networkd writes the forwarding sysctls itself, at runtime,
    ## whenever it configures a link. (``IPMasquerade=`` implies
    ## forwarding.)

proc forwardingFamily*(key: string): string =
  ## "ipv4" or "ipv6" for a forwarding knob (``net/ipv4/ip_forward``, the
  ## per-interface ``forwarding`` of either family), "" otherwise.
  let k = sysctlNormalize(key)
  if k == "net/ipv4/ip_forward" or
      (k.startsWith("net/ipv4/conf/") and k.endsWith("/forwarding")):
    "ipv4"
  elif k.startsWith("net/ipv6/conf/") and k.endsWith("/forwarding"):
    "ipv6"
  else: ""

proc isForwardingKey*(key: string): bool =
  forwardingFamily(key).len > 0

const NetworkdLinkState* = "/run/systemd/netif/links"
  ## networkd's runtime state, one file per link it manages (named by the
  ## link's ifindex), naming the ``.network`` file applied to it
  ## (``NETWORK_FILE=``).

proc networkFilesInUse*(root = "/"): seq[string] =
  ## The ``.network`` files networkd has applied to a link now. A file
  ## whose ``[Match]`` matches no link (the container and VM templates
  ## systemd ships, ``80-container-ve.network``) configures nothing.
  let dir = (if root == "/": "" else: root) & NetworkdLinkState
  if not dirExists(dir): return
  for kind, path in walkDir(dir):
    var text: string
    try: text = readFile(path)
    except IOError, OSError: continue
    for line in text.splitLines():
      if line.startsWith("NETWORK_FILE="):
        let f = line["NETWORK_FILE=".len .. ^1].strip()
        if f.len > 0 and f notin result: result.add(f)

proc networkdManagedLinks*(root = "/"): seq[string] =
  ## The interface names of the links networkd manages now: its runtime
  ## state names them by ifindex, ``/sys/class/net/<name>/ifindex`` maps
  ## the index to the name.
  let base = if root == "/": "" else: root
  let dir = base & NetworkdLinkState
  if not dirExists(dir): return
  var managed: seq[string]
  for kind, path in walkDir(dir):
    var text: string
    try: text = readFile(path)
    except IOError, OSError: continue
    if "NETWORK_FILE=" in text and "NETWORK_FILE=\n" notin text:
      managed.add(extractFilename(path))
  let net = base & "/sys/class/net"
  if not dirExists(net): return
  for kind, path in walkDir(net):
    var idx: string
    try: idx = readFile(path / "ifindex").strip()
    except IOError, OSError: continue
    if idx in managed: result.add(extractFilename(path))

proc boolSetting(v: string): string =
  ## networkd's boolean spelling as a sysctl value, "" when it is not one.
  case v.strip().toLowerAscii()
  of "yes", "true", "1", "on": "1"
  of "no", "false", "0", "off": "0"
  else: ""

const
  NetworkdGlobalForwardingSince* = 256
  ## The systemd release whose networkd changed how it writes forwarding
  ## (systemd v256 NEWS; ``src/network/networkd-sysctl.c`` at v255 and
  ## v256, https://github.com/systemd/systemd/blob/v256/src/network/networkd-sysctl.c).
  ##
  ## Before 256, ``IPForward=`` (``yes``/``ipv4``/``ipv6``/``both``) and
  ## ``IPMasquerade=`` in a ``.network`` file only ever turn the global
  ## knob ON (``net.ipv4.ip_forward``, ``net.ipv6.conf.all.forwarding``),
  ## when a link with that file is configured, and never turn it off
  ## again: ``IPForward=no`` writes nothing. ``networkd.conf`` has no
  ## forwarding setting, and ``IPv4Forwarding=`` / ``IPv6Forwarding=`` are
  ## unknown keys.
  ##
  ## From 256 on, ``IPForward=`` is deprecated and ignored. The global
  ## knob is ``IPv4Forwarding=`` / ``IPv6Forwarding=`` in ``networkd.conf``
  ## (and its drop-ins): a boolean networkd writes in BOTH directions to
  ## ``net.<family>.conf.{default,all}.forwarding``. The same settings in a
  ## ``.network`` file are per link: they write only that link's
  ## ``net.<family>.conf.<link>.forwarding`` (a per-link key of a managed
  ## link is refused on its own, below). ``IPMasquerade=`` enables the
  ## link's forwarding and, from 257 on, the global knob too while
  ## ``networkd.conf`` leaves it unset.
  NetworkdMasqueradeGlobalSince* = 257

proc isGlobalNetworkdSource(source: string): bool =
  ## A ``<file>: <Key>=<value>`` line from ``networkd.conf`` or one of its
  ## drop-ins (global), as opposed to a ``.network`` file or one of its
  ## drop-ins (per link).
  let colon = source.find(": ")
  let file = if colon >= 0: source[0 ..< colon] else: ""
  file.endsWith("networkd.conf") or "networkd.conf.d/" in file

proc networkdForwardingValues*(settings: seq[string];
                               networkdVersion = 0):
    seq[tuple[family, value, source: string]] =
  ## What networkd's forwarding settings (``<file>: <Key>=<value>`` lines,
  ## ``networkdForwardingSettings``) write to the GLOBAL forwarding knob
  ## of each family, as networkd ``networkdVersion`` does
  ## (``NetworkdGlobalForwardingSince``). Per-link writes are not listed:
  ## they touch only the link's own key. A version of 0 (unknown) unites
  ## both behaviours, so an unknown networkd is never assumed harmless.
  let legacy = networkdVersion == 0 or networkdVersion < NetworkdGlobalForwardingSince
  let modern = networkdVersion == 0 or networkdVersion >= NetworkdGlobalForwardingSince
  let masqGlobal = networkdVersion == 0 or
                   networkdVersion >= NetworkdMasqueradeGlobalSince
  var globalSet: array[2, bool]   # ipv4, ipv6: networkd.conf sets it (>= 256)
  var masquerade: seq[tuple[family, source: string]]
  for line in settings:
    let colon = line.find(": ")
    let assign = if colon >= 0: line[colon + 2 .. ^1] else: line
    let eq = assign.find('=')
    if eq <= 0: continue
    let k = assign[0 ..< eq].strip()
    let v = assign[eq + 1 .. ^1].strip().toLowerAscii()
    let global = isGlobalNetworkdSource(line)
    case k
    of "IPForward":
      # A .network setting before 256, one way only: ON, never off.
      if legacy and not global:
        case v
        of "ipv4": result.add(("ipv4", "1", line))
        of "ipv6": result.add(("ipv6", "1", line))
        of "both":
          result.add(("ipv4", "1", line))
          result.add(("ipv6", "1", line))
        else:
          if boolSetting(v) == "1":
            result.add(("ipv4", "1", line))
            result.add(("ipv6", "1", line))
    of "IPv4Forwarding", "IPv6Forwarding":
      # Global (networkd.conf) from 256 on, in both directions.
      let fam = if k == "IPv4Forwarding": "ipv4" else: "ipv6"
      let b = boolSetting(v)
      if modern and global and b.len > 0:
        result.add((fam, b, line))
        globalSet[(if fam == "ipv4": 0 else: 1)] = true
    of "IPMasquerade":
      if global: continue
      var fams: seq[string]
      if v in ["ipv4", "both", "yes", "true", "on", "1"]: fams.add("ipv4")
      if v in ["ipv6", "both"]: fams.add("ipv6")
      for fam in fams:
        if legacy: result.add((fam, "1", line))
        if masqGlobal: masquerade.add((fam, line))
    else: discard
  # From 257 on a masquerading link turns the global knob on, unless
  # networkd.conf decides it.
  for (fam, line) in masquerade:
    if not globalSet[(if fam == "ipv4": 0 else: 1)]:
      let entry = (family: fam, value: "1", source: line)
      if entry notin result: result.add(entry)

proc networkdForwardingSettings*(root = "/"): seq[string] =
  ## Every ``[Network]`` forwarding setting networkd applies now: in a
  ## ``.network`` file it has applied to a link (``networkFilesInUse``)
  ## and that file's drop-ins (``<name>.network.d/*.conf`` in any network
  ## directory, systemd.network(5)), and in ``networkd.conf`` with its
  ## drop-ins (global), as ``<file>: <Key>=<value>``.
  proc scan(path: string; acc: var seq[string]) =
    var text: string
    try: text = readFile(path)
    except IOError, OSError: return
    var inNetwork = false
    for raw in text.splitLines():
      let t = raw.strip()
      if t.startsWith("["):
        inNetwork = t == "[Network]"
        continue
      if not inNetwork or t.len == 0 or t[0] in {'#', ';'}: continue
      let eq = t.find('=')
      if eq <= 0: continue
      let k = t[0 ..< eq].strip()
      if k in NetworkdForwardingKeys:
        acc.add(path & ": " & t)
  proc scanDropIns(dirName: string; acc: var seq[string]) =
    # A drop-in name in an earlier directory hides the same name later.
    var seen: seq[string]
    var files: seq[(string, string)]
    for d in NetworkdDirs:
      let dir = (if root == "/": "" else: root) & d / dirName
      if not dirExists(dir): continue
      for kind, path in walkDir(dir):
        let n = extractFilename(path)
        if n.endsWith(".conf") and n notin seen:
          seen.add(n)
          files.add((n, path))
    files.sort(proc(a, b: (string, string)): int = cmp(a[0], b[0]))
    for (_, path) in files: scan(path, acc)
  let base = if root == "/": "" else: root
  for f in networkFilesInUse(root):
    scan(base & f, result)
    scanDropIns(extractFilename(f) & ".d", result)
  for c in NetworkdConfs:
    scan(base & c, result)
    let dropDir = base & c & ".d"
    if dirExists(dropDir):
      for kind, path in walkDir(dropDir):
        if path.endsWith(".conf"): scan(path, result)

proc networkdRefusal*(key, value: string; networkdInUse: bool;
                      root = "/"; networkdVersion = 0): string =
  ## "" unless an enabled or running systemd-networkd would overwrite the
  ## add-on's value of ``key`` at runtime, whenever it configures a link
  ## (spec §7.2 step 6):
  ##
  ## - a per-interface key (``net/ipv4/conf/<link>/...``,
  ##   ``net/ipv6/conf/<link>/...``) of a link networkd manages now: it
  ##   writes the link's settings (forwarding, ``accept_ra``, reverse-path
  ##   filtering, proxy ARP, ...) each time it configures it;
  ## - a forwarding key whose family's global knob networkd
  ##   ``networkdVersion`` would write with another value
  ##   (``networkdForwardingValues``: before 256 ``IPForward=`` and
  ##   ``IPMasquerade=`` only ever turn it on, from 256 ``networkd.conf``'s
  ##   ``IPv4Forwarding=`` / ``IPv6Forwarding=`` set it either way) -- the
  ##   same value is no conflict, and neither is a setting this networkd
  ##   ignores (``IPForward=no``, ``IPForward=`` from 256 on). 0 (unknown)
  ##   refuses what either behaviour would overwrite.
  ##
  ## *Known limit:* a ``.network`` file that matches a link only later (a
  ## device plugged in, a VPN brought up) is not seen until it does.
  if not networkdInUse: return ""
  let k = sysctlNormalize(key)
  let parts = k.split('/')
  if parts.len >= 5 and parts[0] == "net" and parts[1] in ["ipv4", "ipv6"] and
      parts[2] == "conf" and parts[3] notin ["all", "default"]:
    if parts[3] in networkdManagedLinks(root):
      return "systemd-networkd manages " & parts[3] & " and writes its " &
        "per-link settings (" & key & " among them) whenever it configures " &
        "it; the ledger's value would not hold. Leave the key to networkd " &
        "or stop networkd managing " & parts[3]
  let fam = forwardingFamily(key)
  if fam.len == 0: return ""
  let want = value.strip()
  var clashes: seq[string]
  for (f, v, src) in networkdForwardingValues(networkdForwardingSettings(root),
                                              networkdVersion):
    if f == fam and v != want: clashes.add(src)
  if clashes.len == 0: return ""
  "systemd-networkd" & (if networkdVersion > 0: " " & $networkdVersion
                        else: "") & " writes " & key &
    " itself at runtime with another " &
    "value (" & clashes.join("; ") & "); the ledger's value " & want &
    " would not hold. Drop or change the networkd setting, or leave the " &
    "key to networkd"

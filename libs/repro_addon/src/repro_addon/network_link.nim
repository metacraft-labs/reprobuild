## The ``network`` class (ReproOS Add-On Mode §4.5): an ADDITIONAL link the
## distribution does not manage, with static addresses, beside the
## distribution's own network and changing nothing of it.
##
## A ``linux.networkLink`` is an ``ipvlan`` (L2) or ``macvlan`` child of the
## parent interface whose MAC it names, or a ``dummy`` link. It is realised
## only on a host where NetworkManager is the ACTIVE network manager (§13
## decision 12), as one keyfile
## ``/etc/NetworkManager/system-connections/repro-<name>.nmconnection``
## (a root-owned 0600 copy, as NetworkManager requires), activated with
## ``nmcli connection load`` and ``nmcli connection up`` on that connection
## only. The parent is matched through the keyfile's ``[ethernet]
## mac-address`` (NetworkManager's rule for a child with no ``parent``),
## so the connection follows the NIC however the kernel names it. The
## parent's own connection, its lease and its default route are never
## touched: bringing a child link up or down does not disturb its parent.
##
## This module is the class's pure and host-facing pieces: the keyfile,
## what the host has (links, addresses, routes; ``ip -j``), which manager
## is active, the plan-time refusals, the duplicate-address probe
## (``arping -D``, §13 decision 88), and writing or removing a connection.
## The switch decides when; the network guard (``network_guard``) decides
## whether it stays.
##
## Measured on the Omarchy VM (NetworkManager 1.58.1, iputils 20250605,
## 2026-11-20): an ipvlan keyfile with ``[ethernet] mac-address`` and no
## ``ipvlan.parent`` creates ``<name>@<parent>`` in L2 mode; the parent's
## connection, lease and routes stay as they were; a routing-only domain
## with the link's server reads ``Default Route: no`` in ``resolvectl``;
## and NetworkManager's own duplicate-address detection
## (``ipv4.dad-timeout``) does NOT see an address another LAN host defends
## on an ipvlan child (it does on a macvlan one), which is why the probe
## runs on the parent before the switch. A parent cannot carry ipvlan and
## macvlan children at once (the kernel refuses the second kind with
## ``EBUSY``), which the plan refuses before anything is written.

import std/[algorithm, json, net, os, sets, strutils, tables]

import repro_infra/addon_diagnostics
import repro_infra/profile

import repro_elevation/nofollow_write

import ./fingerprint
import ./host_exec
import ./ledger
import ./mutations

type
  NetworkObject* = object
    ## One connection a generation wants on the host.
    name*: string          ## the link's interface name
    kind*: string          ## ipvlan | macvlan | dummy
    address*: string       ## the resource's address
    path*: string          ## the keyfile
    uuid*: string          ## the connection's UUID
    content*: string       ## the keyfile's bytes
    parentMac*: string
    addresses*: seq[string]

  HostLink* = object
    name*: string
    kind*: string          ## ``linkinfo.info_kind`` ("" for a plain NIC)
    mac*: string           ## lowercase
    parent*: string        ## the parent's name for a child link, else ""
    up*: bool              ## ``LOWER_UP`` (carrier) and administratively up

  HostAddress* = object
    iface*: string
    ip*: string            ## canonical text of the address
    prefixLen*: int

  HostRoute* = object
    family*: string        ## inet | inet6
    dst*: string
    gateway*: string
    dev*: string
    metric*: int
    linkdown*: bool

  HostNetwork* = object
    ## What the host's kernel reports, from ``ip -j``. ``ok`` false with
    ## ``why`` when it could not be read: nothing is decided from an
    ## unreadable host.
    ok*: bool
    why*: string
    links*: seq[HostLink]
    addresses*: seq[HostAddress]
    routes*: seq[HostRoute]

  NetworkChange* = object
    ## What a generation does to the class's objects: which connections it
    ## adds, changes or removes (by keyfile path). A generation with any is
    ## a NETWORK generation, applied only under the guard (spec §4.5).
    added*, changed*, removed*: seq[string]

const
  NmConnectionsDir* = "/etc/NetworkManager/system-connections"
  NmcliCandidates* = ["/usr/bin/nmcli", "/bin/nmcli"]
  IpCandidates* = ["/usr/bin/ip", "/usr/sbin/ip", "/sbin/ip", "/bin/ip"]
  ArpingCandidates* = ["/usr/bin/arping", "/usr/sbin/arping", "/bin/arping",
                       "/sbin/arping"]
  NetworkLinkRouteMetric* = 30000
    ## The route metric of every address the class adds (``ipv4`` /
    ## ``ipv6.route-metric``): above any metric a distribution gives its
    ## own routes (NetworkManager's defaults are 20-800, plus 20000 for a
    ## device's second rank), so a prefix route of a child never wins over
    ## the parent's (spec §4.5).
  DadTimeoutMs* = 3000
    ## ``ipv4.dad-timeout`` in every keyfile (§13 decisions 88, 101).
  ArpingArgs* = ["-D", "-c", "3", "-w", "3"]
    ## The probe of spec §4.5: ``arping -D -I <parent> -c 3 -w 3 <address>``.
  NmcliTimeoutSec* = 90
    ## How long one ``nmcli connection up`` may take (an activation waits
    ## for the link and, with ``dad-timeout``, for its probe).

proc keyfilePath*(name: string): string =
  NmConnectionsDir / ("repro-" & name & ".nmconnection")

proc connectionId*(name: string): string = "repro-" & name

proc isAddOnKeyfile*(path: string): bool =
  ## A path the class writes: ``repro-<name>.nmconnection`` directly in
  ## NetworkManager's connection directory.
  parentDir(path) == NmConnectionsDir and
    extractFilename(path).startsWith("repro-") and
    path.endsWith(".nmconnection")

proc connectionUuid*(name: string): string =
  ## A UUID that depends on the link's name only, so a generation renders
  ## the same bytes every time: the SHA-256 of a fixed tag and the name,
  ## laid out as an RFC 9562 version 8 ("custom") UUID.
  ## https://www.rfc-editor.org/rfc/rfc9562#name-uuid-version-8
  var h = sha256Hex("repro-addon linux.networkLink " & name)[0 ..< 32]
  h[12] = '8'
  h[16] = "89ab"[parseHexInt($h[16]) and 3]
  h[0 ..< 8] & "-" & h[8 ..< 12] & "-" & h[12 ..< 16] & "-" & h[16 ..< 20] &
    "-" & h[20 ..< 32]

proc isIpv4*(cidrOrIp: string): bool =
  let ip = cidrOrIp.split('/')[0]
  try: parseIpAddress(ip).family == IpAddressFamily.IPv4
  except ValueError: false

proc ipOf*(cidr: string): string = cidr.split('/')[0]

proc renderKeyfile*(r: SystemResource): string =
  ## The keyfile of ``r`` (a ``linux.networkLink``): NetworkManager's
  ## keyfile format, https://networkmanager.dev/docs/api/latest/nm-settings-keyfile.html
  ## and nm-settings-nmcli(5) for each setting.
  doAssert r.kind == srkLinuxNetworkLink
  var v4, v6, dns4, dns6: seq[string]
  for a in r.nlAddresses:
    if isIpv4(a): v4.add(a) else: v6.add(a)
  for d in r.nlDnsServers:
    if isIpv4(d): dns4.add(d) else: dns6.add(d)
  result = "[connection]\n"
  result.add("id=" & connectionId(r.nlName) & "\n")
  result.add("uuid=" & connectionUuid(r.nlName) & "\n")
  result.add("type=" & r.nlKind & "\n")
  result.add("interface-name=" & r.nlName & "\n")
  result.add("autoconnect=true\n")
  case r.nlKind
  of "ipvlan":
    # The parent is matched by its MAC (no ``ipvlan.parent``); mode 1 is L2.
    result.add("\n[ethernet]\nmac-address=" & r.nlParentMac & "\n")
    result.add("\n[ipvlan]\nmode=1\n")
  of "macvlan":
    # Mode 2 is bridge: the children of one parent reach each other.
    result.add("\n[ethernet]\nmac-address=" & r.nlParentMac & "\n")
    result.add("\n[macvlan]\nmode=2\ntap=false\n")
  else:
    discard
  # The routing-only domains go with the family whose servers serve them.
  let domainsOn4 = dns4.len > 0 or dns6.len == 0
  result.add("\n[ipv4]\n")
  if v4.len == 0:
    result.add("method=disabled\n")
  else:
    result.add("method=manual\n")
    for i, a in v4:
      result.add("address" & $(i + 1) & "=" & a & "\n")
    result.add("never-default=true\n")
    result.add("route-metric=" & $NetworkLinkRouteMetric & "\n")
    result.add("dad-timeout=" & $DadTimeoutMs & "\n")
    if dns4.len > 0:
      result.add("dns=" & dns4.join(";") & ";\n")
    if domainsOn4 and r.nlDnsDomains.len > 0:
      result.add("dns-search=" & r.nlDnsDomains.join(";") & ";\n")
  result.add("\n[ipv6]\n")
  if v6.len == 0:
    result.add("method=disabled\n")
  else:
    result.add("method=manual\n")
    result.add("addr-gen-mode=stable-privacy\n")
    for i, a in v6:
      result.add("address" & $(i + 1) & "=" & a & "\n")
    result.add("never-default=true\n")
    result.add("route-metric=" & $NetworkLinkRouteMetric & "\n")
    if dns6.len > 0:
      result.add("dns=" & dns6.join(";") & ";\n")
    if not domainsOn4 and r.nlDnsDomains.len > 0:
      result.add("dns-search=" & r.nlDnsDomains.join(";") & ";\n")

proc networkObjectOf*(r: SystemResource): NetworkObject =
  NetworkObject(name: r.nlName, kind: r.nlKind, address: r.address,
    path: keyfilePath(r.nlName), uuid: connectionUuid(r.nlName),
    content: renderKeyfile(r), parentMac: r.nlParentMac,
    addresses: r.nlAddresses)

proc networkObjectsOf*(p: SystemProfile): seq[NetworkObject] =
  for r in p.resources:
    if r.kind == srkLinuxNetworkLink:
      result.add(networkObjectOf(r))

proc networkEntries*(l: Ledger): seq[LedgerEntry] =
  for e in l.entries:
    if e.class == lcNetwork: result.add(e)

proc networkChanges*(previous: Ledger; desired: openArray[NetworkObject]):
    NetworkChange =
  ## What the switch from ``previous`` to ``desired`` does to the class's
  ## objects, by keyfile path and content digest.
  var before = initTable[string, string]()
  for e in networkEntries(previous): before[e.path] = e.sha256
  var wanted = initHashSet[string]()
  for o in desired:
    wanted.incl(o.path)
    if o.path notin before: result.added.add(o.path)
    elif before[o.path] != sha256Hex(o.content): result.changed.add(o.path)
  for p, _ in before:
    if p notin wanted: result.removed.add(p)
  result.removed.sort()

proc any*(c: NetworkChange): bool =
  c.added.len + c.changed.len + c.removed.len > 0

proc describe*(c: NetworkChange): string =
  var parts: seq[string]
  for p in c.added: parts.add("+" & extractFilename(p))
  for p in c.changed: parts.add("~" & extractFilename(p))
  for p in c.removed: parts.add("-" & extractFilename(p))
  parts.join(" ")

# ---------------------------------------------------------------------------
# What the host has.
# ---------------------------------------------------------------------------

proc parseIpLinks*(text: string): seq[HostLink] =
  ## ``ip -j -d link show``.
  for n in parseJson(text):
    var l = HostLink(name: n{"ifname"}.getStr(),
      mac: n{"address"}.getStr().toLowerAscii(), parent: n{"link"}.getStr())
    if n.hasKey("linkinfo"):
      l.kind = n["linkinfo"]{"info_kind"}.getStr()
    var flags: seq[string]
    for f in n{"flags"}.getElems(): flags.add(f.getStr())
    l.up = "UP" in flags and "LOWER_UP" in flags
    result.add(l)

proc parseIpAddrs*(text: string): seq[HostAddress] =
  ## ``ip -j addr show``.
  for n in parseJson(text):
    for a in n{"addr_info"}.getElems():
      let local = a{"local"}.getStr()
      if local.len == 0: continue
      var ip = local
      try: ip = $parseIpAddress(local)
      except ValueError: discard
      result.add(HostAddress(iface: n{"ifname"}.getStr(), ip: ip,
                             prefixLen: a{"prefixlen"}.getInt()))

proc parseIpRoutes*(text, family: string): seq[HostRoute] =
  ## ``ip -j [-6] route show table main``.
  for n in parseJson(text):
    var r = HostRoute(family: family, dst: n{"dst"}.getStr(),
      gateway: n{"gateway"}.getStr(), dev: n{"dev"}.getStr(),
      metric: n{"metric"}.getInt())
    for f in n{"flags"}.getElems():
      if f.getStr() == "linkdown": r.linkdown = true
    result.add(r)

proc render*(r: HostRoute): string =
  result = r.dst
  if r.gateway.len > 0: result.add(" via " & r.gateway)
  result.add(" dev " & r.dev & " metric " & $r.metric)
  if r.linkdown: result.add(" linkdown")
  result = "[" & r.family & "] " & result

proc defaultRoutes*(h: HostNetwork): seq[string] =
  ## The host's default routes, rendered and sorted: what the guard's
  ## invariant compares with the routes observed before the switch. A
  ## route's ``linkdown`` flag is not part of it: the same route on a link
  ## that lost its carrier is still the route observed, and the carrier is
  ## the ``keep`` invariant's to judge -- once NetworkManager drops the
  ## address the route goes too, and both are named (measured with the
  ## parent's cable pulled from outside the guest, AR5 2026-11-20).
  for r in h.routes:
    if r.dst == "default":
      var x = r
      x.linkdown = false
      result.add(x.render)
  result.sort()

proc ipTool(): string =
  resolveHostTool(IpCandidates)

proc observeHostNetwork*(): HostNetwork =
  ## The host's links, addresses and (main table) routes, through the
  ## host's ``ip`` with JSON output. Read in the caller's network
  ## namespace: an operator's apply and ``revert-network`` run in the
  ## host's.
  let ip = ipTool()
  if ip.len == 0:
    return HostNetwork(ok: false, why: "no `ip` (iproute2) on the host")
  try:
    let l = runHostTool([ip, "-j", "-d", "link", "show"], mergeStderr = false,
                        timeoutSec = 30)
    let a = runHostTool([ip, "-j", "addr", "show"], mergeStderr = false,
                        timeoutSec = 30)
    let r4 = runHostTool([ip, "-j", "route", "show", "table", "main"],
                         mergeStderr = false, timeoutSec = 30)
    let r6 = runHostTool([ip, "-j", "-6", "route", "show", "table", "main"],
                         mergeStderr = false, timeoutSec = 30)
    for (what, r) in [("links", l), ("addresses", a), ("routes", r4),
                      ("IPv6 routes", r6)]:
      if r.exitCode != 0:
        return HostNetwork(ok: false, why: "`ip` could not list the host's " &
          what & " (exit " & $r.exitCode & ")")
    result = HostNetwork(ok: true, links: parseIpLinks(l.output),
      addresses: parseIpAddrs(a.output),
      routes: parseIpRoutes(r4.output, "inet") &
              parseIpRoutes(if r6.output.strip().len > 0: r6.output else: "[]",
                            "inet6"))
  except CatchableError as e:
    result = HostNetwork(ok: false, why: "the host's network could not be " &
      "read: " & e.msg)

proc linkNamed*(h: HostNetwork; name: string): int =
  for i, l in h.links:
    if l.name == name: return i
  -1

proc linkWithMac*(h: HostNetwork; mac: string): seq[HostLink] =
  ## The links whose own MAC is ``mac`` and that are not children of
  ## another link (an ipvlan child shares its parent's MAC).
  for l in h.links:
    if l.mac == mac and l.parent.len == 0: result.add(l)

proc addressesOf*(h: HostNetwork; iface: string): seq[HostAddress] =
  for a in h.addresses:
    if a.iface == iface: result.add(a)

proc inPrefix*(ip, prefix: string): bool =
  ## Is ``ip`` inside the CIDR ``prefix``? Same family only.
  try:
    let parts = prefix.split('/')
    let net = parseIpAddress(parts[0])
    let a = parseIpAddress(ip)
    if net.family != a.family: return false
    let bits = parseInt(parts[1])
    var i = 0
    while i * 8 < bits:
      let take = min(8, bits - i * 8)
      let mask = uint8((0xff shl (8 - take)) and 0xff)
      let x = if a.family == IpAddressFamily.IPv4: a.address_v4[i]
              else: a.address_v6[i]
      let y = if a.family == IpAddressFamily.IPv4: net.address_v4[i]
              else: net.address_v6[i]
      if (x and mask) != (y and mask): return false
      inc i
    true
  except CatchableError:
    false

proc renderObservation*(h: HostNetwork): seq[string] =
  ## The collision report's network lines (spec §4.5): every link,
  ## address and route the plan observed.
  if not h.ok:
    return @["network: unreadable: " & h.why]
  var links: seq[string]
  for l in h.links:
    links.add(l.name & (if l.kind.len > 0: " (" & l.kind & ")" else: "") &
              (if l.parent.len > 0: " on " & l.parent else: "") &
              (if l.up: " up" else: " down"))
  result.add("network: links: " & links.join(", "))
  var addrs: seq[string]
  for a in h.addresses:
    addrs.add(a.ip & "/" & $a.prefixLen & " on " & a.iface)
  result.add("network: addresses: " & addrs.join(", "))
  var routes: seq[string]
  for r in h.routes: routes.add(r.render)
  result.add("network: routes: " & routes.join("; "))

# ---------------------------------------------------------------------------
# Which manager runs the network (spec §4.5, §13 decisions 12, 101).
# ---------------------------------------------------------------------------

type ManagerState* = object
  networkManager*: string   ## ``systemctl is-active NetworkManager.service``
  networkd*: string         ## ``... systemd-networkd.service``

proc activeState(unit: string): string =
  try:
    let r = runSystemctl(["is-active", "--", unit])
    let s = r.output.strip().splitLines()
    if s.len > 0 and s[0].len > 0: s[0] else: "unknown"
  except CatchableError:
    "unknown"

proc observeManagers*(): ManagerState =
  ManagerState(networkManager: activeState("NetworkManager.service"),
               networkd: activeState("systemd-networkd.service"))

proc isRunning(state: string): bool =
  state in ["active", "activating", "reloading", "refreshing"]

proc managerRefusal*(m: ManagerState): string =
  ## Why a network object cannot be realised here, or "": only the
  ## NetworkManager realisation exists (§13 decision 12), and it is chosen
  ## by the ACTIVE service, never by configuration files (an Arch host
  ## carries networkd files while NetworkManager runs it). Both or neither
  ## running is refused too (decision 101).
  when mutated("network-manager-by-config-files"):
    return ""
  let nm = isRunning(m.networkManager)
  let nd = isRunning(m.networkd)
  if nm and not nd: return ""
  "only the NetworkManager realisation of the `network` class exists " &
    "(§13 decision 12), and it needs NetworkManager to be the one active " &
    "network manager; observed NetworkManager.service " & m.networkManager &
    ", systemd-networkd.service " & m.networkd

# ---------------------------------------------------------------------------
# Plan-time refusals.
# ---------------------------------------------------------------------------

type
  NetworkPlanInputs* = object
    links*: seq[SystemResource]     ## the profile's linux.networkLink objects
    previous*: Ledger               ## the ledger the switch begins from
    guard*: NetworkGuardSettings
    host*: HostNetwork
    managers*: ManagerState
    agentApply*: bool
    arping*: string                 ## the base's arping, "" when none
    change*: NetworkChange

  NetworkPlan* = object
    ## What the plan decided for the class: each link's parent (resolved
    ## from its MAC), the IPv4 addresses the probe must check, the default
    ## routes observed before the switch.
    parents*: Table[string, string]     ## link name -> parent interface
    probe*: seq[tuple[parent, address: string]]
    defaultRoutes*: seq[string]
    lines*: seq[string]                 ## the plan's report

proc ownLinkNames(previous: Ledger): HashSet[string] =
  for e in networkEntries(previous): result.incl(e.unit)

proc ownAddresses(previous: Ledger; host: HostNetwork): HashSet[string] =
  ## The addresses the add-on's own links hold now.
  let own = ownLinkNames(previous)
  for a in host.addresses:
    if a.iface in own: result.incl(a.ip)

proc planNetwork*(inp: NetworkPlanInputs): NetworkPlan =
  ## Every refusal of spec §4.5 and §8.5 that is decided before anything is
  ## written, in this order: what the class may not declare
  ## (``EAddOnOutOfScope``), an agent apply of a network generation, the
  ## active manager, the guard's settings and what they name on the host,
  ## each link's parent, a link name or an address in use, the kernel's
  ## one-kind-per-parent rule, and a missing ``arping``
  ## (``EAddOnUnsupportedBase``). Raises the refusal; returns the plan.
  for r in inp.links:
    for (field, value) in r.nlUndeclarable:
      when not mutated("network-undeclarable-accepted"):
        raise newAddOnOutOfScope("linux.networkLink." & field, "",
          r.address, "the `network` class adds a link beside the " &
          "distribution's network and changes nothing of it; `" & field &
          " = " & value & "` is not declarable (spec §4.5: no default " &
          "route or gateway, no DHCP on the link, no setting of the " &
          "parent interface, no global DNS server or search domain, no " &
          "dependency on a connection the add-on does not own)")
  if inp.links.len == 0 and not inp.change.any:
    return
  if inp.agentApply:
    raise newAddOnOutOfScope("linux.networkLink", "", "network",
      "a generation that adds, changes or removes a `network` object is " &
      "applied only by an operator, under the network guard (spec §4.5); " &
      "a deploy-agent apply refuses it (" & inp.change.describe & ")")
  let why = managerRefusal(inp.managers)
  if why.len > 0:
    raise newAddOnOutOfScope("linux.networkLink", "", "network", why)
  if not inp.host.ok:
    raise newAddOnError(adNetworkGuard, "the host's links, addresses and " &
      "routes could not be read (" & inp.host.why & "); a network " &
      "generation is not planned blind")
  result.lines = renderObservation(inp.host)
  result.defaultRoutes = defaultRoutes(inp.host)
  if inp.links.len > 0:
    var p = SystemProfile()
    p.resources = inp.links
    p.addOn.networkGuard = inp.guard
    p.addOn.declared = true
    let gp = networkGuardProblem(p)
    if gp.len > 0:
      raise newAddOnOutOfScope("addOn.networkGuard", "", "addOn", gp)
  # What the guard checks must be there to be checked (§8.5): each keep
  # interface holding an address in its prefix, each out-of-band link up
  # with an address.
  if inp.links.len > 0 or inp.change.any:
    for k in inp.guard.keep:
      var held = false
      for a in addressesOf(inp.host, k.iface):
        if inPrefix(a.ip, k.prefix): held = true
      if inp.host.linkNamed(k.iface) < 0 or not held:
        raise newAddOnError(adNetworkGuard, "networkGuard keep " & k.iface &
          " " & k.prefix & " is not observed on the host before the " &
          "switch (" & (if inp.host.linkNamed(k.iface) < 0: "no such link"
                        else: "no address in that prefix") & "); the guard " &
          "could never disarm (§8.5)")
    for l in inp.guard.outOfBand:
      let i = inp.host.linkNamed(l)
      if i < 0 or not inp.host.links[i].up or
          addressesOf(inp.host, l).len == 0:
        raise newAddOnError(adNetworkGuard, "networkGuard outOfBand " & l &
          " is not observed up with an address before the switch; the " &
          "guard could never disarm (§8.5)")
  let own = ownLinkNames(inp.previous)
  let ownAddrs = ownAddresses(inp.previous, inp.host)
  var declaredAddrs = initTable[string, string]()
  var kindOnParent = initTable[string, string]()
  for r in inp.links:
    # The parent, by MAC, never one of the class's own links.
    if r.nlKind != "dummy":
      let cands = linkWithMac(inp.host, r.nlParentMac)
      if cands.len != 1:
        raise newAddOnOutOfScope("linux.networkLink.parentMac", "",
          r.address, "the parent MAC " & r.nlParentMac & " names " &
          (if cands.len == 0: "no link" else: $cands.len & " links") &
          " on the host; the parent must be exactly one observed interface")
      let parent = cands[0].name
      if parent in own or parent.startsWith("repro-"):
        raise newAddOnOutOfScope("linux.networkLink.parentMac", "",
          r.address, "the parent " & parent & " is a link of the add-on's " &
          "own; a child is created on a distribution interface")
      for o in inp.links:
        if o.nlName == parent:
          raise newAddOnOutOfScope("linux.networkLink.parentMac",
            "", r.address, "the parent " & parent & " is a link " &
            "this profile declares")
      result.parents[r.nlName] = parent
      # The kernel refuses ipvlan and macvlan children on one parent.
      let other = if r.nlKind == "ipvlan": "macvlan" else: "ipvlan"
      if kindOnParent.getOrDefault(parent) == other:
        raise newAddOnOutOfScope("linux.networkLink.kind", "",
          r.address, "this profile puts both ipvlan and macvlan links on " &
          parent & "; the kernel refuses the second kind (EBUSY)")
      kindOnParent[parent] = r.nlKind
      for l in inp.host.links:
        if l.parent == parent and l.kind == other and l.name notin own:
          raise newAddOnOutOfScope("linux.networkLink.kind", "",
            r.address, parent & " already carries the " & other & " link " &
            l.name & "; the kernel refuses an " & r.nlKind & " child beside " &
            "it (EBUSY)")
    # A link name in use by anything but the add-on's own link of that name.
    let li = inp.host.linkNamed(r.nlName)
    if li >= 0 and r.nlName notin own:
      when not mutated("network-link-name-in-use-accepted"):
        raise newAddOnOutOfScope("linux.networkLink.name", "",
          r.address, "the link name " & r.nlName & " is in use on the host " &
          "(" & (if inp.host.links[li].kind.len > 0: inp.host.links[li].kind
                 else: "a device") & " not created by the add-on); the " &
          "class adds links, it never takes one over (spec §4.5)")
    # An address present anywhere on the host, unless the add-on's own
    # link of this name holds it already.
    for a in r.nlAddresses:
      let ip = ipOf(a)
      if ip in declaredAddrs:
        raise newAddOnOutOfScope("linux.networkLink.addresses", "",
          r.address, ip & " is declared by both " & declaredAddrs[ip] &
          " and " & r.nlName)
      declaredAddrs[ip] = r.nlName
      for h in inp.host.addresses:
        if h.ip != ip: continue
        if h.iface == r.nlName and r.nlName in own: continue
        when not mutated("network-host-address-accepted"):
          raise newAddOnOutOfScope("linux.networkLink.addresses", "",
            r.address, ip & " is already on the host (on " & h.iface &
            "); the class adds an address no one holds (spec §4.5)")
      # A new IPv4 address on a link with a parent is probed on the
      # parent before the switch (§13 decision 88).
      if isIpv4(a) and r.nlKind != "dummy" and ip notin ownAddrs:
        result.probe.add((result.parents[r.nlName], ip))
  if result.probe.len > 0 and inp.arping.len == 0:
    raise newAddOnUnsupportedBase("", "`arping` (iputils) is required to add an " &
      "IPv4 address (spec §4.5, §13 decision 88): the duplicate-address " &
      "probe runs on the parent before the switch")
  for (parent, ip) in result.probe:
    result.lines.add("network: will probe " & ip & " on " & parent &
      " with arping -D before the switch")

# ---------------------------------------------------------------------------
# The duplicate-address probe (spec §4.5, §13 decision 88).
# ---------------------------------------------------------------------------

type ProbeReply* = object
  address*: string
  mac*: string        ## the replying MAC, as arping prints it, lowercase
  detail*: string

proc parseArpingReply*(output: string): string =
  ## The MAC of the first ``Unicast reply from <ip> [<MAC>]`` line, or "".
  for line in output.splitLines():
    let i = line.find("reply from ")
    if i < 0: continue
    let a = line.find('[', i)
    let b = line.find(']', a + 1)
    if a > 0 and b > a: return line[a + 1 ..< b].toLowerAscii()
  ""

proc probeAddress*(arping, parent, ip: string): ProbeReply =
  ## ``arping -D -I <parent> -c 3 -w 3 <ip>``: exit 0 is "no reply", exit 1
  ## with a reply is "in use"; anything else is a failed probe, raised as
  ## ``EAddOnNetworkGuard`` (an address that could not be probed is not
  ## added).
  when mutated("network-skips-arping-probe"):
    return ProbeReply(address: ip)
  var argv = @[arping]
  argv.add(ArpingArgs[0])
  argv.add(["-I", parent])
  argv.add(ArpingArgs[1 .. ^1])
  argv.add(ip)
  let r = runHostTool(argv, timeoutSec = 15)
  if r.exitCode == 0:
    return ProbeReply(address: ip)
  let mac = parseArpingReply(r.output)
  if r.exitCode == 1 and mac.len > 0:
    return ProbeReply(address: ip, mac: mac, detail: r.output.strip())
  raise newAddOnError(adNetworkGuard, "the duplicate-address probe of " & ip &
    " on " & parent & " failed (`" & argv.join(" ") & "` exit " &
    $r.exitCode & ": " & r.output.strip() & "); nothing was written")

proc probeDuplicates*(arping: string; probe: seq[tuple[parent, address: string]]) =
  ## Probe every new IPv4 address; the first reply refuses the apply with
  ## ``EAddOnNetworkGuard`` naming the replying MAC, before anything is
  ## written (spec §4.5).
  for (parent, ip) in probe:
    let r = probeAddress(arping, parent, ip)
    if r.mac.len > 0:
      raise newAddOnError(adNetworkGuard, "address in use on the LAN: " & ip &
        " answered the duplicate-address probe on " & parent & " from " &
        r.mac & " (arping -D); nothing was written")

# ---------------------------------------------------------------------------
# Writing and removing connections.
# ---------------------------------------------------------------------------

proc nmcli(args: openArray[string]; timeoutSec = NmcliTimeoutSec):
    HostToolResult =
  let exe = resolveHostTool(NmcliCandidates)
  if exe.len == 0:
    return HostToolResult(exitCode: 127, output: "no nmcli on the host")
  runHostTool(@[exe] & @args, timeoutSec = timeoutSec)

const NmcliNotRunning = 8
  ## nmcli(1)'s exit status "NetworkManager is not running". Boot recovery
  ## can run before NetworkManager starts (measured on the Omarchy VM,
  ## 2026-11-20): a keyfile written or removed then takes effect when
  ## NetworkManager reads its connection directory at start, so a revert's
  ## file work is done and only its activation waits for that start.

proc nmNotRunning(r: HostToolResult): bool =
  r.exitCode == NmcliNotRunning or
    "networkmanager is not running" in r.output.toLowerAscii()

proc writeKeyfile*(path, content: string) =
  ## The keyfile as NetworkManager requires it: a regular file, root-owned,
  ## mode 0600, written to a temporary name, fsynced and renamed, never
  ## through a link on the path (``nofollow_write``).
  if not isAddOnKeyfile(path):
    raise newException(ValueError, "not a keyfile of the network class: " &
      path)
  writeFileNoFollow(path, content, 0o600, uid = 0, gid = 0)

proc activateKeyfile*(path, uuid: string): string =
  ## ``nmcli connection load <path>`` then ``nmcli connection up uuid
  ## <uuid>``: that connection only. "" on success, else what failed.
  let l = nmcli(["connection", "load", path])
  if nmNotRunning(l): return ""
  if l.exitCode != 0:
    return "nmcli connection load " & path & " failed (exit " &
      $l.exitCode & "): " & l.output.strip()
  let u = nmcli(["connection", "up", "uuid", uuid])
  if u.exitCode != 0:
    return "nmcli connection up uuid " & uuid & " failed (exit " &
      $u.exitCode & "): " & u.output.strip()
  ""

proc applyNetworkObject*(o: NetworkObject): string =
  ## Write and activate one connection. "" on success.
  try:
    writeKeyfile(o.path, o.content)
  except CatchableError as e:
    return "cannot write " & o.path & ": " & e.msg
  activateKeyfile(o.path, o.uuid)

proc removeOwnLink(name: string): string =
  ## The class's own link ``name``, when one is still there after its
  ## connection went: NetworkManager deletes the software device of a
  ## connection it deactivates, but not one that is ``unavailable`` --
  ## measured with the parent's carrier lost when the guard reverted (AR5,
  ## 2026-11-20), where ``rhome@enp0s3`` stayed with no connection. Only a
  ## link of the class's kinds is removed. "" on success.
  if name.len == 0: return ""
  let ip = resolveHostTool(IpCandidates)
  if ip.len == 0: return ""
  try:
    let r = runHostTool([ip, "-j", "-d", "link", "show", "dev", name],
                        mergeStderr = false, timeoutSec = 30)
    if r.exitCode != 0: return ""          # no such link: nothing left
    let links = parseIpLinks(r.output)
    if links.len != 1 or links[0].kind notin NetworkLinkKinds: return ""
    let d = nmcli(["device", "delete", name])
    if d.exitCode == 0: return ""
    let k = runHostTool([ip, "link", "delete", "dev", name], timeoutSec = 30)
    if k.exitCode != 0:
      # NetworkManager may have removed the device itself between the look
      # and the delete (measured: "Cannot find device"); gone is removed.
      let again = runHostTool([ip, "link", "show", "dev", name],
                              mergeStderr = false, timeoutSec = 30)
      if again.exitCode == 0:
        return "cannot delete the link " & name & ": " & k.output.strip()
  except CatchableError as e:
    return "cannot delete the link " & name & ": " & e.msg
  ""

proc removeNetworkObject*(path, uuid: string; linkName = ""): string =
  ## Take one of the class's connections off the host: ``nmcli connection
  ## delete uuid <uuid>`` (which deactivates it and removes its file), the
  ## file again by name in case NetworkManager did not know it, and its own
  ## link ``linkName`` if that is left behind. A connection already gone,
  ## or NetworkManager not running yet, is not an error. "" on success.
  if not isAddOnKeyfile(path):
    return "not a keyfile of the network class: " & path
  var problems: seq[string]
  if uuid.len > 0:
    let d = nmcli(["connection", "delete", "uuid", uuid])
    if d.exitCode != 0 and not nmNotRunning(d) and
        "not found" notin d.output.toLowerAscii() and
        "unknown connection" notin d.output.toLowerAscii() and
        "cannot find" notin d.output.toLowerAscii():
      problems.add("nmcli connection delete uuid " & uuid & " (exit " &
        $d.exitCode & "): " & d.output.strip())
  try:
    if removeLeafNoFollow(path):
      # NetworkManager reloads a connection whose file went: told
      # explicitly, so it never keeps an in-memory copy.
      discard nmcli(["connection", "load", path])
  except CatchableError as e:
    problems.add("cannot remove " & path & ": " & e.msg)
  let l = removeOwnLink(linkName)
  if l.len > 0: problems.add(l)
  problems.join("; ")

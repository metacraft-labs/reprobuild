## The `network` class and the network guard's pure pieces (ReproOS Add-On
## Mode §4.5, §5.3, §8.5; §13 decisions 12, 86-88, 96, 97, 101-110,
## 116-129, 120; threat model G47, G48, G49, G52, T55, T57, T59, T62).
##
## What is checked here, without a host:
##
## - the profile surface: `linux.networkLink` (text form and DSL), the
##   nested `networkGuard` stanza, their refusals when the profile is
##   parsed, the class directories (`managedEtcPrefixes` and an
##   `fs.systemFile` inside one), and the round trip through the canonical
##   text, the intent JSON and the intent codec;
## - the keyfile each link renders (parent by MAC, `never-default`, the
##   route metric, `ipv4.dad-timeout`, routing-only DNS) and its stable
##   UUID;
## - `ip -j` parsing, the plan-time refusals of spec §4.5 and §8.5 over a
##   host description, and which manager is active;
## - the duplicate-address probe's reply parser;
## - the SSH evidence read only through the journal's trusted fields
##   (`logger -t sshd` does not count), and the confirm's session rule;
## - the guard record, the marker's guard fields, and the guard lock's
##   forward-only transitions (`transitionGuard`), including a step write
##   that must not undo a `fired` written meanwhile.
##
## *Mocking.* None of the host is mocked: the parsers are fed the exact
## output measured on the Omarchy VM (2026-11-20, NetworkManager 1.58.1,
## iproute2, OpenSSH 10), the lock and the markers live in a real
## temporary directory, and the guard lock is pointed there
## (`guard_lock.guardLockPath`) only because a unit test runs unprivileged
## and must not touch `/run`.

import std/[os, strutils, tables, unittest]

import repro_infra/addon_diagnostics
import repro_infra/errors
import repro_infra/intent
import repro_infra/profile
import repro_profile
import repro_profile/types as profileTypes
import repro_profile/emit as profileEmit
import repro_profile_intent/codec
import repro_addon/[addon_apply, fingerprint, guard_lock, ledger, network_guard,
                    network_link, static_tree]

let root = getTempDir() / ("repro-addon-network-" & $getCurrentProcessId())
removeDir(root)
createDir(root)
guardLockPath = root / "guard.lock"

const Link = """
linux.networkLink {
  name = "home0"
  kind = "ipvlan"
  parentMac = "52:54:00:02:a9:e7"
  addresses = ["192.168.77.20/24"]
  dnsServers = ["192.168.77.1"]
  dnsDomains = ["~home.arpa"]
}
"""
const Guard = """
addOn {
  managedEtcPrefixes = ["/etc/web/"]
  networkGuard {
    timeout = 120
    keep = ["enp0s3 192.168.77.0/24"]
    outOfBand = ["enp0s2"]
  }
}
"""

proc refused(text: string): string =
  try:
    discard parseSystemProfile(text)
  except ESystemProfileInvalid as e:
    return e.msg
  ""

suite "the profile surface":
  test "a link and its guard parse and round-trip through the canonical text":
    let p = parseSystemProfile(Guard & Link)
    check p.addOn.networkGuard.declared
    check p.addOn.networkGuard.timeoutSec == 120
    check p.addOn.networkGuard.keep == @[NetworkGuardKeep(iface: "enp0s3",
      prefix: "192.168.77.0/24")]
    check p.addOn.networkGuard.outOfBand == @["enp0s2"]
    check p.addOn.managedEtcPrefixes == @["/etc/web/"]
    require p.resources.len == 1
    let r = p.resources[0]
    check r.kind == srkLinuxNetworkLink
    check r.address == "networkLink:home0"
    check r.nlParentMac == "52:54:00:02:a9:e7"
    check r.nlDnsDomains == @["~home.arpa"]
    check r.nlUndeclarable.len == 0
    let again = parseSystemProfile(renderProfileText(p))
    check renderProfileText(again) == renderProfileText(p)
    check again.addOn.networkGuard == p.addOn.networkGuard

  test "the guard's defaults and its range (§8.5, §13 decision 101)":
    check refused(Guard.replace("timeout = 120", "timeout = 29") & Link).len > 0
    check refused(Guard.replace("timeout = 120", "timeout = 3601") & Link).len > 0
    let p = parseSystemProfile(Guard.replace("timeout = 120\n", "") & Link)
    check p.addOn.networkGuard.timeoutSec == 0
    check DefaultNetworkGuardTimeoutSec == 300

  test "a link needs a guard that checks something (§13 decision 97)":
    check "networkGuard" in refused(Link)
    check "networkGuard" in refused("addOn {\n managedEtcPrefixes = []\n " &
      "networkGuard {\n  timeout = 60\n }\n}\n" & Link)
    # A keep entry or an out-of-band link is enough on its own.
    discard parseSystemProfile(Guard.replace("    outOfBand = [\"enp0s2\"]\n",
      "") & Link)
    discard parseSystemProfile(Guard.replace(
      "    keep = [\"enp0s3 192.168.77.0/24\"]\n", "") & Link)

  test "the guard may not check a link the profile declares":
    check "home0" in refused(Guard.replace("enp0s2", "home0") & Link)
    check "home0" in refused(Guard.replace("enp0s3 192", "home0 192") & Link)

  test "a malformed keep, a second guard, an unknown key are refused":
    check refused(Guard.replace("enp0s3 192.168.77.0/24",
                                "enp0s3  192.168.77.0/24") & Link).len > 0
    check refused(Guard.replace("192.168.77.0/24", "192.168.77.0/33") & Link).len > 0
    check refused(Guard.replace("enp0s3 192", "en/p0 192") & Link).len > 0
    check refused(Guard.replace("timeout = 120", "timeout = 120\n    jitter = 3") &
                  Link).len > 0
    check "twice" in refused(Guard.replace("  }\n}", "  }\n  networkGuard {\n" &
      "    outOfBand = [\"x\"]\n  }\n}") & Link)

  test "a link's own fields are checked as it is parsed":
    check refused(Guard & Link.replace("ipvlan", "vlan")).len > 0
    check refused(Guard & Link.replace("52:54:00:02:a9:e7", "52:54:00:02:A9:E7")).len > 0
    check refused(Guard & Link.replace("192.168.77.20/24", "192.168.77.20")).len > 0
    check refused(Guard & Link.replace("home0", "a-very-long-link-name")).len > 0
    check refused(Guard & Link.replace("  dnsServers", "  bogus = \"1\"\n  dnsServers")).len > 0
    check refused(Guard & Link.replace("kind = \"ipvlan\"", "kind = \"dummy\"")).len > 0

  test "what §4.5 says a link may not declare is kept for the plan to refuse":
    let p = parseSystemProfile(Guard & Link.replace("  dnsServers",
      "  gateway = \"192.168.77.1\"\n  dhcp = \"true\"\n  dnsServers").replace(
      "\"~home.arpa\"", "\"~home.arpa\", \"lan\""))
    var fields: seq[string]
    for (f, _) in p.resources[0].nlUndeclarable: fields.add(f)
    check "gateway" in fields
    check "dhcp" in fields
    check "searchDomains" in fields
    let q = parseSystemProfile(Guard & Link.replace(
      "  dnsDomains = [\"~home.arpa\"]\n", ""))
    check q.resources[0].nlUndeclarable[0].field == "globalDnsServers"

  test "the network class's directories are never managed prefixes (§4.4, §13 decision 120)":
    for pfx in ["/etc/NetworkManager/", "/etc/NetworkManager/system-connections/",
                "/etc/systemd/network/", "/etc/systemd/"]:
      checkpoint pfx
      check managedPrefixError(pfx).len > 0
    check managedPrefixError("/etc/NetworkManager/conf.d/").len == 0

  test "an fs.systemFile inside one is EAddOnOutOfScope in every apply (G52)":
    var p = SystemProfile()
    p.addOn.declared = true
    p.addOn.managedEtcPrefixes = @["/etc/NetworkManager/"]
    p.resources.add(SystemResource(kind: srkFsSystemFile,
      sfPath: "/etc/NetworkManager/system-connections/x.nmconnection",
      sfContent: "x", address: "systemFile:x"))
    var why = ""
    try: checkScope(p)
    except EAddOnOutOfScope as e: why = e.msg
    check "EAddOnOutOfScope" in why

  test "the DSL renders the same stanza and link as the text form":
    var pi = ProfileIntent()
    pi.addOn.declared = true
    pi.addOn.managedEtcPrefixes = @["/etc/web/"]
    pi.addOn.networkGuardDeclared = true
    pi.addOn.networkGuardTimeoutSec = 120
    pi.addOn.networkGuardKeep = @["enp0s3 192.168.77.0/24"]
    pi.addOn.networkGuardOutOfBand = @["enp0s2"]
    var rs: seq[ResourceIntent]
    linuxNetworkLink(rs, name = "home0", kind = "ipvlan",
      addresses = @["192.168.77.20/24"], parentMac = "52:54:00:02:a9:e7",
      dnsServers = @["192.168.77.1"], dnsDomains = @["~home.arpa"])
    pi.resources = rs
    let back = parseProfileIntentJson(emitProfileIntentJson(pi))
    check back.addOn.networkGuardKeep == pi.addOn.networkGuardKeep
    check back.addOn.networkGuardOutOfBand == pi.addOn.networkGuardOutOfBand
    check back.addOn.networkGuardTimeoutSec == 120
    let dec = decodeProfileIntentFromBytes(encodeProfileIntentToBytes(pi))
    check dec.addOn.networkGuardDeclared
    check dec.addOn.networkGuardKeep == pi.addOn.networkGuardKeep

suite "the keyfile":
  let r = parseSystemProfile(Guard & Link).resources[0]
  test "an ipvlan child of the parent matched by MAC, never the default":
    let k = renderKeyfile(r)
    check "type=ipvlan\n" in k
    check "interface-name=home0\n" in k
    check "[ethernet]\nmac-address=52:54:00:02:a9:e7\n" in k
    check "[ipvlan]\nmode=1\n" in k
    check "address1=192.168.77.20/24\n" in k
    check "never-default=true\n" in k
    check "route-metric=30000\n" in k
    check "dad-timeout=3000\n" in k
    check "dns=192.168.77.1;\n" in k
    check "dns-search=~home.arpa;\n" in k
    check "[ipv6]\nmethod=disabled\n" in k
    check "parent=" notin k
    check keyfilePath("home0") ==
      "/etc/NetworkManager/system-connections/repro-home0.nmconnection"

  test "the UUID depends on the name only, and is an RFC 9562 v8 UUID":
    let u = connectionUuid("home0")
    check u == connectionUuid("home0")
    check u != connectionUuid("home1")
    check u.len == 36 and u[14] == '8' and u[19] in {'8', '9', 'a', 'b'}
    check keyfileUuid(renderKeyfile(r)) == u

  test "a dummy link has no parent section":
    let d = parseSystemProfile(Guard & Link.replace("ipvlan", "dummy").replace(
      "  parentMac = \"52:54:00:02:a9:e7\"\n", "")).resources[0]
    let k = renderKeyfile(d)
    check "type=dummy\n" in k
    check "[ethernet]" notin k

suite "what the host has":
  const Links = """[{"ifindex":1,"ifname":"lo","flags":["LOOPBACK","UP","LOWER_UP"],"address":"00:00:00:00:00:00"},
{"ifindex":2,"ifname":"enp0s2","flags":["BROADCAST","MULTICAST","UP","LOWER_UP"],"address":"52:54:00:12:34:56"},
{"ifindex":3,"ifname":"enp0s3","flags":["BROADCAST","MULTICAST","UP","LOWER_UP"],"address":"52:54:00:02:a9:e7"},
{"ifindex":4,"link":"enp0s3","ifname":"rhome","flags":["BROADCAST","MULTICAST","UP","LOWER_UP"],"address":"52:54:00:02:a9:e7","linkinfo":{"info_kind":"ipvlan","info_data":{"mode":"l2"}}}]"""
  const Addrs = """[{"ifname":"lo","addr_info":[{"family":"inet","local":"127.0.0.1","prefixlen":8}]},
{"ifname":"enp0s2","addr_info":[{"family":"inet","local":"10.0.2.15","prefixlen":24}]},
{"ifname":"enp0s3","addr_info":[{"family":"inet","local":"192.168.77.129","prefixlen":24},{"family":"inet6","local":"fe80::8961:4b2d:abb5:7f27","prefixlen":64}]},
{"ifname":"rhome","addr_info":[{"family":"inet","local":"192.168.77.21","prefixlen":24}]}]"""
  const Routes = """[{"dst":"default","gateway":"10.0.2.2","dev":"enp0s2","protocol":"dhcp","metric":100,"flags":[]},
{"dst":"default","gateway":"192.168.77.1","dev":"enp0s3","protocol":"dhcp","metric":20101,"flags":[]},
{"dst":"192.168.77.0/24","dev":"enp0s3","protocol":"kernel","metric":101,"flags":[]}]"""
  let host = HostNetwork(ok: true, links: parseIpLinks(Links),
    addresses: parseIpAddrs(Addrs), routes: parseIpRoutes(Routes, "inet"))
  let p = parseSystemProfile(Guard & Link)
  let nm = ManagerState(networkManager: "active", networkd: "inactive")

  proc plan(links: seq[SystemResource]; host = host; managers = nm;
            agent = false; arping = "/usr/bin/arping";
            previous = Ledger(); guard = p.addOn.networkGuard): string =
    try:
      discard planNetwork(NetworkPlanInputs(links: links, previous: previous,
        guard: guard, host: host, managers: managers, agentApply: agent,
        arping: arping, change: networkChanges(previous,
          (block:
            var os: seq[NetworkObject]
            for l in links: os.add(networkObjectOf(l))
            os))))
    except EAddOn as e:
      return e.msg
    ""

  test "ip -j: links with their parents, addresses, default routes":
    check host.links[3].parent == "enp0s3" and host.links[3].kind == "ipvlan"
    check linkWithMac(host, "52:54:00:02:a9:e7").len == 1
    check defaultRoutes(host) == @[
      "[inet] default via 10.0.2.2 dev enp0s2 metric 100",
      "[inet] default via 192.168.77.1 dev enp0s3 metric 20101"]
    check inPrefix("192.168.77.129", "192.168.77.0/24")
    check not inPrefix("192.168.78.1", "192.168.77.0/24")
    check inPrefix("fe80::1", "fe80::/64")

  test "a free address on the parent matched by MAC plans, and is probed":
    let np = planNetwork(NetworkPlanInputs(links: p.resources,
      guard: p.addOn.networkGuard, host: host, managers: nm,
      arping: "/usr/bin/arping"))
    check np.parents["home0"] == "enp0s3"
    check np.probe == @[(parent: "enp0s3", address: "192.168.77.20")]

  test "only NetworkManager, and only alone (§13 decisions 12, 101)":
    for m in [ManagerState(networkManager: "inactive", networkd: "active"),
              ManagerState(networkManager: "active", networkd: "active"),
              ManagerState(networkManager: "inactive", networkd: "inactive")]:
      let why = plan(p.resources, managers = m)
      check "EAddOnOutOfScope" in why
      check "decision 12" in why
      check "systemd-networkd.service " & m.networkd in why

  test "an agent apply of a network generation is refused":
    check "only by an operator" in plan(p.resources, agent = true)

  test "an agent apply that leaves the connections as they are is not (G47)":
    # The add-on's own link, its keyfile in the previous ledger byte for
    # byte: the generation changes no connection.
    let mine = parseSystemProfile(Guard & Link.replace("home0", "rhome").replace(
      "192.168.77.20", "192.168.77.21")).resources
    let o = networkObjectOf(mine[0])
    var prev = Ledger()
    prev.entries.add(LedgerEntry(class: lcNetwork, unit: "rhome", path: o.path,
      sha256: sha256Hex(o.content)))
    check plan(mine, previous = prev, agent = true) == ""

  test "an address on the host and a link name in use are refused":
    let taken = parseSystemProfile(Guard & Link.replace("192.168.77.20",
      "192.168.77.129")).resources
    check "already on the host" in plan(taken)
    let named = parseSystemProfile(Guard & Link.replace("home0", "rhome")).resources
    check "in use on the host" in plan(named)

  test "the add-on's own link keeps its name and address on the next switch":
    var prev = Ledger()
    prev.entries.add(LedgerEntry(class: lcNetwork, unit: "rhome",
      path: keyfilePath("rhome"), sha256: "x"))
    let mine = parseSystemProfile(Guard & Link.replace("home0", "rhome").replace(
      "192.168.77.20", "192.168.77.21")).resources
    check plan(mine, previous = prev) == ""

  test "what §4.5 may not declare is EAddOnOutOfScope naming it":
    let g = parseSystemProfile(Guard & Link.replace("  dnsServers",
      "  gateway = \"192.168.77.1\"\n  dnsServers")).resources
    let why = plan(g)
    check "EAddOnOutOfScope" in why
    check "linux.networkLink.gateway" in why

  test "a missing arping is EAddOnUnsupportedBase":
    check "EAddOnUnsupportedBase" in plan(p.resources, arping = "")

  test "a parent MAC on no link, and ipvlan beside macvlan, are refused":
    let none = parseSystemProfile(Guard & Link.replace("52:54:00:02:a9:e7",
      "52:54:00:aa:bb:cc")).resources
    check "names no link" in plan(none)
    let mac = parseSystemProfile(Guard & Link.replace("ipvlan", "macvlan")).resources
    check "EBUSY" in plan(mac)

  test "the guard's keep and outOfBand must be there before the switch":
    var g = p.addOn.networkGuard
    g.keep = @[NetworkGuardKeep(iface: "enp0s3", prefix: "10.9.0.0/16")]
    check "keep" in plan(p.resources, guard = g)
    g = p.addOn.networkGuard
    g.outOfBand = @["wt0"]
    check "outOfBand wt0" in plan(p.resources, guard = g)

  test "the invariants after the switch":
    check invariantFailures(p.addOn.networkGuard, defaultRoutes(host), host).len == 0
    var lost = host
    lost.addresses = @[lost.addresses[0], lost.addresses[1]]
    lost.routes = @[lost.routes[0]]
    let f = invariantFailures(p.addOn.networkGuard, defaultRoutes(host), lost)
    check f.len == 2
    check "keep: enp0s3" in f[0]
    check "default route" in f[1]
    var down = host
    down.links[1].up = false
    check "outOfBand: enp0s2 is down" in
      invariantFailures(p.addOn.networkGuard, defaultRoutes(host), down)[0]

  test "a network generation is one whose connections change":
    let o = networkObjectsOf(p)
    check networkChanges(Ledger(), o).added == @[o[0].path]
    var prev = Ledger()
    prev.entries.add(LedgerEntry(class: lcNetwork, path: o[0].path,
      sha256: "0" & o[0].content[1 .. ^1]))
    check networkChanges(prev, o).changed == @[o[0].path]
    check networkChanges(prev, @[]).removed == @[o[0].path]

suite "the duplicate-address probe (§13 decision 88)":
  test "arping's reply names the defender's MAC":
    let output = "ARPING 192.168.77.50 from 0.0.0.0 enp0s3\n" &
      "Unicast reply from 192.168.77.50 [52:54:00:8E:2E:C5]  1.045ms\n" &
      "Sent 1 probes (1 broadcast(s))\nReceived 1 response(s)\n"
    check parseArpingReply(output) == "52:54:00:8e:2e:c5"
    check parseArpingReply("Sent 3 probes (3 broadcast(s))\nReceived 0 response(s)\n") == ""

suite "the SSH evidence (§4.5 step 3, threat model T55)":
  let id = SshIdentity(unit: "sshd.service",
                       exes: @["/usr/bin/sshd", "/usr/lib/ssh/sshd-session"])
  const Real = """{"_SYSTEMD_UNIT":"sshd.service","_EXE":"/usr/lib/ssh/sshd-session","SYSLOG_IDENTIFIER":"sshd-session","MESSAGE":"Accepted publickey for root from 10.0.2.2 port 52186 ssh2: ED25519 SHA256:x","__REALTIME_TIMESTAMP":"1795128481514818"}"""
  const Forged = """{"_SYSTEMD_UNIT":"session-12.scope","_COMM":"logger","SYSLOG_IDENTIFIER":"sshd","MESSAGE":"Accepted publickey for root from 10.9.9.9 port 1 ssh2: FORGED","__REALTIME_TIMESTAMP":"1795128481628494"}"""
  # The moment the switch finished its network writes: every case below
  # but the "not yet written" one reads the journal from here.
  const Written = 1795128481000000'i64
  let own = @["127.0.0.1", "10.0.2.15", "192.168.77.129",
              "fe80::8961:4b2d:abb5:7f27"]
  test "a real login after the switch counts":
    check sshEvidenceIn(Real, id, Written, own).len > 0
  test "before the network writes are done it does not":
    check sshEvidenceIn(Real, id, 1795128481514818, own) == ""
    # Not yet recorded (0): nothing counts, however late the login.
    check sshEvidenceIn(Real, id, 0, own) == ""
  test "logger -t sshd does not, whatever it says (control (g))":
    check sshEvidenceIn(Forged,
                        id, Written, own) == ""
  test "loopback and password logins do not":
    check sshEvidenceIn(Real.replace("10.0.2.2", "127.0.0.1"), id, Written,
                        own) == ""
    check sshEvidenceIn(Real.replace("publickey", "password"), id, Written,
                        own) == ""
  test "a login from an address the host holds itself does not (T55)":
    check sshEvidenceIn(Real.replace("10.0.2.2", "192.168.77.129"), id,
                        Written, own) == ""
    check sshEvidenceIn(Real.replace("10.0.2.2", "::ffff:10.0.2.15"), id,
                        Written, own) == ""
    check sshEvidenceIn(Real.replace("10.0.2.2", "fe80::8961:4b2d:abb5:7f27%enp0s3"),
                        id, Written, own) == ""
    check isOwnAddress("::ffff:192.168.77.129", own)
    check not isOwnAddress("192.168.77.130", own)
    check isLoopback("::ffff:127.0.0.1") and isLoopback("127.1.2.3") and
          isLoopback("::1") and not isLoopback("10.0.2.2")
  test "a confirm counts only from a remote SSH session created after the switch":
    let s = LogindSession(id: "12", service: "sshd", remote: true,
                          remoteHost: "10.0.2.2", createdMonoUs: 2000)
    check confirmProblem(s, 1000, own) == ""
    check "before the switch wrote" in confirmProblem(s, 3000, own)
    check "not yet written" in confirmProblem(s, 0, own)
    var l = s
    l.remoteHost = "127.0.0.1"
    check "loopback" in confirmProblem(l, 1000, own)
    var t = s
    t.service = "login"
    check "not an SSH session" in confirmProblem(t, 1000, own)
  test "a confirm from an address the host holds itself does not count (T55)":
    let s = LogindSession(id: "13", service: "sshd", remote: true,
                          remoteHost: "192.168.77.129", createdMonoUs: 2000)
    check "an address of this host" in confirmProblem(s, 1000, own)

suite "the guard record and the marker's guard (§4.5 step 4)":
  let stateDir = root / "state"
  createDir(stateDir / "addon")
  test "the guard record round-trips":
    let r = GuardRecord(attempt: repeat('a', 32), previous: "g1",
      attemptObjects: @[GuardObject(path: keyfilePath("home0"), uuid: "u",
                                    sha256: "s", name: "home0")],
      previousObjects: @[GuardObject(path: keyfilePath("old"), uuid: "v",
                                     sha256: "t", preserved: "/p", name: "old")])
    writeGuardRecord(stateDir, r)
    check readGuardRecord(stateDir) == r

  test "the guard fields round-trip and are absent from other markers":
    var m = PendingMarker(fromGeneration: "g1", step: ssRealise,
      status: "in-progress", guard: "armed", guardAttempt: repeat('b', 32),
      guardTimer: "repro-addon-guard-x-1", guardPrevious: "g1",
      guardTimeout: 300, guardStartRealtime: 12, guardStartMono: 34)
    check parsePendingMarker(m.render()).guardStartMono == 34
    check parsePendingMarker(m.render()).guard == "armed"
    check "guard-written" notin m.render()
    m.guardWrittenRealtime = 56
    m.guardWrittenMono = 78
    check parsePendingMarker(m.render()).guardWrittenMono == 78
    check parsePendingMarker(m.render()).guardWrittenRealtime == 56
    check "guard" notin PendingMarker(step: ssRealise).render()

  test "the guard moves only forward, and a step write keeps it":
    let a = repeat('c', 32)
    writePendingMarker(stateDir, PendingMarker(fromGeneration: "g1",
      step: ssRealise, status: "in-progress", guard: "armed",
      guardAttempt: a, guardTimer: "t0"))
    let pid = readPendingMarker(stateDir).ownerPid
    # The timer fires first ...
    let f = transitionGuard(stateDir, a, "fired", GuardTimerReason, "t1")
    check f.found and f.before == "armed" and f.after == "fired"
    # ... so the owner's disarm finds `fired` and changes nothing but the
    # record it reads (decision 103).
    let d = transitionGuard(stateDir, a, "disarmed", "")
    check d.before == "fired" and d.after == "fired"
    # A step boundary the owner records does not undo it either.
    var stale = readPendingMarker(stateDir)
    stale.guard = "armed"
    stale.step = ssCopies
    writePendingMarker(stateDir, stale)
    let now = readPendingMarker(stateDir)
    check now.guard == "fired"
    check now.guardReason == GuardTimerReason
    check now.guardTimer == "t1"
    check now.step == ssCopies
    # A guard actor's rewrite does not make it the owner.
    check now.ownerPid == pid
    # Another attempt's actor finds nothing of its own.
    check not transitionGuard(stateDir, repeat('d', 32), "fired", "x").found
    # A fired guard records no end of the network writes: no evidence is
    # needed any more.
    check not recordNetworkWritesDone(stateDir, a, 1, 2)
    clearPendingMarker(stateDir)

  test "the end of the network writes is recorded once and a step write keeps it":
    let a = repeat('e', 32)
    writePendingMarker(stateDir, PendingMarker(fromGeneration: "g1",
      step: ssRealise, status: "in-progress", guard: "armed",
      guardAttempt: a, guardTimer: "t0"))
    check recordNetworkWritesDone(stateDir, a, 100, 200)
    check recordNetworkWritesDone(stateDir, a, 300, 400)   # kept: once
    check readPendingMarker(stateDir).guardWrittenMono == 200
    # The owner's next step boundary, from its in-memory marker that never
    # saw the record, keeps it.
    var stale = readPendingMarker(stateDir)
    stale.guardWrittenMono = 0
    stale.guardWrittenRealtime = 0
    stale.step = ssCopies
    writePendingMarker(stateDir, stale)
    check readPendingMarker(stateDir).guardWrittenMono == 200
    check readPendingMarker(stateDir).guardWrittenRealtime == 100
    check not recordNetworkWritesDone(stateDir, repeat('f', 32), 1, 2)
    clearPendingMarker(stateDir)

  test "the guard lock is 0600 and is not followed through a link (T62)":
    var l = acquireGuardLock()
    l.release()
    check getFilePermissions(guardLockPath) == {fpUserRead, fpUserWrite}
    removeFile(guardLockPath)
    createSymlink(root / "elsewhere", guardLockPath)
    expect GuardLockError:
      discard acquireGuardLock()
    removeFile(guardLockPath)
    check not removeGuardLock()

suite "the guard binary's place in the own profile":
  test "the add-on binary is the one the re-assert unit runs":
    let own = "systemd.systemUnit {\n  name = \"repro-addon-reassert.service\"\n" &
      "  content = \"[Service]\nExecStart=/repro/store/prefixes/repro-addon/" &
      "0.2.10-abcd/bin/repro system addon reassert --boot\n\"\n}\n"
    check storeAddonBinaryOf(own) ==
      "/repro/store/prefixes/repro-addon/0.2.10-abcd/bin/repro"
    check attemptOfUnit(guardUnitName(repeat('e', 32), "0123abcd") & ".timer") ==
      repeat('e', 32)
    check attemptOfUnit("repro-addon-reassert.service") == ""

removeDir(root)

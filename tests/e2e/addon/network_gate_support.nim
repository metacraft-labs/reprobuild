## The test bed of the `network` class's gates (milestone AR5; spec
## ReproOS-Add-On-Mode §4.5, §8.5, §12.1).
##
## Two guests on one test LAN (gosti ``ExtraNic``: a point-to-point link of
## two unix datagram sockets, nothing leaves the host):
##
## - **the Omarchy VM**, which runs NetworkManager. Its first NIC is QEMU's
##   user-mode network, the harness's SSH channel; it stands in for the
##   out-of-band link (NetBird's ``wt0``) and is the guard's ``outOfBand``.
##   Its second NIC, on the LAN, is the PARENT: NetworkManager takes a
##   DHCP lease and a default route on it;
## - **a helper**, a plain Arch guest (``arch-ext4-amd64``), which is the
##   LAN's DHCP server and gateway (systemd-networkd's own server: no
##   package is installed), the second device that holds an address for the
##   duplicate-address gate, and the LAN host that reaches the add-on's
##   address over SSH.
##
## **The harness's own SSH sessions.** Every fresh SSH connection is a new
## key-authenticated session from a non-loopback address -- the very thing
## that disarms the network guard (spec §4.5 step 3). So during a guard's
## window the harness talks to the Omarchy VM only through a connection it
## opened BEFORE the switch (an OpenSSH ``ControlMaster``: one connection,
## one logind session, one "Accepted publickey" journal line), and opens a
## fresh one only where a gate means to disarm (``freshSsh``) -- and only
## once the switch has written its last network object, since a session
## before that is not evidence (spec §4.5 step 3, amended 2026-11-22). The
## apply
## itself runs detached in a transient unit (``startApply``), so the
## harness can watch it, kill it (``systemctl kill``) or let the timer act.
##
## *Mocking.* None: two real VMs, real NetworkManager, systemd-networkd,
## arping, sshd and logind.

import std/[json, os, osproc, strutils, times]

import ./arch_gate_support

export arch_gate_support

const
  LanNet* = "192.168.77"
  HelperLanAddr* = LanNet & ".1"
  LinkName* = "rhome"
  LinkAddr* = LanNet & ".20/24"
  LanPrefix* = LanNet & ".0/24"
  StateDir* = "/var/lib/repro/system"
  # The guard's reasons as the add-on writes them (repro_addon/network_guard).
  GuardTimerReason* = "guard timer fired"
  TimerGoneReason* = "armed, its timer gone"
  ArmedAcrossRebootReason* = "armed across a reboot"
  InterruptedByRebootSuffix* = "; revert interrupted by a reboot"
  MarkerPath* = StateDir & "/addon/pending"

type NetBed* = ref object
  om*, helper*: Guest
  parent*, oob*: string     ## the Omarchy VM's LAN and user-mode NICs
  parentMac*: string
  mux*: string              ## the ControlMaster socket
  muxUp*: bool

proc helperNetworkd(mac: string): string =
  "[Match]\nMACAddress=" & mac & "\n\n[Network]\nAddress=" & HelperLanAddr &
    "/24\nDHCPServer=yes\nIPv6AcceptRA=no\nLinkLocalAddressing=no\n\n" &
    "[DHCPServer]\nPoolOffset=100\nPoolSize=50\nEmitRouter=yes\nEmitDNS=no\n"

proc newNetBed*(): NetBed =
  ## Claim and wire (not boot) the two guests.
  result = NetBed()
  result.helper = newArchGuest(archBaseNamed("arch-ext4-amd64"))
  result.om = newArchGuest(archBaseNamed("omarchy-amd64"))
  lanPair(result.helper, result.om)
  result.mux = result.om.runDir / "mux"

proc ifaceWithMac(g: Guest; mac: string): string =
  g.run("for d in /sys/class/net/*; do [ \"$(cat $d/address)\" = " &
    quoteShell(mac) & " ] && basename $d; done; true").strip().splitLines()[0]

proc bootNetBed*(nb: NetBed; step: StepFn) =
  ## Boot both, make the helper the LAN's DHCP server, and wait until the
  ## Omarchy VM holds a lease and a LAN default route.
  nb.helper.boot()
  nb.om.boot()
  nb.helper.prepareArchGuest()
  nb.om.prepareArchGuest()
  discard nb.helper.run("cat > /etc/systemd/network/05-repro-gate-lan.network <<'EOF'\n" &
    helperNetworkd(nb.helper.lanMac()) & "EOF\nnetworkctl reload")
  nb.parentMac = nb.om.lanMac()
  nb.parent = nb.om.ifaceWithMac(nb.parentMac)
  nb.oob = nb.om.run("ip -4 -o addr show | awk '/10\\.0\\.2\\./{print $2}' | " &
    "head -1").strip()
  # The LAN NIC's DHCP connection activates once the server answers.
  let leased = nb.om.exec("for i in $(seq 1 90); do ip -4 -o addr show dev " &
    nb.parent & " | grep -q " & LanNet & ". && ip -4 route show default | " &
    "grep -q " & HelperLanAddr & " && exit 0; sleep 2; done; exit 1",
    timeoutSec = 240)
  # The parent's own connection as a real host has it: a persistent
  # keyfile (`gate-lan`), not NetworkManager's in-memory auto-default,
  # which NetworkManager does not create again at boot while another
  # connection names the device -- after a reset with a `repro-`
  # connection binding the parent on disk, the parent would be left with
  # none once recovery deletes it.
  let persist = nb.om.exec("nmcli connection add type ethernet ifname " &
    nb.parent & " con-name gate-lan ipv4.method auto ipv6.method auto " &
    "connection.autoconnect yes connection.autoconnect-priority 10 && " &
    "nmcli connection up gate-lan && for i in $(seq 1 60); do ip -4 -o addr " &
    "show dev " & nb.parent & " | grep -q " & LanNet & ". && ip -4 route " &
    "show default | grep -q " & HelperLanAddr & " && exit 0; sleep 2; " &
    "done; exit 1", timeoutSec = 240)
  step("test LAN: the parent's connection is a persistent keyfile (gate-lan)",
       persist.exitCode == 0, persist.stdout & persist.stderr)
  step("test LAN: the Omarchy VM holds a DHCP lease and a default route on " &
       nb.parent & " (" & nb.parentMac & "), out-of-band link " & nb.oob,
       leased.exitCode == 0 and nb.parent.len > 0 and nb.oob.len > 0,
       nb.om.exec("ip -br addr; ip route; nmcli -t c show --active").stdout)
  if leased.exitCode != 0:
    raise newException(TestBedError, "the Omarchy VM got no lease on the test LAN")

proc destroy*(nb: NetBed) =
  if nb == nil: return
  if nb.om != nil: nb.om.destroy()
  if nb.helper != nil: nb.helper.destroy()

# ---------------------------------------------------------------------------
# SSH: the multiplexed channel and a fresh session.
# ---------------------------------------------------------------------------

proc sshBase(g: Guest): seq[string] =
  when defined(gostiAvailable):
    @["ssh", "-q", "-o", "StrictHostKeyChecking=no", "-o",
      "UserKnownHostsFile=/dev/null", "-o", "BatchMode=yes", "-o",
      "ConnectTimeout=20", "-o", "ServerAliveInterval=10", "-i", g.keyPath,
      "-p", $g.vm.sshPort]
  else:
    @[]

proc runSsh(argv: seq[string]; timeoutSec: int): ExecOut =
  let cmd = "timeout " & $timeoutSec & " " & quoteShellCommand(argv)
  let (o, c) = execCmdEx(cmd)
  ExecOut(exitCode: c, stdout: o)

proc startMux*(nb: NetBed) =
  ## Open the harness's one SSH connection to the Omarchy VM; every
  ## ``muxExec`` runs through it (no new session, spec §4.5 step 3).
  let argv = sshBase(nb.om) & @["-o", "ControlMaster=yes", "-o",
    "ControlPath=" & nb.mux, "-o", "ControlPersist=3600", "-N", "-f",
    "root@127.0.0.1"]
  let r = runSsh(argv, 60)
  if r.exitCode != 0:
    raise newException(TestBedError, "cannot open the ControlMaster: " & r.stdout)
  nb.muxUp = true
  nb.om.note("ControlMaster open (" & nb.mux & ")")

proc stopMux*(nb: NetBed) =
  if not nb.muxUp: return
  discard runSsh(sshBase(nb.om) & @["-o", "ControlPath=" & nb.mux, "-O",
                                    "exit", "root@127.0.0.1"], 30)
  nb.muxUp = false

proc muxExec*(nb: NetBed; script: string; timeoutSec = 600): ExecOut =
  ## Run ``script`` through the ControlMaster: no new SSH session.
  if not nb.muxUp:
    raise newException(TestBedError, "muxExec without a ControlMaster")
  runSsh(sshBase(nb.om) & @["-o", "ControlMaster=no", "-o",
    "ControlPath=" & nb.mux, "root@127.0.0.1", "sh", "-c",
    quoteShell(script)], timeoutSec)

proc muxRun*(nb: NetBed; script: string; timeoutSec = 600): string =
  let r = nb.muxExec(script, timeoutSec)
  if r.exitCode != 0:
    raise newException(TestBedError, "`" & script & "` exited " &
      $r.exitCode & ": " & r.stdout)
  r.stdout

proc waitNetworkWritten*(nb: NetBed; timeoutSec = 600): bool =
  ## Wait until the pending marker records that the switch has written its
  ## last network object (``guard-written-mono``) -- the moment from which
  ## a new SSH session counts -- or until no armed guard is pending any
  ## more (the apply ended, or the guard left ``armed``). True when the
  ## writes are recorded.
  nb.muxExec("for i in $(seq 1 " & $timeoutSec & "); do " &
    "grep -q '^guard-written-mono\t' " & MarkerPath & " 2>/dev/null && exit 0; " &
    "grep -q '^guard\tarmed' " & MarkerPath & " 2>/dev/null || exit 1; " &
    "sleep 1; done; exit 1", timeoutSec + 30).exitCode == 0

proc freshSsh*(nb: NetBed; script: string; timeoutSec = 120;
               afterWrites = true): ExecOut =
  ## A brand-new key-authenticated SSH connection from the harness (a new
  ## session from 10.0.2.2, not loopback): what disarms the guard. By
  ## default it waits first for the switch's last network write
  ## (``waitNetworkWritten``), so it is evidence when it arrives.
  if afterWrites and nb.muxUp: discard nb.waitNetworkWritten()
  runSsh(sshBase(nb.om) & @["-o", "ControlPath=none", "root@127.0.0.1",
    "sh", "-c", quoteShell(script)], timeoutSec)

proc passwordSsh*(nb: NetBed; password, script: string;
                  timeoutSec = 120): ExecOut =
  ## A brand-new SSH session from the harness authenticated by PASSWORD
  ## (``passwordLogins`` enables it on the guest): a remote sshd session
  ## in logind that writes no "Accepted publickey" line, so a ``confirm``
  ## run in it is the only evidence it can give (spec §4.5 step 3).
  when defined(gostiAvailable):
    let askpass = getTempDir() / ("repro-gate-askpass-" & $getCurrentProcessId())
    writeFile(askpass, "#!/bin/sh\nprintf '%s\\n' " & quoteShell(password) & "\n")
    setFilePermissions(askpass, {fpUserRead, fpUserWrite, fpUserExec})
    defer: removeFile(askpass)
    let argv = @["ssh", "-q", "-o", "StrictHostKeyChecking=no", "-o",
      "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=20", "-o",
      "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no",
      "-o", "ControlPath=none", "-p", $nb.om.vm.sshPort, "root@127.0.0.1",
      "sh", "-c", quoteShell(script)]
    let cmd = "env SSH_ASKPASS=" & quoteShell(askpass) &
      " SSH_ASKPASS_REQUIRE=force DISPLAY=repro-gate timeout " & $timeoutSec &
      " " & quoteShellCommand(argv) & " </dev/null"
    let (o, c) = execCmdEx(cmd)
    ExecOut(exitCode: c, stdout: o)
  else:
    ExecOut(exitCode: 1, stdout: "no gosti")

const
  GatePasswordDropIn = "/etc/ssh/sshd_config.d/00-repro-gate-password.conf"
  GateShadowCopy = "/root/repro-gate-shadow"

proc passwordLogins*(nb: NetBed; password: string; on: bool): ExecOut =
  ## Enable (``on``) or disable password logins for root on the Omarchy
  ## VM for one gate step: a drop-in sorting before every other (sshd takes
  ## an option's first value) and a password, with ``/etc/shadow`` and its
  ## backup ``/etc/shadow-`` (which ``chpasswd`` rewrites) copied first and
  ## put back byte for byte, owner and mode, after.
  if on:
    nb.muxExec("set -e; cp -a /etc/shadow " & GateShadowCopy & "; " &
      "if [ -e /etc/shadow- ]; then cp -a /etc/shadow- " & GateShadowCopy &
      "-; fi; printf 'root:%s\\n' " & quoteShell(password) & " | chpasswd; " &
      "printf 'PasswordAuthentication yes\\nPermitRootLogin yes\\n' > " &
      GatePasswordDropIn & "; systemctl reload sshd.service")
  else:
    nb.muxExec("set -e; rm -f " & GatePasswordDropIn & "; cp -a " &
      GateShadowCopy & " /etc/shadow; if [ -e " & GateShadowCopy & "- ]; " &
      "then cp -a " & GateShadowCopy & "- /etc/shadow-; else rm -f " &
      "/etc/shadow-; fi; rm -f " & GateShadowCopy & " " & GateShadowCopy &
      "-; systemctl reload sshd.service")

# ---------------------------------------------------------------------------
# Profiles.
# ---------------------------------------------------------------------------

proc guardStanza*(account: string; timeout = 120; keep = true; oob = "";
                  setting = ""): string =
  ## The ``addOn`` stanza with a network guard keeping the parent's LAN
  ## prefix and the out-of-band link up.
  result = "addOn {\n  managedEtcPrefixes = [\"" & FixturePrefix & "\"]\n" &
    "  omarchyAccount = \"" & account & "\"\n" &
    (if setting.len > 0: "  rootSnapshot = \"" & setting & "\"\n" else: "") &
    "  networkGuard {\n    timeout = " & $timeout & "\n"
  if keep: result.add("    keep = [\"PARENT " & LanPrefix & "\"]\n")
  if oob.len > 0: result.add("    outOfBand = [\"" & oob & "\"]\n")
  result.add("  }\n}\n\n")

proc linkStanza*(mac: string; name = LinkName; address = LinkAddr;
                 kind = "ipvlan"; extra = ""; dns = true): string =
  "linux.networkLink {\n  name = \"" & name & "\"\n  kind = \"" & kind &
    "\"\n" & (if kind != "dummy": "  parentMac = \"" & mac & "\"\n" else: "") &
    "  addresses = [\"" & address & "\"]\n" &
    (if dns: "  dnsServers = [\"" & HelperLanAddr & "\"]\n" &
             "  dnsDomains = [\"~home.arpa\"]\n" else: "") & extra & "}\n\n"

proc netProfile*(nb: NetBed; account: string; link = true; timeout = 120;
                 address = LinkAddr; extra = ""; setting = ""): string =
  result = guardStanza(account, timeout, oob = nb.oob, setting = setting).replace(
    "PARENT", nb.parent)
  if link: result.add(linkStanza(nb.parentMac, address = address, extra = extra))

# ---------------------------------------------------------------------------
# The apply, detached.
# ---------------------------------------------------------------------------

proc startApply*(nb: NetBed; repro, name, text: string): string =
  ## Start ``repro infra apply --profile`` in a transient unit
  ## (``repro-gate-apply-<name>``), its output in ``/root/<unit>.log``;
  ## returns the unit. The apply runs as root in the host's namespaces, as
  ## an operator's does.
  let p = "/root/addon/" & name & ".profile"
  discard nb.muxRun("mkdir -p /root/addon && cat > " & p & " <<'REPROEOF'\n" &
    text & "REPROEOF")
  let unit = "repro-gate-apply-" & name
  discard nb.muxRun("systemd-run --quiet --collect --unit=" & unit &
    " --property=StandardOutput=file:/root/" & unit & ".log " &
    "--property=StandardError=file:/root/" & unit & ".log --property=Type=exec " &
    repro & " infra apply --profile " & p)
  unit

proc applyRunning*(nb: NetBed; unit: string): bool =
  nb.muxExec("systemctl is-active --quiet " & unit & ".service").exitCode == 0

proc applyLog*(nb: NetBed; unit: string): string =
  nb.muxExec("cat /root/" & unit & ".log 2>/dev/null").stdout

proc waitApplyDone*(nb: NetBed; unit: string; timeoutSec: int): bool =
  let deadline = epochTime() + timeoutSec.float
  while epochTime() < deadline:
    if not nb.applyRunning(unit): return true
    sleep(2000)
  false

proc killApply*(nb: NetBed; unit: string) =
  ## SIGKILL the apply's unit (its whole control group).
  discard nb.muxExec("systemctl kill --signal=SIGKILL " & unit & ".service")

proc markerField*(nb: NetBed; field: string): string =
  nb.muxExec("sed -n 's/^" & field & "\\t//p' " & MarkerPath &
             " 2>/dev/null").stdout.strip()

proc waitMarkerGuard*(nb: NetBed; states: openArray[string];
                      timeoutSec: int): string =
  ## Wait until the marker's guard is one of ``states`` ("" = no marker).
  let deadline = epochTime() + timeoutSec.float
  while epochTime() < deadline:
    let present = nb.muxExec("test -e " & MarkerPath).exitCode == 0
    let g = if present: nb.markerField("guard") else: ""
    if g in states: return g
    sleep(1000)
  "timeout (" & (if nb.muxExec("test -e " & MarkerPath).exitCode == 0:
                   nb.markerField("guard") else: "no marker") & ")"

proc waitArmedOrDone*(nb: NetBed; unit: string; timeoutSec = 900): bool =
  ## Wait until the apply in ``unit`` has armed its guard (true), or has
  ## ended without (false): a refused apply never writes a marker.
  let deadline = epochTime() + timeoutSec.float
  while epochTime() < deadline:
    if nb.muxExec("grep -q '^guard\tarmed' " & MarkerPath).exitCode == 0:
      return true
    if not nb.applyRunning(unit): return false
    sleep(1000)
  false

proc guardUnits*(nb: NetBed): string =
  nb.muxExec("systemctl list-units --all --plain --no-legend " &
             "'repro-addon-guard-*'").stdout.strip()

# ---------------------------------------------------------------------------
# What the network looks like.
# ---------------------------------------------------------------------------

const NetStateScript* = "ip -4 -o addr show | awk '{print $2, $4}' | sort; " &
  "echo --; ip -o link show | awk -F': ' '{print $2}' | sort; echo --; " &
  "ip -4 route show table main | sed 's/ expires [0-9]*sec//' | sort"
  ## Links, IPv4 addresses and the main table's IPv4 routes: what the
  ## network gates compare beside the fingerprint, which has no network
  ## component (spec §12.2).

proc netState*(nb: NetBed): string =
  if nb.muxUp: nb.muxRun(NetStateScript) else: nb.om.run(NetStateScript)

proc parentHolds*(nb: NetBed): bool =
  let s = if nb.muxUp: nb.muxExec("ip -4 -o addr show dev " & nb.parent).stdout
          else: nb.om.exec("ip -4 -o addr show dev " & nb.parent).stdout
  (LanNet & ".") in s

proc lanSshBanner*(nb: NetBed; address: string): bool =
  ## Does ``address`` answer SSH from the test LAN (the helper)?
  nb.helper.exec("timeout 10 bash -c 'exec 3<>/dev/tcp/" & address &
    "/22; head -c 4 <&3' | grep -q SSH-").exitCode == 0

proc guestJournalSince*(nb: NetBed; unit, since: string): string =
  nb.muxExec("journalctl --no-pager -o cat --since '" & since & "' -u " &
             unit).stdout

proc guardRollbacks*(nb: NetBed): seq[string] =
  ## One entry per ``rolled-back`` record of the generations' apply logs
  ## that names ``EAddOnNetworkGuard``, oldest first: the logs in the order
  ## they were last written (an attempt's log is new with its record), each
  ## record's printable text cut at the next record's ``RBSL`` header (the
  ## log is binary; its strings are printable runs).
  let s = nb.muxExec("cat $(ls -tr " & StateDir & "/generations/*/log/apply.log" &
    " 2>/dev/null) 2>/dev/null | tr -c '[:print:]' ' '").stdout
  let parts = s.split("rolled-back")
  for i in 1 ..< parts.len:
    var rec = parts[i]
    let cut = rec.find("RBSL")
    if cut >= 0: rec = rec[0 ..< cut]
    if "EAddOnNetworkGuard" in rec:
      result.add(rec.strip())

proc hideStore*(nb: NetBed) =
  ## Make the store unreadable (spec §13 decision 127): an empty tmpfs over
  ## ``/repro``. Stopping ``repro.mount`` is not enough on a btrfs root,
  ## where ``/repro`` is a nested subvolume still visible under ``/``.
  discard nb.muxExec("mount -t tmpfs -o size=1m,mode=0700 repro-gate-hide /repro")

proc showStore*(nb: NetBed) =
  discard nb.muxExec("umount /repro")

proc makeWt0*(nb: NetBed) =
  ## The out-of-band link's stand-in for the disarm gates: a dummy ``wt0``
  ## (NetBird's name) with an address, made by the harness (not a
  ## connection: NetworkManager leaves an external device alone).
  discard nb.om.run("ip link add wt0 type dummy && ip addr add " &
    "100.64.0.7/16 dev wt0 && ip link set wt0 up")

proc dropWt0*(nb: NetBed) =
  discard nb.om.exec("ip link del wt0 2>/dev/null; true")

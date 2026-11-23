## Gate ``e2e_addon_fetch_unit_reaches_only_its_origins`` (milestone A8;
## spec §9.1, threat model G7, DET-AO-3).
##
## The fetch unit is paused (seam build) after it selected the manifest. A
## shell moved into its control group (the cgroup's ``IPAddressAllow=`` /
## ``IPAddressDeny=`` filter applies to every socket its processes open)
## connects to the manifest origin and the cache origin (both the
## producer's address): both succeed. A connect to any third address --
## the evidence sink (a listener on the test host's own external address,
## which the guest reaches through its NAT) and a public DNS resolver
## (the user network's 10.0.2.3:53 and 1.1.1.1:53) -- fails. The denial is
## the DET-AO-3 signal; the record keeps each connect's result under
## ``detAo3``. Vacuity guard: the evidence-sink connect succeeds from the
## host's own control group.
##
## A name looked up from inside the unit (its mount namespace, its user,
## its control group) does not resolve: the host's resolver services over
## AF_UNIX are hidden from it, and the NSS ``dns`` fallback is denied by the
## IP filter (second falsifying mutation, ``agent-dns-via-resolved``: the
## resolver sockets stay visible and ``getent`` answers).
##
## Falsifying mutation (``REPRO_ADDON_MUTATION=agent-fetch-unrestricted-egress``):
## no ``IPAddressAllow=`` / ``IPAddressDeny=`` pair; the third connect gets
## through: red.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` (seam build).
##
## *Mocking.* None.

import std/[json, osproc, strutils, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed
import ./agent_e2e_support

const Gate = "e2e_addon_fetch_unit_reaches_only_its_origins"

proc connectCmd(host: string; port: int): string =
  "timeout 10 bash -c 'exec 3<>/dev/tcp/" & host & "/" & $port & "'"

proc inFetchGroup(g: Guest; cmd: string): int =
  ## ``cmd`` from a shell that first moved itself into the fetch unit's
  ## control group (its children inherit it, and with it the unit's IP
  ## filter).
  g.exec("echo $$ > /sys/fs/cgroup/system.slice/repro-agent-fetch.service/" &
    "cgroup.procs && " & cmd).exitCode

proc body(g: Guest; repro: string; step: StepFn; record: JsonNode;
          producer: var Producer) =
  # The DNS channel under test is NSS's `resolve` module asking
  # systemd-resolved over AF_UNIX. Debian 13's and Ubuntu 26.04's images
  # route names that way; Debian 12's and Ubuntu 24.04's do not by default,
  # where the check would hold for want of the channel (and the falsifying
  # build would have nothing to open). The fixture gives every base the
  # channel, so the check means the same thing everywhere.
  let channel = g.exec("grep -q '^hosts:.*resolve' /etc/nsswitch.conf || " &
    "{ DEBIAN_FRONTEND=noninteractive apt-get install -y -q libnss-resolve " &
    "systemd-resolved >/dev/null 2>&1 || { apt-get update -q >/dev/null 2>&1 && " &
    "DEBIAN_FRONTEND=noninteractive apt-get install -y -q libnss-resolve " &
    "systemd-resolved >/dev/null; }; }; systemctl enable --now " &
    "systemd-resolved >/dev/null 2>&1; grep '^hosts:' /etc/nsswitch.conf", timeoutSec = 1800)
  step("fixture: names resolve through systemd-resolved's NSS module",
       channel.exitCode == 0 and "resolve" in channel.stdout,
       channel.stdout & channel.stderr)
  # The evidence sink: a listener on every address of the test host, which
  # the guest reaches at the host's external address through its NAT.
  let hostIp = execCmdEx("ip -4 route get 1.1.1.1 | sed -n 's/.* src \\([0-9.]*\\).*/\\1/p'").output.strip()
  let sinkPort = 18089
  let sink = startProcess("python3", args = ["-m", "http.server", "--bind",
    "0.0.0.0", $sinkPort], options = {poUsePath, poStdErrToStdOut})
  defer:
    sink.terminate()
    discard sink.waitForExit(5000)
    sink.close()
  record["evidenceSink"] = %(hostIp & ":" & $sinkPort)
  discard producer.publish(PublishSpec(sequence: 1,
    profileText: canonicalFile("/etc/repro/a8-origins", "x\n")))
  step("vacuity guard: the evidence sink is reachable outside the unit",
       g.exec(connectCmd(hostIp, sinkPort)).exitCode == 0, hostIp)
  g.armFetchSeam("agent-fetch-after-select")
  g.startFetchNoWait()
  let paused = g.waitSeam(FetchSeamDir, "agent-fetch-after-select")
  step("the fetch unit paused after selecting", paused, "")
  if paused:
    let det = newJObject()
    let origin = g.inFetchGroup(connectCmd(HostFromGuest, producer.port))
    det["manifestAndCacheOrigin"] = %origin
    step("the manifest and cache origin is reachable from the fetch unit",
         origin == 0, $origin)
    for (name, host, port) in [("evidenceSink", hostIp, sinkPort),
                               ("userNetDns", "10.0.2.3", 53),
                               ("publicDns", "1.1.1.1", 53)]:
      let c = g.inFetchGroup(connectCmd(host, port))
      det[name] = %c
      step("a connect to the " & name & " (" & host & ":" & $port &
           ") from the fetch unit is denied", c != 0, $c)
    # Name resolution through the host's resolver services (AF_UNIX:
    # systemd-resolved's varlink and D-Bus, nscd), which the IP filter
    # never sees: from the unit's mount namespace, as its user, in its
    # control group, `getent hosts` must fail. Vacuity guard: it succeeds
    # outside the unit.
    let pid = g.run("systemctl show -p MainPID --value repro-agent-fetch.service").strip()
    let uid = g.run("stat -c %u /proc/" & pid).strip()
    let gid = g.run("stat -c %g /proc/" & pid).strip()
    let outside = g.exec("getent hosts example.com")
    step("vacuity guard: the host resolves example.com outside the unit",
         outside.exitCode == 0, outside.stdout & outside.stderr)
    let inside = g.exec("echo $$ > /sys/fs/cgroup/system.slice/" &
      "repro-agent-fetch.service/cgroup.procs && nsenter --target " & pid &
      " --mount --setuid " & uid & " --setgid " & gid &
      " timeout 20 getent hosts example.com")
    det["resolverViaUnixSockets"] = %inside.exitCode
    # The same name as the vacuity guard's: one that resolves outside.
    # (getent exits non-zero when ANY name of several fails, so one name.)
    step("no name resolves from inside the fetch unit (no DNS channel " &
         "through the host's resolver)", inside.exitCode != 0 and
         inside.stdout.strip().len == 0, inside.stdout & inside.stderr)
    record["detAo3"] = det
    g.resumeSeam(FetchSeamDir)
  g.waitApplyIdle()

suite Gate:
  test "the fetch unit reaches only its origins":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      check gateMain(Gate, body).len == 0

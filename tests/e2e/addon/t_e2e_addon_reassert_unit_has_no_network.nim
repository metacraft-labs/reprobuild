## Gate ``e2e_addon_reassert_unit_has_no_network`` (milestone A9; spec §7.7;
## threat model G16).
##
## The boot-time re-assert unit holds the recipient key and needs no
## network, so it runs with ``PrivateNetwork=yes`` (and the apply unit's
## other network bounds). The gate adds, for its own run only, a drop-in
## under ``/run/systemd/system`` with an ``ExecStartPre=`` that tries a TCP
## connect to the cache origin -- the producer the guest's agent fetches
## from -- and records the result; an ``ExecStartPre=`` runs in the unit's
## own namespaces, under its rendered settings. The unit is then started
## again: the connect from inside fails, and the unit still reports.
## Vacuity guard: the same connect from the host's namespace succeeds.
##
## Falsifying mutation (``REPRO_ADDON_MUTATION=reassert-has-network``): the
## re-assert unit is rendered without its network isolation --
## ``PrivateNetwork=yes``, ``IPAddressDeny=any`` and the AF_UNIX/AF_NETLINK
## address-family restriction, each of which alone stops the connect -- and
## the connect from inside succeeds: red.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``.
##
## *Mocking.* None.

import std/[json, strutils, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed
import ./agent_e2e_support

const
  Gate = "e2e_addon_reassert_unit_has_no_network"
  DropIn = "/run/systemd/system/repro-addon-reassert.service.d/90-a9-probe.conf"
  Result = "/run/a9-reassert-connect"

proc connectCmd(host: string; port: int): string =
  "timeout 10 bash -c 'exec 3<>/dev/tcp/" & host & "/" & $port & "'"

proc body(g: Guest; repro: string; step: StepFn; record: JsonNode;
          producer: var Producer) =
  step("vacuity guard: the origin is reachable from the host's namespace",
       g.exec(connectCmd(HostFromGuest, producer.port)).exitCode == 0, "")
  let probe = "[Service]\nExecStartPre=-/bin/bash -c 'if timeout 10 bash -c " &
    "\"exec 3<>/dev/tcp/" & HostFromGuest & "/" & $producer.port &
    "\"; then echo connected > " & Result & "; else echo failed > " & Result &
    "; fi'\n"
  discard g.run("mkdir -p $(dirname " & DropIn & ") && cat > " & DropIn &
    " <<'A9EOF'\n" & probe & "A9EOF\nrm -f " & Result &
    " && systemctl daemon-reload")
  let net = g.exec("systemctl show -p PrivateNetwork --value " &
                   "repro-addon-reassert.service").stdout.strip()
  record["privateNetwork"] = %net
  let r = g.exec("systemctl restart repro-addon-reassert.service")
  step("the re-assert unit runs", r.exitCode == 0, r.stdout & r.stderr)
  let seen = g.exec("cat " & Result).stdout.strip()
  record["connectFromInside"] = %seen
  step("a connect to the cache origin from inside the re-assert unit fails",
       seen == "failed", "probe recorded '" & seen & "'")
  let report = g.exec("cat /var/lib/repro/system/addon/reassert-report").stdout
  record["report"] = %report
  step("the unit still reports", report.strip().len > 0, report)
  discard g.exec("rm -f " & DropIn & " && systemctl daemon-reload")

suite Gate:
  test "the re-assert unit cannot reach the cache origin":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      check gateMain(Gate, body).len == 0

## The confinement gate's probe never ships, and the copies it runs keep
## every confining line of the unit they copy (ReproOS Add-On Mode spec
## §10.1, CONF-4; threat model G55; the owner's decision of 2026-11-18).
##
## - No object generation 0 renders -- with the deploy agent, the egress
##   observer and the evidence units -- names the probe, its directory or
##   the copies' unit names.
## - ``probeUnitCopy`` keeps every ``[Service]`` line of the unit but its
##   command and run control, in order, then the row's lines; the rows
##   apply only where the unit sets their key.
##
## *Mocking.* None: the renderers' own output.

import std/[strutils, unittest]

import repro_addon/generation0

import ../../../tests/e2e/addon/confinement_rows

const Exe = "/repro/store/prefixes/repro-addon/0.2.99-aaaaaaaaaaaaaaaa/bin/repro"

proc allObjects(): seq[OwnObject] =
  generation0Objects(Gen0Inputs(reproExe: Exe,
    agent: AgentUnitsInputs(target: "https://deploy.example/h",
      sources: @["https://deploy.example/m"], allowedAddresses: @["192.0.2.1"]),
    egress: EgressObserverInputs(nft: "/usr/sbin/nft", allowedAddresses: @["192.0.2.1"]),
    evidence: EvidenceUnitsInputs(sinkAddress: "192.0.2.7:7443")))

suite "the confinement probe never ships":
  test "no object generation 0 renders names it":
    let objs = allObjects()
    check objs.len > 10
    for o in objs:
      for needle in ["a9_confinement_probe", "a9probe", ProbePath, ProbeOutDir, "a9p-"]:
        check needle notin o.content
        check needle notin o.path

suite "a copy keeps the unit's confinement":
  let apply = agentApplyUnit(Exe)
  test "every confining line, in order, then the row's lines":
    let c = probeUnitCopy(apply, "mdwe", "/run/x.out", ["MemoryDenyWriteExecute=no"])
    for l in serviceLines(apply):
      let k = l.split('=')[0]
      if k in ["ExecStart", "Type", "Environment", "TimeoutStartSec", "LoadCredential"]:
        continue
      check ("\n" & l & "\n") in c
    check c.endsWith("MemoryDenyWriteExecute=no\n")
    check ("ExecStart=" & ProbePath & " mdwe\n") in c
    check ("ExecStart=" & Exe) notin c
    check "\n[Install]" notin c
  test "a row applies where the unit sets its key, as root where it must":
    for row in ProbeRows:
      if row.name == "memory-deny-write-execute":
        check rowApplies(row, apply, true).ok
        check not rowApplies(row, "[Service]\nMemoryDenyWriteExecute=no\n", true).ok
      if row.name == "protect-system":
        check not rowApplies(row, "[Service]\nProtectSystem=strict\nDynamicUser=yes\n", true).ok
  test "the apply unit runs every row but the amd64-only one off amd64":
    var ran = 0
    for row in ProbeRows:
      if rowApplies(row, apply, true).ok: inc ran
    check ran >= 20
  test "the outcome reader":
    check heldOk(exBlocked, parseOutcome("A9PROBE mdwe -1 1", "success"))
    check removedOk(exBlocked, parseOutcome("A9PROBE mdwe 0 0", "success"))
    check heldOk(exBlocked, parseOutcome("", "signal"))
    check removedOk(exErrnoNumber, parseOutcome("", "signal"))
    check not removedOk(exErrnoNumber, parseOutcome("A9PROBE filter -1 1", "success"))
    check removedOk(exFilter, parseOutcome("A9PROBE filter -1 2", "success"))
    check not heldOk(exFilter, parseOutcome("A9PROBE filter -1 2", "success"))

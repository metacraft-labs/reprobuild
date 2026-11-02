## Gate ``e2e_addon_service_cannot_exec_outside_closure`` (milestone A9;
## spec §10.1; threat model G12, falsifier 9, the compensating control of
## deviation D1).
##
## A fixture service runs under the add-on's ``serviceFloor`` default: a
## static probe (``fixtures/exec_probe/a9_exec_probe.c``) published to the
## test cache as a store prefix, substituted by the deploy agent's fetch
## unit, and run by a ``systemd.systemUnit`` that names no hardening of its
## own. From inside the service the probe reports:
##
## - ``execve("/usr/bin/id")`` fails with ``EACCES``: the distribution's
##   ``/usr`` is outside the unit's closure, and ``NoExecPaths=/`` makes
##   every mount but the closure's ``ExecPaths=`` noexec;
## - ``execve`` of its own binary, in the closure, succeeds;
## - ``mprotect(PROT_EXEC)`` on an anonymous mapping created writable fails
##   (``MemoryDenyWriteExecute=yes``).
##
## Vacuity guard: the same probe run by root in the guest's own shell (no
## floor) executes ``/usr/bin/id`` and gets its ``mprotect``, so the probe
## can see both succeed. The rendered unit is also read back from the
## guest: it carries ``NoExecPaths=/``, ``ExecPaths=<the probe's prefix>``
## and ``MemoryDenyWriteExecute=yes``.
##
## Falsifying mutations (``REPRO_ADDON_MUTATION=``): ``floor-without-noexec``
## renders the floor without ``NoExecPaths=`` / ``ExecPaths=`` and the exec
## of ``/usr/bin/id`` succeeds; ``floor-without-mdwe`` renders it without
## ``MemoryDenyWriteExecute=`` and the ``mprotect`` succeeds. Each is red.
##
## Needs a static C toolchain on the test host: the gate builds the probe
## with this flake's ``pkgsStatic`` gcc (musl), as
## ``scripts/build_addon_static.sh`` builds the add-on.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``.
##
## *Mocking.* None: the real cache daemon, the real units, the guest's own
## systemd applying the floor.

import std/[json, os, osproc, strutils, unittest]

import repro_test_support/reasoned_skip
import repro_profile
import repro_deploy_agent/manifest
import repro_peer_cache/auth as peerAuth

import ./addon_testbed
import ./agent_e2e_support
import ./cache_e2e_support

const
  Gate = "e2e_addon_service_cannot_exec_outside_closure"
  ProbePrefix = "/repro/store/prefixes/a9-exec-probe/1"
  ProbeBin = ProbePrefix & "/bin/a9-exec-probe"
  ProbeUnit = "a9-exec-probe.service"
  EACCES = 13

proc hexKey(k: openArray[byte]): string =
  for b in k: result.add(toHex(int(b), 2).toLowerAscii())

proc staticCc(): string =
  ## This flake's pkgsStatic gcc (musl).
  let (o, c) = execCmdEx("nix build --no-link --print-out-paths " &
    "--inputs-from " & quoteShell(reproRoot()) & " nixpkgs#pkgsStatic.stdenv.cc")
  doAssert c == 0, "building the static toolchain failed: " & o
  for p in o.splitLines():
    for g in walkFiles(p.strip() / "bin" / "*-gcc"):
      return g
  raise newException(TestBedError, "no gcc in the static toolchain: " & o)

proc buildProbe(dest: string) =
  let src = reproRoot() / "tests" / "e2e" / "addon" / "fixtures" /
            "exec_probe" / "a9_exec_probe.c"
  let (o, c) = execCmdEx(quoteShellCommand([staticCc(), "-static", "-O2",
    "-o", dest, src]))
  doAssert c == 0, "compiling the probe failed: " & o

proc probeAction(): ProfileBuildAction =
  ProfileBuildAction(id: "a9-exec-probe", argv: @["/bin/true"],
    cwd: ProbePrefix, outputs: @["bin"], commandStatsId: "a9-exec-probe",
    substituteOnly: true)

proc parseProbe(line: string): tuple[outside, own, prot: int; ok: bool] =
  ## ``a9-probe exec-outside=N exec-own=N mprotect-exec=N``.
  var seen = 0
  for tok in line.splitWhitespace():
    let kv = tok.split('=')
    if kv.len != 2: continue
    case kv[0]
    of "exec-outside": result.outside = parseInt(kv[1]); inc seen
    of "exec-own": result.own = parseInt(kv[1]); inc seen
    of "mprotect-exec": result.prot = parseInt(kv[1]); inc seen
    else: discard
  result.ok = seen == 3

proc probeLine(text: string): string =
  for l in text.splitLines():
    if l.startsWith("a9-probe "): result = l

proc body(g: Guest; repro: string; step: StepFn; record: JsonNode;
          producer: var Producer) =
  let cache = g.startCache()
  defer: cache.stop()
  let anchored = peerAuth.generateKeypair()
  let tree = g.runDir / "probe-tree"
  createDir(tree / "bin")
  buildProbe(tree / "bin" / "a9-exec-probe")
  let a = probeAction()
  let digest = cache.publishTree(anchored, a, tree)
  let bs = g.bootstrapWithAgent(repro, step, cacheUrl = cache.guestUrl,
    cachePublishers = @[hexKey(anchored.publicKey)])
  producer = bs.producer
  if not bs.ok: return
  # The unit names no hardening: the add-on's default puts it under the
  # floor (no User=, so a dynamic user too).
  let profile = unitProfile(ProbeUnit, ProbeBin, health = "active",
                            floorWaiver = false)
  discard producer.publish(PublishSpec(sequence: 1, profileText: profile,
    buildActions: @[a],
    closureDigests: @[ClosureDigest(actionId: a.id, digest: digest)]))
  let t = g.tickUnits()
  step("the probe's generation applies", t.outcome == "aoApplied",
       $t & "\n" & t.fetchLog & t.applyLog)
  let unitText = g.exec("cat /etc/systemd/system/" & ProbeUnit).stdout
  record["renderedUnit"] = %unitText
  if mutation() notin ["floor-without-noexec"]:
    step("the rendered unit confines execution to the closure",
         "NoExecPaths=/\n" in unitText and
         ("ExecPaths=" & ProbePrefix & "\n") in unitText, unitText)
  if mutation() notin ["floor-without-mdwe"]:
    step("the rendered unit denies write-and-execute memory",
         "MemoryDenyWriteExecute=yes\n" in unitText, unitText)
  # The service's report, from its journal.
  discard g.exec("for i in $(seq 1 60); do journalctl -q -o cat -u " &
    ProbeUnit & " | grep -q '^a9-probe ' && break; sleep 1; done", 120)
  let inside = probeLine(g.exec("journalctl -q -o cat -u " & ProbeUnit).stdout)
  record["inside"] = %inside
  let r = parseProbe(inside)
  step("the probe reported from inside the service", r.ok, inside)
  if r.ok:
    step("execve of /usr/bin/id fails with EACCES", r.outside == EACCES,
         inside)
    step("the closure's own binary runs", r.own == 0, inside)
    step("mprotect(PROT_EXEC) of a writable mapping fails", r.prot != 0,
         inside)
  # Vacuity guard: outside the floor the probe can see both succeed.
  let outside = probeLine(g.exec(ProbeBin & " --once").stdout)
  record["vacuityGuard"] = %outside
  let v = parseProbe(outside)
  step("vacuity guard: without the floor the exec and the mprotect succeed",
       v.ok and v.outside == 0 and v.own == 0 and v.prot == 0, outside)

suite Gate:
  test "a service under serviceFloor cannot execute outside its closure":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      check gateMain(Gate, body, bootstrap = false).len == 0

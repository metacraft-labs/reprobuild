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
##   (``MemoryDenyWriteExecute=yes``);
## - a copy of its own binary written into a ``memfd_create`` file and run
##   with ``execveat(fd, "", AT_EMPTY_PATH)`` -- code on no mount, which
##   ``ExecPaths=`` cannot see -- does not run (the floor's filter denies
##   ``memfd_create``; the child is killed).
##
## A9 review round 2 (floor version 3) adds, each from inside the service:
## a copy of the probe written to ``/tmp``, ``/var/tmp``, ``/dev/shm`` and
## the unit's ``RuntimeDirectory=``, ``StateDirectory=``, ``CacheDirectory=``
## and ``LogsDirectory=`` does not run (``EACCES``: the floor's second
## ``NoExecPaths=`` line); code written into a SysV shared-memory segment
## does not run through an ``SHM_EXEC`` attachment (the filter denies the
## SysV shm calls); a write to ``/proc/self/mem`` cannot patch the probe's
## code (``EROFS``: ``ReadOnlyPaths=/proc``); and no mount in its
## namespace is left executable but the closure's.
##
## Vacuity guard: the same probe run by root in the guest's own shell (no
## floor) executes ``/usr/bin/id``, gets its ``mprotect``, runs its copies
## from ``/tmp``, ``/var/tmp`` and ``/dev/shm``, executes from SysV shared
## memory and patches itself through ``/proc/self/mem``, so the probe can
## see every one of them succeed. The rendered unit is also read back from the
## guest: it carries ``NoExecPaths=/``, ``ExecPaths=<the probe's prefix>``
## and ``MemoryDenyWriteExecute=yes``.
##
## Falsifying mutations (``REPRO_ADDON_MUTATION=``): ``floor-private-mounts-exec``
## (no second ``NoExecPaths=``: the copies run), ``floor-allows-sysv-shm``
## (the shm code runs), ``floor-proc-writable`` (the patch runs);
## ``floor-without-noexec``
## renders the floor without ``NoExecPaths=`` / ``ExecPaths=`` and the exec
## of ``/usr/bin/id`` succeeds; ``floor-without-mdwe`` renders it without
## ``MemoryDenyWriteExecute=`` and the ``mprotect`` succeeds;
## ``floor-allows-memfd`` renders it without ``memfd_create`` in the deny
## line and the memfd copy runs. Each is red.
##
## Needs a static C toolchain on the test host: the gate builds the probe
## for the guest's architecture with this flake's static (musl) gcc for it,
## as ``scripts/build_addon_static.sh`` builds the add-on, and publishes it
## under the cache platform that architecture's add-on keys by.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``.
##
## *Mocking.* None: the real cache daemon, the real units, the guest's own
## systemd applying the floor.

import std/[json, os, osproc, strutils, tables, unittest]

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
  EROFS = 30

proc hexKey(k: openArray[byte]): string =
  for b in k: result.add(toHex(int(b), 2).toLowerAscii())

proc buildProbe(dest, debArch: string) =
  ## The probe for the guest's architecture, by the static toolchain the
  ## add-on itself is built with (``addon_testbed.staticCc``).
  let src = reproRoot() / "tests" / "e2e" / "addon" / "fixtures" /
            "exec_probe" / "a9_exec_probe.c"
  let (o, c) = execCmdEx(quoteShellCommand([staticCc(debArch), "-static",
    "-O2", "-o", dest, src]))
  doAssert c == 0, "compiling the probe failed: " & o

proc probeAction(): ProfileBuildAction =
  ProfileBuildAction(id: "a9-exec-probe", argv: @["/bin/true"],
    cwd: ProbePrefix, outputs: @["bin"], commandStatsId: "a9-exec-probe",
    substituteOnly: true)

const ProbeFields = ["exec-outside", "exec-own", "mprotect-exec", "memfd-exec",
  "tmp-exec", "vartmp-exec", "devshm-exec", "run-exec", "state-exec",
  "cache-exec", "logs-exec", "shm-exec", "procmem"]

proc parseProbe(line: string):
    tuple[f: Table[string, int]; mounts: string; ok: bool] =
  ## ``a9-probe <field>=<n> ... exec-mounts=<list>`` (the probe's header).
  for tok in line.splitWhitespace():
    let eq = tok.find('=')
    if eq <= 0: continue
    let k = tok[0 ..< eq]
    if k == "exec-mounts": result.mounts = tok[eq + 1 .. ^1]
    elif k in ProbeFields:
      try: result.f[k] = parseInt(tok[eq + 1 .. ^1])
      except ValueError: discard
  result.ok = result.f.len == ProbeFields.len

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
  buildProbe(tree / "bin" / "a9-exec-probe", g.base.debArch)
  let a = probeAction()
  let digest = cache.publishTree(anchored, a, tree,
                                 guestPlatformFor(g.base.debArch))
  let bs = g.bootstrapWithAgent(repro, step, cacheUrl = cache.guestUrl,
    cachePublishers = @[hexKey(anchored.publicKey)])
  producer = bs.producer
  if not bs.ok: return
  # The unit names no hardening: the add-on's default puts it under the
  # floor (no User=, so a dynamic user too).
  let profile = unitProfile(ProbeUnit, ProbeBin, health = "active",
    extra = "RuntimeDirectory=a9-rt\nStateDirectory=a9-st\n" &
            "CacheDirectory=a9-ca\nLogsDirectory=a9-lg\n", floorWaiver = false)
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
    let f = r.f
    step("execve of /usr/bin/id fails with EACCES",
         f["exec-outside"] == EACCES, inside)
    step("the closure's own binary runs", f["exec-own"] == 0, inside)
    step("mprotect(PROT_EXEC) of a writable mapping fails",
         f["mprotect-exec"] != 0, inside)
    step("a memfd copy of the binary does not run", f["memfd-exec"] != 0,
         inside)
    for k in ["tmp-exec", "vartmp-exec", "devshm-exec", "run-exec",
              "state-exec", "cache-exec", "logs-exec"]:
      step("a copy written to the place " & k & " names does not run " &
           "(EACCES)", f[k] == EACCES, inside)
    step("code in SysV shared memory does not run (shmat SHM_EXEC)",
         f["shm-exec"] != 0, inside)
    step("a write to /proc/self/mem cannot patch the binary (EROFS)",
         f["procmem"] == 1000 + EROFS, inside)
    var execMounts: seq[string]
    for m in r.mounts.split(','):
      if m.len > 0 and m != ProbePrefix: execMounts.add(m)
    step("no mount in the namespace is executable but the closure's",
         execMounts.len == 0, r.mounts)
  # Vacuity guard: outside the floor the probe can see each of them succeed.
  let outside = probeLine(g.exec(ProbeBin & " --once").stdout)
  record["vacuityGuard"] = %outside
  let v = parseProbe(outside)
  var vacuous = v.ok
  if v.ok:
    for k in ["exec-outside", "exec-own", "mprotect-exec", "memfd-exec",
              "tmp-exec", "vartmp-exec", "devshm-exec", "procmem"]:
      if v.f[k] != 0: vacuous = false
    # debian-12's systemd-less root shell has no MDWE either: the SysV
    # shm path succeeds everywhere outside the floor.
    if v.f["shm-exec"] != 0: vacuous = false
  step("vacuity guard: without the floor every one of them succeeds",
       vacuous, outside)

suite Gate:
  test "a service under serviceFloor cannot execute outside its closure":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      check gateMain(Gate, body, bootstrap = false).len == 0

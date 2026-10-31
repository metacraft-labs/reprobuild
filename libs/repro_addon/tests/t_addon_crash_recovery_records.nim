## The records an interrupted switch is recovered from, and the confirm
## step's checks (ReproOS Add-On Mode §7.2, §7.5, §7.7), at the unit level.
##
## Real files under a temporary directory and real loopback sockets. The
## one substitute is in the ``confirm`` tests: a ``ProbeRunner`` closure
## that answers from a counter instead of probing a service. ``confirm``
## takes the runner as a parameter precisely so its timing contract (the
## clock starts at the call, every check must pass once, the last reason
## is reported) can be tested without systemd; the production runner, which
## runs each probe as a transient unit in the host's namespaces, is
## exercised end to end by the VM gate ``e2e_addon_confirm_or_revert``.

import std/[net, os, strutils, times, unittest]

import repro_infra
import repro_addon/[addon_apply, generation0, health, host_exec, ledger, pending_plan,
                    seams, static_tree]

let root = getTempDir() / ("repro-addon-recovery-" & $getCurrentProcessId())
removeDir(root)
createDir(root / "addon")

suite "pending marker (§7.2)":
  test "the A5 fields round-trip":
    let m = PendingMarker(fromGeneration: "g1", planId: "p", newStatic: "/n",
      previousStatic: "/o", step: ssReconcileLinks, status: "in-progress",
      stopped: @["a.service", "b.service"], disabled: @["c.service"],
      attempt: "g2", purpose: "replay")
    let back = parsePendingMarker(m.render())
    check back.attempt == "g2"
    check back.purpose == "replay"
    check back.disabled == @["c.service"]
    check back.stopped == @["a.service", "b.service"]
    check back.step == ssReconcileLinks

  test "an A4 marker (without the A5 fields) still parses":
    let a4 = PendingMarkerHeader & "\nfrom\tg1\nplan\tp\nstatic\t/n\n" &
      "previous-static\t/o\nstep\t3-flip\nstatus\tin-progress\nstopped\t\n" &
      "detail\t\n"
    let m = parsePendingMarker(a4)
    check m.step == ssFlip
    check m.attempt == "" and m.disabled.len == 0

  test "write, read and clear through the no-follow writer":
    writePendingMarker(root, PendingMarker(fromGeneration: "g", step: ssRealise,
                                           status: "in-progress"))
    check hasPendingMarker(root)
    check readPendingMarker(root).fromGeneration == "g"
    clearPendingMarker(root)
    check not hasPendingMarker(root)

suite "write-ahead plan (§7.7)":
  let plan = PendingPlan(targetOwnText: "own\n", targetUserText: "user\twith tab\n",
    fromUserText: "", fromLedgerText: "# ledger\n", reconcileDrift: true,
    adopt: @["fs.systemFile:/etc/x"], activeUnits: @["a.service", "b.service"],
    plans: @[SavedPlan(address: "fs.systemFile:/etc/x", targetPath: "/etc/x",
      replaced: "f 0644 0:0 sha256:ab", newDirs: @["/etc/d1", "/etc/d1/d2"],
      observation: "unowned", observedSha256: "ab", reason: "why\nnot",
      verdict: "adopt", collision: "adopt", preserved: "/p/ab", form: "copy")])

  test "round-trips every field, including tabs and newlines":
    writePendingPlan(root, plan)
    check hasPendingPlan(root)
    let back = readPendingPlan(root)
    check back.targetUserText == plan.targetUserText
    check back.reconcileDrift
    check back.adopt == plan.adopt
    check back.activeUnits == plan.activeUnits
    check back.plans.len == 1
    check back.plans[0].newDirs == @["/etc/d1", "/etc/d1/d2"]
    check back.plans[0].reason == "why\nnot"
    check back.savedPlanFor("fs.systemFile:/etc/x").found
    check not back.savedPlanFor("nope").found

  test "an incomplete plan is refused, never half-read":
    removeFile(pendingPlanDir(root) / "from-ledger")
    expect PendingPlanError:
      discard readPendingPlan(root)
    writePendingPlan(root, plan)
    writeFile(pendingPlanDir(root) / "plan", PendingPlanHeader & "\nplan\tonly-one-field\n")
    expect PendingPlanError:
      discard readPendingPlan(root)

  test "clearing removes the directory":
    writePendingPlan(root, plan)
    clearPendingPlan(root)
    check not dirExists(pendingPlanDir(root))

suite "healthCheck and confirmTimeout in the profile text (§7.5)":
  test "the four kinds parse":
    check parseHealthCheck("active").kind == hcActive
    let t = parseHealthCheck("tcp:127.0.0.1:8080")
    check t.kind == hcTcp and t.port == 8080
    let t6 = parseHealthCheck("tcp:[::1]:22")
    check t6.host == "::1" and t6.port == 22
    let h = parseHealthCheck("http://localhost:8000/alive")
    check h.kind == hcHttp and h.path == "/alive" and h.port == 8000
    check parseHealthCheck("http://127.0.0.1:80").path == "/"
    let e = parseHealthCheck("exec:/repro/store/prefixes/x/bin/check --quick")
    check e.argv == @["/repro/store/prefixes/x/bin/check", "--quick"]

  test "anything off loopback, outside the store or misspelt is refused":
    for bad in ["tcp:10.0.0.1:80", "http://example.org/", "tcp:127.0.0.1:0",
                "tcp:127.0.0.1:x", "exec:/usr/bin/true",
                "exec:/repro/store/../usr/bin/true", "https://127.0.0.1/",
                "Active", "", "http://127.0.0.1:80/a b"]:
      expect ESystemProfileInvalid:
        discard parseHealthCheck(bad)

  test "both fields round-trip through the canonical text":
    let text = "addOn {\n  managedEtcPrefixes = [\"/etc/app/\"]\n" &
      "  confirmTimeout = 45\n}\n\nsystemd.systemUnit {\n" &
      "  name = \"app.service\"\n  content = \"[Service]\nExecStart=/bin/true\n\"\n" &
      "  healthCheck = \"tcp:127.0.0.1:9000\"\n}\n"
    let p = parseSystemProfile(text)
    check p.addOn.confirmTimeoutSec == 45
    check p.resources[0].suHealthCheck == "tcp:127.0.0.1:9000"
    let again = parseSystemProfile(renderProfileText(p))
    check again.addOn.confirmTimeoutSec == 45
    check again.resources[0].suHealthCheck == "tcp:127.0.0.1:9000"

  test "a malformed check or timeout is refused at parse time":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("systemd.systemUnit {\n  name = \"a.service\"\n" &
        "  content = \"[Service]\nExecStart=/bin/true\n\"\n  healthCheck = \"tcp:8.8.8.8:53\"\n}\n")
    expect ESystemProfileInvalid:
      discard parseSystemProfile("addOn {\n  managedEtcPrefixes = []\n  confirmTimeout = 0\n}\n")

suite "probes on real loopback sockets":
  test "tcp: a listener passes, a closed port fails":
    let server = newSocket()
    server.setSockOpt(OptReuseAddr, true)
    server.bindAddr(Port(0), "127.0.0.1")
    server.listen()
    let port = int(server.getLocalAddr()[1])
    check probeTcp("127.0.0.1", port) == ""
    server.close()
    check probeTcp("127.0.0.1", port).len > 0

  test "http: 2xx passes, anything else fails":
    proc serve(arg: tuple[port: int; status: string]) {.thread.} =
      let s = newSocket()
      s.setSockOpt(OptReuseAddr, true)
      s.bindAddr(Port(arg.port), "127.0.0.1")
      s.listen()
      var c: Socket
      s.accept(c)
      var line = ""
      while true:
        c.readLine(line)
        if line == "\r\n" or line.len == 0: break
      c.send("HTTP/1.0 " & arg.status & "\r\nContent-Length: 0\r\n\r\n")
      c.close()
      s.close()
    for (status, ok) in [("200 OK", true), ("503 Service Unavailable", false)]:
      let probe = newSocket()
      probe.bindAddr(Port(0), "127.0.0.1")
      let port = int(probe.getLocalAddr()[1])
      probe.close()
      var th: Thread[tuple[port: int; status: string]]
      createThread(th, serve, (port, status))
      sleep(200)
      let why = probeHttp("127.0.0.1", port, "/alive")
      joinThread(th)
      check (why == "") == ok
      if not ok: check "503" in why

suite "confirm (§7.5)":
  let checks = @[
    UnitHealthCheck(unit: "a.service", raw: "active",
                    spec: HealthCheckSpec(kind: hcActive)),
    UnitHealthCheck(unit: "b.service", raw: "tcp:127.0.0.1:1",
                    spec: HealthCheckSpec(kind: hcTcp, host: "127.0.0.1", port: 1))]

  test "passes as soon as every check has passed once":
    var rounds = 0
    let runner: ProbeRunner = proc(c: UnitHealthCheck; budgetSec: int): string =
      if c.unit == "a.service": inc rounds
      if rounds >= 3: "" else: "not yet"
    let o = confirm(checks, 10, runner, pollMs = 50)
    check o.passed
    check o.failures.len == 0
    check o.waitedSec < 5

  test "fails at the timeout with each check's last reason":
    let runner: ProbeRunner = proc(c: UnitHealthCheck; budgetSec: int): string =
      if c.unit == "a.service": "" else: "connection refused"
    let start = epochTime()
    let o = confirm(checks, 1, runner, pollMs = 100)
    let took = epochTime() - start
    check not o.passed
    check o.failures == @["b.service tcp:127.0.0.1:1: connection refused"]
    check took >= 1.0 and took < 3.0

  test "a probe gets the remaining budget and a hung one cannot extend the wait":
    var budgets: seq[int]
    let runner: ProbeRunner = proc(c: UnitHealthCheck; budgetSec: int): string =
      budgets.add(budgetSec)
      sleep(budgetSec * 1000)       # a check that hangs for all it is given
      "hung"
    let start = epochTime()
    let o = confirm(checks[0 .. 0], 2, runner, pollMs = 50)
    check not o.passed
    check epochTime() - start < 3.5
    check budgets.len >= 1 and budgets[0] <= 2

  test "the bounded host-tool runner kills at the deadline":
    let start = epochTime()
    let r = runHostTool(["/bin/sh", "-c", "while :; do :; done"], timeoutSec = 1)
    check r.exitCode == 124
    check epochTime() - start < 5

  test "the bounded runner drains output larger than a pipe and keeps a bounded part":
    # A probe that prints far more than the 64 KiB a pipe holds must not
    # block on its write until the deadline kills it.
    let start = epochTime()
    let r = runHostTool(["/bin/sh", "-c",
      # Shell builtins only (the fixed tool environment's PATH need not
      # carry coreutils): 20000 lines of 50 bytes, about 1 MB.
      "i=0; while [ $i -lt 20000 ]; do " &
      "echo xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx; " &
      "i=$((i+1)); done"],
      timeoutSec = 20)
    check r.exitCode == 0
    check r.output.len == BoundedOutputBytes
    check epochTime() - start < 10

  test "no checks: confirmed at once":
    let runner: ProbeRunner = proc(c: UnitHealthCheck; budgetSec: int): string = "never"
    check confirm(@[], 60, runner).passed

suite "the commit point (§7.2 step 9)":
  test "current moves by one rename and leaves no temporary link":
    let sd = root / "state"
    createDir(sd / "generations" / "g1")
    createDir(sd / "generations" / "g2")
    writeCurrentGenerationId(sd, "g1")
    check readCurrentGenerationId(sd) == "g1"
    var points: seq[string]
    writeCurrentGenerationId(sd, "g2", onPoint = proc(p: string) = points.add(p))
    check readCurrentGenerationId(sd) == "g2"
    check points.len == 0          # the product build has no window to name
    for kind, path in walkDir(sd):
      check "tmp" notin extractFilename(path)

  test "the apply lock records the boot it was taken in":
    let rec = ApplyLockRecord(pid: 42, acquiredAt: 1, heartbeatAt: 1,
                              bootId: currentBootId())
    check currentBootId().len > 0
    check parseApplyLockRecord(renderApplyLockRecord(rec)).bootId == currentBootId()
    check parseApplyLockRecord("pid=42\nacquired=1\n").bootId == ""

suite "a failed replay reverts unless no revert is possible (§7.2)":
  test "a failed revert, a first switch and a moved current keep the marker":
    let sd = root / "replay-fail"
    createDir(sd / "addon")
    # A revert that failed is not reverted again.
    let rv = revertAfterFailedReplay(sd, PendingMarker(purpose: "revert",
      fromGeneration: "g1", step: ssPreStop), "boom")
    check not rv.reverted and "revert" in rv.why
    # Bootstrap's first switch has nothing to go back to.
    let first = revertAfterFailedReplay(sd, PendingMarker(purpose: "apply",
      step: ssPreStop), "boom")
    check not first.reverted and "bootstrap" in first.why
    # `current` names neither: never guessed.
    let moved = revertAfterFailedReplay(sd, PendingMarker(purpose: "apply",
      fromGeneration: "g1", step: ssPreStop), "boom")
    check not moved.reverted and "current" in moved.why

suite "boot ordering of the add-on's own units (§7.7, §10.3)":
  test "the secrets unit is off the recovery's path and bounded":
    let objs = generation0Objects(Gen0Inputs(
      reproExe: "/repro/store/prefixes/x/1/bin/repro"))
    var secrets, reassert = ""
    for o in objs:
      if o.unit == SecretsUnit: secrets = o.content
      if o.unit == ReassertUnit: reassert = o.content
    check secrets.len > 0 and reassert.len > 0
    # Default dependencies: it mounts the ramfs through systemd-run, which
    # needs the system bus (after basic.target).
    check "DefaultDependencies=no" notin secrets
    check ReassertUnit notin secrets.split("Before=")[0]
    check "TimeoutStartSec=" & $SecretsUnitTimeoutSec & "s" in secrets
    check "Before=" & ReassertUnit in secrets
    check "After=local-fs.target repro-store.mount " & SecretsUnit in reassert
    # Two capped confirms fit in the re-assert unit's timeout.
    check 2 * BootConfirmCapSec < ReassertTimeoutMin * 60

suite "test seams":
  test "a product build has no pause point":
    check not AddonTestSeams
    writeFile(root / "addon" / "test-pause-at", "step-1\n")
    seamPause(root, "step-1")     # returns at once: no seam is compiled in
    check fileExists(root / "addon" / "test-pause-at")

removeDir(root)

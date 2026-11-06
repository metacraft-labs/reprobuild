## Gate ``e2e_addon_confirm_or_revert`` (milestone A5; spec §7.5, §7.2
## step 8).
##
## Generation A runs a fixture HTTP service whose ``healthCheck`` passes.
## Then:
##
## 1. *positive control*: generation A' changes the service (a new page)
##    and keeps a passing check; it is committed;
## 2. back to A;
## 3. generation B changes the service so its check fails (the check
##    probes a port nothing listens on) with ``confirmTimeout = 20``. The
##    apply must fail reporting ``rolled back``, within confirmTimeout plus
##    the transition time (see *The time bound* below); afterwards
##    ``current`` is a generation with A's content, A's service is active
##    serving A's page, the host's fingerprint equals A's, and the
##    attempt's apply log records ``rolled-back``;
## 3b. *a check that hangs*: generation H checks with a command in the store
##    that never returns (the seam build's ``repro system addon
##    test-sleep``); confirmTimeout must still bound the wait -- the probe is
##    killed at the deadline -- and the switch must be rolled back within
##    the same bound as B;
## 4. *operator rollback* (``repro system rollback``, the milestone's second
##    deliverable): A' is applied again, then ``repro system rollback`` with
##    no argument returns the host to A (A's page, A's fingerprint), and
##    ``repro system rollback <A' generation>`` brings A' back.
##
## The probes are the production ones: ``repro system addon probe`` run as
## a transient unit in the host's namespaces.
##
## *The time bound.* A failed switch's time is the transition into the
## new generation, the confirm wait, and the transition back. Spec §7.5
## bounds only the middle part: the wait starts when step 7 ends and runs
## out at ``confirmTimeout``, the last probe being killed at the deadline
## (at most ``ConfirmOvershootSec`` later). The transitions are the
## switch itself, writes, fsyncs and unit starts, and take as long as the
## host's I/O takes; nothing bounds them except that they are the same
## switch the host just ran. So the gate does not compare the whole apply
## with a transition time sampled earlier -- a host I/O stall during one
## later transition made that comparison red on correct runs (a single
## sample cannot predict the next transition) -- but splits the attempt's
## own time:
##
## - the confirm wait, as the attempt's ``rolled-back`` record states it,
##   measured by the apply's own clock in the guest, must be at least
##   ``confirmTimeout`` (a failing check is not given up early) and at most
##   ``confirmTimeout + ConfirmOvershootSec`` plus one second of scheduling
##   tolerance;
## - that wait must lie inside the apply's window as the guest's clock
##   measures it around the command (so the record cannot claim a wait
##   the apply did not spend), and what remains of the window is the
##   transition time of that same apply, which is recorded.
##
## The falsifying build ``confirm-overruns-deadline`` keeps probing for
## twice ``confirmTimeout``; the gate must go red under it.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``; the seam build (for 3b's hanging
## command; ``scripts/run_addon_gate.sh`` selects it).
##
## *Mocking.* None.

import std/[base64, json, os, strutils, times, unittest]

import repro_test_support/reasoned_skip

import repro_addon/health
import repro_infra/audit_log

import ./addon_testbed

const
  Port = 18080
  ConfirmTimeout = 20
  SchedulingToleranceSeconds = 1.0
    ## Beyond the spec's overshoot: the guest's timers firing late on a
    ## loaded host. Far below what any deadline overrun adds.

proc service(page: string): string =
  # python3 ships in every base of the matrix; the page is the generation.
  # Under the add-on's hardening floor (only its exec confinement waived,
  # for the base's python3): a dynamic user, a read-only system, a runtime
  # directory for its page.
  "[Unit]\nDescription=confirm fixture\n[Service]\n" &
    "RuntimeDirectory=repro-fixture-web\n" &
    "ExecStartPre=/bin/sh -c 'echo " & page &
    " > /run/repro-fixture-web/index.html'\n" &
    "ExecStart=/usr/bin/python3 -m http.server " & $Port &
    " --bind 127.0.0.1 --directory /run/repro-fixture-web\n\n" &
    "[Install]\nWantedBy=multi-user.target\n"

proc profile(page, check: string; timeout = 0): string =
  "addOn {\n  managedEtcPrefixes = [\"/etc/repro-fixture/\"]\n" &
    (if timeout > 0: "  confirmTimeout = " & $timeout & "\n" else: "") & "}\n\n" &
    "systemd.systemUnit {\n  floorExceptions = [\"NoExecPaths: serves " &
    "with the base's own python3\"]\n  name = \"repro-fixture-web.service\"\n" &
    "  content = \"" & service(page) & "\"\n  healthCheck = \"" & check &
    "\"\n}\n\n" &
    "fs.systemFile {\n  path = \"/etc/repro-fixture/page.conf\"\n" &
    "  content = \"" & page & "\n\"\n}\n"

proc served(g: Guest): string =
  g.exec("for i in 1 2 3 4 5 6 7 8 9 10; do curl -sf http://127.0.0.1:" & $Port &
         "/ && exit 0; sleep 1; done; exit 1").stdout.strip()

type TimedApply = object
  r: ExecOut
  guestSeconds: float     ## the apply's duration by the guest's clock
  hostSeconds: float      ## the same, seen from the harness (with SSH)

proc timedApply(g: Guest; repro, name, text: string): TimedApply =
  ## ``repro infra apply`` with the guest's own clock read right before and
  ## after it, in the same shell: the window holds the apply and nothing of
  ## the harness (SSH, polling) around it.
  let p = g.putProfile(name, text)
  let t0 = epochTime()
  result.r = g.exec("s=$(date +%s.%N); " & repro & " infra apply --profile " &
    p & "; rc=$?; e=$(date +%s.%N); echo \"@@guest-window $s $e\" >&2; " &
    "exit $rc", timeoutSec = 1200)
  result.hostSeconds = epochTime() - t0
  result.guestSeconds = -1
  for line in result.r.stderr.splitLines():
    if line.startsWith("@@guest-window "):
      let f = line.splitWhitespace()
      try: result.guestSeconds = parseFloat(f[2]) - parseFloat(f[1])
      except ValueError: discard

proc generations(g: Guest): seq[string] =
  g.exec("ls /var/lib/repro/system/generations").stdout.splitWhitespace()

proc recordedWait(g: Guest; before: seq[string]): (string, float) =
  ## The confirm wait the attempt's ``rolled-back`` record states (the
  ## apply's own measurement, spec §7.5). The attempt is the one
  ## generation that appeared and that ``current`` does not name; its apply
  ## log is copied out (base64 over the exec channel) and decoded with the
  ## product's own reader. Returns -1 when no such record exists.
  let cur = g.run("readlink /var/lib/repro/system/current").strip().extractFilename
  var attempt = ""
  for x in g.generations():
    if x notin before and x != cur: attempt = x
  if attempt.len == 0: return ("no new uncommitted generation", -1.0)
  let b64 = g.exec("base64 -w0 /var/lib/repro/system/generations/" & attempt &
                   "/log/apply.log")
  if b64.exitCode != 0:
    return (attempt & ": no apply log: " & b64.stderr, -1.0)
  let local = g.runDir / ("apply-log-" & attempt)
  writeFile(local, decode(b64.stdout.strip()))
  for rec in readAuditLog(local).records:
    if rec.outcome != "rolled-back": continue
    let i = rec.diagnostic.find("; waited ")
    if i < 0: continue
    let tail = rec.diagnostic[i + "; waited ".len .. ^1]
    let j = tail.find(" s)")
    if j > 0:
      try: return (attempt, parseFloat(tail[0 ..< j]))
      except ValueError: discard
  (attempt & ": no rolled-back record stating its wait", -1.0)

proc checkWait(step: proc(name: string; ok: bool; detail: string);
               what: string; t: TimedApply; attempt: string; waited: float;
               record: JsonNode; key: string) =
  ## The time bound of the header's *The time bound*.
  let upper = ConfirmTimeout.float + ConfirmOvershootSec.float +
              SchedulingToleranceSeconds
  let transitions = t.guestSeconds - waited
  record[key] = %*{"attempt": attempt, "confirmWaitSeconds": waited,
    "guestApplySeconds": t.guestSeconds, "hostApplySeconds": t.hostSeconds,
    "transitionSeconds": transitions}
  let detail = "confirm waited " & $waited & " s (bound [" & $ConfirmTimeout &
    ", " & $upper & "]); the apply took " & $t.guestSeconds &
    " s by the guest's clock (" & $t.hostSeconds & " s from the harness), " &
    $transitions & " s of it the transitions there and back"
  step(what & ": the rolled-back record states the confirm wait",
       waited >= 0, attempt)
  step(what & ": the confirm wait is bounded by confirmTimeout (the " &
       "transitions are not: reverted within confirmTimeout plus the " &
       "transition time)",
       waited >= ConfirmTimeout.float and waited <= upper, detail)
  step(what & ": the confirm wait lies inside the apply's own window",
       t.guestSeconds > 0 and waited <= t.guestSeconds, detail)

proc runBase(b: BaseImage; record: JsonNode): seq[string] =
  var g: Guest
  let steps = newJArray()
  var fails: seq[string]
  proc step(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok: fails.add(b.name & ": " & name & ": " & detail)
  try:
    g = newGuest(b)
    g.boot()
    g.prepareBase()
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    if not g.bootstrapAddon(repro, step): return fails
    let good = "http://127.0.0.1:" & $Port & "/"
    var r = g.applyProfile(repro, "a", profile("page-A", good))
    step("generation A (passing check) committed", r.exitCode == 0,
         r.stdout & r.stderr)
    step("A serves its page", g.served() == "page-A", "")
    # 1. Positive control. Its duration is recorded for comparison only;
    # no bound is derived from it.
    let ta2 = g.timedApply(repro, "a2", profile("page-A2", good))
    r = ta2.r
    record["controlApplySeconds"] = %ta2.guestSeconds
    step("positive control: A' with a passing check is committed",
         r.exitCode == 0 and "rolled back" notin r.stdout & r.stderr,
         r.stdout & r.stderr)
    step("positive control: A' serves its page", g.served() == "page-A2", "")
    # 2. Back to A, and its fingerprint.
    r = g.applyProfile(repro, "a", profile("page-A", good))
    step("back to A", r.exitCode == 0, r.stdout & r.stderr)
    let currentA = g.run("readlink /var/lib/repro/system/current").strip()
    let fpA = g.takeFingerprint(repro)
    # 3. B: the check probes a port nothing listens on.
    let bad = "tcp:127.0.0.1:" & $(Port + 1)
    var before = g.generations()
    let tb = g.timedApply(repro, "b", profile("page-B", bad, ConfirmTimeout))
    r = tb.r
    step("B is refused and rolled back", r.exitCode != 0 and
         "rolled back" in r.stdout & r.stderr, r.stdout & r.stderr)
    let (attemptB, waitB) = g.recordedWait(before)
    checkWait(step, "B", tb, attemptB, waitB, record, "revert")
    step("A's service is active again and serves A's page",
         g.exec("systemctl is-active repro-fixture-web.service").stdout.strip() ==
           "active" and g.served() == "page-A", g.served())
    let fp = g.takeFingerprint(repro)
    let same = identityReport(fpA, fp)
    step("the host's fingerprint equals A's", same.ok, same.text)
    let currentNow = g.run("readlink /var/lib/repro/system/current").strip()
    step("current moved to a new generation with A's content",
         currentNow != currentA and g.run("cat /etc/repro-fixture/page.conf") ==
           "page-A\n", currentA & " -> " & currentNow)
    let logged = g.exec("grep -la 'rolled-back' " &
      "/var/lib/repro/system/generations/*/log/apply.log").stdout.strip()
    step("the attempt's generation log records rolled-back", logged.len > 0 and
         currentNow notin logged, logged)
    step("no pending marker is left",
         g.exec("test ! -e /var/lib/repro/system/addon/pending").exitCode == 0, "")
    # 3b. A check that hangs is bounded by confirmTimeout.
    let storeRepro = g.run("ls /repro/store/prefixes/repro-addon/*/bin/repro " &
                           "| head -1").strip()
    let hang = "exec:" & storeRepro & " system addon test-sleep 100000"
    before = g.generations()
    let th = g.timedApply(repro, "h", profile("page-H", hang, ConfirmTimeout))
    r = th.r
    step("a hanging check: the switch is rolled back", r.exitCode != 0 and
         "rolled back" in r.stdout & r.stderr, r.stdout & r.stderr)
    let (attemptH, waitH) = g.recordedWait(before)
    checkWait(step, "a hanging check", th, attemptH, waitH, record,
              "hangRevert")
    step("a hanging check: A's page is served again", g.served() == "page-A", "")
    step("a hanging check: the hung command was killed",
         # `[a]ddon`: the pattern must not match the shell running pgrep.
         g.exec("pgrep -f '[a]ddon test-sleep'").exitCode != 0,
         g.exec("pgrep -af '[a]ddon test-sleep'").stdout)
    # 4. Operator rollback through the switch.
    r = g.applyProfile(repro, "a2", profile("page-A2", good))
    step("rollback: A' applied again", r.exitCode == 0, r.stdout & r.stderr)
    let genA2 = g.run("readlink /var/lib/repro/system/current").strip()
    let rb = g.exec(repro & " system rollback", timeoutSec = 1200)
    step("rollback: `repro system rollback` succeeded", rb.exitCode == 0,
         rb.stdout & rb.stderr)
    step("rollback: A's page is served again", g.served() == "page-A", "")
    let fpRb = g.takeFingerprint(repro)
    let sameRb = identityReport(fpA, fpRb)
    step("rollback: the host's fingerprint equals A's", sameRb.ok, sameRb.text)
    let rb2 = g.exec(repro & " system rollback " & extractFilename(genA2),
                     timeoutSec = 1200)
    step("rollback: to a named generation (A')", rb2.exitCode == 0 and
         g.served() == "page-A2", rb2.stdout & rb2.stderr)
    let un = g.exec(repro & " system addon uninstall")
    step("uninstall", un.exitCode == 0, un.stdout & un.stderr)
  except CatchableError as e:
    fails.add(b.name & ": " & e.msg)
    steps.add(%*{"step": "exception", "ok": false, "detail": e.msg})
  finally:
    record["steps"] = steps
    if g != nil:
      record["guest"] = %g.name
      record["log"] = %g.log
      g.destroy()
  fails

suite "e2e_addon_confirm_or_revert":
  test "a generation whose health check fails is reverted within confirmTimeout":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just e2e_addon_confirm_or_revert)")
    else:
      var failures: seq[string]
      for b in selectedBases():
        let record = %*{"gate": "e2e_addon_confirm_or_revert",
          "base": b.name, "arch": b.debArch,
          "backend": (if useIncus(): "incus" else: "qemu"),
          "mutation": mutation(), "reprobuild": gitHead(),
          "started": $now().utc}
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord("e2e_addon_confirm_or_revert", record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0

## Gate ``e2e_addon_confirm_or_revert`` (milestone A5; spec §7.5, §7.2
## step 8).
##
## Generation A runs a fixture HTTP service whose ``healthCheck`` passes.
## Then:
##
## 1. *positive control*: generation A' changes the service (a new page)
##    and keeps a passing check; it is committed, and its duration is the
##    host's transition time T for this service;
## 2. back to A;
## 3. generation B changes the service so its check fails (the check
##    probes a port nothing listens on) with ``confirmTimeout = 20``. The
##    apply must fail reporting ``rolled back``, within confirmTimeout plus
##    two transitions (there and back) plus a fixed slack; afterwards
##    ``current`` is a generation with A's content, A's service is active
##    serving A's page, the host's fingerprint equals A's, and the
##    attempt's apply log records ``rolled-back``;
## 4. *operator rollback* (``repro system rollback``, the milestone's second
##    deliverable): A' is applied again, then ``repro system rollback`` with
##    no argument returns the host to A (A's page, A's fingerprint), and
##    ``repro system rollback <A' generation>`` brings A' back.
##
## The probes are the production ones: ``repro system addon probe`` run as
## a transient unit in the host's namespaces.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``.
##
## *Mocking.* None.

import std/[json, os, strutils, times, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed

const
  Port = 18080
  ConfirmTimeout = 20
  SlackSeconds = 15.0

proc service(page: string): string =
  # python3 ships in every base of the matrix; the page is the generation.
  "[Unit]\nDescription=confirm fixture\n[Service]\n" &
    "ExecStartPre=/bin/sh -c 'mkdir -p /run/repro-fixture-www && " &
    "echo " & page & " > /run/repro-fixture-www/index.html'\n" &
    "ExecStart=/usr/bin/python3 -m http.server " & $Port &
    " --bind 127.0.0.1 --directory /run/repro-fixture-www\n\n" &
    "[Install]\nWantedBy=multi-user.target\n"

proc profile(page, check: string; timeout = 0): string =
  "addOn {\n  managedEtcPrefixes = [\"/etc/repro-fixture/\"]\n" &
    (if timeout > 0: "  confirmTimeout = " & $timeout & "\n" else: "") & "}\n\n" &
    "systemd.systemUnit {\n  name = \"repro-fixture-web.service\"\n" &
    "  content = \"" & service(page) & "\"\n  healthCheck = \"" & check &
    "\"\n}\n\n" &
    "fs.systemFile {\n  path = \"/etc/repro-fixture/page.conf\"\n" &
    "  content = \"" & page & "\n\"\n}\n"

proc served(g: Guest): string =
  g.exec("for i in 1 2 3 4 5 6 7 8 9 10; do curl -sf http://127.0.0.1:" & $Port &
         "/ && exit 0; sleep 1; done; exit 1").stdout.strip()

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
    # 1. Positive control, and the transition time.
    var t0 = epochTime()
    r = g.applyProfile(repro, "a2", profile("page-A2", good))
    let transition = epochTime() - t0
    record["transitionSeconds"] = %transition
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
    t0 = epochTime()
    r = g.applyProfile(repro, "b", profile("page-B", bad, ConfirmTimeout))
    let took = epochTime() - t0
    record["revertSeconds"] = %took
    step("B is refused and rolled back", r.exitCode != 0 and
         "rolled back" in r.stdout & r.stderr, r.stdout & r.stderr)
    let bound = ConfirmTimeout.float + 2.0 * transition + SlackSeconds
    step("reverted within confirmTimeout plus the transition time",
         took <= bound, $took & " s, bound " & $bound & " s (confirmTimeout " &
         $ConfirmTimeout & " + 2 x " & $transition & " + " & $SlackSeconds & ")")
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

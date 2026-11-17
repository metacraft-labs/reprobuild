## Attack-shaped adversarial test for reprobuild-pm issue
## ``issues/2026-11-12-base-anchored-trust-does-not-anchor-what-a-required-name-means.md``
## (Test-Certificates.md §"What a required name means: its command set").
##
## The hostile actor is a commit that REDEFINES what a required name runs and
## then re-certifies it. ``unit-suite`` is required on ``main`` under
## ``gate_mode = "required"`` and ``ci_trust = "skip"``; the candidate's own
## ``repro.nim`` decides what ``unit-suite`` means, so before the fix a
## candidate could drop a member of the aggregate (or change a member's
## command), run the real ``repro test``, and:
##
##   (a) push through the gateway: the ratchet saw the name still required and
##       still covered, and ACCEPTED it;
##   (b) be planned by ``repro ci plan`` against the base: the name was
##       covered by a valid certificate under the base's ``skip``, so CI
##       SKIPPED it and never ran the removed test.
##
## The flow is the real one end to end. ``app`` (a real manifest workspace,
## ``certify_workspace_mode_fixture``) declares three edges through a typed
## tool and ``certificate "unit-suite", aggregate("unit-suite", @[unit_a,
## unit_b])``, and enacts its own policy (``policy/app_policy.nim``). The base
## lock is written by the real ``repro lock refresh``; every candidate is
## certified by the real ``repro test`` (its lock-update node rewrites the
## snapshot from the graph it evaluated); the pushes go through a real gateway
## bare whose installed hooks drive the built ``repro``; the plans are the
## built ``repro ci plan``. Then:
##
##   1. DROP: the candidate's aggregate drops ``unit_b``. The gateway REFUSES
##      it, naming ``unit-suite``, ``narrowed`` and the omitted base entry
##      ``unit_b=blake3:…``; ``ci plan --base=<base>`` puts ``unit-suite`` in
##      ``run`` (not ``skip``) and lists it under ``narrowed`` with that entry.
##   2. CHANGE: the candidate keeps both members but changes ``unit_b``'s
##      ``--output`` argument. Same verdicts: the base's ``unit_b`` entry is
##      omitted (its digest no longer matches).
##   3. SUPERSET (positive control): the candidate ADDS ``unit_c``. The gateway
##      accepts it and ``ci plan`` skips ``unit-suite`` (nothing is
##      ``narrowed``): adding a test never weakens the name.
##   4. LEGACY ANCHOR (positive control): a base whose snapshot records no
##      command set (its ``[[certificate_policy.certificate]]`` table removed,
##      as a writer predating the section wrote it), published as ``legacy``.
##      The same DROP, certified on top of it and pushed there, is judged by
##      name alone and ACCEPTED,
##      with a note saying the anchor records no command set; ``ci plan``
##      against that base RUNS ``unit-suite`` and lists it under
##      ``unanchored``.
##   5. DROP BOTH: on top of the superset (now the anchor), a commit that
##      stops requiring ``unit-suite`` AND removes its ``certificate``
##      marking in the same push records no meaning for the name: the gateway
##      REFUSES it as narrowed, naming the anchor's entries.
##   6. RELAX (positive control): the same anchor; push 1 stops requiring
##      ``unit-suite`` and leaves its node unchanged, so its snapshot still
##      records the name's command set (every marked name is recorded): it
##      lands. Push 2, judged by push 1, narrows the name and lands too.
##
## The snapshot itself is asserted too: the refreshed base lock records a
## ``[[certificate_policy.certificate]]`` table for ``unit-suite`` with two
## entries, and the DROP candidate's lock (written by the certifying run's
## node) records one.
##
## Falsifiability: compare names only at the gateway → 1 and 2 are accepted
## and 5 is refused without naming the narrowing; record command sets only
## for required names → 6's first push is refused (the relaxation wedges);
## skip on a valid certificate without comparing command sets → 1 and 2 are
## skipped; treat a legacy anchor as narrowed → 4 is refused (wedging the
## branch); digest the executed argv or compare sets for equality → 3 is
## narrowed.
##
## NO MOCKS: real repositories and manifest, the built ``repro`` (lock
## refresh, ``repro test``, the gateway hooks, ``ci plan``), the real provider,
## engine and monitor, real git. The certificates are those ``repro test``
## issued into the scratch store; the only hand step is putting each one in
## the clone's notes ref (``seedCertificateNote``, the reference library's
## framing), because the pushes use ``--no-verify`` so that only the
## receiving side decides — exactly what the managed pre-push hook would
## carry. Skip rule: ``git`` or ``ssh-keygen`` missing.
##
## This file deliberately uses no API the fix introduced (it reads the
## snapshot as text), so the same source compiles against the unfixed tree
## and shows the attack succeeding there.

import std/[json, os, osproc, strutils, unittest]
import repro_test_support/reasoned_skip
import repro_test_support
import repro_cli_support

import ./certify_workspace_mode_fixture
import ./certificate_note_seed

const memberLine = "aggregate(\"unit-suite\", @[unit_a, unit_b])"

const buildLines =
  "    certificate \"unit-suite\", " & memberLine & "\n"

proc appPolicy(requireUnitSuite = true): string =
  ## ``unit-suite`` required on every branch under ``required``, or (for the
  ## relaxing push) the same rule requiring nothing.
  "import repro_certificates\n\n" &
    "const appPolicy* = certificatePolicy \"app\":\n" &
    "  ciTrust skip\n" &
    "  rule \"**\", detachedHead:\n" &
    "    gateMode required\n" &
    (if requireUnitSuite:
       "    requires \"unit-suite\", platforms = [\"" & currentPlatformTag() &
         "\"]\n"
     else: "")

proc git(fx: WorkspaceCertifyFixture; args: varargs[string]):
    tuple[code: int; output: string] =
  var argv = @[fx.cf.sib.gitBin, "-C", fx.app]
  for a in args: argv.add(a)
  let res = runShell(shellCommand(argv,
    @[(name: "REPROBUILD_REPRO", value: fx.cf.sib.repro)]), fx.app)
  (res.code, res.output)

proc mustGit(fx: WorkspaceCertifyFixture; args: varargs[string]): string =
  var argv: seq[string]
  for a in args: argv.add(a)
  let res = fx.git(argv)
  doAssert res.code == 0, "git " & argv.join(" ") & ":\n" & res.output
  res.output.strip()

proc snapshotText(lock: string): string =
  ## The lines of ``lock`` from ``[certificate_policy]`` on.
  let at = lock.find("[certificate_policy]")
  if at < 0: "" else: lock[at .. ^1]

proc commandEntries(lock: string; name = "unit-suite"): seq[string] =
  ## The ``commands`` entries of the command-set table for ``name``, read as
  ## text so this test needs nothing the fix added.
  var inTable, named = false
  for raw in snapshotText(lock).splitLines():
    let line = raw.strip()
    if line.startsWith("["):
      inTable = line == "[[certificate_policy.certificate]]"
      named = false
      continue
    if inTable and line == "name = \"" & name & "\"":
      named = true
    if inTable and named and line.startsWith("commands"):
      let open = line.find('[')
      let close = line.rfind(']')
      if open >= 0 and close > open:
        for item in line[open + 1 ..< close].split(','):
          let entry = item.strip().strip(chars = {'"'})
          if entry.len > 0: result.add(entry)

proc withoutCommandSets(lock: string): string =
  ## ``lock`` with every ``[[certificate_policy.certificate]]`` table removed:
  ## the snapshot a writer that predates command sets recorded.
  var skipping = false
  var kept: seq[string]
  for raw in lock.splitLines():
    let line = raw.strip()
    if line.startsWith("["):
      skipping = line == "[[certificate_policy.certificate]]"
    if not skipping: kept.add(raw)
  while kept.len > 0 and kept[^1].strip().len == 0:
    kept.setLen(kept.len - 1)
  kept.join("\n") & "\n"

proc entryFor(entries: openArray[string]; actionId: string): string =
  for e in entries:
    if e.startsWith(actionId & "="): return e
  ""

proc certifyCandidate(fx: WorkspaceCertifyFixture; branch, base: string;
                      edit: proc (recipe: string): string): string =
  ## On a new ``branch`` off ``base``: edit the recipe, run the real
  ## ``repro test unit-suite`` (its lock-update node rewrites the snapshot),
  ## commit what it certified, and put its certificate in the notes ref.
  ## Returns the commit.
  discard fx.mustGit("checkout", "-q", "-B", branch, base)
  writeFile(fx.app / "repro.nim", edit(readFile(fx.app / "repro.nim")))
  let run = fx.reproIn(["test", "unit-suite", "--tool-provisioning=path"])
  checkpoint("repro test (" & branch & "):\n" & run.output)
  doAssert run.code == 0, "repro test failed on " & branch & ":\n" & run.output
  let content = fx.contentNow()
  # A certificate names CONTENT, so any certificate for this content covers
  # the commit. Two candidates can certify the same content (the legacy
  # drop below has the drop candidate's bytes once its lock is rewritten),
  # and a run over content that is already certified may issue nothing new;
  # the one this run issued (based on ``base``) is preferred when there is
  # one.
  var certs: seq[TestCertificate]
  for cert in fx.certificatesFor(content, "unit-suite"):
    if cert.vcs.base == base: certs.insert(cert, 0)
    else: certs.add(cert)
  doAssert certs.len >= 1, "no unit-suite certificate for " & content &
    " after repro test on " & branch & ":\n" & run.output
  discard fx.mustGit("add", "-A")
  discard fx.mustGit("commit", "-q", "--no-verify", "-m", branch)
  doAssert treeContentId(fx.cf.sib.gitBin, fx.app, "HEAD") == content,
    "the commit on " & branch & " is not the certified content"
  let noted = seedCertificateNote(fx.cf.sib.gitBin, fx.app, certs[0])
  doAssert noted.ok, noted.diagnostic
  fx.mustGit("rev-parse", "HEAD")

proc pushThroughGateway(fx: WorkspaceCertifyFixture; commit, branch: string):
    tuple[code: int; output: string] =
  result = fx.git("push", "--no-verify", "origin",
    commit & ":refs/heads/" & branch,
    certificateNotesRef & ":" & certificateNotesRef)
  checkpoint("push " & commit[0 ..< 12] & " to " & branch & ":\n" &
    result.output)

proc upstreamRef(origin, branch: string): string =
  let res = execCmdEx(quoteShellCommand(@["git", "-C", origin, "rev-parse",
    "--verify", "--quiet", "refs/heads/" & branch]))
  if res.exitCode != 0: "" else: res.output.strip()

proc ciPlan(fx: WorkspaceCertifyFixture; base, branch: string): JsonNode =
  let res = fx.reproIn(["ci", "plan", "--platform=" & currentPlatformTag(),
    "--branch=" & branch, "--base=" & base,
    "--workspace-root=" & fx.cf.sib.ws, "--current-repo=" & fx.app, "--json"])
  checkpoint("ci plan --base=" & base & ":\n" & res.output)
  doAssert res.code == 0, "repro ci plan failed:\n" & res.output
  let start = res.output.find("{\n")
  doAssert start >= 0, "no JSON in ci plan output:\n" & res.output
  parseJson(res.output[start .. ^1])

proc hostPlan(plan: JsonNode; key: string): seq[string] =
  for p in plan["platforms"]:
    if p["platform"].getStr() == currentPlatformTag() and p.hasKey(key):
      for x in p[key]: result.add(x.getStr())

proc narrowedMissing(plan: JsonNode; name: string):
    tuple[listed: bool; missing: seq[string]] =
  ## The ``narrowed`` row for ``name``, if the plan lists one.
  if not plan.hasKey("narrowed"):
    return
  for row in plan["narrowed"]:
    if row{"certificate"}.getStr() == name:
      result.listed = true
      if row.hasKey("missing"):
        for x in row["missing"]: result.missing.add(x.getStr())

proc listedIn(plan: JsonNode; key, name: string): bool =
  if plan.hasKey(key):
    for x in plan[key]:
      if x.getStr() == name: return true
  false

suite "a narrowed required name is trusted by neither the ratchet nor CI":

  test "t_a_narrowed_required_name_is_not_trusted_by_the_ratchet_or_ci_skip":
    if findExe("git").len == 0 or findExe("ssh-keygen").len == 0:
      skip("git or ssh-keygen is not on PATH; this test signs certificates " &
        "in real repositories")
    else:
      let fx = setupWorkspaceCertifyFixture("narrowed-name",
        ["unit_a", "unit_b", "unit_c"], buildLines)
      defer: removeDir(fx.cf.sib.scratch)
      let app = fx.app
      var origin = ""
      for (name, path) in fx.cf.sib.origins:
        if name == "app": origin = path
      doAssert origin.len > 0

      # ---- the base: the policy, recorded by the real `repro lock refresh` --
      createDir(app / "policy")
      writeFile(app / "policy" / "app_policy.nim", appPolicy())
      let recipe = readFile(app / "repro.nim")
      writeFile(app / "repro.nim", recipe
        .replace("import repro_project_dsl\n",
          "import repro_project_dsl\nimport ./policy/app_policy\n")
        .replace("\n  build:\n", "\n  enactCertificatePolicy appPolicy\n\n" &
          "  build:\n"))
      let refreshed = fx.reproIn(["lock", "refresh", app])
      checkpoint("repro lock refresh:\n" & refreshed.output)
      doAssert refreshed.code == 0, "lock refresh failed:\n" & refreshed.output
      let baseLock = readFile(app / "repro.lock")
      checkpoint("base snapshot:\n" & snapshotText(baseLock))
      doAssert "[certificate_policy]" in baseLock
      discard fx.mustGit("add", "-A")
      discard fx.mustGit("commit", "-q", "--no-verify", "-m", "base policy")
      discard fx.mustGit("push", "-q", "--no-verify", "origin", "main")
      let base = fx.mustGit("rev-parse", "HEAD")
      # What the base says unit-suite means: one entry per member.
      let baseEntries = commandEntries(baseLock)
      check baseEntries.len == 2
      let baseUnitB = entryFor(baseEntries, "unit_b")
      check baseUnitB.startsWith("unit_b=blake3:")
      check entryFor(baseEntries, "unit_a").startsWith("unit_a=blake3:")

      # The legacy base: the same commit's snapshot without its command
      # sets, published directly to the upstream as `legacy`.
      discard fx.mustGit("checkout", "-q", "-B", "legacy-base", base)
      writeFile(app / "repro.lock", withoutCommandSets(baseLock))
      discard fx.mustGit("commit", "-q", "--no-verify", "-a", "--allow-empty",
        "-m", "a snapshot written before command sets")
      let legacyBase = fx.mustGit("rev-parse", "HEAD")
      check "[[certificate_policy.certificate]]" notin
        readFile(app / "repro.lock")
      discard fx.mustGit("push", "-q", "--no-verify", origin,
        "legacy-base:refs/heads/legacy")

      # The gateway in front of the upstream; the anchor of `main` is `base`.
      let gateway = fx.cf.sib.scratch / "gateway.git"
      let wired = wirePushGateway(fx.cf.sib.gitBin, app, gateway,
        fileUrl(origin), GatewayConfig(lockRecordsDir: "",
          registeredKeysPath: registeredKeyStorePath(fx.cf.sib.ws)))
      doAssert wired.ok, wired.diagnostic

      # ---- 1. DROP a member, re-certify ------------------------------------
      let dropped = fx.certifyCandidate("cand-drop", base,
        proc (r: string): string =
          r.replace(memberLine, "aggregate(\"unit-suite\", @[unit_a])"))
      let droppedLock = readFile(app / "repro.lock")
      checkpoint("drop candidate snapshot:\n" & snapshotText(droppedLock))
      check commandEntries(droppedLock).len == 1
      let dropPush = fx.pushThroughGateway(dropped, "main")
      check dropPush.code != 0
      check upstreamRef(origin, "main") == base
      check "unit-suite" in dropPush.output
      check "narrowed: 'unit-suite'" in dropPush.output
      if baseUnitB.len > 0:
        check baseUnitB in dropPush.output
      let dropPlan = fx.ciPlan(base, "main")
      check dropPlan["ci_trust"].getStr() == "skip"
      check hostPlan(dropPlan, "skip").len == 0
      check hostPlan(dropPlan, "run") == @["unit-suite"]
      let dropNarrowed = narrowedMissing(dropPlan, "unit-suite")
      check dropNarrowed.listed
      check dropNarrowed.missing == @[baseUnitB]

      # ---- 2. CHANGE a member's command, re-certify ------------------------
      let changed = fx.certifyCandidate("cand-change", base,
        proc (r: string): string =
          r.replace("output = \"build/unit_b-out\"",
            "output = \"build/unit_b-renamed-out\""))
      let changedLock = readFile(app / "repro.lock")
      checkpoint("change candidate snapshot:\n" & snapshotText(changedLock))
      check commandEntries(changedLock).len == 2
      if baseUnitB.len > 0:
        check baseUnitB notin commandEntries(changedLock)
      let changePush = fx.pushThroughGateway(changed, "main")
      check changePush.code != 0
      check upstreamRef(origin, "main") == base
      check "narrowed: 'unit-suite'" in changePush.output
      if baseUnitB.len > 0:
        check baseUnitB in changePush.output
      let changePlan = fx.ciPlan(base, "main")
      check hostPlan(changePlan, "skip").len == 0
      check hostPlan(changePlan, "run") == @["unit-suite"]
      check narrowedMissing(changePlan, "unit-suite").missing == @[baseUnitB]

      # ---- 4. a LEGACY anchor: judged by name alone, run by CI -------------
      # The same drop, on top of the legacy base (a fast-forward of the
      # `legacy` anchor).
      let legacyDropped = fx.certifyCandidate("cand-legacy-drop", legacyBase,
        proc (r: string): string =
          r.replace(memberLine, "aggregate(\"unit-suite\", @[unit_a])"))
      let legacyPush = fx.pushThroughGateway(legacyDropped, "legacy")
      check legacyPush.code == 0
      check upstreamRef(origin, "legacy") == legacyDropped
      check "records no command set" in legacyPush.output
      let legacyPlan = fx.ciPlan(legacyBase, "legacy")
      check legacyPlan["ci_trust"].getStr() == "skip"
      check hostPlan(legacyPlan, "skip").len == 0
      check hostPlan(legacyPlan, "run") == @["unit-suite"]
      check legacyPlan.listedIn("unanchored", "unit-suite")
      check not narrowedMissing(legacyPlan, "unit-suite").listed

      # ---- 3. a SUPERSET is still trusted ----------------------------------
      let grown = fx.certifyCandidate("cand-grow", base,
        proc (r: string): string =
          r.replace(memberLine,
            "aggregate(\"unit-suite\", @[unit_a, unit_b, unit_c])"))
      let grownLock = readFile(app / "repro.lock")
      check commandEntries(grownLock).len == 3
      for entry in baseEntries:
        check entry in commandEntries(grownLock)
      let growPlan = fx.ciPlan(base, "main")
      check hostPlan(growPlan, "skip") == @["unit-suite"]
      check hostPlan(growPlan, "run").len == 0
      check not narrowedMissing(growPlan, "unit-suite").listed
      check not growPlan.listedIn("unanchored", "unit-suite")
      let growPush = fx.pushThroughGateway(grown, "main")
      check growPush.code == 0
      check upstreamRef(origin, "main") == grown
      let grownEntries = commandEntries(grownLock)

      # ---- 5. dropping the requirement AND the declaration in one push -----
      # The anchor (`grown`) requires `unit-suite`. The commit stops
      # requiring it and removes its `certificate` marking in the same push,
      # so its snapshot records no meaning for the name at all: narrowed.
      discard fx.mustGit("checkout", "-q", "-B", "cand-drop-both", grown)
      writeFile(app / "policy" / "app_policy.nim",
        appPolicy(requireUnitSuite = false))
      writeFile(app / "repro.nim", readFile(app / "repro.nim").replace(
        "    certificate \"unit-suite\", " &
          "aggregate(\"unit-suite\", @[unit_a, unit_b, unit_c])\n",
        "    discard aggregate(\"unit-suite\", @[unit_a])\n"))
      check "certificate \"unit-suite\"" notin readFile(app / "repro.nim")
      let dropBothRefresh = fx.reproIn(["lock", "refresh", app])
      checkpoint("lock refresh (drop both):\n" & dropBothRefresh.output)
      check dropBothRefresh.code == 0
      check commandEntries(readFile(app / "repro.lock")).len == 0
      discard fx.mustGit("add", "-A")
      discard fx.mustGit("commit", "-q", "--no-verify", "-m",
        "drop unit-suite from the rule and the recipe")
      let droppedBoth = fx.mustGit("rev-parse", "HEAD")
      let dropBothPush = fx.pushThroughGateway(droppedBoth, "main")
      check dropBothPush.code != 0
      check upstreamRef(origin, "main") == grown
      check "narrowed: 'unit-suite'" in dropBothPush.output
      for entry in grownEntries:
        check entry in dropBothPush.output

      # ---- 6. RELAXING (positive control): two pushes ----------------------
      # Push 1 stops requiring `unit-suite` and leaves its node unchanged, so
      # its snapshot still records the anchor's meaning of the name: it lands
      # (certified for the anchor's requirement). Push 2, judged by push 1 as
      # its anchor, narrows the name and lands too.
      let relaxed = fx.certifyCandidate("cand-relax", grown,
        proc (r: string): string =
          writeFile(app / "policy" / "app_policy.nim",
            appPolicy(requireUnitSuite = false))
          r)
      let relaxedLock = readFile(app / "repro.lock")
      checkpoint("relaxing snapshot:\n" & snapshotText(relaxedLock))
      check "certificate = \"unit-suite\"" notin snapshotText(relaxedLock)
      check commandEntries(relaxedLock) == grownEntries
      let relaxPush = fx.pushThroughGateway(relaxed, "main")
      check relaxPush.code == 0
      check upstreamRef(origin, "main") == relaxed
      check "narrowed:" notin relaxPush.output
      let narrowedLater = fx.certifyCandidate("cand-narrow-later", relaxed,
        proc (r: string): string =
          r.replace("aggregate(\"unit-suite\", @[unit_a, unit_b, unit_c])",
            "aggregate(\"unit-suite\", @[unit_a])"))
      check commandEntries(readFile(app / "repro.lock")).len == 1
      let narrowLaterPush = fx.pushThroughGateway(narrowedLater, "main")
      check narrowLaterPush.code == 0
      check upstreamRef(origin, "main") == narrowedLater

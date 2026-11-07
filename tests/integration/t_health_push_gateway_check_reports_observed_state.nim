## PG-16 — ``repro health``'s ``push-gateway`` and ``certificate-policy`` rows
## report OBSERVED and RESOLVED state, not constants.
##
## THE DEFECT (spec §1.6c, re-stated in §7.6.6). Both rows shipped as
## unconditional ``hsOk`` carrying a constant detail string —
##
##   push-gateway        ok   no certificate-enforcing project; pushes are direct
##   certificate-policy  ok   certificates: advisory/off (pushes not gated)
##
## — emitted with no enclosing ``block``, no manifest read and no probe. Both
## sentences were TRUE on the host they were measured on. Neither would have
## changed if they had stopped being true: the same two strings would have been
## printed, byte for byte, by a workspace whose project declares ``gate_mode =
## required`` and whose repos are not wired at all, which is the one state these
## rows exist to find. CLI/health.md's stated purpose is to localize the
## problem, so a hardcoded ``ok`` is worse than no check — it removes the
## layer from suspicion. (Prose, not a quotation: health.md reads *"`repro
## health` localizes the problem"*.)
##
## WHY THE GUARD IS A DIFFERENCE AND NOT A PRESENCE. This is the whole design
## of this suite and the milestone states it as a warning: *"a test that merely
## asserts the check EXISTS passes against a constant"*. So the subject is never
## one workspace's output. It is TWO workspaces that differ in exactly one
## property, and the assertion is that their ``push-gateway`` details are NOT
## EQUAL. A constant fails that by construction, whatever the constant says.
##
## WHICH ARMS ARE THE MUTATION GUARDS, and what each one would catch:
##
##   (A) DIFFERENCE. An unwired workspace and a wired one — identical in every
##       other respect, both with no policy (off) — produce different
##       ``push-gateway`` details. Catches: any constant; any implementation
##       that reads the policy but never looks at a remote.
##   (B) The counts are the OBSERVATION, each with its population: the unwired
##       workspace reports ``0 wired`` / ``1 not-wired`` and NAMES the repo and
##       the reason; the wired one reports ``1 wired`` / ``0 not-wired``.
##       Catches an implementation that reports a difference without reporting
##       which way round it is (e.g. one keyed on a hash of the workspace path).
##   (C) CONTRADICTION ⇒ ``fail``. A repo whose OWN policy (TC-9d: the
##       ``[certificate_policy]`` its checked-out ``repro.lock`` records) gates
##       its push at non-``off``, while its push is ungoverned, is §7.6.6's "`required` on an `unwired` repo … visible as the
##       contradiction it is", and the deliverable requires the row to be
##       CAPABLE of ``fail``. Its own control is the SAME workspace after
##       wiring, which must return to ``ok``: without that control, "fail"
##       could come from the ``advisory`` policy alone rather than from the
##       missing wiring.
##   (D) ``certificate-policy`` reports the RESOLVED policy — per repo, the
##       policy its checked-out ``repro.lock`` records, the checked-out
##       branch, the rule matching it, the mode, every required name with its
##       platforms and the policy's ``ci_trust``; a repo whose
##       ``repro.lock`` records no policy is named as having none — and
##       two workspaces with different policies produce different details.
##       Catches the retired constant, and catches a row that resolves the
##       policy but prints only a verdict word. A manifest that still carries
##       a ``[certificates]`` table fails the ``manifest`` row, its remedy
##       naming the policy design (``certificatePolicy`` /
##       ``enactCertificatePolicy``) (TC-9d, D18).
##   (E) FOREIGN (§7.3). A pushurl this tool did not set is counted and named
##       as ``foreign``, never as ``wired``, and ``health`` does not overwrite
##       it. Catches a reporting row that repairs.
##   (F) ``stale-gateway`` vs ``foreign``, split by the §7.6.3 PROVENANCE RECORD
##       and not by the path's shape. One pushurl — gateway-shaped, under this
##       fixture's own gateways root — reads ``foreign`` without the record and
##       ``stale-gateway`` with it. Catches the shape test an implementer reaches
##       for first, which §7.6.3 names as the thing that would clobber the
##       developer the rule exists to protect.
##   (G) §7.4's THREE OPT-OUT SCOPES — per repo, per machine, per workspace —
##       each named with its scope, under a ``required`` policy where silence
##       would be most expensive, against a no-opt-out control in the same
##       fixture. §7.4: *"An opt-out suppresses wiring, never reporting …
##       Silence about a disabled safety mechanism is how the mechanism is
##       forgotten."* Catches a row that reports the fact without the scope,
##       and catches one that goes quiet the moment an operator opts out.
##
## THE POLICY IS HELD CONSTANT ACROSS (A) AND (B), which is the control that
## makes the difference attributable. Neither fixture's repo records a
## certificate policy, so both are default-off; the only thing that differs is
## whether ``remote.origin.pushurl`` names this workspace's gateway. (D) then
## varies the policy and holds the wiring constant, so each half of the pair has
## one arm in which it is the only moving part.
##
## EVERY ``notin`` ASSERTION IS PAIRED WITH AN ``in``. Spec §1.6's qualifier
## rule: *"a string's absence from a binary is evidence only alongside a control
## string that is present"*. The retired constants are asserted absent only
## beside a live substring asserted present, so a row that went empty — or a
## report this suite failed to locate at all — cannot read as a pass.
##
## HERMETIC, and specifically never touching the operator's real cache.
## ``REPRO_WORKSPACE_CLONES`` is set per fixture to a directory inside that
## fixture's own ``createTempDir``, so ``defaultCacheRoot`` resolves there and
## ``gatewayBarePathFor`` puts the gateways tree beside it. Nothing reaches
## ``~/.cache/reprobuild``. Origins are local bares reached over ``file://``;
## there is no network. ``repro hooks ensure`` is NEVER run here — this suite's
## subject is the push path, and the one in-tree action that rewrites hook
## bodies has no business in it.
##
## Skip rule: ``git`` missing on PATH.

import std/[json, os, osproc, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

import repro_test_support
import repro_cli_support
import repro_lock
import repro_lock/certificate_policy
import repro_workspace_manifests
import ./every_branch_policy

proc q(value: string): string = quoteShell(value)

proc runCmd(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd,
    options = {poStdErrToStdOut, poUsePath})
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  let res = runCmd(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

const projectTomlHeader = """
schema = "reprobuild.workspace.project.v1"

[project]
name = "lib-a"

[[remote]]
name = "lib-a-origin"
fetch = "LIB_A_URL"

includes = [
  "repos/lib-a.toml",
]
"""

const libAFragmentToml = """
schema = "reprobuild.workspace.repo.v2"

[repo]
name = "lib-a"
path = "lib-a"
remote = "lib-a-origin"
mainline = "main"
"""

const retiredGatewayConstant =
  "no certificate-enforcing project; pushes are direct"
  ## The exact string the ``push-gateway`` row shipped (spec §1.6c).

const retiredPolicyConstant = "certificates: advisory/off (pushes not gated)"
  ## The exact string the ``certificate-policy`` row shipped (spec §1.6c).

proc policyLockFor(mode: PolicyMode; targets, platforms: seq[string];
                   ciTrust = pctAdvisory): string =
  ## A committed ``repro.lock`` (pinning nothing) whose ``[certificate_policy]``
  ## has one rule for every branch (``everyBranchPolicy``): since TC-9d the
  ## only place a repo's policy lives.
  replaceCertificatePolicySection(
    serializeLockedDependencies(LockedDependencies(
      schema: "reprobuild.solved-graph-lock.v2", deps: @[])),
    everyBranchSnapshot(mode, targets, platforms, ciTrust = ciTrust,
      name = "lib-a"))

proc seedOrigin(gitBin, originPath, seedPath: string; policyLock = "") =
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  discard requireGit(q(gitBin) & " init -b main " & q(seedPath))
  discard requireGit(q(gitBin) & " -C " & q(seedPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(seedPath) &
    " config user.name \"PG16 Tester\"")
  writeFile(seedPath / "README.md", "PG-16 fixture\n")
  if policyLock.len > 0:
    writeFile(seedPath / "repro.lock", policyLock)
  discard requireGit(q(gitBin) & " -C " & q(seedPath) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(seedPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(seedPath) & " remote add origin " &
    q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(seedPath) & " push origin main")

type
  Fixture = object
    scratch: string
    workspaceRoot: string
    repoPath: string
    cacheRoot: string      ## the CLONES root; the gateways tree lands beside it
    reproBin: string

proc setupFixture(gitBin, slug, policyLock: string;
                  manifestExtra = ""): Fixture =
  ## One workspace, one participating repo, one local bare origin, and a cache
  ## root INSIDE the fixture.
  ##
  ## ``policyLock`` is committed as lib-a's ``repro.lock`` (TC-9d: a repo's
  ## certificate policy lives in its own content). "" is RA-32's default-off
  ## state, no policy at all, which is what the unwired/wired pair must hold
  ## constant, while an explicit policy is what arm (D) varies.
  ## ``manifestExtra`` is appended to ``projects/lib-a.toml`` verbatim.
  result.scratch = createTempDir("repro-pg16-gateway-" & slug & "-", "")
  result.reproBin = reproBinary()
  let origin = result.scratch / "origin-lib-a.git"
  seedOrigin(gitBin, origin, result.scratch / "seed-lib-a", policyLock)
  result.workspaceRoot = result.scratch / "workspace"
  result.cacheRoot = result.scratch / "cache" / "clones"
  createDir(result.workspaceRoot)
  createDir(result.workspaceRoot / ".repro")
  createDir(result.workspaceRoot / "projects")
  createDir(result.workspaceRoot / "repos")
  createDir(result.cacheRoot)
  writeFile(result.workspaceRoot / "projects" / "lib-a.toml",
    projectTomlHeader.replace("LIB_A_URL", fileUrl(origin)) &
      manifestExtra)
  writeFile(result.workspaceRoot / "repos" / "lib-a.toml", libAFragmentToml)
  result.repoPath = result.workspaceRoot / "lib-a"
  discard requireGit(q(gitBin) & " clone " & q(fileUrl(origin)) & " " &
    q(result.repoPath))

proc fixtureEnv(fx: Fixture): seq[tuple[name, value: string]] =
  ## ``REPRO_WORKSPACE_CLONES`` is the cache-root injection: ``defaultCacheRoot``
  ## returns this override verbatim, so every gateway path the product computes
  ## lands under this fixture's temp dir. ``REPROBUILD_REPRO`` pins the
  ## neighbouring PG-14 ``hook-interpreter`` row to the binary under test, so a
  ## machine-wide skew on the host cannot colour this suite's subject.
  @[(name: "REPRO_WORKSPACE_CLONES", value: fx.cacheRoot),
    (name: "REPROBUILD_REPRO", value: fx.reproBin)]

proc invokeHealth(fx: Fixture;
                  extraEnv: openArray[tuple[name, value: string]] = []):
    CmdResult =
  runShell(shellCommand(
    @[fx.reproBin, "health", "lib-a", "--json",
      "--workspace-root=" & fx.workspaceRoot],
    fixtureEnv(fx) & @extraEnv))

proc migrate(fx: Fixture): CmdResult =
  ## The PRODUCTION wiring path (``repro gateway migrate``), not a hand-written
  ## ``git config``. A hand-written pushurl would make the test re-implement
  ## ``gatewayBarePathFor`` + ``urlSlug``, and a test that computes the expected
  ## path itself cannot distinguish "the product agrees with me" from "we are
  ## both wrong in the same way" — the ``wired`` arm would silently become an
  ## arm about nothing.
  runShell(shellCommand(
    @[fx.reproBin, "gateway", "migrate",
      "--workspace-root=" & fx.workspaceRoot],
    fixtureEnv(fx)))

proc pushurlOf(gitBin: string; fx: Fixture): string =
  let res = runCmd(q(gitBin) & " -C " & q(fx.repoPath) &
    " config --get remote.origin.pushurl")
  if res.code == 0: res.output.strip() else: ""

proc findCheck(report: JsonNode; name: string): JsonNode =
  for entry in report["checks"]:
    if entry["name"].getStr() == name:
      return entry
  nil

type
  Rows = object
    gateway: JsonNode
    policy: JsonNode
    failedRows: int

proc healthRows(fx: Fixture; label: string;
                extraEnv: openArray[tuple[name, value: string]] = []): Rows =
  let res = invokeHealth(fx, extraEnv)
  checkpoint(label & ": health --json exit=" & $res.code)
  let report =
    try: parseJson(res.output)
    except CatchableError:
      checkpoint(label & ": health emitted unparseable output:\n" & res.output)
      quit 1
  result.gateway = findCheck(report, "push-gateway")
  result.policy = findCheck(report, "certificate-policy")
  doAssert not result.gateway.isNil, label & ": health emitted no push-gateway row"
  doAssert not result.policy.isNil,
    label & ": health emitted no certificate-policy row"
  result.failedRows = report["failed"].getInt()
  checkpoint(label & ": push-gateway=" & $result.gateway)
  checkpoint(label & ": certificate-policy=" & $result.policy)
  checkpoint(label & ": failed rows=" & $result.failedRows &
    " of " & $report["checks"].len)

suite "PG-16 — health's push-gateway check reports observed state":

  test "t_health_push_gateway_check_reports_observed_state":
    ## Arms (A), (B) and (E). The subject is the DIFFERENCE between two
    ## workspaces, so there are two fixtures and no shared state between them.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; this case needs two real workspaces holding " &
        "real git repos for a push path to be observed at all")
    else:
      let unwired = setupFixture(gitBin, "unwired", "")
      defer: removeDir(unwired.scratch)
      let wired = setupFixture(gitBin, "wired", "")
      defer: removeDir(wired.scratch)
      # The qualifier rule (§1.6): name the binary by PATH, not by version.
      checkpoint("binary under test: " & unwired.reproBin)

      # Wire ONE of them, through the production verb.
      let migrated = migrate(wired)
      checkpoint("gateway migrate: exit=" & $migrated.code & "\n" &
        migrated.output)
      check migrated.code == 0
      let wiredPushurl = pushurlOf(gitBin, wired)
      checkpoint("wired fixture pushurl: '" & wiredPushurl & "'")
      # FIXTURE PRECONDITIONS, asserted rather than assumed. If migrate ever
      # stops wiring, the arms below would compare two unwired workspaces and
      # pass by reporting no difference — a green run about nothing.
      check wiredPushurl.len > 0
      check wiredPushurl.startsWith(wired.scratch)
      check pushurlOf(gitBin, unwired).len == 0

      let u = healthRows(unwired, "unwired")
      let w = healthRows(wired, "wired")
      let uDetail = u.gateway["detail"].getStr()
      let wDetail = w.gateway["detail"].getStr()

      # CONTROL — the policy half is held CONSTANT across the pair. Neither
      # repo records a certificate policy (TC-9d: a repo's policy is its own
      # repro.lock's), so both are default-off, and any difference below is
      # attributable to the wiring and to nothing else.
      check "RA-32 default-off state" in u.policy["detail"].getStr()
      check "RA-32 default-off state" in w.policy["detail"].getStr()
      check u.policy["detail"].getStr() == w.policy["detail"].getStr()
      check u.gateway["status"].getStr() == "ok"
      check w.gateway["status"].getStr() == "ok"

      # (A) THE MUTATION GUARD. Against the shipped constant these are equal.
      check uDetail != wDetail

      # (B) ... and the difference is the OBSERVATION, the right way round,
      # with the population stated on both sides of it.
      check "gateway 0 wired" in uDetail
      check "1 not-wired across 1 participating repo(s)" in uDetail
      check "gateway 1 wired" in wDetail
      check "0 not-wired across 1 participating repo(s)" in wDetail
      # The unwired repo is NAMED with its reason, not merely counted.
      check "remote.origin.pushurl is unset" in uDetail
      check "remote.origin.pushurl is unset" notin wDetail
      # The `gate_mode` that would apply is reported beside the counts (§7.6.6),
      # on BOTH sides, so the row is readable without a second command.
      const noGatingPolicy = "no participating repo's checked-out " &
        "repro.lock records a certificate policy that gates a push of its " &
        "current branch"
      check noGatingPolicy in uDetail
      check noGatingPolicy in wDetail

      # §7.6.6's summary sentence, and the ONE number here that is derived
      # rather than observed. A WIRED repo with no policy (off) is gated by
      # NOTHING — the gateway is attached and no policy stands behind it — so
      # the answer is 0 of 1 on BOTH sides. Reporting the wired count here
      # instead would print "would gate 1 of 1" for a workspace that refuses
      # nothing, which is a true-in-one-state sentence printed in every state:
      # the §1.6c defect at one remove.
      check "policy would gate 0 of 1 participating repo(s)" in uDetail
      check "policy would gate 0 of 1 participating repo(s)" in wDetail
      check "no policy gates a push: nothing is refused anywhere" in wDetail

      # The retired constant is gone. Asserted against a CONTROL substring
      # that IS present in the same string (§1.6's qualifier rule), so an
      # empty or missing detail cannot satisfy this by absence alone.
      check "participating repo(s)" in uDetail
      check retiredGatewayConstant notin uDetail
      check "participating repo(s)" in wDetail
      check retiredGatewayConstant notin wDetail

      # (E) FOREIGN (§7.3). Re-point the unwired fixture's pushurl at a path
      # this tool did not set and does not own.
      let foreignPath = unwired.scratch / "an-operators-own-mirror.git"
      discard requireGit(q(gitBin) & " -C " & q(unwired.repoPath) &
        " config remote.origin.pushurl " & q(foreignPath))
      let f = healthRows(unwired, "foreign")
      let fDetail = f.gateway["detail"].getStr()
      check "1 foreign" in fDetail
      check "gateway 0 wired" in fDetail          # NOT counted as wired
      check fDetail != uDetail                    # and distinguished from unwired
      check fDetail != wDetail
      # And the row does NOT claim this workspace's pushes are direct. "Nothing
      # is wired" is not "everything is direct": a foreign pushurl sends pushes
      # to whatever it names. The absence is asserted beside a control PRESENCE
      # in the same string (`1 foreign`, above) and beside the arm where the
      # sentence IS true and IS printed, so a row that simply went quiet cannot
      # satisfy this.
      check "pushes are direct" notin fDetail
      check "pushes are direct" in uDetail
      # Reported, NEVER overwritten: `health` is the read-only side of §7.6.1's
      # split, so the value it complained about is still there afterwards.
      check pushurlOf(gitBin, unwired) == foreignPath

  test "t_health_push_gateway_fails_on_a_governed_but_unwired_workspace":
    ## Arm (C). The deliverable: the row "must be capable of reporting fail".
    ## Its control is the same workspace after wiring.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; this case needs a real workspace holding a real " &
        "git repo whose push path can be left unwired")
    else:
      let fx = setupFixture(gitBin, "governed", policyLockFor(pmAdvisory,
        @["t-unit"], @["linux/amd64"]))
      defer: removeDir(fx.scratch)
      checkpoint("binary under test: " & fx.reproBin)
      check pushurlOf(gitBin, fx).len == 0

      let before = healthRows(fx, "governed-unwired")
      let beforeDetail = before.gateway["detail"].getStr()

      # THE CONTRADICTION: a policy that gates, over a repo whose pushes do not
      # reach the thing that would gate them.
      check before.gateway["status"].getStr() == "fail"
      check "lib-a" in beforeDetail
      check "not-wired" in beforeDetail
      check "judged by nothing" in beforeDetail
      check before.gateway["remedy"].getStr().len > 0
      # NOT auto-fixable: wiring rewrites a remote on an operator's checkout,
      # and §7.6.1 keeps that on the attended `sync` path. `health --fix` is
      # unattended by construction.
      check before.gateway["fixable"].getBool() == false
      # §7.7 step 4 — `advisory` is the MEASUREMENT instrument, so an
      # unattached instrument is a finding and not a lesser one. The count
      # carries the qualifier that makes it mean something.
      check "policy would gate 0 of 1 participating repo(s)" in beforeDetail
      check "all advisory" in beforeDetail

      # THE CONTROL, and the reason this arm is not satisfiable by a row wired
      # to `fail` whenever a certificate policy exists: wire the SAME
      # workspace and the SAME policy, and the row must come back to `ok`.
      let migrated = migrate(fx)
      checkpoint("gateway migrate: exit=" & $migrated.code & "\n" &
        migrated.output)
      check migrated.code == 0
      check pushurlOf(gitBin, fx).len > 0

      let after = healthRows(fx, "governed-wired")
      let afterDetail = after.gateway["detail"].getStr()
      check after.gateway["status"].getStr() == "ok"
      check "gateway 1 wired" in afterDetail
      check "judged by nothing" notin afterDetail
      check afterDetail != beforeDetail
      # The policy did NOT move — same repro.lock, same rule — which is what
      # makes the status change attributable to the wiring.
      check "advisory, requires t-unit (linux/amd64)" in
        before.policy["detail"].getStr()
      check before.policy["detail"].getStr() ==
        after.policy["detail"].getStr()
      # The gateway row names the repo whose own policy gates it, with the
      # mode that policy applies to its checked-out branch.
      check "per repo's own certificate policy: lib-a (advisory" in
        beforeDetail

      # Principle 2 — the finding reaches the aggregate verdict rather than
      # being a cosmetic row. Both numbers are taken from THIS fixture, on the
      # two sides of the wiring change; the absolute values are not asserted,
      # because other rows in a bare fixture legitimately fail too (no managed
      # hooks are installed here, by design).
      check before.failedRows == after.failedRows + 1

  test "t_health_certificate_policy_reports_the_resolved_values":
    ## Arm (D). Two workspaces, identical in their WIRING (both unwired),
    ## differing only in the policy lib-a's repro.lock records. The policy
    ## row must differ.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; this case needs two real workspaces for the " &
        "manifest ladder to resolve a project at all")
    else:
      let plain = setupFixture(gitBin, "policy-default", "")
      defer: removeDir(plain.scratch)
      let enforcing = setupFixture(gitBin, "policy-required", policyLockFor(
        pmRequired, @["t-unit", "t-integration"], @["linux/amd64"],
        ciTrust = pctSkip))
      defer: removeDir(enforcing.scratch)
      checkpoint("binary under test: " & plain.reproBin)

      let p = healthRows(plain, "policy-default")
      let e = healthRows(enforcing, "policy-required")
      let pDetail = p.policy["detail"].getStr()
      let eDetail = e.policy["detail"].getStr()

      # THE MUTATION GUARD: against the shipped constant these are equal.
      check pDetail != eDetail

      # RA-32's default-off, read from each repo's repro.lock rather than
      # assumed (TC-9d: there is no project-wide policy to read any more).
      check "RA-32 default-off state" in pDetail
      check "read from each repo's repro.lock" in pDetail
      # No snapshot: the row says there is no policy, and names the repo.
      check "no participating repo's checked-out repro.lock records a " &
        "certificate policy" in pDetail
      check "no certificate policy recorded in the repro.lock of: lib-a" in
        pDetail
      check "ci_trust" notin pDetail

      # What the policy IS, and WHOSE it is — a row that printed only a
      # verdict word would satisfy the inequality above. The row names the
      # repo, the policy, the rule that matched its checked-out branch, the
      # mode, every required name with its platforms, the checked-out branch
      # it was matched for, and the policy's ci_trust (operator decision
      # 2026-10-17).
      check "certificate policy 'lib-a'" in eDetail
      check "matched by \"**\"" in eDetail
      check "required, requires t-unit (linux/amd64), " &
        "t-integration (linux/amd64)" in eDetail
      check "lib-a (branch 'main': " in eDetail
      check "; ci_trust skip)" in eDetail

      # The retired constant, each absence paired with a control presence.
      check "certificate policy" in pDetail
      check retiredPolicyConstant notin pDetail
      check retiredPolicyConstant notin eDetail

      # An enforcing project whose pushes are not wired is the §7.4 / §7.6.6
      # contradiction, and the two rows divide the labour: the policy row says
      # what the policy IS and hands the "does a push reach it?" question to
      # the gateway row, which is the row that fails on it.
      check "push-gateway row" in eDetail
      check e.gateway["status"].getStr() == "fail"

      # TC-9d: a project manifest that still carries the retired
      # `[certificates]` table does not resolve. The manifest row fails, names
      # the file and the table, and its remedy is the policy design
      # (D18), not `workspace sync` (which would meet the same refusal).
      let legacy = setupFixture(gitBin, "policy-legacy-table", "",
        manifestExtra = "\n[certificates]\ngate_mode = \"required\"\n" &
          "required_targets = [\"t-unit\"]\n" &
          "required_platforms = [\"linux/amd64\"]\n")
      defer: removeDir(legacy.scratch)
      let legacyRun = invokeHealth(legacy)
      checkpoint("legacy table: health exit=" & $legacyRun.code & "\n" &
        legacyRun.output)
      let manifestRow = findCheck(parseJson(legacyRun.output), "manifest")
      doAssert not manifestRow.isNil, "health emitted no manifest row"
      check manifestRow["status"].getStr() == "fail"
      check "[certificates]" in manifestRow["detail"].getStr()
      check (legacy.workspaceRoot / "projects" / "lib-a.toml") in
        manifestRow["detail"].getStr()
      let remedy = manifestRow["remedy"].getStr()
      check "certificatePolicy" in remedy
      check "enactCertificatePolicy" in remedy
      check "repro lock refresh" in remedy
      check "migrate-policy" notin remedy
      check "workspace sync" notin manifestRow["remedy"].getStr()

  test "t_health_push_gateway_splits_stale_gateway_from_foreign_by_provenance":
    ## §7.3's two "not the expected gateway" verdicts, and §7.6.3's rule about
    ## how they are told apart. ``stale-gateway`` is repairable by repointing;
    ## ``foreign`` must NEVER be overwritten. Collapsing them attaches the
    ## wrong remedy to a developer's own mirror.
    ##
    ## THE GUARD IS THAT PATH SHAPE IS NOT PROVENANCE. §7.6.3: *"a user who read
    ## this document and pointed their own mirror at a cache-root-shaped path
    ## would be clobbered by a rule whose entire purpose is not to clobber
    ## them"*. So both arms below use the SAME pushurl — a gateway-shaped path
    ## under this fixture's own gateways root — and differ only in whether the
    ## provenance record says reprobuild wrote it. A shape test gives them the
    ## same verdict and fails this case.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; this case needs a real repository whose pushurl " &
        "and provenance config can be set independently of each other")
    else:
      let fx = setupFixture(gitBin, "provenance", "")
      defer: removeDir(fx.scratch)
      checkpoint("binary under test: " & fx.reproBin)

      # Wire for real first, so the gateway-shaped path below is derived from
      # what the PRODUCT computes rather than from the test's own arithmetic.
      let migrated = migrate(fx)
      checkpoint("gateway migrate: exit=" & $migrated.code & "\n" &
        migrated.output)
      check migrated.code == 0
      let realGateway = pushurlOf(gitBin, fx)
      check realGateway.len > 0
      check "/gateways/workspace/" in realGateway

      # §7.3's "a different gateway under this cache root (e.g. the workspace
      # was renamed)". Same cache root, same layout, different workspace
      # segment — so it is gateway-SHAPED and is not this workspace's gateway.
      let renamed = realGateway.replace("/gateways/workspace/",
        "/gateways/a-workspace-this-checkout-was-renamed-from/")
      check renamed != realGateway
      discard requireGit(q(gitBin) & " -C " & q(fx.repoPath) &
        " config remote.origin.pushurl " & q(renamed))

      # ARM 1 — gateway-shaped, NO provenance record. Must read `foreign`.
      let noProv = healthRows(fx, "shaped-without-provenance")
      let noProvDetail = noProv.gateway["detail"].getStr()
      check "1 foreign" in noProvDetail
      check "0 stale-gateway" in noProvDetail
      check "gateway 0 wired" in noProvDetail
      check "NEVER overwritten" in noProvDetail
      # The row says WHY the shape did not decide it, so a reader does not have
      # to rediscover §7.6.3.
      check "path shape is not provenance" in noProvDetail

      # ARM 2 — the same pushurl, now with the §7.6.3 record saying reprobuild
      # set it, for THIS workspace. Must read `stale-gateway`.
      for key, value in {
          "reprobuild.pushGateway.setBy": "reprobuild",
          "reprobuild.pushGateway.value": renamed,
          "reprobuild.pushGateway.workspace": fx.workspaceRoot}.items:
        discard requireGit(q(gitBin) & " -C " & q(fx.repoPath) &
          " config " & key & " " & q(value))
      let withProv = healthRows(fx, "shaped-with-provenance")
      let withProvDetail = withProv.gateway["detail"].getStr()
      check "1 stale-gateway" in withProvDetail
      check "0 foreign" in withProvDetail
      check "gateway 0 wired" in withProvDetail
      # Drift in state this tool wrote is worth saying even at `gate_mode =
      # off`, and it is repairable, so it is a warn with a remedy rather than
      # an `ok` or a `fail`.
      check withProv.gateway["status"].getStr() == "warn"
      check withProv.gateway["remedy"].getStr().len > 0
      check withProv.gateway["fixable"].getBool() == false

      # THE SPLIT, as a difference rather than as two independent claims: one
      # pushurl, two verdicts, decided by the record and not by the path.
      check noProvDetail != withProvDetail
      check pushurlOf(gitBin, fx) == renamed   # reported, never repaired

  test "t_health_push_gateway_reports_each_opt_out_scope_and_silences_none":
    ## §7.4's three opt-out scopes, under §7.4's own rule: *"An opt-out
    ## suppresses wiring, never reporting … Silence about a disabled safety
    ## mechanism is how the mechanism is forgotten."* And §7.6.6's sharper
    ## form: an `opted-out` repo in a project at `gate_mode = required` is
    ## **still named**.
    ##
    ## The fixture is at `required`, which is the only mode in which silence
    ## would actually cost something, and every arm asserts the row still
    ## `fail`s and still names the repo. The three arms are also asserted to
    ## differ FROM EACH OTHER: reporting "something opted out" without saying
    ## WHICH SCOPE did it sends the operator to the wrong file, and a single
    ## shared string would satisfy an arm-by-arm test that never compared them.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; this case needs a real repository whose per-repo " &
        "opt-out marker can be written into its git config")
    else:
      let fx = setupFixture(gitBin, "optouts", policyLockFor(pmRequired,
        @["t-unit"], @["linux/amd64"]))
      defer: removeDir(fx.scratch)
      checkpoint("binary under test: " & fx.reproBin)
      check pushurlOf(gitBin, fx).len == 0

      # SCOPE 1 — per repo (§7.4: `unwire`'s marker; `unwire` itself is PG-9's).
      discard requireGit(q(gitBin) & " -C " & q(fx.repoPath) &
        " config reprobuild.pushGateway.optOut true")
      let perRepo = healthRows(fx, "opt-out/per-repo")
      let perRepoDetail = perRepo.gateway["detail"].getStr()
      check perRepo.gateway["status"].getStr() == "fail"
      check "1 opted-out" in perRepoDetail
      check "opted-out: lib-a" in perRepoDetail
      check "per-repo opt-out marker" in perRepoDetail
      discard requireGit(q(gitBin) & " -C " & q(fx.repoPath) &
        " config --unset reprobuild.pushGateway.optOut")

      # SCOPE 2 — per machine. §7.4: "Intended for CI images and for bisecting
      # a gateway-related failure", so it is the scope most likely to be set
      # and forgotten, and the one whose silence would be most expensive.
      let perMachine = healthRows(fx, "opt-out/per-machine",
        [(name: "REPRO_PUSH_GATEWAY", value: "off")])
      let perMachineDetail = perMachine.gateway["detail"].getStr()
      check perMachine.gateway["status"].getStr() == "fail"
      check "1 opted-out" in perMachineDetail
      check "opted-out: lib-a" in perMachineDetail
      check "a per-machine opt-out is in force" in perMachineDetail
      check "suppresses WIRING and not REPORTING" in perMachineDetail

      # SCOPE 3 — per workspace (`push_gateway = "off"` in
      # `.repro-workspace.toml`). Reached through `REPRO_WORKSPACE_CONFIG`
      # rather than by writing the file into the fixture, because
      # `findBootstrapConfigPath` walks ANCESTOR directories: a file planted in
      # the fixture would be found, but so would one in any ancestor of the
      # system temp dir, and the override makes the arm independent of what is
      # above `createTempDir` on the host running it.
      let wsConfig = fx.scratch / "bootstrap-with-gateway-off.toml"
      # A settings file must declare its schema (Workspace-Settings-Files.md
      # §3); the strict reader that now reads this key rejects one that does
      # not, where the old line scan read any file. The fixture is otherwise
      # the same opt-out §7.4 documents.
      writeFile(wsConfig, "schema = \"reprobuild.workspace.settings.v1\"\n" &
        "push_gateway = \"off\"\n")
      let perWorkspace = healthRows(fx, "opt-out/per-workspace",
        [(name: "REPRO_WORKSPACE_CONFIG", value: wsConfig)])
      let perWorkspaceDetail = perWorkspace.gateway["detail"].getStr()
      check perWorkspace.gateway["status"].getStr() == "fail"
      check "1 opted-out" in perWorkspaceDetail
      check "opted-out: lib-a" in perWorkspaceDetail
      check "a per-workspace opt-out is in force" in perWorkspaceDetail

      # THE SCOPE IS REPORTED, not merely the fact. Three distinct details.
      check perRepoDetail != perMachineDetail
      check perMachineDetail != perWorkspaceDetail
      check perRepoDetail != perWorkspaceDetail

      # CONTROL — and the arm that makes the three above mean something: with
      # no opt-out in force at all, the SAME fixture reports the repo under a
      # different verdict entirely. Without this, a row that answered
      # "opted-out" for every unwired repo would pass all three arms.
      let none = healthRows(fx, "opt-out/none")
      let noneDetail = none.gateway["detail"].getStr()
      check "0 opted-out" in noneDetail
      check "1 not-wired" in noneDetail
      check noneDetail != perRepoDetail

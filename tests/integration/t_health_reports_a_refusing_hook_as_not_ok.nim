## PG-16 — ``repro health``'s ``vcs-hooks`` row does NOT report a refusing
## managed hook as ``ok``, and does not count it as wired.
##
## THE DEFECT, measured end to end rather than read from source (spec §1.6c).
## With ``repro 0.2.2`` the check runs and reports
##
##   vcs-hooks  fail  95 managed hook(s) missing across 172 participating repo(s)
##
## — the 95 being 5 hooks × 19 repos with no managed hooks at all.
## ``reprobuild-specs``, whose ``post-commit`` had just been **fired and
## refused**, is **not** in that list: it was counted into ``okCount``. The
## check's verdict for a hook that refuses on every fire was *ok*.
##
## The source said why. The wiring test was ``isReprobuildVcsHook``, a three-way
## substring sniff for ``VcsDispatcherMarker`` / "reprobuild hook dispatcher" /
## "reprobuild managed <hook> hook" — markers **every** generated body carries,
## old and new — and nothing in the arm asked whether the installed body is one
## this build can service. ``managedHookBodyIsCurrent`` *is* that question and
## existed throughout; its only caller was ``effectivePrePushHook``.
##
## WHAT THIS SUITE GUARDS, and which arms are the mutation guards:
##
##   (A) A body demanding a contract this build does not generate makes the row
##       NON-``ok``. **Mutation-verified: this arm FAILS against the shipped
##       check, which reports ``ok``.**
##   (B) It is not counted into ``okCount``. With five present bodies and one
##       foreign contract the row must say **four** wired, never five.
##       **Mutation-verified: the shipped check says five.**
##   (C) It is its OWN state, not ``missing``. ``missing``'s remedy is an
##       ``--fix``-able ``hooks ensure --vcs``, and that is the one action the
##       hook body's own refusal text warns against — *"that rewrites this file
##       with its own older body, the contract line disappears, and you silence
##       this message instead of fixing it"*. So the stale row must NOT be
##       advertised as fixable, and must not be worded as a missing hook. The
##       "not worded as missing" half is falsified by `stale.add` → `missing.add`
##       — classifying a stale body as `missing`, the arm that already exists —
##       and NOT by defeating the freshness test; the inline note at that
##       assertion says so, because the distinction is easy to get backwards.
##   (D) A body carrying NO contract line at all is the same class of finding
##       with a different reason (``managedHookBodyContractDemand`` returns ""
##       as a positive finding, not a parse failure), and must also not be
##       ``ok``.
##   (E) CONTROL — the untouched fixture, whose bodies this build DID write, is
##       ``ok`` with all five counted. Without this arm every assertion above is
##       satisfied by a check hardwired to ``fail``.
##   (F) THE ORDERING, which (A)-(E) leave unguarded and which the product's own
##       block comment calls "the safety property rather than a preference": a
##       repo holding BOTH a stale hook and a missing one must take the STALE
##       arm, because ``missing``'s arm advertises an ``--fix``-able ``hooks
##       ensure`` and running that under a live contract mismatch deletes the
##       diagnostic instead of the defect. (A)-(E) cannot see this: their fixture
##       has nothing missing, so ``missing.len > 0`` is false and the stale arm
##       is reached whichever order the arms are written in. (F) is the arm that
##       fails if they are swapped — and it also holds the row to NAMING the
##       missing hook in the same detail, so taking the safer arm does not drop
##       the other finding.
##
## WHY THE FIXTURE MUTATES A TOKEN RATHER THAN INSTALLING AN OLD BUILD. The
## state being reproduced is "the installed body was written by a build that is
## not this one", and on the measured host that meant one of SEVENTEEN reprobuild
## store paths. No second real build can be produced hermetically, and the
## defect is not about any particular other build — it is about the comparison
## never being made. Rewriting the demanded token is that state exactly, by the
## only property the comparison reads. Everything else is real: the real
## binary installs the real hooks into a real git repo, and the real ``health``
## reads them.
##
## Hermetic: one ``createTempDir``, local bares only, no network.
## Skip rule: ``git`` missing on PATH.

import std/[json, os, osproc, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

import repro_test_support

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

const projectToml = """
schema = "reprobuild.workspace.project.v1"

[project]
name = "lib-a"
default_revision = "main"
trunk = "main"

[[remote]]
name = "lib-a-origin"
fetch = "LIB_A_URL"

includes = [
  "repos/lib-a.toml",
]
"""

const libAFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-a"
path = "lib-a"
remote = "lib-a-origin"
revision = "main"
"""

proc seedOrigin(gitBin, originPath, seedPath: string) =
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  discard requireGit(q(gitBin) & " init -b main " & q(seedPath))
  discard requireGit(q(gitBin) & " -C " & q(seedPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(seedPath) &
    " config user.name \"PG16 Tester\"")
  writeFile(seedPath / "README.md", "PG-16 fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(seedPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(seedPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(seedPath) & " remote add origin " &
    q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(seedPath) & " push origin main")

type
  Fixture = object
    scratch: string
    workspaceRoot: string
    repoPath: string
    reproBin: string

proc setupFixture(gitBin, slug: string): Fixture =
  result.scratch = createTempDir("repro-pg16-hooks-" & slug & "-", "")
  result.reproBin = reproBinary()
  let origin = result.scratch / "origin-lib-a.git"
  seedOrigin(gitBin, origin, result.scratch / "seed-lib-a")
  result.workspaceRoot = result.scratch / "workspace"
  createDir(result.workspaceRoot)
  createDir(result.workspaceRoot / ".repro")
  createDir(result.workspaceRoot / "projects")
  createDir(result.workspaceRoot / "repos")
  writeFile(result.workspaceRoot / "projects" / "lib-a.toml",
    projectToml.replace("LIB_A_URL", fileUrl(origin)))
  writeFile(result.workspaceRoot / "repos" / "lib-a.toml", libAFragmentToml)
  result.repoPath = result.workspaceRoot / "lib-a"
  discard requireGit(q(gitBin) & " clone " & q(fileUrl(origin)) & " " &
    q(result.repoPath))
  # The REAL binary installs the REAL hooks. The fixture's whole subject is a
  # body this build did write, minimally altered in the one property the check
  # is supposed to read.
  let ensured = runShell(shellCommand(@[
    result.reproBin, "hooks", "ensure", "--vcs", result.workspaceRoot]))
  checkpoint("hooks ensure: " & ensured.output)
  doAssert ensured.code == 0, "fixture could not install managed hooks"
  let managed = result.repoPath / ".git" / "hooks" / "post-commit.repro-managed"
  doAssert fileExists(managed), "fixture installed no managed post-commit"
  doAssert "--hook-contract=" in readFile(managed),
    "fixture's managed body carries no contract token; (A)-(E) prove nothing"

const contractFlag = "--hook-contract="

proc demandedToken(body: string): string =
  ## The token the body demands, read the way the product reads it: from the
  ## first ``--hook-contract=`` to the first character outside the token's own
  ## alphabet.
  let at = body.find(contractFlag)
  doAssert at >= 0, "fixture body carries no contract flag"
  var i = at + contractFlag.len
  var j = i
  while j < body.len and (body[j] in {'a' .. 'z', 'A' .. 'Z', '0' .. '9'} or
      body[j] in {'.', '-', '_'}):
    inc j
  body[i ..< j]

proc managedBodyPath(fx: Fixture; hookName: string): string =
  fx.repoPath / ".git" / "hooks" / (hookName & ".repro-managed")

proc rewriteDemandedToken(fx: Fixture; hookName, replacement: string): string =
  ## Make the installed body demand a DIFFERENT contract, in every place it
  ## names one, and return the token that was there. The dispatcher at the
  ## canonical path is untouched, so every marker ``isReprobuildVcsHook`` sniffs
  ## for is still present — which is the entire point: the shipped check sees an
  ## installed, marker-bearing, executable managed hook and calls it wired.
  let path = managedBodyPath(fx, hookName)
  let body = readFile(path)
  let token = demandedToken(body)
  let newToken = token[0 .. token.rfind('.')] & replacement
  writeFile(path, body.replace(token, newToken))
  token

proc stripContractLine(fx: Fixture; hookName: string) =
  ## The state the hook body's own remedy text warns ``hooks ensure`` creates:
  ## "the contract line disappears, and you silence this message instead of
  ## fixing it".
  let path = managedBodyPath(fx, hookName)
  let body = readFile(path)
  let token = demandedToken(body)
  writeFile(path, body.replace(contractFlag & token, ""))

proc removeHookEntirely(fx: Fixture; hookName: string) =
  ## Delete the dispatcher AND the managed body, which is what the arm reads as
  ## ``missing`` — the state 19 repos in the measured workspace were in.
  removeFile(fx.repoPath / ".git" / "hooks" / hookName)
  removeFile(managedBodyPath(fx, hookName))

proc invokeHealth(fx: Fixture): CmdResult =
  ## ``REPROBUILD_REPRO`` is pinned to the real binary so the neighbouring
  ## PG-14 ``hook-interpreter`` row is not what this suite is accidentally
  ## measuring: the subject here is the per-repo contract comparison, and the
  ## machine-wide skew question has its own row and its own suite.
  runShell(shellCommand(
    @[fx.reproBin, "health", "lib-a", "--json",
      "--workspace-root=" & fx.workspaceRoot],
    @[(name: "REPROBUILD_REPRO", value: fx.reproBin)]))

proc findCheck(report: JsonNode; name: string): JsonNode =
  for entry in report["checks"]:
    if entry["name"].getStr() == name:
      return entry
  nil

proc vcsHooksRow(fx: Fixture): JsonNode =
  let res = invokeHealth(fx)
  checkpoint("health --json output:\n" & res.output)
  let row = findCheck(parseJson(res.output), "vcs-hooks")
  doAssert not row.isNil, "health emitted no vcs-hooks row"
  row

suite "PG-16 — health reports a refusing hook as not ok":

  test "t_health_reports_a_refusing_hook_as_not_ok":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; this case needs a real repository carrying " &
        "real installed managed hooks for the contract comparison to have a " &
        "subject")
    else:
      let fx = setupFixture(gitBin, "foreign")
      defer: removeDir(fx.scratch)

      # (E) CONTROL FIRST, so the later arms cannot be satisfied by a check
      # wired to fail. Every body here was written by this build.
      let control = vcsHooksRow(fx)
      checkpoint("control vcs-hooks: " & $control)
      check control["status"].getStr() == "ok"
      check "5 managed hook(s) wired" in control["detail"].getStr()
      check control["remedy"].getStr().len == 0

      # Now make ONE of the five bodies demand a contract this build does not
      # generate. Nothing else changes: same file, same markers, same mode.
      let wasToken = fx.rewriteDemandedToken("post-commit", "0123456789abcdef")
      checkpoint("rewrote post-commit's demand away from " & wasToken)

      let row = vcsHooksRow(fx)
      let status = row["status"].getStr()
      let detail = row["detail"].getStr()
      let remedy = row["remedy"].getStr()
      checkpoint("vcs-hooks: status=" & status & "\ndetail=" & detail &
        "\nremedy=" & remedy)

      # (A) THE MUTATION GUARD. The shipped check reports `ok` here.
      check status != "ok"
      # It names the offending repo and hook, not just a count.
      check "lib-a/post-commit" in detail
      # Both sides of the comparison are named, so the operator can see WHICH
      # contract was demanded and WHICH this build generates.
      check "0123456789abcdef" in detail
      check wasToken in detail

      # (B) THE SECOND MUTATION GUARD: not counted as wired. Five bodies are
      # present; four are serviceable.
      check "4 managed hook(s) wired" in detail
      check "5 managed hook(s) wired" notin detail

      # (C) its own state, with its own remedy — and NOT `missing`, whose
      # remedy is an --fix-able `hooks ensure` that would delete the evidence.
      check "STALE" in detail
      # WHAT FALSIFIES THE LINE BELOW, stated because it is not the mutation a
      # reader would guess. It does NOT fire when the freshness test is
      # defeated (`classifyManagedHookFreshness` pinned to `mhfCurrent`): that
      # yields the `ok` census, which contains no "missing" either, so the line
      # passes against the broken behaviour. The mutation it DOES catch is the
      # competing wrong implementation — classifying a stale body as `missing`
      # (`stale.add` → `missing.add`), which is the most plausible way to get
      # this wrong, because it reaches for the arm that already exists. Under
      # that mutation the detail reads "1 managed hook(s) missing …" and this
      # line fails, together with the `fixable == false` check two lines down,
      # which is the harm: `missing`'s arm advertises the `hooks ensure` the
      # installed body's own refusal text warns against. Case (F) does NOT
      # cover this — (F) asserts `"1 missing" in detail`, a PRESENCE, because
      # its fixture genuinely has a missing hook to name.
      check "missing" notin detail
      check remedy.len > 0
      check row["fixable"].getBool() == false

      # Principle 2 — a failing row makes the command exit non-zero rather than
      # hiding the finding behind a zero status.
      if status == "fail":
        check invokeHealth(fx).code != 0

  test "t_health_reports_a_contractless_hook_as_not_ok":
    ## (D) The second way a present body is unserviceable: it names no contract
    ## at all. Same class of finding, different reason, and it must not be
    ## reported as `ok` either — nor as `missing`, since the hook is there.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; this case needs a real repository carrying " &
        "real installed managed hooks for the contract comparison to have a " &
        "subject")
    else:
      let fx = setupFixture(gitBin, "contractless")
      defer: removeDir(fx.scratch)

      check vcsHooksRow(fx)["status"].getStr() == "ok"   # control

      fx.stripContractLine("pre-push")
      let row = vcsHooksRow(fx)
      let detail = row["detail"].getStr()
      checkpoint("vcs-hooks: " & $row)
      check row["status"].getStr() != "ok"
      check "lib-a/pre-push" in detail
      check "NO contract line" in detail
      check "4 managed hook(s) wired" in detail
      check row["fixable"].getBool() == false

  test "t_health_takes_the_stale_arm_ahead_of_missing_and_names_both":
    ## (F) The ordering. One repo, one stale hook and one absent hook, so both
    ## arms' conditions hold at once and the row has to choose.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; this case needs a real repository in which one " &
        "managed hook can be made stale and another removed outright")
    else:
      let fx = setupFixture(gitBin, "stale-and-missing")
      defer: removeDir(fx.scratch)

      check vcsHooksRow(fx)["status"].getStr() == "ok"   # control

      let wasToken = fx.rewriteDemandedToken("post-commit", "0123456789abcdef")
      fx.removeHookEntirely("post-merge")
      checkpoint("post-commit's demand moved off " & wasToken &
        "; post-merge deleted outright")

      let row = vcsHooksRow(fx)
      let detail = row["detail"].getStr()
      let remedy = row["remedy"].getStr()
      checkpoint("vcs-hooks: " & $row)

      # The STALE arm was taken, not the ``missing`` one ...
      check row["status"].getStr() == "fail"
      check "STALE" in detail
      check "lib-a/post-commit" in detail
      # ... and the remedy does NOT lead with ``hooks ensure``, which is the
      # action the installed body's own refusal text warns against. It leads
      # with reconciling what supplies ``repro``.
      check remedy.startsWith("direnv reload")
      check row["fixable"].getBool() == false
      # ... and nothing was dropped by taking it: the missing hook is named in
      # the same detail, with its count.
      check "1 missing" in detail
      check "lib-a/post-merge" in detail
      # Three of the five bodies are serviceable: one is stale, one is gone.
      check "3 managed hook(s) wired across 1 participating repo(s)" in detail

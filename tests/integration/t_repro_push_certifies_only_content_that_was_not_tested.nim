## ``repro push`` certifies by content:
## what is covered runs nothing, the worktree's uncovered content
## is tested and certified, and an uncovered commit that is not the worktree's
## content is refused by name, before anything is published.
##
## Real: the manifest workspace and repository, the built ``repro``, the real
## provider and engine running ``repro certify``, the managed hooks, and a real
## gateway bare with its hooks forwarding to the upstream bare, which judges every
## push by the policy in the pushed tree. The certificates are signed with the
## fixture's registered key. No mocks.
##
## One repository, with a lock that pins no sibling, because the gateway's public
## lock gate refuses a pin of another repository's revision.
##
## The rule's ``commit_gate`` is ``off``: with the default, the pre-commit gate
## refuses an uncovered commit, so the states under test could not be committed
## with hooks on. ``advisory`` is the other way to arrive at them, and has a case
## of its own.

import std/unittest

import repro_test_support/reasoned_skip

include certificate_push_fixture
from test_certificates/notes as tcnotes import nil
from test_certificates/roots as tcroots import nil

const certToolInterface = "import repro_project_dsl\n\n" &
  "defineCliInterface certTool, \"cert-tool\":\n" &
  "  call:\n" &
  "    flag input is string, alias = \"--input\", role = input, required = true\n" &
  "    flag output is string, alias = \"--output\", role = output, required = true\n" &
  "    flag marker is string, alias = \"--marker\", required = true\n" &
  "    outputs output\n"

  ## Copies ``--input`` to ``--output`` and logs the output to ``--marker``, so a
  ## case can tell that a test ran. An input starting with FAIL makes it fail.
const certToolScript = """#!/bin/sh
set -eu
if [ "${1:-}" = "--version" ]; then echo 'cert-tool 1.0.0'; exit 0; fi
input= output= marker=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --input) input=$2; shift 2 ;;
    --output) output=$2; shift 2 ;;
    --marker) marker=$2; shift 2 ;;
    *) echo "unknown arg $1" >&2; exit 64 ;;
  esac
done
mkdir -p "$(dirname "$output")" "$(dirname "$marker")"
printf '%s\n' "$output" >> "$marker"
case "$(head -c 4 "$input")" in FAIL) echo "$input says FAIL" >&2; exit 1 ;; esac
cp "$input" "$output"
"""

proc policyModule(mode, platform: string): string =
  "import repro_certificates\n\n" &
    "const teamPolicy* = certificatePolicy \"team\":\n" &
    "  rule \"**\":\n" &
    "    gateMode " & mode & "\n" &
    "    commitGate off\n" &
    "    requires \"t-unit\", platforms = [\"" & platform & "\"]\n"

const recipe = "import repro_project_dsl\n" &
  "import \"policy/team_policy\"\n\n" &
  "package lib_a:\n" &
  "  usesImportPath \"reprobuild/packages\"\n" &
  "  enactCertificatePolicy teamPolicy\n" &
  "  uses:\n" &
  "    \"cert-tool >=1.0 <2.0\"\n\n" &
  "  build:\n" &
  "    let unit = certTool(actionId = \"unit\",\n" &
  "      input = \"src/unit.txt\",\n" &
  "      output = \"build/unit-out\",\n" &
  "      marker = \".repro/runs.log\")\n" &
  "    certificate \"t-unit\", aggregate(\"t-unit\", @[unit])\n"

type PushFixture = object
  sf: StoreFixture
  binDir: string

proc app(fx: PushFixture): string = fx.sf.libAPath

proc git(fx: PushFixture; args: string): string =
  let res = execCmdEx("git -C " & quoteShell(fx.app) & " " & args)
  doAssert res.exitCode == 0, args & ":\n" & res.output
  res.output.strip()

proc repro(fx: PushFixture; args: seq[string];
           env: seq[tuple[name, value: string]] = @[]):
    tuple[code: int; output: string] =
  result = runArgv(@[fx.sf.reproBin] & args, fx.app,
    daemonKeyEnv(fx.sf.daemonKey, storeKeyId) &
    @[(name: "PATH", value: fx.binDir & $PathSep & pathWithoutTool()),
      (name: "REPROBUILD_REPRO", value: fx.sf.reproBin)] & env)
  checkpoint("repro " & args.join(" ") & ":\n" & result.output)

proc push(fx: PushFixture; args: seq[string] = @[];
          env: seq[tuple[name, value: string]] = @[]):
    tuple[code: int; output: string] =
  fx.repro(@["push", "--tool-provisioning=path"] & args, env)

proc certify(fx: PushFixture) =
  let res = fx.repro(@["certify", "t-unit", "--tool-provisioning=path"])
  doAssert res.code == 0, res.output

proc runs(fx: PushFixture): int =
  ## How many times the test command has run.
  let log = fx.app / ".repro" / "runs.log"
  if fileExists(log):
    for line in readFile(log).splitLines():
      if line.strip().len > 0: inc result

proc commitEdit(fx: PushFixture; body, message: string): string =
  writeFile(fx.app / "src" / "unit.txt", body)
  discard fx.git("add -A")
  discard fx.git("commit -q -m " & quoteShell(message))
  fx.git("rev-parse HEAD")

proc certifyThenCommit(fx: PushFixture; body, message: string): string =
  writeFile(fx.app / "src" / "unit.txt", body)
  fx.certify()
  discard fx.git("add -A")
  discard fx.git("commit -q -m " & quoteShell(message))
  fx.git("rev-parse HEAD")

proc tree(fx: PushFixture; commit: string): string =
  fx.git("rev-parse " & commit & "^{tree}")

proc records(fx: PushFixture; tree: string): int =
  noteOnRemote(fx.sf.upstreamBare, tree).count("# --- test-certificate ---")

proc storedFor(fx: PushFixture; tree: string): int =
  ## The certificates the local store holds for this tree.
  let lookup = findCertificatesInLocalStore(stateWithKnownContent(
    [KnownContentId(algorithm: "git-tree-sha1", id: "git-tree-sha1:" & tree)]))
  lookup.found.len

proc setupPush(slug: string; mode: string): PushFixture =
  result.sf = setupStoreFixture("", slug, recordStore = false)
  result.binDir = result.sf.scratch / "bin"
  createDir(result.binDir)
  writeFile(result.binDir / "cert-tool", certToolScript)
  setFilePermissions(result.binDir / "cert-tool",
    {fpUserRead, fpUserWrite, fpUserExec})
  let app = result.sf.libAPath
  createDir(app / "src")
  createDir(app / "policy")
  createDir(app / "reprobuild" / "packages")
  writeFile(app / "src" / "unit.txt", "unit v1\n")
  writeFile(app / "policy" / "team_policy.nim",
    policyModule(mode, currentPlatformTag()))
  writeFile(app / "reprobuild" / "packages" / "cert_tool.nim", certToolInterface)
  writeFile(app / "repro.nim", recipe)
  writeFile(app / ".gitignore", ".repro/\nbuild/\ntest-logs/\n")
  let refreshed = result.repro(@["lock", "refresh"])
  doAssert refreshed.code == 0, refreshed.output
  doAssert "gate_mode = \"" & mode & "\"" in readFile(app / "repro.lock"),
    readFile(app / "repro.lock")
  discard result.git("add -A")
  discard result.git("commit -q -m project")
  discard result.git("push -q origin main")
  # A committed-lock project: the gateway reads the lock out of the pushed tree.
  let wired = wirePushGateway("git", app, result.sf.gatewayBare,
    fileUrl(result.sf.upstreamBare), GatewayConfig(
      registeredKeysPath: registeredKeyStorePath(result.sf.workspaceRoot)))
  doAssert wired.ok, wired.diagnostic
  installHooks(result.sf)

template guarded(body: untyped) =
  if findExe("git").len == 0 or findExe("ssh-keygen").len == 0:
    skip("git and ssh-keygen are needed")
  else:
    body

suite "repro push certifies only content that was not tested":
  test "covered runs nothing, uncovered worktree content certifies then pushes":
    guarded:
      let fx = setupPush("push-certify", "required")
      defer: removeDir(fx.sf.scratch)

      # ---- test, then commit: the normal case, a lookup ---------------------
      let certified = fx.certifyThenCommit("unit v2\n", "certified")
      let ran = fx.runs()
      let before = fx.git("worktree list").splitLines().len
      let covered = fx.push()
      check covered.code == 0
      check fx.runs() == ran
      check "certified: " notin covered.output
      check upstreamTip(fx.sf) == certified
      # The tool carried it, through the gateway, keyed by tree.
      check fx.records(fx.tree(certified)) == 1

      # ---- committed without testing: tested here, then pushed --------------
      let untested = fx.commitEdit("unit v3\n", "not tested yet")
      check fx.storedFor(fx.tree(untested)) == 0
      let certifying = fx.push()
      check certifying.code == 0
      check fx.runs() == ran + 1
      check "certified: t-unit" in certifying.output
      check fx.storedFor(fx.tree(untested)) == 1
      check upstreamTip(fx.sf) == untested
      check fx.records(fx.tree(untested)) == 1

      # ---- a second push of the same content runs nothing -------------------
      let again = fx.push()
      check again.code == 0
      check fx.runs() == ran + 1
      check "already-published" in again.output
      check fx.records(fx.tree(untested)) == 1
      check fx.git("worktree list").splitLines().len == before

  test "a failing test issues nothing and pushes nothing":
    guarded:
      let fx = setupPush("push-failing", "required")
      defer: removeDir(fx.sf.scratch)
      let tip = upstreamTip(fx.sf)
      let failing = fx.commitEdit("FAIL on purpose\n", "breaks the test")
      let refused = fx.push()
      check refused.code == 2
      check "stage=certify" in refused.output
      check "'repro certify t-unit' failed" in refused.output
      check fx.storedFor(fx.tree(failing)) == 0
      check upstreamTip(fx.sf) == tip
      check fx.records(fx.tree(failing)) == 0

  test "an uncovered older commit is refused by name, and the remedy works":
    guarded:
      let fx = setupPush("push-older", "required")
      defer: removeDir(fx.sf.scratch)
      let tip = upstreamTip(fx.sf)
      let worktrees = fx.git("worktree list").splitLines().len
      let ran = fx.runs()
      let older = fx.commitEdit("unit older\n", "an intermediate state")
      let newest = fx.certifyThenCommit("unit newest\n", "the certified tip")
      let afterCertify = fx.runs()
      check afterCertify == ran + 1

      let refused = fx.push()
      check refused.code == 2
      check "stage=certify-preflight" in refused.output
      check older[0 ..< 12] in refused.output
      check "an intermediate state" in refused.output
      check "is not this checkout's content" in refused.output
      check "t-unit" in refused.output
      check ("check " & older[0 ..< 12] & " out and run 'repro test'") in
        refused.output
      check "--no-certify" in refused.output
      # Refused before any test or any transport, and no scratch worktree.
      check fx.runs() == afterCertify
      check upstreamTip(fx.sf) == tip
      check fx.git("worktree list").splitLines().len == worktrees

      # ---- the remedy it names ----------------------------------------------
      discard fx.git("switch -q --detach " & older)
      fx.certify()
      discard fx.git("switch -q main")
      let accepted = fx.push()
      check accepted.code == 0
      check upstreamTip(fx.sf) == newest
      # The hook carried both, since the push introduced both.
      check fx.records(fx.tree(older)) == 1
      check fx.records(fx.tree(newest)) == 1

  test "--no-certify runs nothing and leaves the decision to the gates":
    guarded:
      let fx = setupPush("push-no-certify", "required")
      defer: removeDir(fx.sf.scratch)
      let tip = upstreamTip(fx.sf)
      let ran = fx.runs()
      let older = fx.commitEdit("unit older\n", "never tested")
      let newest = fx.commitEdit("unit newest\n", "never tested either")
      let refused = fx.push(@["--no-certify"])
      check refused.code != 0
      check fx.runs() == ran
      # The client gate's refusal, by its own words: the step did not run.
      check "stage=source-push" in refused.output
      check "stage=certify" notin refused.output
      check "no trusted" in refused.output or "uncovered" in refused.output
      check upstreamTip(fx.sf) == tip
      check older.len > 0

      # Covered at the tip: the gates judge tips, so it lands, with the older
      # commit that --certify would have stopped on.
      fx.certify()
      let landed = fx.push(@["--no-certify"])
      check landed.code == 0
      check upstreamTip(fx.sf) == newest

  test "advisory: certifies and refuses like required, --no-certify pushes":
    guarded:
      let fx = setupPush("push-advisory", "advisory")
      defer: removeDir(fx.sf.scratch)
      let ran = fx.runs()
      let skipped = fx.commitEdit("unit two\n", "advisory, not certified")
      let plain = fx.push(@["--no-certify"])
      check plain.code == 0
      check fx.runs() == ran
      check upstreamTip(fx.sf) == skipped
      check fx.storedFor(fx.tree(skipped)) == 0

      let tested = fx.commitEdit("unit three\n", "advisory, certified by push")
      let certifying = fx.push()
      check certifying.code == 0
      check fx.runs() == ran + 1
      check upstreamTip(fx.sf) == tested
      check fx.records(fx.tree(tested)) == 1

      # The policy changed and nothing refreshed the lock: the run's lock refresh
      # moves the content away from the commit, so what it certified is not what
      # would be pushed. It stops, and says so, rather than push uncovered content.
      writeFile(fx.app / "policy" / "team_policy.nim",
        policyModule("advisory", "linux/second"))
      discard fx.commitEdit("unit four\n", "changes the policy")
      let moved = fx.push()
      check moved.code == 2
      check "stage=certify" in moved.output
      check "certifying changed the working tree" in moved.output
      check upstreamTip(fx.sf) == tested
      check fx.runs() == ran + 2

      # A name only another host can produce is reported under advisory, and
      # stopping for it would refuse every push of a two-platform policy.
      discard fx.git("add -A")
      discard fx.git("commit -q --amend --no-edit")
      let elsewhere = fx.git("rev-parse HEAD")
      let reported = fx.push()
      check reported.code == 0
      check fx.runs() == ran + 2
      check "on a linux/second host" in reported.output
      check upstreamTip(fx.sf) == elsewhere

  test "a certificate issued after publication reaches the remote":
    guarded:
      let fx = setupPush("push-later", "required")
      defer: removeDir(fx.sf.scratch)
      let commit = fx.certifyThenCommit("unit later\n", "certified")
      check fx.push().code == 0
      check fx.records(fx.tree(commit)) == 1

      check publishCertificateToLocalStore(signedCertFor(fx.sf,
        "git-tree-sha1:" & fx.tree(commit), commit, platform = "linux/second"),
        fx.app).written
      # The propagation switch governs this as it governs the hook.
      let off = fx.push(@["--no-certify"],
        @[(name: "TEST_CERTIFICATES_HOOK", value: "off")])
      check off.code == 0
      check "not carried" in off.output
      check fx.records(fx.tree(commit)) == 1

      # With --no-certify too: carrying issues nothing.
      let carried = fx.push(@["--no-certify"])
      check carried.code == 0
      check "already-published" in carried.output
      check "certificate(s) for " & commit in carried.output
      check "test-certificates notes publish" notin carried.output
      check fx.records(fx.tree(commit)) == 2

      # Nothing further to say, and nothing added.
      let settled = fx.push(@["--no-certify"])
      check settled.code == 0
      check "certificate(s) for " notin settled.output
      check fx.records(fx.tree(commit)) == 2

      # A note published locally whose push never happened is carried by the
      # next push, though publishing it again would add nothing.
      check publishCertificateToLocalStore(signedCertFor(fx.sf,
        "git-tree-sha1:" & fx.tree(commit), commit, platform = "linux/third"),
        fx.app).written
      let local = tcnotes.publishNotes(fx.app, tcroots.nativeRoots(), [commit])
      check local.ok
      check fx.records(fx.tree(commit)) == 2
      check fx.push(@["--no-certify"]).code == 0
      check fx.records(fx.tree(commit)) == 3

  test "a new branch at a reachable commit gets through a required gateway":
    guarded:
      let fx = setupPush("push-new-branch", "required")
      defer: removeDir(fx.sf.scratch)
      let commit = fx.certifyThenCommit("unit branch\n", "certified")
      # §4.2's exclusion for a new branch: a remote-tracking ref reaches it, as
      # after a fetch of a branch since deleted. The remote does not have it.
      discard fx.git("update-ref refs/remotes/origin/elsewhere " & commit)
      discard fx.git("switch -q -c topic")
      let pushed = fx.push()
      check pushed.code == 0
      check gitOut(fx.sf.upstreamBare, "rev-parse", "refs/heads/topic") == commit
      check fx.records(fx.tree(commit)) == 1

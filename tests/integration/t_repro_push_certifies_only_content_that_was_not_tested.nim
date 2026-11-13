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
## Most cases that wire a gateway have one repository. The closure and cycle
## cases that are about the client side run without a gateway. One suite pushes
## a closure lib-c -> lib-b -> lib-a with every member behind its own gateway
## under `required`, in ONE `repro push`. Each member is certified at its
## turn without its lock changing, each gateway finds the certificate in the
## pushed notes, and `repro push` shows each gateway's report under its
## member, including the siblings the public lock gate did not verify
## server-side. A member pushed without its certificate is refused by its
## gateway; a member whose test fails stops the run before its dependents,
## and what was already published stays published.
##
## Another suite pushes a dependency cycle lib-a <-> lib-b with new commits in
## both, each member behind its own gateway, in ONE `repro push`, under
## `required` and under `advisory`. Issuance accepts the unpublished peer whose
## commit the tested lock pins; the member whose lock keeps the peer's older,
## published commit is decided before anything runs; the member pinning its
## peer's new commit is pushed after that peer; a test failure in either
## member publishes neither. `repro certify` on a cycle member accepts its
## peer, and still refuses an unpublished dependency outside the cycle.
## Issuance accepts a peer only at the commit the lock records for that peer,
## in its `repro.lock` entry or a `flake.lock` input bound to it: one at a
## commit the lock records for another entry or input is refused. A member
## certified against its pins has the submodules the user initialized, nested
## ones included, at the committed commits, populated from the user's
## checkouts with nothing fetched; one the user did not initialize stays empty.
##
## The rule's ``commit_gate`` is ``off``: with the default, the pre-commit gate
## refuses an uncovered commit, so the states under test could not be committed
## with hooks on. ``advisory`` is the other way to arrive at them, and has a case
## of its own.

import std/[posix, sequtils, streams, strtabs, unittest]

import repro_test_support/reasoned_skip
from repro_tool_profiles import tpmPathOnly

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

  ## case can tell that a test ran. An input starting with FAIL makes it fail;
  ## one starting with SLOW takes two minutes, long enough to interrupt.
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
case "$(head -c 4 "$input")" in
  FAIL) echo "$input says FAIL" >&2; exit 1 ;;
  SLOW) sleep 120 ;;
esac
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

proc setupPush(slug: string; mode: string; recordStore = false;
               gateway = true): PushFixture =
  result.sf = setupStoreFixture("", slug, recordStore = recordStore)
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
  if gateway:
    if recordStore:
      wireStoreGateway(result.sf)
    else:
      # A committed-lock project: the gateway reads the lock out of the pushed
      # tree.
      let wired = wirePushGateway("git", app, result.sf.gatewayBare,
        fileUrl(result.sf.upstreamBare), GatewayConfig(
          registeredKeysPath: registeredKeyStorePath(result.sf.workspaceRoot)))
      doAssert wired.ok, wired.diagnostic
  installHooks(result.sf)
  if recordStore:
    # A store the gate can publish to, with the hook repro push preflights for.
    let lockStore = result.sf.workspaceRoot / ".repro" / "manifests"
    let lockBare = result.sf.scratch / "locks.git"
    discard gitOut(result.sf.scratch, "init", "-q", "--bare", "-b", "main", lockBare)
    discard gitOut(lockStore, "remote", "add", "origin", lockBare)
    discard gitOut(lockStore, "push", "-q", "-u", "origin", "main")
    writeFile(result.sf.workspaceRoot / "repro-workspace.toml",
      "schema = \"reprobuild.workspace.settings.v1\"\n\n[records]\nurl = \"" &
      fileUrl(lockBare) & "\"\npublish_locks = true\n")
    let hooks = runArgv(@[result.sf.reproBin, "hooks", "ensure", "--vcs", lockStore],
      env = @[(name: "REPROBUILD_REPRO", value: result.sf.reproBin)])
    doAssert hooks.code == 0, hooks.output

proc moveUpstream(fx: PushFixture; file, body: string): string =
  ## Someone else's commit reaching the upstream directly, as if merged there.
  let other = fx.sf.scratch / ("other-" & $getCurrentProcessId())
  discard gitOut(fx.sf.scratch, "clone", "-q", fileUrl(fx.sf.upstreamBare), other)
  discard gitOut(other, "config", "user.email", "other@example.invalid")
  discard gitOut(other, "config", "user.name", "Someone Else")
  writeFile(other / file, body)
  discard gitOut(other, "add", "-A")
  discard gitOut(other, "commit", "-q", "-m", "their change")
  result = gitOut(other, "rev-parse", "HEAD")
  discard gitOut(other, "push", "-q", "origin", "HEAD:main")
  removeDir(other)

type Sibling = object
  path, bare: string

proc addSibling(fx: PushFixture; name: string; cycle: bool): Sibling =
  ## A second repository lib-a depends on, with the same recipe and policy. With
  ## ``cycle`` it depends on lib-a too. Its own policy, its own bare, no gateway:
  ## these cases are about the client side.
  let ws = fx.sf.workspaceRoot
  result.bare = fx.sf.scratch / ("upstream-" & name & ".git")
  result.path = ws / name
  discard gitOut(fx.sf.scratch, "clone", "-q", "--bare", fx.sf.upstreamBare,
    result.bare)
  discard gitOut(fx.sf.scratch, "clone", "-q", fileUrl(result.bare), result.path)
  discard gitOut(result.path, "config", "user.email", "tester@example.invalid")
  discard gitOut(result.path, "config", "user.name", "TC8c Tester")
  writeFile(ws / "repos" / (name & ".toml"),
    "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\nname = \"" & name &
    "\"\npath = \"" & name & "\"\nremote = \"" & name & "-origin\"\n" &
    "mainline = \"main\"\n" &
    (if cycle: "depends = [\"lib-a\"]\n" else: ""))
  writeFile(ws / "repos" / "lib-a.toml", storeLibAFragment &
    "depends = [\"" & name & "\"]\n")
  writeFile(ws / "projects" / "lib-a.toml",
    "schema = \"reprobuild.workspace.project.v1\"\n\n[project]\nname = \"lib-a\"\n\n" &
    "[[remote]]\nname = \"lib-a-origin\"\nfetch = \"" &
      fileUrl(fx.sf.upstreamBare) & "\"\n\n" &
    "[[remote]]\nname = \"" & name & "-origin\"\nfetch = \"" &
      fileUrl(result.bare) & "\"\n\n" &
    "includes = [\n  \"repos/lib-a.toml\",\n  \"repos/" & name & ".toml\",\n]\n")
  let hooks = runArgv(@[fx.sf.reproBin, "hooks", "ensure", "--vcs", result.path],
    env = @[(name: "REPROBUILD_REPRO", value: fx.sf.reproBin)])
  doAssert hooks.code == 0, hooks.output

proc commitIn(fx: PushFixture; sibling: Sibling; body, message: string): string =
  writeFile(sibling.path / "src" / "unit.txt", body)
  discard gitOut(sibling.path, "add", "-A")
  discard gitOut(sibling.path, "commit", "-q", "-m", message)
  gitOut(sibling.path, "rev-parse", "HEAD")

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
      check "stage=certify\n" in (refused.output & "\n")
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
      check "stage=certify\n" in (moved.output & "\n")
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

  test "advisory: a long branch of uncertified commits is reported, not refused":
    guarded:
      let fx = setupPush("push-long-advisory", "advisory")
      defer: removeDir(fx.sf.scratch)
      let ran = fx.runs()
      var older: seq[string]
      for i in 1 .. 8:
        older.add(fx.commitEdit("unit step " & $i & "\n", "step " & $i))
      let tip = fx.commitEdit("unit tip\n", "the tip")
      let pushed = fx.push()
      check pushed.code == 0
      check upstreamTip(fx.sf) == tip
      # Only the tip is the worktree's content, so only the tip is tested.
      check fx.runs() == ran + 1
      check "certified: t-unit" in pushed.output
      check "stage=certify" notin pushed.output
      # Newest first, five by name, and the rest counted: no wall of text.
      check older[^1][0 ..< 12] & " lacks" in pushed.output
      check older[0][0 ..< 12] & " lacks" notin pushed.output
      check "and 3 more commit(s) this push introduces are not covered" in
        pushed.output

  test "advisory: a failing test stops the push and names the way past it":
    guarded:
      let fx = setupPush("push-advisory-failing", "advisory")
      defer: removeDir(fx.sf.scratch)
      let tip = upstreamTip(fx.sf)
      let failing = fx.commitEdit("FAIL on purpose\n", "breaks the test")
      let refused = fx.push()
      check refused.code == 2
      check "stage=certify\n" in (refused.output & "\n")
      check "'repro push --no-certify' pushes without it" in refused.output
      check upstreamTip(fx.sf) == tip
      check fx.push(@["--no-certify"]).code == 0
      check upstreamTip(fx.sf) == failing

  test "required: a name only another platform can produce refuses, running nothing":
    guarded:
      let fx = setupPush("push-required-elsewhere", "required")
      defer: removeDir(fx.sf.scratch)
      let tip = upstreamTip(fx.sf)
      let ran = fx.runs()
      writeFile(fx.app / "policy" / "team_policy.nim",
        policyModule("required", "linux/second"))
      let refreshed = fx.repro(@["lock", "refresh"])
      check refreshed.code == 0
      discard fx.commitEdit("unit elsewhere\n", "asks for another platform")
      let refused = fx.push()
      check refused.code == 2
      check "stage=certify-preflight" in refused.output
      check "linux/second" in refused.output
      check fx.runs() == ran
      check upstreamTip(fx.sf) == tip

  test "required: what a merge of the mainline brought along is not judged":
    guarded:
      let fx = setupPush("push-merge-mainline", "required")
      defer: removeDir(fx.sf.scratch)
      # A topic branch the remote already has.
      fx.certify()
      discard fx.git("switch -q -c topic")
      check fx.push(@["--no-certify"]).code == 0

      # The mainline moves on, with an intermediate state no store here covers.
      discard fx.git("switch -q main")
      let intermediate = fx.commitEdit("unit mainline one\n", "someone's step")
      let mainTip = fx.certifyThenCommit("unit mainline two\n", "someone's tip")
      check fx.push(@["--no-certify"]).code == 0
      check upstreamTip(fx.sf) == mainTip

      # Catching up by merging it. §4.2 lists the intermediate commit as
      # introduced to topic, and refusing it would stop every such branch, with a
      # remedy nobody can act on: test other people's history, one commit at a time.
      discard fx.git("switch -q topic")
      discard fx.certifyThenCommit("unit topic\n", "own work")
      discard fx.git("merge -q --no-edit -X ours main")
      let merged = fx.git("rev-parse HEAD")
      let pushed = fx.push()
      check pushed.code == 0
      check intermediate[0 ..< 12] notin pushed.output
      check gitOut(fx.sf.upstreamBare, "rev-parse", "refs/heads/topic") == merged

  test "--sync: a merge it makes is new content, and is certified":
    guarded:
      let fx = setupPush("push-sync-merge", "required")
      defer: removeDir(fx.sf.scratch)
      let theirs = fx.moveUpstream("other.txt", "their change\n")
      let mine = fx.certifyThenCommit("unit mine\n", "certified before the sync")
      let pushed = fx.push(@["--sync", "--merge"])
      check pushed.code == 0
      let merged = upstreamTip(fx.sf)
      check merged == fx.git("rev-parse HEAD")
      check merged != mine
      check gitOut(fx.sf.upstreamBare, "merge-base", "--is-ancestor", theirs,
        merged).len == 0
      # The merge's tree had no certificate: it gets its own. The test command need
      # not run again, since the merge left its input alone and the run is incremental.
      check "certified: t-unit" in pushed.output
      check fx.records(fx.tree(merged)) == 1
      check fx.records(fx.tree(mine)) == 1

  test "--sync --rebase: rewritten older commits follow the mode":
    guarded:
      # ---- required: each rewritten commit is new content the remote lacks ----
      let fx = setupPush("push-sync-rebase", "required")
      defer: removeDir(fx.sf.scratch)
      let before = upstreamTip(fx.sf)
      discard fx.certifyThenCommit("unit one\n", "first")
      discard fx.certifyThenCommit("unit two\n", "second")
      let theirs = fx.moveUpstream("other.txt", "their change\n")
      let ran = fx.runs()
      let refused = fx.push(@["--sync", "--rebase"])
      check refused.code == 2
      check "stage=certify-preflight" in refused.output
      check "(first)" in refused.output
      check "--no-certify" in refused.output
      check fx.runs() == ran
      check upstreamTip(fx.sf) == theirs
      check before != theirs

      # The exit it names: certify the tip here, and leave the rest to the gates.
      fx.certify()
      let landed = fx.push(@["--no-certify"])
      check landed.code == 0
      check upstreamTip(fx.sf) == fx.git("rev-parse HEAD")

      # ---- advisory: the same history is reported and pushed ------------------
      let adv = setupPush("push-sync-rebase-adv", "advisory")
      defer: removeDir(adv.sf.scratch)
      discard adv.certifyThenCommit("unit one\n", "first")
      discard adv.certifyThenCommit("unit two\n", "second")
      discard adv.moveUpstream("other.txt", "their change\n")
      let pushed = adv.push(@["--sync", "--rebase"])
      check pushed.code == 0
      check "certified: t-unit" in pushed.output
      check "lacks" in pushed.output
      check upstreamTip(adv.sf) == adv.git("rev-parse HEAD")

  test "a remote with two push URLs gets the source and the certificate at both":
    guarded:
      let fx = setupPush("push-two-urls", "required")
      defer: removeDir(fx.sf.scratch)
      # A second destination holding what the first one holds, then pushurls for
      # both, so each URL gets a hook run of its own.
      let second = fx.sf.scratch / "second.git"
      discard gitOut(fx.sf.scratch, "clone", "--bare", fx.sf.upstreamBare, second)
      discard fx.git("config --unset-all remote.origin.pushurl")
      discard fx.git("remote set-url --add --push origin " &
        quoteShell(fileUrl(fx.sf.upstreamBare)))
      discard fx.git("remote set-url --add --push origin " &
        quoteShell(fileUrl(second)))

      let commit = fx.certifyThenCommit("unit both\n", "certified")
      let ran = fx.runs()
      let pushed = fx.push()
      check pushed.code == 0
      check fx.runs() == ran
      for bare in [fx.sf.upstreamBare, second]:
        check gitOut(bare, "rev-parse", "refs/heads/main") == commit
        check noteOnRemote(bare, fx.tree(commit)).count(
          "# --- test-certificate ---") == 1

      # Published at both: a later certificate is carried to both.
      check publishCertificateToLocalStore(signedCertFor(fx.sf,
        "git-tree-sha1:" & fx.tree(commit), commit, platform = "linux/second"),
        fx.app).written
      let again = fx.push()
      check again.code == 0
      check "already-published" in again.output
      for bare in [fx.sf.upstreamBare, second]:
        check noteOnRemote(bare, fx.tree(commit)).count(
          "# --- test-certificate ---") == 2

  test "a record-store project is judged and certified without its lock in the tree":
    guarded:
      let fx = setupPush("push-record-store", "required", recordStore = true)
      defer: removeDir(fx.sf.scratch)
      let ran = fx.runs()
      let covered = fx.certifyThenCommit("unit stored\n", "certified")
      let afterCertify = fx.runs()
      check afterCertify == ran + 1
      let lookup = fx.push()
      checkpoint(lookup.output)
      check lookup.code == 0
      check fx.runs() == afterCertify
      check upstreamTip(fx.sf) == covered
      check fx.records(fx.tree(covered)) == 1

      let untested = fx.commitEdit("unit stored two\n", "not tested yet")
      let certifying = fx.push()
      checkpoint(certifying.output)
      check certifying.code == 0
      check fx.runs() == afterCertify + 1
      check upstreamTip(fx.sf) == untested
      check fx.records(fx.tree(untested)) == 1

  test "a failing test stops at its member, with the dependency already published":
    guarded:
      let fx = setupPush("push-closure", "required", gateway = false)
      defer: removeDir(fx.sf.scratch)
      let dep = fx.addSibling("lib-b", cycle = false)
      installHooks(fx.sf)
      let depTip = fx.commitIn(dep, "unit dep\n", "dep, not tested yet")
      let before = upstreamTip(fx.sf)
      let failing = fx.commitEdit("FAIL on purpose\n", "breaks the test")

      let stopped = fx.push()
      check stopped.code == 2
      check "stage=certify\n" in (stopped.output & "\n")
      check "stopped repo=lib-a" in stopped.output
      # Resumable, not atomic: the dependency's refs stay, and are reported.
      check "(lib-b) → pushed" in stopped.output
      check "retry: repro push" in stopped.output
      check gitOut(dep.bare, "rev-parse", "refs/heads/main") == depTip
      check upstreamTip(fx.sf) == before
      check fx.storedFor(fx.tree(failing)) == 0

      # A fix on top leaves the broken state in what is pushed, so it is named.
      discard fx.commitEdit("unit fixed\n", "fixes the test")
      let onTop = fx.push()
      check onTop.code == 2
      check "stage=certify-preflight" in onTop.output
      check "(breaks the test)" in onTop.output

      # Folded in, the retry finds the dependency published.
      discard fx.git("reset -q --soft HEAD~2")
      discard fx.git("commit -q -m fixed")
      let fixedTip = fx.git("rev-parse HEAD")
      let retried = fx.push()
      checkpoint(retried.output)
      check retried.code == 0
      check "(lib-b) → already-published" in retried.output
      check upstreamTip(fx.sf) == fixedTip

  test "a refusal needing no test run publishes no member of the closure":
    guarded:
      let fx = setupPush("push-closure-preflight", "required", gateway = false)
      defer: removeDir(fx.sf.scratch)
      let dep = fx.addSibling("lib-b", cycle = false)
      installHooks(fx.sf)
      let depBefore = gitOut(dep.bare, "rev-parse", "refs/heads/main")
      discard fx.commitIn(dep, "unit dep\n", "dep, not tested yet")
      let older = fx.commitEdit("unit older\n", "an intermediate state")
      discard fx.certifyThenCommit("unit newest\n", "the certified tip")
      let refused = fx.push()
      check refused.code == 2
      check "stage=certify-preflight" in refused.output
      check older[0 ..< 12] in refused.output
      check gitOut(dep.bare, "rev-parse", "refs/heads/main") == depBefore

proc addGatewayedChain(fx: PushFixture): seq[Sibling] =
  ## lib-a -> lib-b -> lib-c, each with the same recipe and policy, its own
  ## upstream bare and its own gateway. lib-a's gateway is the fixture's.
  let ws = fx.sf.workspaceRoot
  for name in ["lib-b", "lib-c"]:
    var s = Sibling(bare: fx.sf.scratch / ("upstream-" & name & ".git"),
      path: ws / name)
    discard gitOut(fx.sf.scratch, "clone", "-q", "--bare", fx.sf.upstreamBare,
      s.bare)
    discard gitOut(fx.sf.scratch, "clone", "-q", fileUrl(s.bare), s.path)
    discard gitOut(s.path, "config", "user.email", "tester@example.invalid")
    discard gitOut(s.path, "config", "user.name", "Closure Tester")
    let wired = wirePushGateway("git", s.path,
      fx.sf.scratch / ("gateway-" & name & ".git"), fileUrl(s.bare),
      GatewayConfig(
        registeredKeysPath: registeredKeyStorePath(fx.sf.workspaceRoot)))
    doAssert wired.ok, wired.diagnostic
    result.add(s)
  proc fragment(name, depends: string): string =
    "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\nname = \"" & name &
      "\"\npath = \"" & name & "\"\nremote = \"" & name & "-origin\"\n" &
      "mainline = \"main\"\n" &
      (if depends.len > 0: "depends = [\"" & depends & "\"]\n" else: "")
  writeFile(ws / "repos" / "lib-b.toml", fragment("lib-b", "lib-c"))
  writeFile(ws / "repos" / "lib-c.toml", fragment("lib-c", ""))
  writeFile(ws / "repos" / "lib-a.toml", storeLibAFragment &
    "depends = [\"lib-b\"]\n")
  writeFile(ws / "projects" / "lib-a.toml",
    "schema = \"reprobuild.workspace.project.v1\"\n\n[project]\nname = \"lib-a\"\n\n" &
    "[[remote]]\nname = \"lib-a-origin\"\nfetch = \"" &
      fileUrl(fx.sf.upstreamBare) & "\"\n\n" &
    "[[remote]]\nname = \"lib-b-origin\"\nfetch = \"" &
      fileUrl(result[0].bare) & "\"\n\n" &
    "[[remote]]\nname = \"lib-c-origin\"\nfetch = \"" &
      fileUrl(result[1].bare) & "\"\n\n" &
    "includes = [\n  \"repos/lib-a.toml\",\n  \"repos/lib-b.toml\",\n" &
    "  \"repos/lib-c.toml\",\n]\n")
  for s in result:
    let hooks = runArgv(@[fx.sf.reproBin, "hooks", "ensure", "--vcs", s.path],
      env = @[(name: "REPROBUILD_REPRO", value: fx.sf.reproBin)])
    doAssert hooks.code == 0, hooks.output

proc gatewayOf(fx: PushFixture; name: string): string =
  if name == "lib-a": fx.sf.gatewayBare
  else: fx.sf.scratch / ("gateway-" & name & ".git")

proc memberReport(output, name: string): string =
  ## What `repro push` printed for closure member ``name``: its outcome line
  ## and the indented lines under it.
  var inside = false
  for line in output.splitLines():
    if line.startsWith("repro push: "):
      inside = line.startsWith("repro push: " & name & " (" & name & ") → ")
      if inside: result.add(line & "\n")
    elif inside and line.startsWith("    "):
      result.add(line & "\n")
    elif inside:
      inside = false

proc chainWithUntestedWork(fx: PushFixture): tuple[b, c: Sibling] =
  ## The chain, with an untested, unpublished commit in every member. Each
  ## commit's managed pre-commit hook pins its sibling's new commit, so lib-a's
  ## lock pins two commits that neither lib-a's gateway nor any upstream has.
  let chain = fx.addGatewayedChain()
  result = (b: chain[0], c: chain[1])
  installHooks(fx.sf)
  discard fx.commitIn(result.c, "unit c\n", "lib-c, not tested yet")

suite "repro push publishes a certified closure through every member's gateway":
  test "required: one run certifies and publishes the closure, each gateway " &
      "reports its member covered and names the siblings it did not verify":
    guarded:
      let fx = setupPush("push-closure-gateways", "required")
      defer: removeDir(fx.sf.scratch)
      let (libB, libC) = fx.chainWithUntestedWork()
      let cTip = gitOut(libC.path, "rev-parse", "HEAD")
      let bTip = fx.commitIn(libB, "unit b\n", "lib-b, not tested yet")
      let aTip = fx.commitEdit("unit a\n", "lib-a, not tested yet")
      let aLock = fx.git("show " & aTip & ":repro.lock")
      checkpoint("lib-a's committed lock:\n" & aLock)
      check bTip in aLock
      check cTip in aLock
      check cTip in gitOut(libB.path, "show", bTip & ":repro.lock")
      for (path, tip) in [(libC.path, cTip), (libB.path, bTip), (fx.app, aTip)]:
        check fx.storedFor(gitOut(path, "rev-parse", tip & "^{tree}")) == 0

      # ---- one repro push: certify, publish, dependency first ------------
      # Each member is certified at its turn, after what it pins has been
      # published by this same run, and certifying it changes nothing in its
      # tree: the pins its lock recorded before the push are the pins it
      # records after.
      let pushed = fx.push()
      checkpoint("repro push:\n" & pushed.output)
      check pushed.code == 0
      check "push order: lib-c → lib-b → lib-a" in pushed.output
      check "certifying changed the working tree" notin pushed.output
      check "locked-integrity-mismatch" notin pushed.output
      # Nothing was rewritten: the commits pushed are the commits made.
      check gitOut(libC.path, "rev-parse", "HEAD") == cTip
      check gitOut(libB.path, "rev-parse", "HEAD") == bTip
      check fx.git("rev-parse HEAD") == aTip
      for (name, path, tip) in [("lib-c", libC.path, cTip),
                                ("lib-b", libB.path, bTip),
                                ("lib-a", fx.app, aTip)]:
        let report = memberReport(pushed.output, name)
        checkpoint(name & "'s report:\n" & report)
        check (name & " (" & name & ") → pushed") in report
        check "certified: t-unit" in report
        # The member's own gateway speaks, under the member it judged.
        check "reprobuild gateway: refs/heads/main: certificate gate: " &
          "COVERED" in report
        check "public-tier lock gate: read repro.lock blob" in report
        let gateway = fx.gatewayOf(name)
        # It accepted the push ...
        check gitOut(gateway, "rev-parse", "refs/heads/main") == tip
        # ... with the notes ref it read, carrying the pushed tree's
        # certificate ...
        check remoteHasNotes(gateway)
        let tree = gitOut(path, "rev-parse", tip & "^{tree}")
        check noteOnRemote(gateway, tree).count("# --- test-certificate ---") >= 1
      # ... and forwarded it upstream.
      check gitOut(libC.bare, "rev-parse", "refs/heads/main") == cTip
      check gitOut(libB.bare, "rev-parse", "refs/heads/main") == bTip
      check upstreamTip(fx.sf) == aTip
      # The boundary statement, per member: each gateway names the siblings
      # its member's lock pins and it did not verify.
      let aReport = memberReport(pushed.output, "lib-a")
      check "'lib-b' NOT verified server-side" in aReport
      check "'lib-c' NOT verified server-side" in aReport
      let bReport = memberReport(pushed.output, "lib-b")
      check "'lib-c' NOT verified server-side" in bReport
      check "'lib-b' NOT verified server-side" notin bReport

      # ---- negative: a member pushed with no certificate -----------------
      # `--no-verify` skips the managed hook, so no note travels; under
      # `required` the gateway refuses, whatever the lock gate thinks.
      let uncovered = fx.commitIn(libC, "unit c2\n", "lib-c, never tested")
      let refused = runArgv(@["git", "-C", libC.path, "push", "--no-verify",
        "origin", "main"], env = @[(name: "REPROBUILD_REPRO",
        value: fx.sf.reproBin)])
      checkpoint("uncovered push:\n" & refused.output)
      check refused.code != 0
      check "push REJECTED" in refused.output
      check "no covering test certificate" in refused.output
      check "COVERED by" notin refused.output
      check gitOut(fx.gatewayOf("lib-c"), "rev-parse", "refs/heads/main") == cTip
      check gitOut(libC.bare, "rev-parse", "refs/heads/main") == cTip
      check uncovered != cTip

  test "required: a member whose test fails stops the run before its " &
      "dependents; what was published stays, and the retry resumes":
    guarded:
      let fx = setupPush("push-closure-gateways-failing", "required")
      defer: removeDir(fx.sf.scratch)
      let (libB, libC) = fx.chainWithUntestedWork()
      let cTip = gitOut(libC.path, "rev-parse", "HEAD")
      let bBefore = gitOut(libB.bare, "rev-parse", "refs/heads/main")
      let aBefore = upstreamTip(fx.sf)
      let failing = fx.commitIn(libB, "FAIL on purpose\n", "lib-b, breaks")
      discard fx.commitEdit("unit a\n", "lib-a, not tested yet")

      let stopped = fx.push()
      checkpoint("repro push:\n" & stopped.output)
      check stopped.code == 2
      check "stopped repo=lib-b stage=certify" in stopped.output
      check "retry: repro push" in stopped.output
      # Resumable, not atomic: lib-c, which lib-b depends on, went through its
      # gateway and stays published ...
      check "(lib-c) → pushed" in stopped.output
      check gitOut(fx.gatewayOf("lib-c"), "rev-parse", "refs/heads/main") == cTip
      check gitOut(libC.bare, "rev-parse", "refs/heads/main") == cTip
      # ... and nothing that depends on the failing member was published.
      check gitOut(libB.bare, "rev-parse", "refs/heads/main") == bBefore
      check upstreamTip(fx.sf) == aBefore
      check execCmdEx(quoteShellCommand(@["git", "-C", fx.gatewayOf("lib-b"),
        "cat-file", "-e", failing & "^{commit}"])).exitCode != 0
      check fx.storedFor(gitOut(libB.path, "rev-parse", failing & "^{tree}")) == 0

      # The fix, folded into lib-b's unpublished commit. lib-a's work is
      # committed again from its published lock, so its hook pins the fixed
      # commit as a forward move.
      writeFile(libB.path / "src" / "unit.txt", "unit b fixed\n")
      discard gitOut(libB.path, "add", "-A")
      discard gitOut(libB.path, "commit", "-q", "--amend", "-m", "lib-b, fixed")
      let bFixed = gitOut(libB.path, "rev-parse", "HEAD")
      discard fx.git("checkout HEAD~1 -- repro.lock")
      discard fx.git("reset -q --soft HEAD~1")
      discard fx.git("commit -q -m " & quoteShell("lib-a, not tested yet"))
      let aFixed = fx.git("rev-parse HEAD")
      check bFixed in fx.git("show " & aFixed & ":repro.lock")

      let retried = fx.push()
      checkpoint("retry:\n" & retried.output)
      check retried.code == 0
      check "(lib-c) → already-published" in retried.output
      check gitOut(libB.bare, "rev-parse", "refs/heads/main") == bFixed
      check upstreamTip(fx.sf) == aFixed

proc addMembers(fx: PushFixture;
                members: openArray[tuple[name: string; depends: seq[string]]];
                libADepends: seq[string]; gateways: bool): seq[Sibling] =
  ## Repositories beside lib-a, each with the same recipe and policy and its own
  ## upstream bare, behind its own gateway when ``gateways``. lib-a depends on
  ## ``libADepends``; a member that depends on lib-a closes a cycle with it.
  let ws = fx.sf.workspaceRoot
  proc quoted(names: seq[string]): string =
    names.mapIt("\"" & it & "\"").join(", ")
  var remotes = "[[remote]]\nname = \"lib-a-origin\"\nfetch = \"" &
    fileUrl(fx.sf.upstreamBare) & "\"\n\n"
  var includes = "  \"repos/lib-a.toml\",\n"
  for member in members:
    var s = Sibling(bare: fx.sf.scratch / ("upstream-" & member.name & ".git"),
      path: ws / member.name)
    discard gitOut(fx.sf.scratch, "clone", "-q", "--bare", fx.sf.upstreamBare,
      s.bare)
    discard gitOut(fx.sf.scratch, "clone", "-q", fileUrl(s.bare), s.path)
    discard gitOut(s.path, "config", "user.email", "tester@example.invalid")
    discard gitOut(s.path, "config", "user.name", "Cycle Tester")
    if gateways:
      let wired = wirePushGateway("git", s.path,
        fx.sf.scratch / ("gateway-" & member.name & ".git"), fileUrl(s.bare),
        GatewayConfig(
          registeredKeysPath: registeredKeyStorePath(fx.sf.workspaceRoot)))
      doAssert wired.ok, wired.diagnostic
    writeFile(ws / "repos" / (member.name & ".toml"),
      "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\nname = \"" &
      member.name & "\"\npath = \"" & member.name & "\"\nremote = \"" &
      member.name & "-origin\"\nmainline = \"main\"\n" &
      (if member.depends.len > 0: "depends = [" & quoted(member.depends) & "]\n"
       else: ""))
    remotes.add("[[remote]]\nname = \"" & member.name & "-origin\"\nfetch = \"" &
      fileUrl(s.bare) & "\"\n\n")
    includes.add("  \"repos/" & member.name & ".toml\",\n")
    result.add(s)
  writeFile(ws / "repos" / "lib-a.toml", storeLibAFragment &
    "depends = [" & quoted(libADepends) & "]\n")
  writeFile(ws / "projects" / "lib-a.toml",
    "schema = \"reprobuild.workspace.project.v1\"\n\n[project]\nname = \"lib-a\"\n\n" &
    remotes & "includes = [\n" & includes & "]\n")
  for s in result:
    let hooks = runArgv(@[fx.sf.reproBin, "hooks", "ensure", "--vcs", s.path],
      env = @[(name: "REPROBUILD_REPRO", value: fx.sf.reproBin)])
    doAssert hooks.code == 0, hooks.output
  installHooks(fx.sf)

proc reproIn(fx: PushFixture; dir: string; args: seq[string]):
    tuple[code: int; output: string] =
  ## ``repro`` run in another member's checkout, with the fixture's key and tools.
  result = runArgv(@[fx.sf.reproBin] & args, dir,
    daemonKeyEnv(fx.sf.daemonKey, storeKeyId) &
    @[(name: "PATH", value: fx.binDir & $PathSep & pathWithoutTool()),
      (name: "REPROBUILD_REPRO", value: fx.sf.reproBin)])
  checkpoint("repro " & args.join(" ") & " in " & dir & ":\n" & result.output)

proc lagFirstCycle(fx: PushFixture; bBody = "unit b\n"):
    tuple[b: Sibling; a0, aTip, bTip: string] =
  ## lib-a <-> lib-b, each behind its own gateway, with a new commit in each.
  ## lib-b is committed first, so its lock keeps lib-a's published commit; lib-a
  ## is committed second, so its lock pins lib-b's new, unpublished commit. Two
  ## locks cannot each name the other's newest commit; this is the shape a
  ## cycle with new work on both sides takes. Neither commit is tested.
  result.b = fx.addMembers([(name: "lib-b", depends: @["lib-a"])], @["lib-b"],
    gateways = true)[0]
  result.a0 = upstreamTip(fx.sf)
  result.bTip = fx.commitIn(result.b, bBody, "lib-b, not tested yet")
  result.aTip = fx.commitEdit("unit a\n", "lib-a, not tested yet")
  let aLock = fx.git("show " & result.aTip & ":repro.lock")
  let lockOfB = gitOut(result.b.path, "show", result.bTip & ":repro.lock")
  checkpoint("lib-a's lock:\n" & aLock & "\nlib-b's lock:\n" & lockOfB)
  doAssert result.bTip in aLock
  doAssert result.a0 in lockOfB and result.aTip notin lockOfB

proc checkPublishedThroughGateway(fx: PushFixture; output, name, path, bare,
                                  tip: string) =
  ## The member went through its own gateway, which reported it covered, read
  ## the certificate for the pushed tree from the notes, and forwarded it.
  let report = memberReport(output, name)
  checkpoint(name & "'s report:\n" & report)
  check (name & " (" & name & ") → pushed") in report
  check "reprobuild gateway: refs/heads/main: certificate gate: COVERED" in report
  let gateway = fx.gatewayOf(name)
  check gitOut(gateway, "rev-parse", "refs/heads/main") == tip
  check remoteHasNotes(gateway)
  let tree = gitOut(path, "rev-parse", tip & "^{tree}")
  check noteOnRemote(gateway, tree).count("# --- test-certificate ---") >= 1
  check gitOut(bare, "rev-parse", "refs/heads/main") == tip

proc checkoutState(path: string): string =
  ## What a push must leave as it found it: HEAD, the branch, and the worktrees
  ## registered in the repository.
  gitOut(path, "rev-parse", "HEAD") & "\n" &
    gitOut(path, "symbolic-ref", "-q", "HEAD") & "\n" &
    gitOut(path, "worktree", "list", "--porcelain")

proc isolatedScratchDirs(fx: PushFixture): seq[string] =
  ## Temporary workspaces a push of THIS fixture certified in and left
  ## behind. The test runner runs the cases of this file in parallel under
  ## one TMPDIR, so a ``repro-push-pins-*`` directory there may be another
  ## case's push, running now. A workspace is this fixture's when one of its
  ## members is a ``git clone --shared`` of a repository under the fixture's
  ## scratch directory (its alternates name that repository's objects).
  ## A private TMPDIR per case would also separate them, but it leaves each
  ## push without the temp-dir caches the suite shares (the interface
  ## extraction cache), and the interrupted case's push then needs longer
  ## than its two minutes to reach lib-b's test.
  for kind, path in walkDir(getTempDir()):
    if kind != pcDir or not extractFilename(path).startsWith("repro-push-pins-"):
      continue
    for mk, member in walkDir(path / "workspace"):
      let alternates = member / ".git" / "objects" / "info" / "alternates"
      if fileExists(alternates) and
          fx.sf.scratch in (try: readFile(alternates) except IOError: ""):
        result.add(path)
        break

proc announcedScratchDirs(output: string): seq[string] =
  ## The temporary workspaces a push said it certified in ("in temporary
  ## worktrees under <dir> (your checkouts are not touched)").
  const Head = "in temporary worktrees under "
  for line in output.splitLines():
    let at = line.find(Head)
    if at < 0: continue
    let rest = line[at + Head.len .. ^1]
    let stop = rest.find(" (")
    result.add(if stop < 0: rest.strip() else: rest[0 ..< stop])

template checkScratchRemoved(fx: PushFixture; output: string;
                             scratchBefore: seq[string]) =
  ## The push removed every temporary workspace it worked in: none of this
  ## fixture's is left, and each one it announced is gone.
  check isolatedScratchDirs(fx) == scratchBefore
  for dir in announcedScratchDirs(output):
    checkpoint("announced temporary workspace: " & dir)
    check not dirExists(dir)

suite "repro push publishes a certified dependency cycle through every member's gateway":
  test "required: one run certifies and publishes a cycle with new commits in " &
      "both members, each through its own gateway":
    guarded:
      let fx = setupPush("push-cycle-required", "required")
      defer: removeDir(fx.sf.scratch)
      let (libB, a0, aTip, bTip) = fx.lagFirstCycle()
      let before = (a: checkoutState(fx.app), b: checkoutState(libB.path))
      let scratchBefore = isolatedScratchDirs(fx)

      # ---- one repro push from a fully untested state. lib-b's commit names
      # lib-a's published commit while lib-a's checkout is past it, so lib-b is
      # certified against that commit in temporary worktrees. lib-a is
      # certified here, against lib-b's unpublished commit, which its lock pins
      # exactly. lib-b is pushed first, since lib-a's lock names its new commit.
      let pushed = fx.push()
      checkpoint("repro push:\n" & pushed.output)
      check pushed.code == 0
      check "push order: lib-b → lib-a" in pushed.output
      check "dependency has unpushed commits" notin pushed.output
      check "source-component-unpublished-pin" notin pushed.output
      check "certifying changed the working tree" notin pushed.output
      let bReport = memberReport(pushed.output, "lib-b")
      check "certified: t-unit" in bReport
      check "certified against 'lib-a' at its pinned commit " & a0 in bReport
      check "certified: t-unit" in memberReport(pushed.output, "lib-a")
      check "certified against" notin memberReport(pushed.output, "lib-a")
      # The user's checkouts were never touched, and nothing is left behind.
      check checkoutState(fx.app) == before.a
      check checkoutState(libB.path) == before.b
      check gitOut(libB.path, "status", "--porcelain").len == 0
      check fx.git("status --porcelain").len == 0
      fx.checkScratchRemoved(pushed.output, scratchBefore)
      check gitOut(libB.path, "rev-parse", "HEAD") == bTip
      check fx.git("rev-parse HEAD") == aTip
      fx.checkPublishedThroughGateway(pushed.output, "lib-b", libB.path,
        libB.bare, bTip)
      fx.checkPublishedThroughGateway(pushed.output, "lib-a", fx.app,
        fx.sf.upstreamBare, aTip)

  test "advisory: one run certifies and publishes a cycle with new commits in " &
      "both members":
    guarded:
      let fx = setupPush("push-cycle-advisory", "advisory")
      defer: removeDir(fx.sf.scratch)
      let (libB, a0, aTip, bTip) = fx.lagFirstCycle()
      let pushed = fx.push()
      checkpoint("repro push:\n" & pushed.output)
      check pushed.code == 0
      check "push order: lib-b → lib-a" in pushed.output
      check "source-component-unpublished-pin" notin pushed.output
      check "dependency has unpushed commits" notin pushed.output
      check "certified against 'lib-a' at its pinned commit " & a0 in
        memberReport(pushed.output, "lib-b")
      fx.checkPublishedThroughGateway(pushed.output, "lib-b", libB.path,
        libB.bare, bTip)
      fx.checkPublishedThroughGateway(pushed.output, "lib-a", fx.app,
        fx.sf.upstreamBare, aTip)

  test "required: a sibling already at the commit the lagging member's lock " &
      "pins is mirrored into the temporary workspace, not cloned":
    guarded:
      # lib-c, a published dependency of lib-b outside the cycle, is at the
      # commit lib-b's lock pins, so the temporary workspace links the user's
      # checkout of it. The test must run against it there without the lock
      # code seeing another path or revision for it (it would re-pin, and the
      # certification would refuse a changed working tree).
      let fx = setupPush("push-cycle-shared-sibling", "required")
      defer: removeDir(fx.sf.scratch)
      let members = fx.addMembers([(name: "lib-b", depends: @["lib-a", "lib-c"]),
        (name: "lib-c", depends: newSeq[string]())], @["lib-b"],
        gateways = true)
      let (libB, libC) = (members[0], members[1])
      # Someone else's commit on lib-c's upstream, so that its pin names lib-c
      # alone (the fixture's repositories share their first commits).
      let other = fx.sf.scratch / "other-lib-c"
      discard gitOut(fx.sf.scratch, "clone", "-q", fileUrl(libC.bare), other)
      discard gitOut(other, "config", "user.email", "other@example.invalid")
      discard gitOut(other, "config", "user.name", "Someone Else")
      writeFile(other / "notes.txt", "lib-c\n")
      discard gitOut(other, "add", "-A")
      discard gitOut(other, "commit", "-q", "-m", "lib-c, published")
      let cTip = gitOut(other, "rev-parse", "HEAD")
      discard gitOut(other, "push", "-q", "origin", "HEAD:main")
      discard gitOut(libC.path, "fetch", "-q", "origin")
      discard gitOut(libC.path, "merge", "-q", "--ff-only", "origin/main")
      let a0 = upstreamTip(fx.sf)
      let bTip = fx.commitIn(libB, "unit b\n", "lib-b, not tested yet")
      let aTip = fx.commitEdit("unit a\n", "lib-a, not tested yet")
      let lockOfB = gitOut(libB.path, "show", bTip & ":repro.lock")
      checkpoint("lib-b's lock:\n" & lockOfB)
      doAssert a0 in lockOfB and cTip in lockOfB and aTip notin lockOfB
      let cBefore = checkoutState(libC.path)
      let scratchBefore = isolatedScratchDirs(fx)

      let pushed = fx.push()
      checkpoint("repro push:\n" & pushed.output)
      check pushed.code == 0
      check "certifying changed the working tree" notin pushed.output
      let bReport = memberReport(pushed.output, "lib-b")
      check "certified: t-unit" in bReport
      check "certified against 'lib-a' at its pinned commit " & a0 in bReport
      check "'lib-c' at" notin pushed.output
      check checkoutState(libC.path) == cBefore
      check gitOut(libC.path, "status", "--porcelain").len == 0
      fx.checkScratchRemoved(pushed.output, scratchBefore)
      fx.checkPublishedThroughGateway(pushed.output, "lib-b", libB.path,
        libB.bare, bTip)
      fx.checkPublishedThroughGateway(pushed.output, "lib-a", fx.app,
        fx.sf.upstreamBare, aTip)

  test "required: a member certified against its pins whose test fails stops " &
      "the run, publishes nothing and leaves the checkouts as they were":
    guarded:
      let fx = setupPush("push-cycle-isolated-failing", "required")
      defer: removeDir(fx.sf.scratch)
      let (libB, a0, aTip, bTip) = fx.lagFirstCycle("FAIL on purpose\n")
      let before = (a: checkoutState(fx.app), b: checkoutState(libB.path))
      let bBefore = gitOut(libB.bare, "rev-parse", "refs/heads/main")
      let scratchBefore = isolatedScratchDirs(fx)
      let stopped = fx.push()
      checkpoint("repro push:\n" & stopped.output)
      check stopped.code == 2
      check "stopped repo=lib-b stage=certify" in stopped.output
      check "against 'lib-a' at " & a0[0 ..< 12] in stopped.output
      check "this run pushed no member of the dependency cycle" in stopped.output
      check checkoutState(fx.app) == before.a
      check checkoutState(libB.path) == before.b
      fx.checkScratchRemoved(stopped.output, scratchBefore)
      check gitOut(libB.bare, "rev-parse", "refs/heads/main") == bBefore
      check upstreamTip(fx.sf) == a0
      for (name, commit) in [("lib-b", bTip), ("lib-a", aTip)]:
        check execCmdEx(quoteShellCommand(@["git", "-C", fx.gatewayOf(name),
          "cat-file", "-e", commit & "^{commit}"])).exitCode != 0
      check fx.storedFor(gitOut(libB.path, "rev-parse", bTip & "^{tree}")) == 0

  test "required: a cycle member whose test fails stops the run before any " &
      "member of the cycle is published, and the retry publishes both":
    guarded:
      let fx = setupPush("push-cycle-failing", "required")
      defer: removeDir(fx.sf.scratch)
      let libB = fx.addMembers([(name: "lib-b", depends: @["lib-a"])],
        @["lib-b"], gateways = true)[0]
      let aBefore = upstreamTip(fx.sf)
      let bBefore = gitOut(libB.bare, "rev-parse", "refs/heads/main")
      # lib-b: test, then commit, against lib-a's published commit.
      writeFile(libB.path / "src" / "unit.txt", "unit b\n")
      check fx.reproIn(libB.path, @["certify", "t-unit",
        "--tool-provisioning=path"]).code == 0
      discard gitOut(libB.path, "add", "-A")
      discard gitOut(libB.path, "commit", "-q", "-m", "lib-b, tested")
      let bTip = gitOut(libB.path, "rev-parse", "HEAD")
      let failing = fx.commitEdit("FAIL on purpose\n", "lib-a, breaks")
      check bTip in fx.git("show " & failing & ":repro.lock")

      let stopped = fx.push()
      checkpoint("repro push:\n" & stopped.output)
      check stopped.code == 2
      check "stopped repo=lib-a stage=certify" in stopped.output
      check "this run pushed no member of the dependency cycle" in stopped.output
      check "retry: repro push" in stopped.output
      # lib-b would be transported first, and is not: the cycle's members are
      # certified before the first of them is pushed.
      check "(lib-b) → pushed" notin stopped.output
      for (name, commit) in [("lib-b", bTip), ("lib-a", failing)]:
        check execCmdEx(quoteShellCommand(@["git", "-C", fx.gatewayOf(name),
          "cat-file", "-e", commit & "^{commit}"])).exitCode != 0
      check gitOut(libB.bare, "rev-parse", "refs/heads/main") == bBefore
      check upstreamTip(fx.sf) == aBefore
      check fx.storedFor(fx.tree(failing)) == 0

      # The fix, folded into lib-a's commit; its lock still pins lib-b's.
      writeFile(fx.app / "src" / "unit.txt", "unit a fixed\n")
      discard fx.git("add -A")
      discard fx.git("commit -q --amend -m " & quoteShell("lib-a, fixed"))
      let aFixed = fx.git("rev-parse HEAD")
      let retried = fx.push()
      checkpoint("retry:\n" & retried.output)
      check retried.code == 0
      check "push order: lib-b → lib-a" in retried.output
      fx.checkPublishedThroughGateway(retried.output, "lib-b", libB.path,
        libB.bare, bTip)
      fx.checkPublishedThroughGateway(retried.output, "lib-a", fx.app,
        fx.sf.upstreamBare, aFixed)

  test "'repro certify' on a cycle member accepts its unpublished peer, and " &
      "still refuses a dependency outside the cycle with a remedy that works":
    guarded:
      let fx = setupPush("certify-cycle-member", "required", gateway = false)
      defer: removeDir(fx.sf.scratch)
      # lib-a <-> lib-b is a cycle; lib-c is an ordinary dependency of lib-a.
      let members = fx.addMembers([(name: "lib-b", depends: @["lib-a"]),
        (name: "lib-c", depends: newSeq[string]())], @["lib-b", "lib-c"],
        gateways = false)
      let (libB, libC) = (members[0], members[1])
      let bBefore = gitOut(libB.bare, "rev-parse", "refs/heads/main")
      let cTip = fx.commitIn(libC, "unit c\n", "lib-c, not published")
      let bTip = fx.commitIn(libB, "unit b\n", "lib-b, not published")
      writeFile(fx.app / "src" / "unit.txt", "unit a\n")

      let refused = fx.repro(@["certify", "t-unit", "--tool-provisioning=path"])
      check refused.code == 0
      check "issued test-certificate" notin refused.output
      check "no certificate — dependency has unpushed commits (lib-c)" in
        refused.output
      check "publish it first: run 'repro push' in lib-c" in refused.output
      check "(lib-b)" notin refused.output

      # The remedy, as printed.
      let published = fx.reproIn(libC.path, @["push", "--tool-provisioning=path"])
      check published.code == 0
      check gitOut(libC.bare, "rev-parse", "refs/heads/main") == cTip

      # lib-b is still unpublished; its commit is the one lib-a's tested lock
      # pins, and it publishes together with lib-a, so issuance accepts it.
      let issued = fx.repro(@["certify", "t-unit", "--tool-provisioning=path"])
      check issued.code == 0
      check "issued test-certificate.v1 for 't-unit'" in issued.output
      check "dependency has unpushed commits" notin issued.output
      check bTip in readFile(fx.app / "repro.lock")
      check gitOut(libB.bare, "rev-parse", "refs/heads/main") == bBefore

  test "a record-store cycle with new commits in both members is certified " &
      "and published by one run":
    guarded:
      # A record-store project's lock is the record the pre-push gate writes,
      # but its tracked repro.lock carries the policy snapshot, and the managed
      # refresh pins every develop-set sibling there too: the cycle takes the
      # same path as a committed-lock one, the lagging member included.
      let fx = setupPush("push-cycle-record-store", "required",
        recordStore = true, gateway = false)
      defer: removeDir(fx.sf.scratch)
      let libB = fx.addMembers([(name: "lib-b", depends: @["lib-a"])],
        @["lib-b"], gateways = false)[0]
      let bTip = fx.commitIn(libB, "unit b\n", "lib-b, not tested yet")
      let aTip = fx.commitEdit("unit a\n", "lib-a, not tested yet")
      checkpoint("lib-a's tracked lock:\n" & fx.git("show " & aTip & ":repro.lock"))
      let pushed = fx.push()
      checkpoint("repro push:\n" & pushed.output)
      check pushed.code == 0
      check "dependency has unpushed commits" notin pushed.output
      check "certified: t-unit" in memberReport(pushed.output, "lib-a")
      check "certified: t-unit" in memberReport(pushed.output, "lib-b")
      check "certified against 'lib-a' at its pinned commit" in
        memberReport(pushed.output, "lib-b")
      check gitOut(libB.bare, "rev-parse", "refs/heads/main") == bTip
      check upstreamTip(fx.sf) == aTip
      check fx.records(fx.tree(aTip)) == 1

  test "an interrupted push removes the temporary checkouts it certified in, " &
      "and leaves the user's checkouts as they were":
    guarded:
      let fx = setupPush("push-cycle-interrupted", "required")
      defer: removeDir(fx.sf.scratch)
      let (libB, a0, _, _) = fx.lagFirstCycle("SLOW, then passes\n")
      let before = (a: checkoutState(fx.app), b: checkoutState(libB.path))
      let bBefore = gitOut(libB.bare, "rev-parse", "refs/heads/main")
      let scratchBefore = isolatedScratchDirs(fx)
      var env = newStringTable(modeCaseSensitive)
      for name, value in envPairs():
        env[name] = value
      for (name, value) in daemonKeyEnv(fx.sf.daemonKey, storeKeyId) &
          @[(name: "PATH", value: fx.binDir & $PathSep & pathWithoutTool()),
            (name: "REPROBUILD_REPRO", value: fx.sf.reproBin)]:
        env[name] = value
      let push = startProcess(fx.sf.reproBin, workingDir = fx.app,
        args = ["push", "--tool-provisioning=path"], env = env,
        options = {poStdErrToStdOut})
      defer: push.close()
      # Interrupt once lib-b's test is running in its temporary checkout.
      var running = false
      for _ in 0 ..< 600:
        for dir in isolatedScratchDirs(fx):
          if dir notin scratchBefore and
              fileExists(dir / "workspace" / "lib-b" / ".repro" / "runs.log"):
            running = true
        if running or not push.running: break
        sleep(200)
      check running
      discard posix.kill(Pid(push.processID), SIGINT)
      let code = push.waitForExit(60_000)
      let transcript = push.outputStream.readAll()
      checkpoint("interrupted push:\n" & transcript)
      # 130, as for any interrupted command; the push reports the interrupt
      # and removes the temporary workspace before it exits.
      check code == 130
      check "interrupted; the temporary workspace was removed" in transcript
      fx.checkScratchRemoved(transcript, scratchBefore)
      check checkoutState(fx.app) == before.a
      check checkoutState(libB.path) == before.b
      check gitOut(libB.path, "status", "--porcelain").len == 0
      check fx.git("status --porcelain").len == 0
      check gitOut(libB.bare, "rev-parse", "refs/heads/main") == bBefore
      check upstreamTip(fx.sf) == a0

proc publishOnly(fx: PushFixture; sibling: Sibling; file, body: string): string =
  ## Someone else's commit on ``sibling``'s upstream, fast-forwarded into its
  ## checkout: published, and a commit no other repository's upstream has.
  let other = fx.sf.scratch / ("other-" & extractFilename(sibling.path))
  discard gitOut(fx.sf.scratch, "clone", "-q", fileUrl(sibling.bare), other)
  discard gitOut(other, "config", "user.email", "other@example.invalid")
  discard gitOut(other, "config", "user.name", "Someone Else")
  writeFile(other / file, body)
  discard gitOut(other, "add", "-A")
  discard gitOut(other, "commit", "-q", "-m", "published elsewhere")
  result = gitOut(other, "rev-parse", "HEAD")
  discard gitOut(other, "push", "-q", "origin", "HEAD:main")
  discard gitOut(sibling.path, "fetch", "-q", "origin")
  discard gitOut(sibling.path, "merge", "-q", "--ff-only", "origin/main")

suite "issuance accepts a cycle peer only at its own pin":
  test "a cycle peer at a commit the tested lock pins for ANOTHER entry is " &
      "refused, with the cycle's remedy":
    guarded:
      let fx = setupPush("issuance-cycle-own-entry", "required", gateway = false)
      defer: removeDir(fx.sf.scratch)
      # lib-a <-> lib-b is a cycle; lib-c is an ordinary, published dependency
      # of lib-a, at a commit only lib-c's upstream has.
      let members = fx.addMembers([(name: "lib-b", depends: @["lib-a"]),
        (name: "lib-c", depends: newSeq[string]())], @["lib-b", "lib-c"],
        gateways = false)
      let (libB, libC) = (members[0], members[1])
      let cTip = fx.publishOnly(libC, "notes.txt", "lib-c\n")
      let bTip = fx.commitIn(libB, "unit b\n", "lib-b, not published")
      writeFile(fx.app / "src" / "unit.txt", "unit a\n")
      let refreshed = fx.repro(@["lock", "refresh"])
      check refreshed.code == 0
      let lock = readFile(fx.app / "repro.lock")
      checkpoint("lib-a's lock:\n" & lock)
      doAssert bTip in lock and cTip in lock

      # Control: lib-b at the commit lib-a's lock records for lib-b is accepted.
      let accepted = evaluateIssuancePreconditions(fx.sf.workspaceRoot, fx.app)
      checkpoint("at its own pin: " & $accepted.kind & " " & accepted.offender &
        ": " & accepted.remedy)
      check accepted.kind == ipOk

      # lib-b's checkout moves, clean, to the commit the lock records for
      # lib-c. It is unpublished in lib-b, and the lock names it, but not for
      # lib-b: lib-a's tests would not have run against the lib-b it names.
      discard gitOut(libB.path, "fetch", "-q", libC.bare, "main")
      discard gitOut(libB.path, "checkout", "-q", "-B", "main", cTip)
      check gitOut(libB.path, "status", "--porcelain").len == 0
      check gitOut(libB.path, "rev-parse", "HEAD") == cTip
      let refused = evaluateIssuancePreconditions(fx.sf.workspaceRoot, fx.app)
      checkpoint("at another entry's pin: " & $refused.kind & " " &
        refused.offender & ": " & refused.remedy)
      check refused.kind == ipUnpublished
      check "lib-b" in refused.offender
      check "is in the same dependency cycle as 'lib-a'" in refused.remedy
      check "its checkout is at " & cTip & ", which the tested lock does not " &
        "pin for it" in refused.remedy

  test "flake.lock: a cycle peer at the commit an input bound to it pins is " &
      "accepted; at the commit another input pins it is refused":
    guarded:
      let fx = setupPush("issuance-cycle-own-flake-input", "required",
        gateway = false)
      defer: removeDir(fx.sf.scratch)
      # lib-a <-> lib-b is a cycle. lib-c is a workspace repository lib-a does
      # not depend on, so its `repro.lock` has no entry for it: only the
      # flake.lock names lib-c's commit, through an input bound to lib-c.
      let members = fx.addMembers([(name: "lib-b", depends: @["lib-a"]),
        (name: "lib-c", depends: newSeq[string]())], @["lib-b"],
        gateways = false)
      let (libB, libC) = (members[0], members[1])
      let cTip = fx.publishOnly(libC, "notes.txt", "lib-c\n")
      let bTip = fx.commitIn(libB, "unit b\n", "lib-b, not published")
      writeFile(fx.app / "src" / "unit.txt", "unit a\n")
      check fx.repro(@["lock", "refresh"]).code == 0
      let lock = readFile(fx.app / "repro.lock")
      checkpoint("lib-a's lock:\n" & lock)
      doAssert bTip in lock and cTip notin lock
      # A second lib-b commit, which only the flake.lock names: its input for
      # lib-b pins it, while repro.lock still pins bTip.
      let zTip = fx.commitIn(libB, "unit b, again\n", "lib-b, flake pin only")
      doAssert zTip notin lock
      proc node(input, bare, rev: string): string =
        "    \"" & input & "\": {\n      \"flake\": false,\n" &
        "      \"locked\": {\n        \"lastModified\": 1787946353,\n" &
        "        \"narHash\": \"sha256-fv2PzTwKsfeBptF8u/G0w9eh6GDsib/62l5cyuKNGYM=\",\n" &
        "        \"rev\": \"" & rev & "\",\n        \"revCount\": 1,\n" &
        "        \"type\": \"git\",\n        \"url\": \"" & fileUrl(bare) &
        "\"\n      },\n      \"original\": {\n        \"ref\": \"main\",\n" &
        "        \"type\": \"git\",\n        \"url\": \"" & fileUrl(bare) &
        "\"\n      }\n    }"
      writeFile(fx.app / "flake.nix", "{\n  inputs = {\n" &
        "    lib-b-src = {\n      url = \"git+" & fileUrl(libB.bare) &
        "?ref=main\";\n      flake = false;\n    };\n" &
        "    lib-c-src = {\n      url = \"git+" & fileUrl(libC.bare) &
        "?ref=main\";\n      flake = false;\n    };\n" &
        "  };\n  outputs = _: { };\n}\n")
      writeFile(fx.app / "flake.lock", "{\n  \"nodes\": {\n" &
        node("lib-b-src", libB.bare, zTip) & ",\n" &
        node("lib-c-src", libC.bare, cTip) & ",\n" &
        "    \"root\": {\n      \"inputs\": {\n" &
        "        \"lib-b-src\": \"lib-b-src\",\n" &
        "        \"lib-c-src\": \"lib-c-src\"\n      }\n    }\n  },\n" &
        "  \"root\": \"root\",\n  \"version\": 7\n}\n")

      # lib-b at the commit the flake input bound to it pins: the cycle
      # exemption accepts it, so what refuses is the stale repro.lock pin, not
      # lib-b's publication.
      check gitOut(libB.path, "rev-parse", "HEAD") == zTip
      let accepted = evaluateIssuancePreconditions(fx.sf.workspaceRoot, fx.app)
      checkpoint("at its own flake pin: " & $accepted.kind & " " &
        accepted.offender & ": " & accepted.remedy)
      check accepted.kind != ipUnpublished
      check "same dependency cycle" notin accepted.remedy

      # lib-b at the commit the flake records for lib-c's input: unpublished
      # in lib-b, named by the flake, but not for lib-b.
      discard gitOut(libB.path, "fetch", "-q", libC.bare, "main")
      discard gitOut(libB.path, "checkout", "-q", "-B", "main", cTip)
      check gitOut(libB.path, "status", "--porcelain").len == 0
      let refused = evaluateIssuancePreconditions(fx.sf.workspaceRoot, fx.app)
      checkpoint("at another input's pin: " & $refused.kind & " " &
        refused.offender & ": " & refused.remedy)
      check refused.kind == ipUnpublished
      check "lib-b" in refused.offender
      check "is in the same dependency cycle as 'lib-a'" in refused.remedy
      check "its checkout is at " & cTip & ", which the tested lock does not " &
        "pin for it" in refused.remedy

const subToolInterface = "import repro_project_dsl\n\n" &
  "defineCliInterface subTool, \"sub-tool\":\n" &
  "  call:\n" &
  "    flag input is string, alias = \"--input\", role = input, required = true\n" &
  "    flag output is string, alias = \"--output\", role = output, required = true\n" &
  "    flag record is string, alias = \"--record\", required = true\n" &
  "    flag probe is string, alias = \"--probe\", required = true\n" &
  "    outputs output\n"

  ## Records what it read and what ``--probe`` (a directory) holds, in a file
  ## outside the temporary workspace, so the case can read it after the push
  ## removed that workspace. An input starting with FAIL makes it fail.
const subToolScript = """#!/bin/sh
set -eu
if [ "${1:-}" = "--version" ]; then echo 'sub-tool 1.0.0'; exit 0; fi
input= output= record= probe=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --input) input=$2; shift 2 ;;
    --output) output=$2; shift 2 ;;
    --record) record=$2; shift 2 ;;
    --probe) probe=$2; shift 2 ;;
    *) echo "unknown arg $1" >&2; exit 64 ;;
  esac
done
mkdir -p "$(dirname "$output")" "$(dirname "$record")"
printf '%s in %s: %s; %s holds [%s]\n' "$input" "$(pwd)" "$(cat "$input")" \
  "$probe" "$(ls -A "$probe" | tr '\n' ' ')" >> "$record"
case "$(head -c 4 "$input")" in
  FAIL) echo "$input says FAIL" >&2; exit 1 ;;
esac
cp "$input" "$output"
"""

proc subRecipe(record: string): string =
  ## lib-b's recipe: lib-a's, with two more tests in ``t-unit`` that read a
  ## file of submodule ``sub`` and of its nested submodule ``sub/nested``.
  "import repro_project_dsl\n" &
    "import \"policy/team_policy\"\n\n" &
    "package lib_a:\n" &
    "  usesImportPath \"reprobuild/packages\"\n" &
    "  enactCertificatePolicy teamPolicy\n" &
    "  uses:\n" &
    "    \"cert-tool >=1.0 <2.0\"\n" &
    "    \"sub-tool >=1.0 <2.0\"\n\n" &
    "  build:\n" &
    "    let unit = certTool(actionId = \"unit\",\n" &
    "      input = \"src/unit.txt\",\n" &
    "      output = \"build/unit-out\",\n" &
    "      marker = \".repro/runs.log\")\n" &
    "    let sub = subTool(actionId = \"sub\",\n" &
    "      input = \"sub/unit.txt\",\n" &
    "      output = \"build/sub-out\",\n" &
    "      record = \"" & record & "\",\n" &
    "      probe = \"uninit\")\n" &
    "    let nested = subTool(actionId = \"nested\",\n" &
    "      input = \"sub/nested/unit.txt\",\n" &
    "      output = \"build/nested-out\",\n" &
    "      record = \"" & record & "\",\n" &
    "      probe = \"uninit\")\n" &
    "    certificate \"t-unit\", aggregate(\"t-unit\", @[unit, sub, nested])\n"

proc sourceRepo(dir, body: string): string =
  ## A repository with ``unit.txt``; its HEAD.
  discard gitOut(parentDir(dir), "init", "-q", "-b", "main", dir)
  discard gitOut(dir, "config", "user.email", "tester@example.invalid")
  discard gitOut(dir, "config", "user.name", "Submodule Tester")
  writeFile(dir / "unit.txt", body)
  discard gitOut(dir, "add", "-A")
  discard gitOut(dir, "commit", "-q", "-m", "unit")
  gitOut(dir, "rev-parse", "HEAD")

suite "a member certified against its pins has the submodules it initialized":
  test "required: the temporary checkout has the initialized submodules, " &
      "nested ones too, at the committed commits, fetched from nowhere; an " &
      "uninitialized one stays empty":
    guarded:
      let fx = setupPush("push-cycle-submodules", "required")
      defer: removeDir(fx.sf.scratch)
      writeFile(fx.binDir / "sub-tool", subToolScript)
      setFilePermissions(fx.binDir / "sub-tool",
        {fpUserRead, fpUserWrite, fpUserExec})
      let libB = fx.addMembers([(name: "lib-b", depends: @["lib-a"])],
        @["lib-b"], gateways = true)[0]
      let record = fx.sf.scratch / "sub-reads.log"
      # Every submodule URL names a location that does not exist, and the
      # repositories the user initialized them from are removed below:
      # population must take everything from the user's checkouts.
      let nowhere = fx.sf.scratch / "nowhere" & "/"
      let s = fx.sf.scratch / "submodule-sources"
      createDir(s)
      discard sourceRepo(s / "nested", "nested, committed\n")
      discard sourceRepo(s / "sub", "sub, committed\n")
      discard gitOut(s / "sub", "-c", "protocol.file.allow=always", "submodule",
        "add", "-q", s / "nested", "nested")
      discard gitOut(s / "sub", "config", "-f", ".gitmodules",
        "submodule.nested.url", nowhere & "nested.git")
      discard gitOut(s / "sub", "add", "-A")
      discard gitOut(s / "sub", "commit", "-q", "-m", "nested")
      discard sourceRepo(s / "uninit", "never initialized\n")

      # lib-b: two submodules, `sub` (with `sub/nested`) initialized and
      # `uninit` not, and a recipe whose tests read `sub` and `sub/nested`.
      discard gitOut(libB.path, "-c", "protocol.file.allow=always", "submodule",
        "add", "-q", s / "sub", "sub")
      discard gitOut(libB.path / "sub", "config", "submodule.nested.url",
        s / "nested")
      discard gitOut(libB.path / "sub", "-c", "protocol.file.allow=always",
        "submodule", "update", "-q", "--init")
      discard gitOut(libB.path, "-c", "protocol.file.allow=always", "submodule",
        "add", "-q", s / "uninit", "uninit")
      discard gitOut(libB.path, "submodule", "deinit", "-q", "-f", "uninit")
      for name in ["sub", "uninit"]:
        discard gitOut(libB.path, "config", "-f", ".gitmodules",
          "submodule." & name & ".url", nowhere & name & ".git")
      discard gitOut(libB.path, "submodule", "sync", "-q", "--recursive")
      removeDir(s)
      check gitOut(libB.path / "sub", "config", "submodule.nested.url") ==
        nowhere & "nested.git"
      check readFile(libB.path / "sub" / "nested" / "unit.txt") ==
        "nested, committed\n"
      check toSeq(walkDir(libB.path / "uninit")).len == 0
      writeFile(libB.path / "repro.nim", subRecipe(record))
      writeFile(libB.path / "reprobuild" / "packages" / "sub_tool.nim",
        subToolInterface)
      let refreshedB = fx.reproIn(libB.path, @["lock", "refresh"])
      check refreshedB.code == 0
      let a0 = upstreamTip(fx.sf)
      let bTip = fx.commitIn(libB, "unit b\n", "lib-b, with submodules")
      let committedSub = gitOut(libB.path, "rev-parse", bTip & ":sub")
      check committedSub == gitOut(libB.path / "sub", "rev-parse", "HEAD")
      let aTip = fx.commitEdit("unit a\n", "lib-a, not tested yet")
      doAssert bTip in fx.git("show " & aTip & ":repro.lock")
      doAssert a0 in gitOut(libB.path, "show", bTip & ":repro.lock")

      # The user's checkout of `sub` moves past the committed commit, to
      # content the tests refuse. The pushed commit names the committed one,
      # so that is the one the tests must read.
      #
      # `ignore = all` is what makes this state reachable, and it hides no
      # defect. Without it the moved submodule is an uncommitted change, and
      # `repro push` stops at lib-b's clean preflight ("working tree has
      # uncommitted changes"), which is right: in place the tests would read
      # content no commit names. With it git calls the checkout clean; a
      # member certified IN PLACE then tests the moved submodule, but the
      # content id names the checked-out submodule commit
      # (`--ignore-submodules=none`), so the certificate is for that content,
      # not for the pushed commit, and the push refuses the commit as
      # uncovered (checked by hand on a single-repository push). Only a
      # member certified against its pins, as here, is certified for the
      # pushed commit, and there the tests must read the committed submodule.
      writeFile(libB.path / "sub" / "unit.txt", "FAIL: the user's checkout\n")
      discard gitOut(libB.path / "sub", "-c", "user.email=t@example.invalid",
        "-c", "user.name=T", "commit", "-q", "-am", "moved on")
      discard gitOut(libB.path, "config", "submodule.sub.ignore", "all")
      check gitOut(libB.path, "status", "--porcelain").len == 0
      let scratchBefore = isolatedScratchDirs(fx)

      let pushed = fx.push()
      checkpoint("repro push:\n" & pushed.output)
      let reads = if fileExists(record): readFile(record) else: ""
      checkpoint("the tests read:\n" & reads)
      check pushed.code == 0
      let bReport = memberReport(pushed.output, "lib-b")
      check "certified: t-unit" in bReport
      check "certified against 'lib-a' at its pinned commit " & a0 in bReport
      # Read in the temporary workspace, from the committed submodule commits;
      # `uninit` held nothing there.
      var inScratch = 0
      for line in reads.splitLines():
        if line.len == 0: continue
        check "/repro-push-pins-" in line
        check "holds []" in line
        if "/repro-push-pins-" in line: inc inScratch
      check inScratch == 2
      check "sub/unit.txt in " in reads and ": sub, committed;" in reads
      check "sub/nested/unit.txt in " in reads and
        ": nested, committed;" in reads
      check "FAIL" notin reads
      fx.checkScratchRemoved(pushed.output, scratchBefore)
      check gitOut(libB.path / "sub", "rev-parse", "HEAD") != committedSub
      fx.checkPublishedThroughGateway(pushed.output, "lib-b", libB.path,
        libB.bare, bTip)

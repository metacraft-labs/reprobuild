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
## Where a gateway is wired there is one repository, with a lock that pins no
## sibling, because the gateway's public lock gate refuses a pin of another
## repository's revision. The closure and cycle cases therefore run without one.
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
  ## a lock pinning a sibling does not pass one.
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

  test "a cycle member with an unpublished peer is stopped by issuance, and says so":
    guarded:
      let fx = setupPush("push-cycle", "required", gateway = false)
      defer: removeDir(fx.sf.scratch)
      let peer = fx.addSibling("lib-b", cycle = true)
      installHooks(fx.sf)
      let peerBefore = gitOut(peer.bare, "rev-parse", "refs/heads/main")
      let before = upstreamTip(fx.sf)
      discard fx.commitIn(peer, "unit peer\n", "peer, not tested yet")
      discard fx.commitEdit("unit cycle\n", "member, not tested yet")
      let stopped = fx.push()
      checkpoint(stopped.output)
      check stopped.code == 2
      check "dependency has unpushed commits" in stopped.output
      check "is still not covered" in stopped.output
      check "stage=certify\n" in (stopped.output & "\n")
      check gitOut(peer.bare, "rev-parse", "refs/heads/main") == peerBefore
      check upstreamTip(fx.sf) == before

  test "advisory: the certify step lets a cycle through to the pin rule":
    guarded:
      let fx = setupPush("push-cycle-advisory", "advisory", gateway = false)
      defer: removeDir(fx.sf.scratch)
      let peer = fx.addSibling("lib-b", cycle = true)
      installHooks(fx.sf)
      discard fx.commitIn(peer, "unit peer\n", "peer, not tested yet")
      discard fx.commitEdit("unit cycle\n", "member, not tested yet")
      let pushed = fx.push()
      checkpoint(pushed.output)
      # Issuance could not run, and under advisory that is a report. What stops
      # this push is another rule: each commit's lock, refreshed by its hook, pins
      # the peer's unpublished commit.
      check "still not covered after certifying" in pushed.output
      check "stage=certify" notin pushed.output
      check "stage=source-push" in pushed.output
      check "source-component-unpublished-pin" in pushed.output

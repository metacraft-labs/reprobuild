## `repro workspace migrate` must never walk a pinned checkout off its pin.
##
## The regression this locks down. A vendored reference tree declares BOTH a
## branch and an exact revision, and they mean different things: the branch is
## where to clone FROM, the revision is where to SIT. That is the whole point of
## keeping the pin — the consumer was built against one commit of an upstream
## that has since moved on, so the checkout is deliberately detached at that
## commit while `main` runs ahead of it.
##
## The reconciler read `branch` first and treated a detached HEAD as damage. It
## therefore saw four vendored trees "stranded" and offered to attach each one
## to its declared branch, which would have moved every one of them off the
## pinned commit and onto whatever the branch tip had reached — reintroducing,
## from the reconciler, the exact drift the retained pin exists to prevent. The
## check that was supposed to stop this looked at `branch` being empty, and once
## the manifests declared both keys it never fired again.
##
## So the rule is now read off `revision` ALONE: a fragment that names an exact
## commit is asking for a detached HEAD at that commit, whatever else it
## declares. Three neighbouring cases, decided deliberately:
##
##   * pinned and HEAD is at the pin — the steady state. Silent, because
##     narrating it would report these repos on every single merge forever.
##   * pinned and HEAD is detached somewhere else — genuinely adrift, but
##     attaching would move it to the branch TIP, i.e. further from the pin.
##     Reported with the remedy (`sync`, which converges to the pin), never
##     moved.
##   * pinned and HEAD is on a branch — somebody put it there on purpose. Left
##     alone and unmentioned, exactly like every other attached checkout;
##     "is this repo at its pinned revision" is a real question that belongs to
##     `sync` and `workspace status`, not to a second voice inside a hook.
##
## Asserted:
##   1. A fragment with `branch` + a sha `revision`, HEAD at the pin, is left
##      EXACTLY there: same commit, still detached, and absent from the report.
##   2. The same fragment where the declared branch exists locally and is AHEAD
##      of the pin is still not moved. This is the case that would have bitten:
##      `main` was ahead of the pin in three of the four real checkouts, so a
##      test whose branch equalled the pin would have passed against the defect.
##   3. A fragment with `branch` and NO revision still attaches — the feature
##      this fix must not undo.
##   4. A pinned checkout detached at the WRONG commit is deferred with a
##      remedy, and still not moved.
##   5. Idempotence and the `--dry-run` prediction both still hold across all
##      of it.
##
## No mocks: real `git init --bare` origins over `file://`, real clones detached
## at real non-tip commits, and the engine-built `build/bin/repro`. Skipped only
## when `git` is missing from PATH.

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support

proc q(value: string): string = quoteShell(value)

proc git(gitBin, args: string): tuple[code: int; output: string] =
  let res = execCmdEx(q(gitBin) & " " & args)
  (code: res.exitCode, output: res.output)

proc requireGit(gitBin, args: string): string =
  let res = git(gitBin, args)
  if res.code != 0:
    checkpoint("git " & args & " failed: exit=" & $res.code & "\n" & res.output)
    fail()
  res.output

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc seedBareWithHistory(gitBin, bareDir, branch: string): string =
  ## Three commits on `branch`; returns the FIRST one — a commit that is
  ## genuinely not the tip, so "sat on the pin" and "sat on the branch tip" are
  ## distinguishable states rather than the same sha.
  let work = bareDir & "-seed"
  createDir(work)
  discard requireGit(gitBin, "init --quiet --initial-branch " & q(branch) &
    " " & q(work))
  const author = " -c user.email=t@example.invalid -c user.name=t "
  writeFile(work / "first.txt", "first\n")
  discard requireGit(gitBin, "-C " & q(work) & " add .")
  discard requireGit(gitBin, "-C " & q(work) & author & "commit --quiet -m first")
  let pinned = requireGit(gitBin, "-C " & q(work) & " rev-parse HEAD").strip()
  writeFile(work / "second.txt", "second\n")
  discard requireGit(gitBin, "-C " & q(work) & " add .")
  discard requireGit(gitBin, "-C " & q(work) & author & "commit --quiet -m second")
  writeFile(work / "third.txt", "third\n")
  discard requireGit(gitBin, "-C " & q(work) & " add .")
  discard requireGit(gitBin, "-C " & q(work) & author & "commit --quiet -m third")
  discard requireGit(gitBin, "clone --quiet --bare " & q(work) & " " &
    q(bareDir))
  removeDir(work)
  pinned

proc headSha(gitBin, checkout: string): string =
  requireGit(gitBin, "-C " & q(checkout) & " rev-parse HEAD").strip()

proc headBranch(gitBin, checkout: string): string =
  let res = git(gitBin, "-C " & q(checkout) & " symbolic-ref --short -q HEAD")
  if res.code != 0: "" else: res.output.strip()

proc refSha(gitBin, checkout, refName: string): string =
  let res = git(gitBin, "-C " & q(checkout) & " rev-parse --verify --quiet " &
    q(refName))
  if res.code != 0: "" else: res.output.strip()

proc migrate(root: string; extra: openArray[string] = []): CmdResult =
  var argv = @[reproBinary(), "workspace", "migrate",
    "--workspace-root=" & root, "--no-write-report"]
  for e in extra:
    argv.add(e)
  runShell(shellCommand(argv))

proc writeWorkspace(root, prefix: string;
                    fragments: openArray[tuple[name, extra: string]]) =
  ## The CONVERTED manifest shape — url-prefixes plus a repo-set — because that
  ## is the shape whose arrival activated the defect. A test written against the
  ## older spelling would not have exercised it.
  createDir(root / "url-prefixes")
  createDir(root / "repos")
  createDir(root / "repo-sets")
  createDir(root / ".repro")
  writeFile(root / "url-prefixes" / "vendor.toml",
    "schema = \"reprobuild.workspace.url-prefix.v1\"\n\n" &
    "[url-prefix]\nname = \"vendor\"\nurl = \"" & prefix & "\"\n")
  var members: seq[string]
  for f in fragments:
    writeFile(root / "repos" / (f.name & ".toml"),
      "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
      "[repo]\nname = \"" & f.name & "\"\npath = \"" & f.name & "\"\n" &
      "url_prefix = \"vendor\"\n" & f.extra)
    members.add("\"" & f.name & "\"")
  writeFile(root / "repo-sets" / "demo.toml",
    "schema = \"reprobuild.workspace.repo-set.v1\"\n\n" &
    "[repo-set]\nname = \"demo\"\n\nmember_repos = [" &
    members.join(", ") & "]\n")
  writeFile(root / ".repro" / "workspace.toml",
    "schema = \"reprobuild.workspace.local.v1\"\n\n" &
    "[workspace]\nproject = \"demo\"\nprojects = [\"demo\"]\n")

suite "workspace migrate leaves a pinned checkout on its pin":

  test "t_migrate_does_not_attach_a_pinned_checkout_whose_branch_ran_ahead":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-migrate-pin-", "")
      defer: removeDirEventually(scratch)
      let remotes = scratch / "remotes"
      createDir(remotes)
      let pinnedSha = seedBareWithHistory(gitBin, remotes / "pinned-ref", "main")
      let unpinnedSha = seedBareWithHistory(gitBin, remotes / "tracking-lib",
        "main")
      discard unpinnedSha
      let prefix = fileUrl(remotes)

      let root = scratch / "workspace"
      writeWorkspace(root, prefix, [
        # The converted vendored-reference shape: BOTH keys, and they disagree
        # on purpose.
        (name: "pinned-ref",
         extra: "branch = \"main\"\nrevision = \"" & pinnedSha & "\"\n"),
        # A repo that lost its pin in the conversion — it must still attach.
        (name: "tracking-lib", extra: "branch = \"main\"\n")])

      for name in ["pinned-ref", "tracking-lib"]:
        discard requireGit(gitBin, "clone --quiet " &
          q(prefix & "/" & name) & " " & q(root / name))
        discard requireGit(gitBin, "-C " & q(root / name) &
          " checkout --quiet --detach HEAD")

      # The pinned one is put where its pin says, detached. Its local `main`
      # stays at the TIP, two commits ahead — which is the real-world shape:
      # three of the four vendored trees had `main` ahead of their pin, so a
      # fixture where they matched would pass against the defect.
      discard requireGit(gitBin, "-C " & q(root / "pinned-ref") &
        " checkout --quiet --detach " & q(pinnedSha))
      check headSha(gitBin, root / "pinned-ref") == pinnedSha
      let localMain = refSha(gitBin, root / "pinned-ref", "refs/heads/main")
      check localMain.len == 40
      check localMain != pinnedSha        # the branch really is ahead

      # --- dry run predicts, and touches nothing ---
      let dry = migrate(root, ["--dry-run"])
      checkpoint("dry-run: " & dry.output)
      check dry.code == 0
      check not dry.output.contains("pinned-ref")
      check dry.output.contains("tracking-lib")
      check headSha(gitBin, root / "pinned-ref") == pinnedSha

      # --- and the real run agrees with the prediction ---
      let res = migrate(root, ["--json"])
      checkpoint("migrate: " & res.output)
      check res.code == 0

      # The pinned tree is EXACTLY where it was: same commit, still detached.
      check headSha(gitBin, root / "pinned-ref") == pinnedSha
      check headBranch(gitBin, root / "pinned-ref") == ""
      check refSha(gitBin, root / "pinned-ref", "refs/heads/main") == localMain

      # The unpinned one still attaches — the feature this fix must not undo.
      check headBranch(gitBin, root / "tracking-lib") == "main"

      # ...and the pinned repo is absent from the report entirely. Silence is
      # the assertion: these repos are in this state permanently, so a
      # reconciler that mentioned them would speak on every merge forever.
      let report = parseJson(res.output)
      var mentioned: seq[string]
      for entry in report["repos"]:
        mentioned.add(entry["path"].getStr())
      check "pinned-ref" notin mentioned
      check "tracking-lib" in mentioned

      # Idempotent: nothing left to do, nothing said.
      let again = migrate(root)
      check again.code == 0
      check again.output.contains("already match the manifest")
      check headSha(gitBin, root / "pinned-ref") == pinnedSha

  test "t_migrate_reports_a_pinned_checkout_that_drifted_off_its_pin":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-migrate-pin-drift-", "")
      defer: removeDirEventually(scratch)
      let remotes = scratch / "remotes"
      createDir(remotes)
      let pinnedSha = seedBareWithHistory(gitBin, remotes / "adrift-ref", "main")
      let prefix = fileUrl(remotes)

      let root = scratch / "workspace"
      writeWorkspace(root, prefix, [
        (name: "adrift-ref",
         extra: "branch = \"main\"\nrevision = \"" & pinnedSha & "\"\n")])
      discard requireGit(gitBin, "clone --quiet " & q(prefix & "/adrift-ref") &
        " " & q(root / "adrift-ref"))

      # Detached, but at the branch TIP rather than at the pin — adrift.
      discard requireGit(gitBin, "-C " & q(root / "adrift-ref") &
        " checkout --quiet --detach main")
      let adriftAt = headSha(gitBin, root / "adrift-ref")
      check adriftAt != pinnedSha

      let res = migrate(root)
      checkpoint("migrate: " & res.output)

      # Reported, not repaired — and specifically NOT attached, because
      # attaching would move it to the tip, i.e. further from the pin.
      check res.code == 2
      check res.output.contains("adrift-ref")
      check res.output.contains("pins " & pinnedSha)
      check res.output.contains("repro workspace sync")
      check headSha(gitBin, root / "adrift-ref") == adriftAt
      check headBranch(gitBin, root / "adrift-ref") == ""

      # A pinned repo somebody deliberately put ON a branch is left alone and
      # left unmentioned — same contract every other attached checkout gets.
      discard requireGit(gitBin, "-C " & q(root / "adrift-ref") &
        " checkout --quiet main")
      let onBranch = migrate(root)
      checkpoint("on-branch: " & onBranch.output)
      check onBranch.code == 0
      check onBranch.output.contains("already match the manifest")
      check headBranch(gitBin, root / "adrift-ref") == "main"

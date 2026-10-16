## `repro hooks ensure --vcs` REMOVES the hook dispatcher of the retired
## `repo-workspaces` tool instead of chaining it as a user hook, keeps the user
## hook that dispatcher had preserved, and `repro health` reports the retired
## files until it has.
##
## THE DEFECT (reprobuild-pm issue 2026-09-30, "hooks ensure chains the retired
## repo-workspaces dispatcher"). `repo-workspaces`, the tool Reprobuild
## replaced, installed its own dispatcher at `.git/hooks/<hook>` (marker line
## `# repo-workspaces hook dispatcher`) with its body in
## `<hook>.repo-workspaces-managed` and the user's previous hook preserved in
## `<hook>.repo-workspaces-local`. `ensure` recognised none of it, classified
## the dispatcher as a foreign user hook and chained it to
## `<hook>.repro-local` — which Reprobuild's own dispatcher runs FIRST. Every
## push from such a repository kept running the retired tool's
## `workspace __hook pre-push`, which publishes locks by committing and
## pushing into the manifest repository, and `ensure` reported the state as
## an ordinary `chained-user-hook`.
##
## WHAT IS ASSERTED
##
##   (a) A retired dispatcher at the standard path is removed, not chained:
##       outcome `removed-retired-dispatcher`, no file in the hooks directory
##       still carries a retired marker, `<hook>.repo-workspaces-managed` is
##       gone. **Fails against the unfixed build, which reports
##       `chained-user-hook`.**
##   (b) The state the issue observed — the retired dispatcher ALREADY chained
##       at `<hook>.repro-local` by an earlier `ensure` — is repaired the same
##       way, as is a retired dispatcher at `<hook>.legacy` (pre-commit or prek
##       installed over it). **The unfixed build reports both as
##       `already-up-to-date`.**
##   (c) The user hook the retired tool preserved in
##       `<hook>.repo-workspaces-local` is not lost: it is migrated to
##       `<hook>.repro-local`, and a REAL `git commit` runs it through the
##       managed dispatcher while the retired managed body does NOT run.
##   (d) `repro health` reports the retired state as a `vcs-hooks` failure of
##       its own (naming the files, `--fix`-able with `hooks ensure`), and the
##       row is `ok` once `ensure` has run. **The unfixed build reports (b)'s
##       state as `ok`.**
##   (e) CONTROL — a genuine user hook is still chained (`chained-user-hook`),
##       and a genuine user hook chained in the SAME call as a retired removal
##       does not hide the removal from the report.
##   (f) A second `ensure` is a no-op: every outcome `already-up-to-date`,
##       every file unchanged.
##   (g) Two different user hooks competing for `<hook>.repro-local` (the one
##       already chained, and the one the retired tool preserved) are REFUSED
##       with both files named — and nothing is deleted by the refusal.
##   (h) `hooks uninstall --vcs` does not put a chained retired dispatcher
##       back at the standard path.
##
## TEST DOUBLES, and why each is justified. The retired DISPATCHER is embedded
## verbatim (both variants, from `repo-workspaces`' `hookDispatcherContent`),
## because its exact text is what the recogniser is exercised against. The
## retired MANAGED BODY is a stub that keeps the real header (shebang plus the
## `# repo-workspaces managed <hook> hook` marker line) and replaces the rest
## with one line appending to a sentinel file. The real body locates a
## `repo-workspaces` checkout by walking up from `$PWD` and exits 0 when it
## finds none — which in a scratch directory it never does — so the real text
## would make "the retired body did not run" unobservable. Everything else is
## real: the real `repro` binary, real `git`, a real commit firing real hooks.
##
## Hermetic: one `createTempDir`, local bares only, no network; the
## Reprobuild cache is redirected into the scratch directory so the managed
## post-commit hook writes nowhere outside it.
## Skip rule: `git` missing on PATH.

import std/[algorithm, json, os, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

import repro_test_support

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

# ---------------------------------------------------------------------------
# The retired tool's files, verbatim.

const retiredPrePushDispatcher = """#!/usr/bin/env bash
# repo-workspaces hook dispatcher
#
# Hook management policy:
# - This dispatcher is owned by repo-workspaces and is recognizable by the
#   repo-workspaces dispatcher marker above.
# - Non-managed hooks are preserved as {hookName}.repo-workspaces-local and
#   are invoked before repo-workspaces-managed logic.
# - repo-workspaces-managed logic lives in {hookName}.repo-workspaces-managed.
# - Uninstall restores the preserved local hook when this dispatcher is active.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_HOOK="$HOOK_DIR/{hookName}.repo-workspaces-local"
MANAGED_HOOK="$HOOK_DIR/{hookName}.repo-workspaces-managed"
STDIN_COPY=$(mktemp "${TMPDIR:-/tmp}/repo-workspaces-{hookName}.XXXXXX")
trap 'rm -f "$STDIN_COPY"' EXIT HUP INT TERM

cat > "$STDIN_COPY"

# If pre-commit's `hook-impl` shim is the preserved local hook, it chains into
# `$HOOK_DIR/{hookName}.legacy`. When pre-commit was installed on top of a
# previous repo-workspaces dispatcher, that `.legacy` file *is* this dispatcher,
# which makes pre-commit re-enter the dispatcher (and itself) until it crashes
# in migration mode. The file is always our own dispatcher (never a genuine
# user hook), so remove it defensively to keep the chain finite. `workspace
# hooks ensure` performs the same cleanup; this is the runtime safety net in
# case pre-commit is reinstalled after hooks were set up.
PRECOMMIT_LEGACY="$HOOK_DIR/{hookName}.legacy"
if [[ -f "$PRECOMMIT_LEGACY" ]] && grep -q 'repo-workspaces hook dispatcher' "$PRECOMMIT_LEGACY" 2>/dev/null; then
    rm -f "$PRECOMMIT_LEGACY"
fi

run_hook() {
    local hook_file="$1"
    shift
    [[ -x "$hook_file" ]] || return 0
    # A preserved local hook may be pre-commit's `hook-impl` shim. pre-commit
    # self-checks for migration mode via PRE_COMMIT_RUNNING_LEGACY and aborts
    # if it sees it set, which can happen when pre-commit was installed over a
    # previous repo-workspaces dispatcher. Clear it so the shim runs cleanly.
    PRE_COMMIT_RUNNING_LEGACY= "$hook_file" "$@" < "$STDIN_COPY"
}

run_hook "$LOCAL_HOOK" "$@" || exit $?
run_hook "$MANAGED_HOOK" "$@" || exit $?
exit 0
"""

const retiredDispatcher = """#!/usr/bin/env bash
# repo-workspaces hook dispatcher
#
# Hook management policy:
# - This dispatcher is owned by repo-workspaces and is recognizable by the
#   repo-workspaces dispatcher marker above.
# - Non-managed hooks are preserved as {hookName}.repo-workspaces-local and
#   are invoked before repo-workspaces-managed logic.
# - repo-workspaces-managed logic lives in {hookName}.repo-workspaces-managed.
# - Uninstall restores the preserved local hook when this dispatcher is active.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_HOOK="$HOOK_DIR/{hookName}.repo-workspaces-local"
MANAGED_HOOK="$HOOK_DIR/{hookName}.repo-workspaces-managed"

# See note in the pre-push dispatcher: drop a stale pre-commit `.legacy` that is
# actually this dispatcher, otherwise pre-commit re-enters us in a loop.
PRECOMMIT_LEGACY="$HOOK_DIR/{hookName}.legacy"
if [[ -f "$PRECOMMIT_LEGACY" ]] && grep -q 'repo-workspaces hook dispatcher' "$PRECOMMIT_LEGACY" 2>/dev/null; then
    rm -f "$PRECOMMIT_LEGACY"
fi

run_hook() {
    local hook_file="$1"
    shift
    [[ -x "$hook_file" ]] || return 0
    # See note in the pre-push dispatcher: clear pre-commit's migration-mode
    # guard so a preserved pre-commit shim runs cleanly when chained.
    PRE_COMMIT_RUNNING_LEGACY= "$hook_file" "$@"
}

run_hook "$LOCAL_HOOK" "$@" || exit $?
run_hook "$MANAGED_HOOK" "$@" || exit $?
exit 0
"""

proc retiredDispatcherFor(hookName: string): string =
  (if hookName == "pre-push": retiredPrePushDispatcher
   else: retiredDispatcher).replace("{hookName}", hookName)

proc retiredManagedStub(hookName, sentinel: string): string =
  ## See "TEST DOUBLES" in the header: the real header, a sentinel body.
  "#!/usr/bin/env bash\n# repo-workspaces managed " & hookName & " hook\n" &
    "#\n# (stub body: records that the retired tool's hook ran)\n" &
    "echo " & hookName & " >> " & quoteShell(sentinel) & "\n"

proc userHook(label, sentinel: string): string =
  "#!/bin/sh\n# my own " & label & " checks\necho " & label & " >> " &
    quoteShell(sentinel) & "\n"

const retiredMarkers = ["repo-workspaces hook dispatcher",
  "repo-workspaces managed"]

# ---------------------------------------------------------------------------
# Fixture: a one-repo workspace (the shape `repro health` sweeps).

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

type
  Fixture = object
    scratch, workspaceRoot, repoPath, hooks, reproBin: string
    retiredRan, userRan: string   ## sentinel files

proc env(fx: Fixture): seq[tuple[name, value: string]] =
  ## ``REPROBUILD_REPRO`` pins the managed bodies to the binary under test;
  ## ``XDG_CACHE_HOME`` keeps the post-commit cache push inside the scratch.
  @[(name: "REPROBUILD_REPRO", value: fx.reproBin),
    (name: "XDG_CACHE_HOME", value: fx.scratch / "cache"),
    (name: "PATH", value: fx.reproBin.parentDir & PathSep & getEnv("PATH"))]

proc run(fx: Fixture; args: openArray[string]; cwd = ""): CmdResult =
  runShell(shellCommand(args, fx.env),
    if cwd.len > 0: cwd else: fx.scratch)

proc mustRun(fx: Fixture; args: openArray[string]; cwd = ""): string =
  let res = fx.run(args, cwd)
  if res.code != 0:
    checkpoint("command failed: " & args.join(" ") & "\nexit=" & $res.code &
      "\n" & res.output)
    raise newException(AssertionDefect, "command failed: " & args.join(" "))
  res.output

proc slot(fx: Fixture; name: string): string = fx.hooks / name

proc plant(path, content: string) =
  writeFile(path, content)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc setupFixture(slug: string): Fixture =
  result.scratch = createTempDir("repro-retired-rw-" & slug & "-", "")
  result.reproBin = reproBinary()
  result.retiredRan = result.scratch / "retired-ran.txt"
  result.userRan = result.scratch / "user-ran.txt"
  createDir(result.scratch / "cache")
  let fx = result
  let origin = fx.scratch / "origin-lib-a.git"
  let seed = fx.scratch / "seed-lib-a"
  discard fx.mustRun(["git", "init", "-q", "--bare", "-b", "main", origin])
  discard fx.mustRun(["git", "init", "-q", "-b", "main", seed])
  discard fx.mustRun(["git", "-C", seed, "config", "user.email",
    "tester@example.invalid"])
  discard fx.mustRun(["git", "-C", seed, "config", "user.name", "Tester"])
  writeFile(seed / "README.md", "retired dispatcher fixture\n")
  discard fx.mustRun(["git", "-C", seed, "add", "README.md"])
  discard fx.mustRun(["git", "-C", seed, "commit", "-q", "-m", "fixture"])
  discard fx.mustRun(["git", "-C", seed, "push", "-q", origin, "main"])
  result.workspaceRoot = fx.scratch / "workspace"
  createDir(result.workspaceRoot / ".repro")
  createDir(result.workspaceRoot / "projects")
  createDir(result.workspaceRoot / "repos")
  writeFile(result.workspaceRoot / "projects" / "lib-a.toml",
    projectToml.replace("LIB_A_URL", fileUrl(origin)))
  writeFile(result.workspaceRoot / "repos" / "lib-a.toml", libAFragmentToml)
  result.repoPath = result.workspaceRoot / "lib-a"
  discard fx.mustRun(["git", "clone", "-q", fileUrl(origin), result.repoPath])
  discard fx.mustRun(["git", "-C", result.repoPath, "config", "user.email",
    "tester@example.invalid"])
  discard fx.mustRun(["git", "-C", result.repoPath, "config", "user.name",
    "Tester"])
  result.hooks = fx.mustRun(["git", "-C", result.repoPath, "rev-parse",
    "--path-format=absolute", "--git-path", "hooks"]).strip()
  createDir(result.hooks)
  for kind, path in walkDir(result.hooks):
    if path.endsWith(".sample"):
      removeFile(path)

proc plantRetiredAtStandard(fx: Fixture; hookName: string) =
  ## The layout `repo-workspaces hooks ensure` left behind.
  plant(fx.slot(hookName), retiredDispatcherFor(hookName))
  plant(fx.slot(hookName & ".repo-workspaces-managed"),
    retiredManagedStub(hookName, fx.retiredRan))

proc jsonDocument(output: string): JsonNode =
  ## The one JSON document in ``output``. stderr is merged into it, and the
  ## installer's advisories go to stderr, so the document is cut out by its
  ## first ``{`` line and last ``}`` line rather than parsed whole.
  let lines = output.splitLines()
  var first = -1
  var last = -1
  for i, line in lines:
    if line == "{" and first < 0: first = i
    if line == "}": last = i
  doAssert first >= 0 and last > first, "no JSON document in output"
  parseJson(lines[first .. last].join("\n"))

proc ensureJson(fx: Fixture): tuple[code: int; outcomes: JsonNode;
    output: string] =
  ## `ensure` in workspace mode with `--json`: the only form that reports a
  ## per-hook outcome tag. Returns ``{hook: outcome}`` for repo lib-a.
  let res = fx.run([fx.reproBin, "hooks", "ensure", "--vcs", "--json",
    fx.workspaceRoot])
  checkpoint("hooks ensure --json (exit " & $res.code & "):\n" & res.output)
  result.code = res.code
  result.output = res.output
  result.outcomes = newJObject()
  if res.code != 0:
    return
  let doc = jsonDocument(res.output)
  for entry in doc["entries"]:
    if entry["repo"].getStr() == "lib-a":
      result.outcomes[entry["hook"].getStr()] = entry["outcome"]

proc vcsHooksRow(fx: Fixture): JsonNode =
  let res = fx.run([fx.reproBin, "health", "lib-a", "--json",
    "--workspace-root=" & fx.workspaceRoot])
  checkpoint("health --json output:\n" & res.output)
  for entry in jsonDocument(res.output)["checks"]:
    if entry["name"].getStr() == "vcs-hooks":
      return entry
  doAssert false, "health emitted no vcs-hooks row"

proc rowText(row: JsonNode): string =
  ## The unabridged detail when the row carries one, else the digest.
  if row.hasKey("fullDetail") and row["fullDetail"].getStr().len > 0:
    row["fullDetail"].getStr()
  else:
    row["detail"].getStr()

proc retiredFilesLeft(fx: Fixture): seq[string] =
  ## Every file in the hooks directory that still carries a retired marker,
  ## plus every `*.repo-workspaces-managed` whatever it holds.
  for kind, path in walkDir(fx.hooks):
    if kind != pcFile: continue
    let name = extractFilename(path)
    if name.endsWith(".repo-workspaces-managed"):
      result.add(name)
      continue
    let body = readFile(path)
    for marker in retiredMarkers:
      if marker in body:
        result.add(name)
        break
  result.sort()

proc snapshot(fx: Fixture): seq[(string, string)] =
  for kind, path in walkDir(fx.hooks):
    if kind == pcFile:
      result.add((extractFilename(path), readFile(path)))
  result.sort()

proc linesOf(path: string): seq[string] =
  if fileExists(path): readFile(path).strip().splitLines() else: @[]

proc commit(fx: Fixture; message: string): CmdResult =
  writeFile(fx.repoPath / "change.txt", message & "\n")
  discard fx.mustRun(["git", "add", "change.txt"], fx.repoPath)
  fx.run(["git", "commit", "-q", "-m", message], fx.repoPath)

suite "hooks ensure removes the retired repo-workspaces dispatcher":

  test "retired dispatcher at the standard path: removed, user hook migrated":
    if findExe("git").len == 0:
      skip("git not on PATH; this case needs a real repository whose hooks " &
        "a real commit fires")
    else:
      let fx = setupFixture("standard")
      defer: removeDir(fx.scratch)

      # The layout the issue found: both of the retired tool's hooks at the
      # standard path. post-commit additionally carries a user hook the retired
      # tool had preserved, and the `.original` backup it kept.
      fx.plantRetiredAtStandard("pre-push")
      fx.plantRetiredAtStandard("post-commit")
      let preserved = userHook("post-commit", fx.userRan)
      plant(fx.slot("post-commit.repo-workspaces-local"), preserved)
      plant(fx.slot("post-commit.original"), "#!/bin/sh\n# old backup\n")

      # ---- (d) health BEFORE ensure ------------------------------------
      let before = fx.vcsHooksRow()
      let beforeText = rowText(before)
      check before["status"].getStr() == "fail"
      check "RETIRED" in beforeText
      check "lib-a/pre-push" in beforeText
      check "lib-a/post-commit" in beforeText
      check "post-commit.repo-workspaces-managed" in beforeText
      check before["fixable"].getBool()
      check "hooks ensure --vcs" in before["remedy"].getStr()

      # ---- (a) ensure removes, never chains -----------------------------
      let e1 = fx.ensureJson()
      check e1.code == 0
      check e1.outcomes{"pre-push"}.getStr() == "removed-retired-dispatcher"
      check e1.outcomes{"post-commit"}.getStr() == "removed-retired-dispatcher"
      check fx.retiredFilesLeft().len == 0
      checkpoint("retired files left: " & $fx.retiredFilesLeft())
      check not fileExists(fx.slot("pre-push.repo-workspaces-managed"))
      check not fileExists(fx.slot("post-commit.repo-workspaces-managed"))
      # pre-push had no user hook, so nothing is chained for it.
      check not fileExists(fx.slot("pre-push.repro-local"))
      check readFile(fx.slot("pre-push")).contains("reprobuild hook dispatcher")
      # ---- (c) ... and the preserved user hook is migrated, not lost ----
      check not fileExists(fx.slot("post-commit.repo-workspaces-local"))
      check fileExists(fx.slot("post-commit.repro-local"))
      if fileExists(fx.slot("post-commit.repro-local")):
        check readFile(fx.slot("post-commit.repro-local")) == preserved
      # The retired tool's `.original` is a user backup nothing runs: kept.
      check fileExists(fx.slot("post-commit.original"))

      # A real commit runs the migrated user hook through the managed
      # dispatcher, and the retired body does not run.
      let c = fx.commit("after ensure")
      checkpoint("commit: " & c.output)
      check c.code == 0
      check linesOf(fx.userRan) == @["post-commit"]
      check not fileExists(fx.retiredRan)

      # ---- (d) health AFTER ensure --------------------------------------
      let after = fx.vcsHooksRow()
      check after["status"].getStr() == "ok"
      check "RETIRED" notin rowText(after)

      # ---- (f) idempotent ------------------------------------------------
      let snap = fx.snapshot()
      let e2 = fx.ensureJson()
      check e2.code == 0
      for hook, outcome in e2.outcomes:
        checkpoint(hook & ": " & outcome.getStr())
        check outcome.getStr() == "already-up-to-date"
      check fx.snapshot() == snap

  test "retired dispatcher already chained at .repro-local or at .legacy":
    if findExe("git").len == 0:
      skip("git not on PATH; this case needs a real repository whose hooks " &
        "a real commit fires")
    else:
      let fx = setupFixture("chained")
      defer: removeDir(fx.scratch)

      # Reprobuild's hooks installed first: the control state.
      check fx.ensureJson().code == 0
      check fx.vcsHooksRow()["status"].getStr() == "ok"

      # Then the state an earlier, unfixed `ensure` produced over a retired
      # install: the retired dispatcher chained at `<hook>.repro-local`, its
      # bodies beside it, the preserved user hook still where the retired
      # tool put it. And for post-merge, the retired dispatcher displaced to
      # `.legacy` by a pre-commit/prek install.
      for hookName in ["pre-push", "post-commit"]:
        plant(fx.slot(hookName & ".repro-local"), retiredDispatcherFor(hookName))
        plant(fx.slot(hookName & ".repo-workspaces-managed"),
          retiredManagedStub(hookName, fx.retiredRan))
      let preserved = userHook("post-commit", fx.userRan)
      plant(fx.slot("post-commit.repo-workspaces-local"), preserved)
      plant(fx.slot("post-merge.legacy"), retiredDispatcherFor("post-merge"))

      # ---- (d) health reports it: the unfixed build calls this `ok` -------
      let before = fx.vcsHooksRow()
      let beforeText = rowText(before)
      check before["status"].getStr() == "fail"
      check "RETIRED" in beforeText
      check "pre-push.repro-local" in beforeText
      check "post-commit.repro-local" in beforeText
      check "post-merge.legacy" in beforeText
      check before["fixable"].getBool()

      # ---- (b) ensure removes the chained copies --------------------------
      let e1 = fx.ensureJson()
      check e1.code == 0
      check e1.outcomes{"pre-push"}.getStr() == "removed-retired-dispatcher"
      check e1.outcomes{"post-commit"}.getStr() == "removed-retired-dispatcher"
      check e1.outcomes{"post-merge"}.getStr() == "removed-retired-dispatcher"
      checkpoint("retired files left: " & $fx.retiredFilesLeft())
      check fx.retiredFilesLeft().len == 0
      check not fileExists(fx.slot("pre-push.repro-local"))
      check not fileExists(fx.slot("post-merge.legacy"))
      # ---- (c) the user hook takes the freed slot ------------------------
      check not fileExists(fx.slot("post-commit.repo-workspaces-local"))
      check fileExists(fx.slot("post-commit.repro-local"))
      if fileExists(fx.slot("post-commit.repro-local")):
        check readFile(fx.slot("post-commit.repro-local")) == preserved

      let c = fx.commit("after ensure")
      checkpoint("commit: " & c.output)
      check c.code == 0
      check linesOf(fx.userRan) == @["post-commit"]
      check not fileExists(fx.retiredRan)

      check fx.vcsHooksRow()["status"].getStr() == "ok"
      let snap = fx.snapshot()
      let e2 = fx.ensureJson()
      check e2.code == 0
      for hook, outcome in e2.outcomes:
        check outcome.getStr() == "already-up-to-date"
      check fx.snapshot() == snap

  test "a genuine user hook is still chained, and does not hide a removal":
    if findExe("git").len == 0:
      skip("git not on PATH")
    else:
      let fx = setupFixture("control")
      defer: removeDir(fx.scratch)

      # (e) CONTROL: a hand-written hook at the standard path, nothing
      # retired anywhere near it, is chained exactly as before.
      let mine = userHook("pre-push", fx.userRan)
      plant(fx.slot("pre-push"), mine)
      # In the SAME call for another hook: a hand-written hook at the standard
      # path AND a retired dispatcher chained at `.repro-local` (pre-commit
      # rewrote the slot after an unfixed `ensure` had chained the retired
      # dispatcher). Both a chain and a removal happen; the removal wins the
      # report. The unfixed build refuses here ("already holds a different
      # preserved hook"), treating the retired dispatcher as a user's hook.
      let other = userHook("post-commit", fx.userRan)
      plant(fx.slot("post-commit"), other)
      plant(fx.slot("post-commit.repro-local"),
        retiredDispatcherFor("post-commit"))

      let e1 = fx.ensureJson()
      check e1.code == 0
      check e1.outcomes{"pre-push"}.getStr() == "chained-user-hook"
      check e1.outcomes{"post-commit"}.getStr() == "removed-retired-dispatcher"
      check readFile(fx.slot("pre-push.repro-local")) == mine
      check readFile(fx.slot("post-commit.repro-local")) == other
      check fx.retiredFilesLeft().len == 0
      check fx.vcsHooksRow()["status"].getStr() == "ok"

  test "two different user hooks for one slot: refused, nothing deleted":
    if findExe("git").len == 0:
      skip("git not on PATH")
    else:
      let fx = setupFixture("conflict")
      defer: removeDir(fx.scratch)

      check fx.ensureJson().code == 0
      # (g) Retired dispatcher at the standard path (the retired tool
      # reinstalled itself), Reprobuild's chain already holding one user
      # hook, and the retired tool's preserved slot holding a DIFFERENT one.
      # Both are user content; discarding either would lose checks.
      let chained = userHook("chained", fx.userRan)
      let rwLocal = userHook("rw-local", fx.userRan)
      plant(fx.slot("post-commit.repro-local"), chained)
      plant(fx.slot("post-commit.repo-workspaces-local"), rwLocal)
      fx.plantRetiredAtStandard("post-commit")
      let snap = fx.snapshot()

      let e = fx.ensureJson()
      check e.code != 0
      check "post-commit.repro-local" in e.output
      check "post-commit.repo-workspaces-local" in e.output
      # The refusal deleted nothing: the retired dispatcher still runs the
      # user hook it preserved, exactly as before the call.
      check fx.snapshot() == snap

  test "uninstall does not restore a chained retired dispatcher":
    if findExe("git").len == 0:
      skip("git not on PATH")
    else:
      let fx = setupFixture("uninstall")
      defer: removeDir(fx.scratch)

      check fx.ensureJson().code == 0
      plant(fx.slot("pre-push.repro-local"), retiredDispatcherFor("pre-push"))
      # (h) The single-repo uninstall path.
      let res = fx.run([fx.reproBin, "hooks", "uninstall", "--vcs",
        fx.repoPath], fx.repoPath)
      checkpoint("uninstall: " & res.output)
      check res.code == 0
      check not fileExists(fx.slot("pre-push"))
      check not fileExists(fx.slot("pre-push.repro-local"))

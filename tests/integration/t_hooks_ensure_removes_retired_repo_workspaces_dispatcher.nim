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
##   (i) The retired tool's FIRST generation — the self-contained WRAPPER its
##       `hooks/install.sh` installed for `pre-commit` and `post-commit`,
##       which ran the user's hook from `<hook>.original` — is removed AND
##       that `.original` is migrated to `<hook>.repro-local`, so a real
##       commit still runs the user's hook and no longer runs the retired
##       tool's checks. Covered at the standard path and chained at
##       `.repro-local`. **The unfixed build removes the wrapper and leaves
##       `.original` behind, where nothing runs it: the user's hook silently
##       stops.** With only a DISPATCHER present, `.original` is left exactly
##       as found and is not run ((a) asserts that): the dispatcher never ran
##       it.
##   (j) Migrating `.original` follows (g)'s conflict rules: a different hook
##       already chained, or a different `<hook>.repo-workspaces-local` that a
##       dispatcher in the same directory runs, is REFUSED naming both files,
##       and nothing is deleted.
##   (k) `hooks uninstall --vcs` that deletes a retired file chained at
##       `.repro-local` RESTORES the user hook that file preserved and ran
##       first — `.original` under a wrapper, `.repo-workspaces-local` under a
##       dispatcher — to the canonical path, bytes and mode intact, and a real
##       commit runs it. **The unfixed build deletes the retired file and
##       strands the user hook where nothing runs it.** Two different
##       preserved hooks for the one slot are REFUSED naming both files, with
##       nothing of that hook deleted.
##
## TEST DOUBLES, and why each is justified. The retired DISPATCHER is embedded
## verbatim (both variants, from `repo-workspaces`' `hookDispatcherContent`),
## because its exact text is what the recogniser is exercised against. So are
## the two WRAPPERS (`hooks/pre-commit-wrapper` and `hooks/post-commit-wrapper`
## at `repo-workspaces` `4db74ae`, its initial commit). They need no stub to be
## observable: they locate the framework by walking up from `$PWD` to a
## `repo-workspaces/hooks` directory, and the fixture plants one in the scratch
## directory whose two scripts append to the retired sentinel. The
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
from repro_cli_support import selfHealManagedHooks

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
  "repo-workspaces managed", "repo-workspaces pre-commit wrapper",
  "repo-workspaces post-commit wrapper"]

# The first generation: `repo-workspaces` `4db74ae:hooks/<hook>-wrapper`,
# verbatim. `hooks/install.sh` renamed an existing hook to `<hook>.original`
# and copied the wrapper over it.
const retiredPreCommitWrapper = """#!/usr/bin/env bash
# repo-workspaces pre-commit wrapper
# Chains with existing pre-commit hooks and adds dependency validation

set -euo pipefail

REPO_HOOKS_DIR=".git/hooks"

# Run original pre-commit hook if it was preserved
if [[ -x "$REPO_HOOKS_DIR/pre-commit.original" ]]; then
    "$REPO_HOOKS_DIR/pre-commit.original" "$@" || exit $?
fi

# Find repo-workspaces framework hooks directory
find_framework_hooks() {
    # Check environment variable first
    if [[ -n "${REPO_WORKSPACES_FRAMEWORK:-}" ]] && [[ -d "$REPO_WORKSPACES_FRAMEWORK/hooks" ]]; then
        echo "$REPO_WORKSPACES_FRAMEWORK/hooks"
        return 0
    fi

    local dir="$PWD"
    while [[ "$dir" != "/" ]]; do
        # Check in workspace parent
        if [[ -d "$dir/../repo-workspaces/hooks" ]]; then
            echo "$dir/../repo-workspaces/hooks"
            return 0
        fi
        # Check in workspace itself
        if [[ -d "$dir/repo-workspaces/hooks" ]]; then
            echo "$dir/repo-workspaces/hooks"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    return 1
}

FRAMEWORK_HOOKS=$(find_framework_hooks) || {
    # Can't find framework hooks, skip our checks
    exit 0
}

# Run dependency checks
if [[ -x "$FRAMEWORK_HOOKS/check-dependencies.sh" ]]; then
    "$FRAMEWORK_HOOKS/check-dependencies.sh" "$@" || exit $?
fi

exit 0
"""

const retiredPostCommitWrapper = """#!/usr/bin/env bash
# repo-workspaces post-commit wrapper
# Chains with existing post-commit hooks and creates workspace locks

set -euo pipefail

REPO_HOOKS_DIR=".git/hooks"

# Run original post-commit hook if it was preserved
if [[ -x "$REPO_HOOKS_DIR/post-commit.original" ]]; then
    "$REPO_HOOKS_DIR/post-commit.original" "$@"
    # Don't exit on failure - post-commit hooks shouldn't block
fi

# Find repo-workspaces framework hooks directory
find_framework_hooks() {
    # Check environment variable first
    if [[ -n "${REPO_WORKSPACES_FRAMEWORK:-}" ]] && [[ -d "$REPO_WORKSPACES_FRAMEWORK/hooks" ]]; then
        echo "$REPO_WORKSPACES_FRAMEWORK/hooks"
        return 0
    fi

    local dir="$PWD"
    while [[ "$dir" != "/" ]]; do
        # Check in workspace parent
        if [[ -d "$dir/../repo-workspaces/hooks" ]]; then
            echo "$dir/../repo-workspaces/hooks"
            return 0
        fi
        # Check in workspace itself
        if [[ -d "$dir/repo-workspaces/hooks" ]]; then
            echo "$dir/repo-workspaces/hooks"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    return 1
}

FRAMEWORK_HOOKS=$(find_framework_hooks) || {
    # Can't find framework hooks, skip lock creation
    exit 0
}

# Run lock creation (best-effort, don't fail)
if [[ -x "$FRAMEWORK_HOOKS/create-lock.sh" ]]; then
    "$FRAMEWORK_HOOKS/create-lock.sh" "$@" || true
fi

exit 0
"""

proc retiredWrapperFor(hookName: string): string =
  doAssert hookName in ["pre-commit", "post-commit"],
    "the retired tool wrote wrappers only for pre-commit and post-commit"
  if hookName == "pre-commit": retiredPreCommitWrapper
  else: retiredPostCommitWrapper

# ---------------------------------------------------------------------------
# Fixture: a one-repo workspace (the shape `repro health` sweeps).

const projectToml = """
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

proc plantRetiredFramework(fx: Fixture) =
  ## The `repo-workspaces/hooks` directory the wrappers walk up from `$PWD`
  ## to find (`find_framework_hooks`: `<ancestor>/../repo-workspaces/hooks`).
  ## Planted in the scratch directory, the parent of the workspace root, and
  ## so found from inside the repository. Each script records that the
  ## retired tool's own check ran.
  let dir = fx.scratch / "repo-workspaces" / "hooks"
  createDir(dir)
  plant(dir / "check-dependencies.sh", "#!/bin/sh\necho pre-commit >> " &
    quoteShell(fx.retiredRan) & "\n")
  plant(dir / "create-lock.sh", "#!/bin/sh\necho post-commit >> " &
    quoteShell(fx.retiredRan) & "\n")

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
      # A `.original` beside a DISPATCHER: the dispatcher never ran it (only
      # the first release's wrapper did), so it stays as the user left it.
      let originalRan = fx.scratch / "original-ran.txt"
      let backup = userHook("original", originalRan)
      plant(fx.slot("post-commit.original"), backup)

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
      # With only a dispatcher present, `.original` ran in no chain: it is
      # neither migrated nor deleted.
      check fileExists(fx.slot("post-commit.original"))
      if fileExists(fx.slot("post-commit.original")):
        check readFile(fx.slot("post-commit.original")) == backup

      # A real commit runs the migrated user hook through the managed
      # dispatcher, and the retired body does not run.
      let c = fx.commit("after ensure")
      checkpoint("commit: " & c.output)
      check c.code == 0
      check linesOf(fx.userRan) == @["post-commit"]
      check not fileExists(fx.retiredRan)
      check not fileExists(originalRan)

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

  test "retired wrapper at the standard path: the .original hook it ran is migrated":
    if findExe("git").len == 0:
      skip("git not on PATH; this case needs a real repository whose hooks " &
        "a real commit fires")
    else:
      let fx = setupFixture("wrapper")
      defer: removeDir(fx.scratch)

      # (i) The layout the retired tool's `hooks/install.sh` left: the user's
      # hooks renamed to `<hook>.original`, the wrappers copied over them.
      fx.plantRetiredFramework()
      var mine: seq[string]
      for hookName in ["pre-commit", "post-commit"]:
        let body = userHook(hookName, fx.userRan)
        mine.add(body)
        plant(fx.slot(hookName & ".original"), body)
        plant(fx.slot(hookName), retiredWrapperFor(hookName))

      # POSITIVE CONTROL: the fixture is the state it claims to be. A real
      # commit through the wrappers runs the user's hooks AND the retired
      # tool's checks, so "did not run" below is observable.
      let c0 = fx.commit("through the retired wrappers")
      checkpoint("control commit: " & c0.output)
      check c0.code == 0
      check linesOf(fx.userRan) == @["pre-commit", "post-commit"]
      check linesOf(fx.retiredRan) == @["pre-commit", "post-commit"]
      removeFile(fx.userRan)
      removeFile(fx.retiredRan)

      let before = fx.vcsHooksRow()
      check before["status"].getStr() == "fail"
      check "RETIRED" in rowText(before)
      check "lib-a/pre-commit" in rowText(before)
      check "lib-a/post-commit" in rowText(before)

      let e1 = fx.ensureJson()
      check e1.code == 0
      check e1.outcomes{"pre-commit"}.getStr() == "removed-retired-dispatcher"
      check e1.outcomes{"post-commit"}.getStr() == "removed-retired-dispatcher"
      checkpoint("retired files left: " & $fx.retiredFilesLeft())
      check fx.retiredFilesLeft().len == 0
      for i, hookName in ["pre-commit", "post-commit"]:
        checkpoint("hook: " & hookName)
        check readFile(fx.slot(hookName)).contains("reprobuild hook dispatcher")
        # The wrapper's preserved hook moved into Reprobuild's chain, mode
        # and bytes intact; nothing is left at `.original`.
        check not fileExists(fx.slot(hookName & ".original"))
        check fileExists(fx.slot(hookName & ".repro-local"))
        if fileExists(fx.slot(hookName & ".repro-local")):
          check readFile(fx.slot(hookName & ".repro-local")) == mine[i]
          check fpUserExec in getFilePermissions(
            fx.slot(hookName & ".repro-local"))

      # The user's hooks still run on a real commit; the retired checks do not.
      let c = fx.commit("after ensure")
      checkpoint("commit: " & c.output)
      check c.code == 0
      check linesOf(fx.userRan) == @["pre-commit", "post-commit"]
      check not fileExists(fx.retiredRan)

      check fx.vcsHooksRow()["status"].getStr() == "ok"
      let snap = fx.snapshot()
      let e2 = fx.ensureJson()
      check e2.code == 0
      for hook, outcome in e2.outcomes:
        checkpoint(hook & ": " & outcome.getStr())
        check outcome.getStr() == "already-up-to-date"
      check fx.snapshot() == snap

  test "retired wrapper already chained at .repro-local: its .original is migrated":
    if findExe("git").len == 0:
      skip("git not on PATH; this case needs a real repository whose hooks " &
        "a real commit fires")
    else:
      let fx = setupFixture("wrapper-chained")
      defer: removeDir(fx.scratch)

      check fx.ensureJson().code == 0
      # The state an `ensure` without the recogniser produced over a wrapper
      # install: the wrapper chained at `.repro-local`, still running
      # `.original` first from inside Reprobuild's dispatcher.
      fx.plantRetiredFramework()
      let mine = userHook("post-commit", fx.userRan)
      plant(fx.slot("post-commit.original"), mine)
      plant(fx.slot("post-commit.repro-local"),
        retiredWrapperFor("post-commit"))
      # No control commit here, unlike the standard-path case: with managed
      # hooks installed, a commit's own hooks re-assert the hook set (the same
      # repair as `ensure`), so it would perform the migration under test
      # before `ensure` is called.

      let e1 = fx.ensureJson()
      check e1.code == 0
      check e1.outcomes{"post-commit"}.getStr() == "removed-retired-dispatcher"
      check fx.retiredFilesLeft().len == 0
      check not fileExists(fx.slot("post-commit.original"))
      check fileExists(fx.slot("post-commit.repro-local"))
      if fileExists(fx.slot("post-commit.repro-local")):
        check readFile(fx.slot("post-commit.repro-local")) == mine

      let c = fx.commit("after ensure")
      checkpoint("commit: " & c.output)
      check c.code == 0
      check linesOf(fx.userRan) == @["post-commit"]
      check not fileExists(fx.retiredRan)

  test "wrapper's .original vs a different chained hook: refused, nothing deleted":
    if findExe("git").len == 0:
      skip("git not on PATH")
    else:
      let fx = setupFixture("wrapper-conflict")
      defer: removeDir(fx.scratch)

      check fx.ensureJson().code == 0
      # (j) The wrapper reinstalled at the standard path over Reprobuild's
      # dispatcher, a user hook already chained, and the wrapper's
      # `.original` holding a DIFFERENT one.
      plant(fx.slot("post-commit.repro-local"),
        userHook("chained", fx.userRan))
      plant(fx.slot("post-commit.original"), userHook("original", fx.userRan))
      plant(fx.slot("post-commit"), retiredWrapperFor("post-commit"))
      let snap = fx.snapshot()

      let e = fx.ensureJson()
      check e.code != 0
      check "post-commit.original" in e.output
      check "post-commit.repro-local" in e.output
      check "wrapper" in e.output
      check fx.snapshot() == snap

  test "dispatcher's preserved hook vs a different wrapper .original: refused":
    if findExe("git").len == 0:
      skip("git not on PATH")
    else:
      let fx = setupFixture("both-generations")
      defer: removeDir(fx.scratch)

      # (j) Both generations' preserved hooks qualify: the dispatcher at the
      # standard path runs `.repo-workspaces-local`, and the wrapper an
      # earlier `ensure` chained at `.repro-local` runs `.original`. They are
      # different hooks headed for the one slot, so neither may win silently.
      # The other hooks are installed first, so the snapshot below isolates
      # post-commit.
      check fx.ensureJson().code == 0
      fx.plantRetiredAtStandard("post-commit")
      plant(fx.slot("post-commit.repo-workspaces-local"),
        userHook("rw-local", fx.userRan))
      plant(fx.slot("post-commit.repro-local"),
        retiredWrapperFor("post-commit"))
      plant(fx.slot("post-commit.original"), userHook("original", fx.userRan))
      let snap = fx.snapshot()

      let e = fx.ensureJson()
      check e.code != 0
      check "post-commit.original" in e.output
      check "post-commit.repo-workspaces-local" in e.output
      check fx.snapshot() == snap

  test "uninstall restores the hook a chained retired file preserved":
    if findExe("git").len == 0:
      skip("git not on PATH; this case needs a real repository whose hooks " &
        "a real commit fires")
    else:
      let fx = setupFixture("uninstall-restore")
      defer: removeDir(fx.scratch)

      check fx.ensureJson().code == 0
      # (k) Both retired generations chained at `.repro-local` by an `ensure`
      # without the recogniser, each with the user hook it preserved and ran
      # first: the wrapper for post-commit (`.original`), the dispatcher for
      # pre-push (`.repo-workspaces-local`).
      fx.plantRetiredFramework()
      let postCommit = userHook("post-commit", fx.userRan)
      plant(fx.slot("post-commit.original"), postCommit)
      plant(fx.slot("post-commit.repro-local"),
        retiredWrapperFor("post-commit"))
      let prePush = userHook("pre-push", fx.userRan)
      plant(fx.slot("pre-push.repo-workspaces-local"), prePush)
      plant(fx.slot("pre-push.repro-local"), retiredDispatcherFor("pre-push"))

      let res = fx.run([fx.reproBin, "hooks", "uninstall", "--vcs",
        fx.repoPath], fx.repoPath)
      checkpoint("uninstall: " & res.output)
      check res.code == 0
      # The retired files are gone and NOT restored ((h)) — but the user hooks
      # they ran are back at the canonical path, bytes and mode intact. The
      # unfixed build deletes the retired file and leaves the user hook
      # stranded where nothing runs it.
      check fx.retiredFilesLeft().len == 0
      checkpoint("retired files left: " & $fx.retiredFilesLeft())
      for (hookName, body, preservedAt) in [
          ("post-commit", postCommit, "post-commit.original"),
          ("pre-push", prePush, "pre-push.repo-workspaces-local")]:
        checkpoint("hook: " & hookName)
        check not fileExists(fx.slot(hookName & ".repro-local"))
        check not fileExists(fx.slot(preservedAt))
        check fileExists(fx.slot(hookName))
        if fileExists(fx.slot(hookName)):
          check readFile(fx.slot(hookName)) == body
          check fpUserExec in getFilePermissions(fx.slot(hookName))

      # A real commit runs the restored user hook, and nothing retired.
      let c = fx.commit("after uninstall")
      checkpoint("commit: " & c.output)
      check c.code == 0
      check linesOf(fx.userRan) == @["post-commit"]
      check not fileExists(fx.retiredRan)

  test "uninstall with two different preserved hooks: refused, nothing deleted":
    if findExe("git").len == 0:
      skip("git not on PATH")
    else:
      let fx = setupFixture("uninstall-conflict")
      defer: removeDir(fx.scratch)

      check fx.ensureJson().code == 0
      # (k) A wrapper chained at `.repro-local`, with a `.original` it ran and
      # a DIFFERENT `.repo-workspaces-local` beside it — the qualification
      # `ensure` uses lets both claim the canonical slot. Neither may win
      # silently, and the refusal comes before anything is deleted.
      plant(fx.slot("post-commit.repro-local"),
        retiredWrapperFor("post-commit"))
      plant(fx.slot("post-commit.original"), userHook("original", fx.userRan))
      plant(fx.slot("post-commit.repo-workspaces-local"),
        userHook("rw-local", fx.userRan))
      let snap = fx.snapshot()

      let res = fx.run([fx.reproBin, "hooks", "uninstall", "--vcs",
        fx.repoPath], fx.repoPath)
      checkpoint("uninstall: " & res.output)
      check res.code != 0
      check "post-commit.original" in res.output
      check "post-commit.repo-workspaces-local" in res.output
      # post-commit's files are untouched. Hooks uninstalled before
      # post-commit in the same call are gone; compare post-commit's only.
      var after: seq[(string, string)]
      var before: seq[(string, string)]
      for item in fx.snapshot():
        if item[0].startsWith("post-commit"): after.add(item)
      for item in snap:
        if item[0].startsWith("post-commit"): before.add(item)
      check after == before

  test "separate record stores restore users from both retired dispatcher layouts":
    require findExe("git").len > 0
    when defined(posix):
      const variants = [("retired-standard", true),
        ("retired-chained", true), ("retired-standard", false),
        ("retired-chained", false), ("retired-reshadowed", true),
        ("retired-reshadowed", false)]
    else:
      # Windows file permissions do not represent a non-executable file.
      const variants = [("retired-standard", true),
        ("retired-chained", true), ("retired-reshadowed", true)]
    for (layout, userExecutable) in variants:
      checkpoint("record-store layout: " & layout &
        ", user executable: " & $userExecutable)
      let fx = setupFixture("store-" & layout)
      defer: removeDir(fx.scratch)
      let hadInterpreter = existsEnv("REPROBUILD_REPRO")
      let previousInterpreter = getEnv("REPROBUILD_REPRO")
      putEnv("REPROBUILD_REPRO", fx.reproBin)
      defer:
        if hadInterpreter: putEnv("REPROBUILD_REPRO", previousInterpreter)
        else: delEnv("REPROBUILD_REPRO")

      # The public repair API runs the same store cleanup as explicit ensure.
      # Compile it from the code under test: a stale CLI cannot implement the
      # cleanup that this regression measures. Its protocol probe still uses
      # the real paired CLI, just as production repair does.
      if layout in ["retired-chained", "retired-reshadowed"]:
        for line in selfHealManagedHooks(fx.repoPath):
          checkpoint(line)
          require not line.contains("could NOT")
        require fileExists(fx.slot("post-commit"))
        require fileExists(fx.slot("post-commit.repro-managed"))

      let store = fx.scratch / ".repro" / "records"
      createDir(parentDir(store))
      discard fx.mustRun(["git", "init", "-q", "-b", "main", store])
      discard fx.mustRun(["git", "-C", store, "config", "user.email",
        "tester@example.invalid"])
      discard fx.mustRun(["git", "-C", store, "config", "user.name", "Tester"])
      let hooks = store / ".git" / "hooks"
      let preserved = "#!/bin/sh\nprintf 'context=%s\\n' " &
        "\"${REPROBUILD_INTERNAL_HOOK_CONTEXT-}\" >> " &
        quoteShell(fx.userRan) & "\n"
      # A re-shadowed current installation keeps its genuine user's hook in
      # our preserved slot; it has no retired-tool preserved user to migrate.
      let preservedPath = hooks / (if layout == "retired-reshadowed":
        "post-commit.repro-local" else: "post-commit.repo-workspaces-local")
      plant(preservedPath, preserved)
      if not userExecutable:
        setFilePermissions(preservedPath,
          {fpUserRead, fpUserWrite, fpGroupRead, fpOthersRead})
      plant(hooks / "post-commit.repo-workspaces-managed",
        retiredManagedStub("post-commit", fx.retiredRan))
      if layout == "retired-chained":
        for suffix in ["", ".repro-managed"]:
          copyFile(fx.slot("post-commit" & suffix),
            hooks / ("post-commit" & suffix))
          setFilePermissions(hooks / ("post-commit" & suffix),
            getFilePermissions(fx.slot("post-commit" & suffix)))
        plant(hooks / "post-commit.repro-local",
          retiredDispatcherFor("post-commit"))
      else:
        plant(hooks / "post-commit", retiredDispatcherFor("post-commit"))
        if layout == "retired-reshadowed":
          copyFile(fx.slot("post-commit.repro-managed"),
            hooks / "post-commit.repro-managed")
          require not fileExists(hooks / "post-commit.repo-workspaces-local")

      for line in selfHealManagedHooks(store):
        checkpoint(line)
        check not line.contains("could NOT")
      check fileExists(hooks / "pre-push")
      check fileExists(hooks / "pre-push.repro-managed")
      check fileExists(hooks / "post-commit")
      if fileExists(hooks / "post-commit"):
        check readFile(hooks / "post-commit") == preserved
        check (fpUserExec in getFilePermissions(hooks / "post-commit")) ==
          userExecutable
      for hook in ["pre-commit", "post-commit", "post-merge", "post-checkout"]:
        for suffix in [".repro-managed", ".repro-local",
                       ".repo-workspaces-managed", ".repo-workspaces-local"]:
          check not fileExists(hooks / (hook & suffix))
        if hook != "post-commit": check not fileExists(hooks / hook)

      writeFile(store / "record.txt", "real commit through the preserved user hook\n")
      discard fx.mustRun(["git", "-C", store, "add", "record.txt"])
      let committed = fx.run(["git", "-C", store, "commit", "-q", "-m",
        "after record-store repair"])
      checkpoint(committed.output)
      check committed.code == 0
      if userExecutable:
        check linesOf(fx.userRan) == @["context="]
      else:
        # The retired dispatcher skipped this user hook. Migration must not
        # grant it execution merely because its canonical pathname changes.
        check not fileExists(fx.userRan)
      check not fileExists(fx.retiredRan)
      check not dirExists(store / ".repro")

      var afterRepair = fx
      afterRepair.hooks = hooks
      let beforeSecondRepair = afterRepair.snapshot()
      for line in selfHealManagedHooks(store):
        checkpoint(line)
        check not line.contains("could NOT")
      check afterRepair.snapshot() == beforeSecondRepair


  test "separate record stores preserve the qualified retired user hook's execution state":
    require findExe("git").len > 0
    when defined(posix):
      const variants = [("wrapper", "preserved-only"),
        ("wrapper", "executable-duplicate"),
        ("wrapper", "conflicting-current"),
        ("wrapper", "conflicting-retired"),
        ("wrapper", "nonexecutable-duplicate"),
        ("dispatcher", "nonexecutable-duplicate"),
        ("wrapper", "inactive-preserved")]
    else:
      # Windows does not represent a non-executable preserved hook. Keep
      # wrapper restoration and both collision controls on every platform.
      const variants = [("wrapper", "preserved-only"),
        ("wrapper", "executable-duplicate"),
        ("wrapper", "conflicting-current"),
        ("wrapper", "conflicting-retired")]
    for (generation, layout) in variants:
      checkpoint("qualified store user: " & generation & "/" & layout)
      let fx = setupFixture("qualified-" & generation & "-" & layout)
      defer: removeDir(fx.scratch)
      fx.plantRetiredFramework()
      let hadInterpreter = existsEnv("REPROBUILD_REPRO")
      let previousInterpreter = getEnv("REPROBUILD_REPRO")
      putEnv("REPROBUILD_REPRO", fx.reproBin)
      defer:
        if hadInterpreter: putEnv("REPROBUILD_REPRO", previousInterpreter)
        else: delEnv("REPROBUILD_REPRO")

      let store = fx.scratch / ".repro" / "records"
      createDir(parentDir(store))
      discard fx.mustRun(["git", "init", "-q", "-b", "main", store])
      discard fx.mustRun(["git", "-C", store, "config", "user.email",
        "tester@example.invalid"])
      discard fx.mustRun(["git", "-C", store, "config", "user.name", "Tester"])
      let hooks = store / ".git" / "hooks"
      # The public API compiles from the production code under test. First
      # install the applicable store hook, so a collision's complete snapshot
      # cannot differ merely because repair also ensures pre-push afterwards.
      for line in selfHealManagedHooks(store):
        checkpoint(line)
        require not line.contains("could NOT")
      require fileExists(hooks / "pre-push.repro-managed")
      require not fileExists(hooks / "post-commit.repro-managed")

      let body = "#!/bin/sh\nprintf 'context=%s\\n' " &
        "\"${REPROBUILD_INTERNAL_HOOK_CONTEXT-}\" >> " &
        quoteShell(fx.userRan) & "\n"
      let preservedPath = hooks / (if generation == "wrapper":
        "post-commit.original" else: "post-commit.repo-workspaces-local")
      plant(preservedPath, body)
      let qualifiedExecutable = layout != "inactive-preserved"
      if not qualifiedExecutable:
        setFilePermissions(preservedPath,
          {fpUserRead, fpUserWrite, fpGroupRead, fpOthersRead})
      let expectedPermissions = getFilePermissions(preservedPath)
      if generation == "wrapper":
        plant(hooks / "post-commit", retiredWrapperFor("post-commit"))
      else:
        plant(hooks / "post-commit", retiredDispatcherFor("post-commit"))
        plant(hooks / "post-commit.repo-workspaces-managed",
          retiredManagedStub("post-commit", fx.retiredRan))
      let currentLocal = hooks / "post-commit.repro-local"
      if layout in ["executable-duplicate", "nonexecutable-duplicate",
                    "inactive-preserved"]:
        plant(currentLocal, body)
        if layout == "nonexecutable-duplicate":
          setFilePermissions(currentLocal,
            {fpUserRead, fpUserWrite, fpGroupRead, fpOthersRead})
      elif layout == "conflicting-current":
        plant(currentLocal, userHook("different-current", fx.userRan))
      elif layout == "conflicting-retired":
        plant(hooks / "post-commit.repo-workspaces-local",
          userHook("different-retired", fx.userRan))

      # A canonical oldest wrapper runs ONLY .original; even an executable
      # identical .repro-local is not in its chain. This real pre-control pins
      # which hook is authoritative, including the inactive-preserved variant.
      let control = fx.run(["git", "-C", store, "commit", "-q", "--allow-empty",
        "-m", "before qualified store repair"])
      checkpoint(control.output)
      require control.code == 0
      if qualifiedExecutable:
        require linesOf(fx.userRan) == @["context="]
      else:
        require not fileExists(fx.userRan)
      if fileExists(fx.userRan): removeFile(fx.userRan)
      if fileExists(fx.retiredRan): removeFile(fx.retiredRan)

      var storeFixture = fx
      storeFixture.hooks = hooks
      let beforeRepair = storeFixture.snapshot()
      var permissionsBefore: seq[(string, set[FilePermission])]
      for kind, path in walkDir(hooks):
        if kind == pcFile:
          permissionsBefore.add((path, getFilePermissions(path)))
      let repair = selfHealManagedHooks(store)
      for line in repair: checkpoint(line)
      if layout.startsWith("conflicting-"):
        check repair.join("\n").contains("could NOT")
        check repair.join("\n").contains("post-commit.original")
        check repair.join("\n").contains(if layout == "conflicting-current":
          "post-commit.repro-local" else: "post-commit.repo-workspaces-local")
        check storeFixture.snapshot() == beforeRepair
        for (path, permissions) in permissionsBefore:
          check fileExists(path)
          if fileExists(path): check getFilePermissions(path) == permissions
      else:
        check not repair.join("\n").contains("could NOT")
        check fileExists(hooks / "post-commit")
        if fileExists(hooks / "post-commit"):
          check readFile(hooks / "post-commit") == body
          check getFilePermissions(hooks / "post-commit") == expectedPermissions
        for suffix in [".original", ".repro-local", ".repro-managed",
                       ".repo-workspaces-local", ".repo-workspaces-managed"]:
          check not fileExists(hooks / ("post-commit" & suffix))
        check fileExists(hooks / "pre-push.repro-managed")
        for hook in ["pre-commit", "post-merge", "post-checkout"]:
          check not fileExists(hooks / hook)
          check not fileExists(hooks / (hook & ".repro-managed"))
        let committed = fx.run(["git", "-C", store, "commit", "-q", "--allow-empty",
          "-m", "after qualified store repair"])
        checkpoint(committed.output)
        check committed.code == 0
        if qualifiedExecutable:
          # Nonfatal mode/byte checks above must not prevent observing whether
          # the formerly active qualified hook actually still runs in Git.
          check linesOf(fx.userRan) == @["context="]
        else:
          check not fileExists(fx.userRan)
        check not fileExists(fx.retiredRan)
        check not dirExists(store / ".repro")
        let afterRepair = storeFixture.snapshot()
        for line in selfHealManagedHooks(store):
          checkpoint(line)
          check not line.contains("could NOT")
        check storeFixture.snapshot() == afterRepair


  when defined(posix):
    test "separate store retired users retain safe symlink targets during cleanup":
      require findExe("git").len > 0
      for (layout, userExecutable) in [("current-local", true),
          ("current-local", false), ("directory-alias", true),
          ("qualified-local", true),
          ("external", true), ("external", false),
          ("unqualified-original", true), ("unqualified-managed", true)]:
        checkpoint("store preserved symlink: " & layout &
          ", user executable: " & $userExecutable)
        let fx = setupFixture("store-link-" & layout)
        defer: removeDir(fx.scratch)
        fx.plantRetiredFramework()
        let hadInterpreter = existsEnv("REPROBUILD_REPRO")
        let previousInterpreter = getEnv("REPROBUILD_REPRO")
        putEnv("REPROBUILD_REPRO", fx.reproBin)
        defer:
          if hadInterpreter: putEnv("REPROBUILD_REPRO", previousInterpreter)
          else: delEnv("REPROBUILD_REPRO")
        let store = fx.scratch / ".repro" / "records"
        createDir(parentDir(store))
        discard fx.mustRun(["git", "init", "-q", "-b", "main", store])
        discard fx.mustRun(["git", "-C", store, "config", "user.email",
          "tester@example.invalid"])
        discard fx.mustRun(["git", "-C", store, "config", "user.name", "Tester"])
        let hooks = store / ".git" / "hooks"
        for line in selfHealManagedHooks(store):
          checkpoint(line)
          require not line.contains("could NOT")
        require fileExists(hooks / "pre-push.repro-managed")
        let body = "#!/bin/sh\nprintf 'context=%s\\n' " &
          "\"${REPROBUILD_INTERNAL_HOOK_CONTEXT-}\" >> " &
          quoteShell(fx.userRan) & "\n"
        let original = hooks / "post-commit.original"
        let currentLocal = hooks / "post-commit.repro-local"
        let retiredLocal = hooks / "post-commit.repo-workspaces-local"
        let external = fx.scratch / "read-only-user-hook"
        let target =
          case layout
          of "current-local", "directory-alias": currentLocal
          of "qualified-local": retiredLocal
          of "external": external
          of "unqualified-managed": hooks / "post-commit.repro-managed"
          else: original
        plant(target, body)
        if layout == "external":
          setFilePermissions(target, if userExecutable:
            {fpUserRead, fpUserExec, fpGroupRead, fpGroupExec,
              fpOthersRead, fpOthersExec}
            else: {fpUserRead, fpGroupRead, fpOthersRead})
        elif not userExecutable:
          setFilePermissions(target,
            {fpUserRead, fpUserWrite, fpGroupRead, fpOthersRead})
        let targetPermissions = getFilePermissions(target)
        if layout in ["unqualified-original", "unqualified-managed"]:
          # An orphan .original is untouched and remains a safe user target.
          # A foreign current-managed entry would be deleted by uninstall,
          # so that unqualified target must instead be refused before mutation.
          createSymlink(target.extractFilename(), retiredLocal)
          plant(hooks / "post-commit", retiredDispatcherFor("post-commit"))
          plant(hooks / "post-commit.repo-workspaces-managed",
            retiredManagedStub("post-commit", fx.retiredRan))
        else:
          let linkTarget =
            if layout == "external": target
            elif layout == "directory-alias":
              let alias = fx.scratch / "hooks-alias"
              createSymlink(hooks, alias)
              alias / currentLocal.extractFilename()
            else: target.extractFilename()
          createSymlink(linkTarget, original)
          plant(hooks / "post-commit", retiredWrapperFor("post-commit"))
        if layout notin ["current-local", "directory-alias"]:
          plant(currentLocal, body)
          if userExecutable:
            setFilePermissions(currentLocal,
              {fpUserRead, fpUserWrite, fpGroupRead, fpOthersRead})
        let control = fx.run(["git", "-C", store, "commit", "-q", "--allow-empty",
          "-m", "before store symlink repair"])
        checkpoint(control.output)
        require control.code == 0
        if userExecutable: require linesOf(fx.userRan) == @["context="]
        else: require not fileExists(fx.userRan)
        if fileExists(fx.userRan): removeFile(fx.userRan)
        if fileExists(fx.retiredRan): removeFile(fx.retiredRan)

        var storeFixture = fx
        storeFixture.hooks = hooks
        let beforeRepair = storeFixture.snapshot()
        var permissionsBefore: seq[(string, set[FilePermission])]
        for kind, path in walkDir(hooks):
          if kind in {pcFile, pcLinkToFile}:
            permissionsBefore.add((path, getFilePermissions(path)))
        let beforeOriginalLink = if symlinkExists(original): expandSymlink(original)
          else: ""
        let beforeRetiredLink = if symlinkExists(retiredLocal): expandSymlink(retiredLocal)
          else: ""
        let repair = selfHealManagedHooks(store)
        for line in repair: checkpoint(line)
        if layout == "unqualified-managed":
          check repair.join("\n").contains("could NOT")
          check repair.join("\n").contains("symlink")
          check repair.join("\n").contains("post-commit.repro-managed")
          check storeFixture.snapshot() == beforeRepair
          for (path, permissions) in permissionsBefore:
            check fileExists(path)
            if fileExists(path): check getFilePermissions(path) == permissions
          check symlinkExists(retiredLocal)
          if symlinkExists(retiredLocal):
            check expandSymlink(retiredLocal) == beforeRetiredLink
          check fileExists(target)
          if fileExists(target):
            check getFilePermissions(target) == targetPermissions
        else:
          check not repair.join("\n").contains("could NOT")
          check fileExists(hooks / "post-commit")
          if fileExists(hooks / "post-commit"):
            check readFile(hooks / "post-commit") == body
            check getFilePermissions(hooks / "post-commit") == targetPermissions
          for suffix in [".original", ".repro-local", ".repro-managed",
                         ".repo-workspaces-local", ".repo-workspaces-managed"]:
            if layout == "unqualified-original" and suffix == ".original":
              check fileExists(original)
              if fileExists(original):
                check readFile(original) == body
                check getFilePermissions(original) == targetPermissions
            else:
              check not fileExists(hooks / ("post-commit" & suffix))
              check not symlinkExists(hooks / ("post-commit" & suffix))
          if layout == "unqualified-original":
            check symlinkExists(hooks / "post-commit")
            if symlinkExists(hooks / "post-commit"):
              check expandSymlink(hooks / "post-commit") ==
                "post-commit.original"
          if layout == "external":
            check symlinkExists(hooks / "post-commit")
            if symlinkExists(hooks / "post-commit"):
              check expandSymlink(hooks / "post-commit") == beforeOriginalLink
            check fileExists(external)
            if fileExists(external):
              check readFile(external) == body
              check getFilePermissions(external) == targetPermissions
          let committed = fx.run(["git", "-C", store, "commit", "-q", "--allow-empty",
            "-m", "after store symlink repair"])
          checkpoint(committed.output)
          check committed.code == 0
          if userExecutable: check linesOf(fx.userRan) == @["context="]
          else: check not fileExists(fx.userRan)
          check not fileExists(fx.retiredRan)
          check not dirExists(store / ".repro")
          let afterRepair = storeFixture.snapshot()
          for line in selfHealManagedHooks(store):
            checkpoint(line)
            check not line.contains("could NOT")
          check storeFixture.snapshot() == afterRepair


  when defined(posix):
    test "public store uninstall and reinstall preserve the qualified retired user's mode":
      require findExe("git").len > 0
      for (action, userExecutable) in [("uninstall", true),
          ("uninstall", false), ("reinstall", true), ("reinstall", false)]:
        checkpoint("public record-store hooks " & action &
          ", qualified user executable: " & $userExecutable)
        let fx = setupFixture("public-store-" & action)
        defer: removeDir(fx.scratch)
        fx.plantRetiredFramework()
        let store = fx.scratch / ".repro" / "records"
        createDir(parentDir(store))
        discard fx.mustRun(["git", "init", "-q", "-b", "main", store])
        discard fx.mustRun(["git", "-C", store, "config", "user.email",
          "tester@example.invalid"])
        discard fx.mustRun(["git", "-C", store, "config", "user.name", "Tester"])
        # Both public paths start with a real installed store pre-push. The
        # paired app is rebuilt from the production source before this runs.
        let ensured = fx.run([fx.reproBin, "hooks", "ensure", "--vcs", store], store)
        checkpoint(ensured.output)
        require ensured.code == 0
        let hooks = store / ".git" / "hooks"
        require fileExists(hooks / "pre-push")
        require fileExists(hooks / "pre-push.repro-managed")
        require not fileExists(hooks / "post-commit.repro-managed")
        let body = "#!/bin/sh\nprintf 'context=%s\\n' " &
          "\"${REPROBUILD_INTERNAL_HOOK_CONTEXT-}\" >> " &
          quoteShell(fx.userRan) & "\n"
        let original = hooks / "post-commit.original"
        let local = hooks / "post-commit.repro-local"
        plant(original, body)
        plant(local, body)
        if userExecutable:
          setFilePermissions(local,
            {fpUserRead, fpUserWrite, fpGroupRead, fpOthersRead})
        else:
          setFilePermissions(original,
            {fpUserRead, fpUserWrite, fpGroupRead, fpOthersRead})
        let originalPermissions = getFilePermissions(original)
        plant(hooks / "post-commit", retiredWrapperFor("post-commit"))
        # The initial canonical wrapper really runs only .original, not the
        # equal-byte current-local copy with the opposite execution state.
        let control = fx.run(["git", "-C", store, "commit", "-q", "--allow-empty",
          "-m", "before public store hook repair"])
        checkpoint(control.output)
        require control.code == 0
        if userExecutable: require linesOf(fx.userRan) == @["context="]
        else: require not fileExists(fx.userRan)
        if fileExists(fx.userRan): removeFile(fx.userRan)
        if fileExists(fx.retiredRan): removeFile(fx.retiredRan)

        let repaired = fx.run([fx.reproBin, "hooks", action, "--vcs", store], store)
        checkpoint(repaired.output)
        check repaired.code == 0
        check fileExists(hooks / "post-commit")
        if fileExists(hooks / "post-commit"):
          check readFile(hooks / "post-commit") == body
          check getFilePermissions(hooks / "post-commit") == originalPermissions
        for suffix in [".original", ".repro-local", ".repro-managed",
                       ".repo-workspaces-local", ".repo-workspaces-managed"]:
          check not fileExists(hooks / ("post-commit" & suffix))
          check not symlinkExists(hooks / ("post-commit" & suffix))
        if action == "reinstall":
          check fileExists(hooks / "pre-push")
          check fileExists(hooks / "pre-push.repro-managed")
        else:
          check not fileExists(hooks / "pre-push")
          check not fileExists(hooks / "pre-push.repro-managed")
        for hook in ["pre-commit", "post-merge", "post-checkout"]:
          check not fileExists(hooks / hook)
          check not fileExists(hooks / (hook & ".repro-managed"))
        let committed = fx.run(["git", "-C", store, "commit", "-q", "--allow-empty",
          "-m", "after public store hook repair"])
        checkpoint(committed.output)
        check committed.code == 0
        if userExecutable: check linesOf(fx.userRan) == @["context="]
        else: check not fileExists(fx.userRan)
        check not fileExists(fx.retiredRan)
        check not dirExists(store / ".repro")
        check not fileExists(store / "repro.lock")


  when defined(posix):
    test "public store cleanup preserves current chained user's execution state":
      require findExe("git").len > 0
      for (action, userExecutable) in [("ensure", true), ("ensure", false),
          ("uninstall", true), ("uninstall", false),
          ("reinstall", true), ("reinstall", false)]:
        checkpoint("public current-managed store hooks " & action &
          ", user executable: " & $userExecutable)
        let fx = setupFixture("current-store-" & action)
        defer: removeDir(fx.scratch)
        # Generate genuine current dispatcher/body bytes through the public
        # ordinary-repository path; no retired tool or mock dispatcher exists.
        let installed = fx.run([fx.reproBin, "hooks", "reinstall", "--vcs",
          fx.repoPath], fx.repoPath)
        checkpoint(installed.output)
        require installed.code == 0
        require fileExists(fx.slot("post-commit"))
        require fileExists(fx.slot("post-commit.repro-managed"))
        let store = fx.scratch / ".repro" / "records"
        createDir(parentDir(store))
        discard fx.mustRun(["git", "init", "-q", "-b", "main", store])
        discard fx.mustRun(["git", "-C", store, "config", "user.email",
          "tester@example.invalid"])
        discard fx.mustRun(["git", "-C", store, "config", "user.name", "Tester"])
        let hooks = store / ".git" / "hooks"
        let canonical = hooks / "post-commit"
        let local = hooks / "post-commit.repro-local"
        let body = "#!/bin/sh\nprintf 'context=%s\\n' " &
          "\"${REPROBUILD_INTERNAL_HOOK_CONTEXT-}\" >> " &
          quoteShell(fx.userRan) & "\n"
        plant(canonical, body)
        if not userExecutable:
          setFilePermissions(canonical,
            {fpUserRead, fpUserWrite, fpGroupRead, fpOthersRead})
        let userPermissions = getFilePermissions(canonical)
        # A raw Git control proves this user's actual execution state without
        # letting a managed dispatcher self-heal and change the fixture first.
        let control = fx.run(["git", "-C", store, "commit", "-q", "--allow-empty",
          "-m", "before current store hook cleanup"])
        checkpoint(control.output)
        require control.code == 0
        if userExecutable: require linesOf(fx.userRan) == @["context="]
        else: require not fileExists(fx.userRan)
        if fileExists(fx.userRan): removeFile(fx.userRan)
        moveFile(canonical, local)
        for suffix in ["", ".repro-managed"]:
          copyFile(fx.slot("post-commit" & suffix),
            hooks / ("post-commit" & suffix))
          setFilePermissions(hooks / ("post-commit" & suffix),
            getFilePermissions(fx.slot("post-commit" & suffix)))
        require readFile(local) == body
        require getFilePermissions(local) == userPermissions
        for suffix in [".original", ".repo-workspaces-local",
                       ".repo-workspaces-managed"]:
          require not fileExists(hooks / ("post-commit" & suffix))
        let repaired = fx.run([fx.reproBin, "hooks", action, "--vcs", store], store)
        checkpoint(repaired.output)
        check repaired.code == 0
        check fileExists(canonical)
        if fileExists(canonical):
          check readFile(canonical) == body
          check getFilePermissions(canonical) == userPermissions
        for suffix in [".original", ".repro-local", ".repro-managed",
                       ".repo-workspaces-local", ".repo-workspaces-managed"]:
          check not fileExists(hooks / ("post-commit" & suffix))
          check not symlinkExists(hooks / ("post-commit" & suffix))
        if action == "uninstall":
          check not fileExists(hooks / "pre-push")
          check not fileExists(hooks / "pre-push.repro-managed")
        else:
          check fileExists(hooks / "pre-push")
          check fileExists(hooks / "pre-push.repro-managed")
        for hook in ["pre-commit", "post-merge", "post-checkout"]:
          check not fileExists(hooks / hook)
          check not fileExists(hooks / (hook & ".repro-managed"))
        let committed = fx.run(["git", "-C", store, "commit", "-q", "--allow-empty",
          "-m", "after current store hook cleanup"])
        checkpoint(committed.output)
        check committed.code == 0
        if userExecutable: check linesOf(fx.userRan) == @["context="]
        else: check not fileExists(fx.userRan)
        check not dirExists(store / ".repro")
        check not fileExists(store / "repro.lock")

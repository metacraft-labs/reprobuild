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
##       strands the user hook where nothing runs it.** One retired file ran
##       at most one preserved hook, so uninstall has nothing to choose
##       between: what the file did not run stays where it is ((l)).
##   (l) A preserved hook is migrated only when the retired file present
##       actually RAN it. `<hook>.repo-workspaces-local` was run only by the
##       DISPATCHER: beside a lone WRAPPER (at the canonical path for
##       `ensure`, chained at `.repro-local` for `uninstall`) the wrapper is
##       removed and `.repo-workspaces-local` is left exactly as found, run by
##       no real commit, and nothing of it reaches the chain or the canonical
##       path. **The unfixed build migrates it into the chain under `ensure`,
##       so a commit starts running a hook nothing ran before, and refuses the
##       `uninstall` as a conflict with the wrapper's `.original`.**
##   (m) The same for a lone `<hook>.repo-workspaces-managed` (the
##       dispatcher's body, which never ran `.repo-workspaces-local` itself):
##       the body is removed, `.repo-workspaces-local` is left alone. A
##       regression guard, not a reproduction: the unfixed build already
##       left it, because a lone body was never at one of the three places
##       its dispatcher test looked.
##   (n) `<hook>.original` was run by the wrapper as `.git/hooks/<hook>.original`
##       relative to the repository's top level, so only from the default
##       hooks directory. In a repository whose `core.hooksPath` names another
##       directory holding a wrapper and a `.original`, the wrapper is removed
##       and `.original` is left untouched and unrun. A real commit through
##       the wrapper there is the positive control: it does not run
##       `.original`. **The unfixed build migrates it into the chain.**
##   (o)-(s) "The default hooks directory" means the directory the wrapper's
##       `.git/hooks` spelling REACHES from the top level, compared by file
##       identity — not a path that happens to end in `.git/hooks`. Git
##       resolves symlinks when it names the hooks directory, so with `.git`
##       a symlink (o) or `.git/hooks` a symlink (p) the directory is spelled
##       elsewhere and the wrapper still ran the `.original` in it: migrated.
##       A `core.hooksPath` naming this repository's own `.git/hooks` (q) is
##       that directory: migrated. One naming ANOTHER repository's
##       `.git/hooks` (r) is spelled like a default directory, but the
##       wrapper fired from this repository never ran the `.original` there:
##       left alone. `ensure` aimed at a linked worktree (s), whose `.git` is
##       a file, still migrates the main worktree's `.original`, which the
##       wrapper ran on every commit made there. Each case's control commit
##       shows what Git really ran. **A name-only test strands the user's hook
##       in (o) and (p) and starts running a never-run hook in (r).**
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
## Skip rule: `git` missing on PATH; (o) and (p) additionally on Windows,
## where creating a directory symlink needs a privilege only some accounts
## hold.

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

# Helpers for (o)-(s), which differ only in how the hooks directory is
# reached; see the header.

proc plantWrapperAndOriginal(fx: Fixture): string =
  ## The wrapper at the canonical post-commit path and the user's hook it
  ## preserved as `.original`; returns the user hook's bytes.
  fx.plantRetiredFramework()
  result = userHook("original", fx.userRan)
  plant(fx.slot("post-commit.original"), result)
  plant(fx.slot("post-commit"), retiredWrapperFor("post-commit"))

proc controlCommit(fx: Fixture; originalRuns: bool) =
  ## POSITIVE CONTROL: a real commit through the wrapper runs the retired
  ## check, and runs the user's `.original` exactly when ``originalRuns`` —
  ## the fixture is the state the case claims, so what `ensure` does with
  ## `.original` below is judged against what Git really ran.
  let c0 = fx.commit("through the retired wrapper")
  checkpoint("control commit: " & c0.output)
  check c0.code == 0
  check linesOf(fx.retiredRan) == @["post-commit"]
  if originalRuns:
    check linesOf(fx.userRan) == @["original"]
  else:
    check not fileExists(fx.userRan)
  if fileExists(fx.retiredRan): removeFile(fx.retiredRan)
  if fileExists(fx.userRan): removeFile(fx.userRan)

proc checkOriginalMigrated(fx: Fixture; original: string) =
  check fx.retiredFilesLeft().len == 0
  check readFile(fx.slot("post-commit")).contains(
    "reprobuild hook dispatcher")
  check not fileExists(fx.slot("post-commit.original"))
  check fileExists(fx.slot("post-commit.repro-local"))
  if fileExists(fx.slot("post-commit.repro-local")):
    check readFile(fx.slot("post-commit.repro-local")) == original
  let c = fx.commit("after ensure")
  checkpoint("commit: " & c.output)
  check c.code == 0
  check linesOf(fx.userRan) == @["original"]
  check not fileExists(fx.retiredRan)

proc checkOriginalLeft(fx: Fixture; original: string) =
  check fx.retiredFilesLeft().len == 0
  check readFile(fx.slot("post-commit")).contains(
    "reprobuild hook dispatcher")
  check not fileExists(fx.slot("post-commit.repro-local"))
  check fileExists(fx.slot("post-commit.original"))
  if fileExists(fx.slot("post-commit.original")):
    check readFile(fx.slot("post-commit.original")) == original
  let c = fx.commit("after ensure")
  checkpoint("commit: " & c.output)
  check c.code == 0
  check not fileExists(fx.userRan)
  check not fileExists(fx.retiredRan)

proc refreshHooks(fx: var Fixture) =
  fx.hooks = fx.mustRun(["git", "-C", fx.repoPath, "rev-parse",
    "--path-format=absolute", "--git-path", "hooks"]).strip()

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

  test "uninstall under a lone wrapper restores .original, not .repo-workspaces-local":
    if findExe("git").len == 0:
      skip("git not on PATH; this case needs a real repository whose hooks " &
        "a real commit fires")
    else:
      let fx = setupFixture("uninstall-wrapper-only")
      defer: removeDir(fx.scratch)

      check fx.ensureJson().code == 0
      # (l) A wrapper chained at `.repro-local`, the `.original` it ran, and a
      # `.repo-workspaces-local` beside them that no file present ever ran
      # (only a dispatcher runs it). Uninstall restores the wrapper's hook and
      # leaves the other where it is.
      fx.plantRetiredFramework()
      let original = userHook("original", fx.userRan)
      plant(fx.slot("post-commit.repro-local"),
        retiredWrapperFor("post-commit"))
      plant(fx.slot("post-commit.original"), original)
      let rwLocalRan = fx.scratch / "rw-local-ran.txt"
      let rwLocal = userHook("rw-local", rwLocalRan)
      plant(fx.slot("post-commit.repo-workspaces-local"), rwLocal)

      let res = fx.run([fx.reproBin, "hooks", "uninstall", "--vcs",
        fx.repoPath], fx.repoPath)
      checkpoint("uninstall: " & res.output)
      check res.code == 0
      check fx.retiredFilesLeft().len == 0
      check not fileExists(fx.slot("post-commit.repro-local"))
      check not fileExists(fx.slot("post-commit.original"))
      check fileExists(fx.slot("post-commit"))
      if fileExists(fx.slot("post-commit")):
        check readFile(fx.slot("post-commit")) == original
      check fileExists(fx.slot("post-commit.repo-workspaces-local"))
      if fileExists(fx.slot("post-commit.repo-workspaces-local")):
        check readFile(fx.slot("post-commit.repo-workspaces-local")) == rwLocal

      let c = fx.commit("after uninstall")
      checkpoint("commit: " & c.output)
      check c.code == 0
      check linesOf(fx.userRan) == @["original"]
      check not fileExists(rwLocalRan)
      check not fileExists(fx.retiredRan)

  test "lone wrapper beside a .repo-workspaces-local: wrapper removed, local left":
    if findExe("git").len == 0:
      skip("git not on PATH; this case needs a real repository whose hooks " &
        "a real commit fires")
    else:
      let fx = setupFixture("wrapper-rw-local")
      defer: removeDir(fx.scratch)

      # (l) The wrapper at the canonical path with no `.original`, and a
      # `.repo-workspaces-local` the wrapper never ran (it runs only
      # `.original`; only the dispatcher runs `.repo-workspaces-local`).
      fx.plantRetiredFramework()
      plant(fx.slot("post-commit"), retiredWrapperFor("post-commit"))
      let rwLocal = userHook("rw-local", fx.userRan)
      plant(fx.slot("post-commit.repo-workspaces-local"), rwLocal)

      # POSITIVE CONTROL: through the wrapper the retired check runs and
      # `.repo-workspaces-local` does not, so "not run" below means something.
      let c0 = fx.commit("through the retired wrapper")
      checkpoint("control commit: " & c0.output)
      check c0.code == 0
      check linesOf(fx.retiredRan) == @["post-commit"]
      check not fileExists(fx.userRan)
      if fileExists(fx.retiredRan): removeFile(fx.retiredRan)

      let e1 = fx.ensureJson()
      check e1.code == 0
      check e1.outcomes{"post-commit"}.getStr() == "removed-retired-dispatcher"
      check fx.retiredFilesLeft().len == 0
      check readFile(fx.slot("post-commit")).contains(
        "reprobuild hook dispatcher")
      check not fileExists(fx.slot("post-commit.repro-local"))
      check fileExists(fx.slot("post-commit.repo-workspaces-local"))
      if fileExists(fx.slot("post-commit.repo-workspaces-local")):
        check readFile(fx.slot("post-commit.repo-workspaces-local")) == rwLocal

      let c = fx.commit("after ensure")
      checkpoint("commit: " & c.output)
      check c.code == 0
      check not fileExists(fx.userRan)
      check not fileExists(fx.retiredRan)

      let snap = fx.snapshot()
      let e2 = fx.ensureJson()
      check e2.code == 0
      for hook, outcome in e2.outcomes:
        checkpoint(hook & ": " & outcome.getStr())
        check outcome.getStr() == "already-up-to-date"
      check fx.snapshot() == snap

  test "lone .repo-workspaces-managed beside a .repo-workspaces-local: local left":
    if findExe("git").len == 0:
      skip("git not on PATH; this case needs a real repository whose hooks " &
        "a real commit fires")
    else:
      let fx = setupFixture("managed-rw-local")
      defer: removeDir(fx.scratch)

      check fx.ensureJson().code == 0
      # (m) The dispatcher already deleted by hand: its body and the user's
      # preserved hook remain, and nothing runs either.
      plant(fx.slot("post-commit.repo-workspaces-managed"),
        retiredManagedStub("post-commit", fx.retiredRan))
      let rwLocal = userHook("rw-local", fx.userRan)
      plant(fx.slot("post-commit.repo-workspaces-local"), rwLocal)

      let e1 = fx.ensureJson()
      check e1.code == 0
      check e1.outcomes{"post-commit"}.getStr() == "removed-retired-dispatcher"
      check fx.retiredFilesLeft().len == 0
      check not fileExists(fx.slot("post-commit.repro-local"))
      check fileExists(fx.slot("post-commit.repo-workspaces-local"))
      if fileExists(fx.slot("post-commit.repo-workspaces-local")):
        check readFile(fx.slot("post-commit.repo-workspaces-local")) == rwLocal

      let c = fx.commit("after ensure")
      checkpoint("commit: " & c.output)
      check c.code == 0
      check not fileExists(fx.userRan)
      check not fileExists(fx.retiredRan)

  test "wrapper in a non-default core.hooksPath: .original left untouched":
    if findExe("git").len == 0:
      skip("git not on PATH; this case needs a real repository whose hooks " &
        "a real commit fires")
    else:
      var fx = setupFixture("hooks-path")
      defer: removeDir(fx.scratch)

      # (n) Hooks served from an absolute directory outside `.git`. The
      # wrapper runs `.git/hooks/<hook>.original` relative to the top level,
      # which is not this directory, so the `.original` beside it never ran.
      let shared = fx.scratch / "shared-hooks"
      createDir(shared)
      discard fx.mustRun(["git", "-C", fx.repoPath, "config",
        "core.hooksPath", shared])
      fx.hooks = fx.mustRun(["git", "-C", fx.repoPath, "rev-parse",
        "--path-format=absolute", "--git-path", "hooks"]).strip()
      check fx.hooks == shared
      fx.plantRetiredFramework()
      plant(fx.slot("post-commit"), retiredWrapperFor("post-commit"))
      let original = userHook("original", fx.userRan)
      plant(fx.slot("post-commit.original"), original)

      # POSITIVE CONTROL: git runs the wrapper from this directory (the
      # retired check runs), and the wrapper does not run `.original`.
      let c0 = fx.commit("through the retired wrapper")
      checkpoint("control commit: " & c0.output)
      check c0.code == 0
      check linesOf(fx.retiredRan) == @["post-commit"]
      check not fileExists(fx.userRan)
      if fileExists(fx.retiredRan): removeFile(fx.retiredRan)

      let e1 = fx.ensureJson()
      check e1.code == 0
      check e1.outcomes{"post-commit"}.getStr() == "removed-retired-dispatcher"
      check fx.retiredFilesLeft().len == 0
      check readFile(fx.slot("post-commit")).contains(
        "reprobuild hook dispatcher")
      check not fileExists(fx.slot("post-commit.repro-local"))
      check fileExists(fx.slot("post-commit.original"))
      if fileExists(fx.slot("post-commit.original")):
        check readFile(fx.slot("post-commit.original")) == original

      let c = fx.commit("after ensure")
      checkpoint("commit: " & c.output)
      check c.code == 0
      check not fileExists(fx.userRan)
      check not fileExists(fx.retiredRan)

  test "wrapper in a repository whose .git is a symlink: .original migrated":
    if findExe("git").len == 0:
      skip("git not on PATH; this case needs a real repository whose hooks " &
        "a real commit fires")
    elif defined(windows):
      skip("creating a directory symlink needs a privilege Windows grants " &
        "only to some accounts; the layout is POSIX-only here")
    else:
      var fx = setupFixture("symlinked-git")
      defer: removeDir(fx.scratch)

      # (o) The retired installer accepted it (`[[ -d "$repo/.git" ]]`
      # follows the link) and the wrapper's `.git/hooks/post-commit.original`
      # reaches the file through it. Git spells the hooks directory by the
      # link's target.
      let store = fx.scratch / "git-store" / "lib-a.git"
      createDir(parentDir(store))
      moveDir(fx.repoPath / ".git", store)
      createSymlink(store, fx.repoPath / ".git")
      fx.refreshHooks()
      check fx.hooks == store / "hooks"
      let original = fx.plantWrapperAndOriginal()
      fx.controlCommit(originalRuns = true)

      let e1 = fx.ensureJson()
      check e1.code == 0
      check e1.outcomes{"post-commit"}.getStr() == "removed-retired-dispatcher"
      fx.checkOriginalMigrated(original)

  test "wrapper in a symlinked .git/hooks: .original migrated":
    if findExe("git").len == 0:
      skip("git not on PATH; this case needs a real repository whose hooks " &
        "a real commit fires")
    elif defined(windows):
      skip("creating a directory symlink needs a privilege Windows grants " &
        "only to some accounts; the layout is POSIX-only here")
    else:
      var fx = setupFixture("symlinked-hooks")
      defer: removeDir(fx.scratch)

      # (p) `.git/hooks` itself a link to a directory outside `.git`.
      let target = fx.scratch / "hooks-store"
      moveDir(fx.repoPath / ".git" / "hooks", target)
      createSymlink(target, fx.repoPath / ".git" / "hooks")
      fx.refreshHooks()
      check fx.hooks == target
      let original = fx.plantWrapperAndOriginal()
      fx.controlCommit(originalRuns = true)

      let e1 = fx.ensureJson()
      check e1.code == 0
      check e1.outcomes{"post-commit"}.getStr() == "removed-retired-dispatcher"
      fx.checkOriginalMigrated(original)

  test "core.hooksPath naming this repository's own .git/hooks: .original migrated":
    if findExe("git").len == 0:
      skip("git not on PATH; this case needs a real repository whose hooks " &
        "a real commit fires")
    else:
      var fx = setupFixture("hooks-path-self")
      defer: removeDir(fx.scratch)

      # (q) A `core.hooksPath` that names the default directory is the
      # default directory: the wrapper there runs the `.original` beside it.
      discard fx.mustRun(["git", "-C", fx.repoPath, "config",
        "core.hooksPath", fx.repoPath / ".git" / "hooks"])
      fx.refreshHooks()
      let original = fx.plantWrapperAndOriginal()
      fx.controlCommit(originalRuns = true)

      let e1 = fx.ensureJson()
      check e1.code == 0
      check e1.outcomes{"post-commit"}.getStr() == "removed-retired-dispatcher"
      fx.checkOriginalMigrated(original)

  test "core.hooksPath naming ANOTHER repository's .git/hooks: .original left":
    if findExe("git").len == 0:
      skip("git not on PATH; this case needs a real repository whose hooks " &
        "a real commit fires")
    else:
      var fx = setupFixture("hooks-path-other")
      defer: removeDir(fx.scratch)

      # (r) The directory is SPELLED `<x>/.git/hooks`, but the wrapper in it,
      # fired from this repository, resolves `.git/hooks/post-commit.original`
      # against THIS top level and so never runs the `.original` beside it.
      let other = fx.scratch / "other"
      discard fx.mustRun(["git", "init", "-q", other])
      createDir(other / ".git" / "hooks")
      discard fx.mustRun(["git", "-C", fx.repoPath, "config",
        "core.hooksPath", other / ".git" / "hooks"])
      fx.refreshHooks()
      check fx.hooks == other / ".git" / "hooks"
      let original = fx.plantWrapperAndOriginal()
      fx.controlCommit(originalRuns = false)

      let e1 = fx.ensureJson()
      check e1.code == 0
      check e1.outcomes{"post-commit"}.getStr() == "removed-retired-dispatcher"
      fx.checkOriginalLeft(original)

  test "ensure run from a linked worktree: the main worktree's .original migrated":
    if findExe("git").len == 0:
      skip("git not on PATH; this case needs a real repository whose hooks " &
        "a real commit fires")
    else:
      let fx = setupFixture("linked-worktree")
      defer: removeDir(fx.scratch)

      # (s) The hooks directory is the main worktree's `.git/hooks`, and the
      # wrapper ran its `.original` on every commit made THERE. `ensure`
      # aimed at a linked worktree (whose `.git` is a file) still sees that.
      let original = fx.plantWrapperAndOriginal()
      fx.controlCommit(originalRuns = true)
      let linked = fx.scratch / "linked"
      discard fx.mustRun(["git", "-C", fx.repoPath, "worktree", "add", "-q",
        "--detach", linked])
      let res = fx.run([fx.reproBin, "hooks", "ensure", "--vcs", linked],
        linked)
      checkpoint("hooks ensure (linked): " & res.output)
      check res.code == 0
      fx.checkOriginalMigrated(original)

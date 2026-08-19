## A declared checkout path is a directory BENEATH the workspace root, and
## nothing downstream has to take that on trust.
##
## Why this matters more than it looks. Every consumer turns a declared path
## into `<workspaceRoot> / <path>`, and several of them delete the directory
## they compute: a half-finished clone is cleaned up by removing its target, a
## checkout that dies mid-filter is discarded the same way, and disabling a
## project removes the trees only it declared. All of that is correct exactly
## as long as the computed directory is the repo's own tree. Given
## `path = "."` the identical line computes the WORKSPACE ROOT; given
## `path = "../x"` it computes a sibling. So a degenerate value here is not a
## bad checkout — it is an unbounded recursive delete somewhere else on the
## disk, arriving through the recovery paths, which are the ones nobody
## exercises by hand.
##
## It is the same shape as the remote-alignment defect fixed alongside this:
## unrepresentable in a hand-written manifest, entirely reachable from a
## generator or a resolver bug. The guard used to live immediately in front of
## one `removeDir`, inside `workspace disable`. That is the wrong altitude — it
## protects one call site and leaves every other one exposed, which is how a
## guard that exists still fails to hold. It now lives at the schema boundary,
## so the degenerate value cannot reach any consumer at all.
##
## Asserted:
##   1. Reading a repo fragment whose `path` is `.`, `..`, a `..`-containing
##      path, an absolute path, or empty is REFUSED, and the diagnostic names
##      the offending fragment file and the key.
##   2. Ordinary paths — including nested ones like `a/b/c`, which real
##      manifests use for vendored reference trees — still resolve unchanged.
##      The guard must not be so eager that it breaks the layouts in use.
##   3. Belt to that pair of braces: handed such a path DIRECTLY, past the
##      reader, the clone action's cleanup still refuses to delete anything
##      outside the workspace root. Constructed in code because no valid
##      manifest can express it any more — which is the point, and also the
##      reason this half cannot be tested through the manifest.
##
## No mocks: real manifest files on disk read by the real reader, and a real
## clone action executed through the real build engine against a real
## `git init --bare` origin.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_build_engine
import repro_workspace_manifests
import git_actions
import git_tool

proc q(value: string): string = quoteShell(value)

proc requireGit(gitBin, args: string): string =
  let res = execCmdEx(q(gitBin) & " " & args)
  if res.exitCode != 0:
    checkpoint("git " & args & " failed: exit=" & $res.exitCode &
      "\n" & res.output)
    fail()
  res.output

proc writeFragment(path, name, checkoutPath: string) =
  writeFile(path,
    "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
    "[repo]\nname = \"" & name & "\"\npath = \"" & checkoutPath & "\"\n" &
    "remote = \"org\"\n")

suite "a declared checkout path cannot escape the workspace root":

  test "t_degenerate_checkout_paths_are_refused_at_the_schema_boundary":
    let scratch = createTempDir("repro-pathguard-reject-", "")
    defer: removeDir(scratch)

    # Each of these turns `<workspaceRoot> / <path>` into something that is not
    # the repo's own tree — the workspace root itself, or a directory outside
    # it entirely.
    const degenerate = [".", "..", "../sibling", "a/../..", "./.",
                        "nested/../../escape"]
    for idx, value in degenerate:
      let fragment = scratch / ("bad-" & $idx & ".toml")
      writeFragment(fragment, "bad-" & $idx, value)
      var refused = false
      try:
        discard readRepoFragment(fragment)
      except WorkspaceManifestParseError as err:
        refused = true
        # The diagnostic has to be actionable: which file, which key, and the
        # value that was rejected. "Invalid manifest" would send the reader
        # hunting through 163 fragments.
        check err.path == fragment
        check err.keyPath == "repo.path"
        check err.msg.contains(value)
      if not refused:
        checkpoint("checkout path '" & value & "' was accepted")
      check refused

    # An absolute path is refused too. Written separately because its spelling
    # differs per platform.
    let absolutePathValue =
      when defined(windows): "C:/somewhere/else"
      else: "/somewhere/else"
    let absFragment = scratch / "bad-abs.toml"
    writeFragment(absFragment, "bad-abs", absolutePathValue)
    var absRefused = false
    try:
      discard readRepoFragment(absFragment)
    except WorkspaceManifestParseError as err:
      absRefused = true
      check err.keyPath == "repo.path"
    check absRefused

    # ...and so is an empty one, which the pre-existing required-key check
    # already caught; asserted here so the two guards cannot both be removed
    # on the assumption that the other covers it.
    let emptyFragment = scratch / "bad-empty.toml"
    writeFragment(emptyFragment, "bad-empty", "")
    var emptyRefused = false
    try:
      discard readRepoFragment(emptyFragment)
    except WorkspaceManifestParseError as err:
      emptyRefused = true
      check err.keyPath == "repo.path"
    check emptyRefused

  test "t_ordinary_and_nested_checkout_paths_still_resolve":
    let scratch = createTempDir("repro-pathguard-accept-", "")
    defer: removeDir(scratch)

    # Nested paths are not exotic: real manifests check vendored reference
    # trees out underneath another repo's directory. A guard that rejected them
    # would be worse than the hazard it closes.
    const fine = ["lib-a", "reprobuild/references/buildxl",
                  "references-gpl/seL4", "a/b/c/d"]
    for idx, value in fine:
      let fragment = scratch / ("ok-" & $idx & ".toml")
      writeFragment(fragment, "ok-" & $idx, value)
      let read = readRepoFragment(fragment)
      check read.repo.path == value

  test "t_clone_cleanup_refuses_to_delete_outside_the_workspace_root":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-pathguard-clone-", "")
      defer: removeDir(scratch)
      let identity = ensureGitToolResolvable(tpmPathOnly, gitBin.parentDir)
      installGitVcsExecutor()

      # A real origin, so the only thing under test is where the cleanup
      # points — not whether the clone could have worked.
      let origin = scratch / "origin.git"
      let seed = scratch / "seed"
      discard requireGit(gitBin, "init --quiet --initial-branch main " & q(seed))
      writeFile(seed / "README.md", "seed\n")
      discard requireGit(gitBin, "-C " & q(seed) & " add .")
      discard requireGit(gitBin, "-C " & q(seed) &
        " -c user.email=t@example.invalid -c user.name=t commit --quiet -m seed")
      discard requireGit(gitBin, "clone --quiet --bare " & q(seed) & " " &
        q(origin))

      let workspaceRoot = scratch / "workspace"
      createDir(workspaceRoot)
      # Contents that must survive. The workspace root is deliberately NOT a
      # git checkout: that is what sends `executeClone` down its half-clone
      # cleanup branch, which is the branch that used to hold the unbounded
      # `removeDir`.
      writeFile(workspaceRoot / "precious.txt", "must survive\n")
      createDir(workspaceRoot / "precious-dir")
      writeFile(workspaceRoot / "precious-dir" / "inner.txt", "also\n")

      # `path = "."` — past the reader, which can no longer produce it. This is
      # the shape a synthesized action or a resolver defect hands over.
      var action = gitCloneAction("escape-clone", identity,
        remoteUrl = "file://" & origin.replace('\\', '/'),
        repoPath = ".",
        receiptPath = ".repro" / "escape.receipt",
        revision = "main")
      action.cwd = workspaceRoot
      var config = defaultBuildEngineConfig(scratch / "engine-cache")
      config.suppressTrace = true
      config.fallbackToRunQuotaBypass = true
      let res = runBuild(graph([action]), config)

      # The action FAILS — refusing to delete is the correct outcome, and a
      # refusal that reported success would be worse than the delete.
      check res.results.len == 1
      check res.results[0].status notin {asSucceeded, asCacheHit, asUpToDate}

      # ...and everything that was in the workspace root is still there.
      check dirExists(workspaceRoot)
      check fileExists(workspaceRoot / "precious.txt")
      check readFile(workspaceRoot / "precious.txt") == "must survive\n"
      check fileExists(workspaceRoot / "precious-dir" / "inner.txt")

      # A sibling-escaping path is refused the same way, and the sibling is
      # untouched.
      let sibling = scratch / "sibling"
      createDir(sibling)
      writeFile(sibling / "not-ours.txt", "leave me\n")
      var escape = gitCloneAction("escape-clone-2", identity,
        remoteUrl = "file://" & origin.replace('\\', '/'),
        repoPath = ".." / "sibling",
        receiptPath = ".repro" / "escape2.receipt",
        revision = "main")
      escape.cwd = workspaceRoot
      let res2 = runBuild(graph([escape]), config)
      check res2.results.len == 1
      check res2.results[0].status notin {asSucceeded, asCacheHit, asUpToDate}
      check fileExists(sibling / "not-ours.txt")
      check readFile(sibling / "not-ours.txt") == "leave me\n"

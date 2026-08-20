## Workspace sibling ignore set — the four properties that make the managed
## ``.git/info/exclude`` block safe to regenerate on every workspace command.
##
## Spec: ``reprobuild-specs/Workspace-Sibling-Ignore-Set.md``. Ported from the
## retired ``repo-workspaces`` routine (``bin/workspace.nim``'s
## ``updateManagedGitExclude``).
##
## No mocks. Each case builds a REAL git checkout in a temp directory, creates
## real sibling directories and real symlinks, and drives the real
## ``refreshWorkspaceSiblingIgnores`` against the real ``git`` binary. The
## properties under test (what git considers tracked; how git distinguishes a
## symlink from a directory) are only meaningful against git itself, so a fake
## would test nothing.
##
## Cases:
##   - ``regeneration_preserves_user_entries`` — hand-written lines outside
##     the marker block survive. This is the load-bearing property: without
##     it, "regenerate on every workspace verb" silently eats hand-added
##     ignores.
##   - ``tracked_directory_is_not_ignored`` — a tracked directory never
##     enters the set, and one that BECOMES tracked leaves it.
##   - ``symlinked_checkout_uses_the_no_slash_form`` — ``/name`` for a
##     symlinked checkout, ``/name/`` for a real directory.
##   - ``regeneration_is_idempotent`` — two runs produce byte-identical
##     bytes and the second reports no change.
##
## Skip rule: ``git`` missing on PATH (the convention the workspace suite
## already follows).

import std/[algorithm, os, osproc, strutils, tempfiles, unittest]

import sibling_ignores

proc q(value: string): string = quoteShell(value)

proc git(gitBin, cwd: string; args: varargs[string]): string =
  var cmd = q(gitBin)
  for a in args:
    cmd.add(" " & q(a))
  let res = execCmdEx(cmd, workingDir = cwd)
  if res.exitCode != 0:
    checkpoint("git failed: " & cmd & "\nexit=" & $res.exitCode &
      "\n" & res.output)
    doAssert false, "git command failed"
  res.output

proc seedWorkspaceRoot(gitBin, root: string) =
  ## A workspace root is an ordinary git checkout carrying the manifests.
  createDir(root)
  discard git(gitBin, root, "init", "-b", "main", ".")
  discard git(gitBin, root, "config", "user.email", "tester@example.invalid")
  discard git(gitBin, root, "config", "user.name", "Sibling Ignore Tester")
  writeFile(root / "README.md", "workspace manifests\n")
  discard git(gitBin, root, "add", "README.md")
  discard git(gitBin, root, "commit", "-m", "seed")

proc excludePath(root: string): string =
  root / ".git" / "info" / "exclude"

proc managedBlock(text: string): seq[string] =
  ## The lines strictly between the markers (markers excluded).
  var inside = false
  for line in text.splitLines():
    if line == SiblingIgnoreBeginMarker:
      inside = true
      continue
    if line == SiblingIgnoreEndMarker:
      inside = false
      continue
    if inside:
      result.add(line)

proc markerCount(text, marker: string): int =
  for line in text.splitLines():
    if line == marker:
      inc result

suite "workspace sibling ignore set":

  test "regeneration_preserves_user_entries":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-sibling-ignore-preserve-", "")
      defer: removeDir(scratch)
      let root = scratch / "workspace"
      seedWorkspaceRoot(gitBin, root)
      createDir(root / "sibling-a")

      let first = refreshWorkspaceSiblingIgnores(gitBin, root)
      check first.ok
      check first.changed

      # A developer edits the file by hand: one line ABOVE the managed block
      # and one BELOW it. Both are outside the markers, so both must survive.
      let handAbove = "my-local-scratch/"
      let handBelow = "*.local-notes"
      block:
        var text = readFile(excludePath(root))
        text = text.replace(SiblingIgnoreBeginMarker,
          handAbove & "\n" & SiblingIgnoreBeginMarker)
        if not text.endsWith("\n"): text.add("\n")
        text.add(handBelow & "\n")
        writeFile(excludePath(root), text)

      # The sibling set changes, so the block genuinely has to be rewritten.
      createDir(root / "sibling-b")
      let second = refreshWorkspaceSiblingIgnores(gitBin, root)
      check second.ok

      let after = readFile(excludePath(root))
      let inside = managedBlock(after)

      # PRIMARY: both hand-written lines survived a rewrite of the block.
      check handAbove in after.splitLines()
      check handBelow in after.splitLines()
      # ...and they are the user's lines, not managed ones: they live OUTSIDE
      # the markers, so a future regeneration will not drop them either.
      check handAbove notin inside
      check handBelow notin inside

      # Secondary: the rewrite did what it was for.
      check "/sibling-b/" in inside
      check "/sibling-a/" in inside
      check markerCount(after, SiblingIgnoreBeginMarker) == 1
      check markerCount(after, SiblingIgnoreEndMarker) == 1

  test "tracked_directory_is_not_ignored":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-sibling-ignore-tracked-", "")
      defer: removeDir(scratch)
      let root = scratch / "workspace"
      seedWorkspaceRoot(gitBin, root)

      # A REAL source directory the workspace repo tracks...
      createDir(root / "projects")
      writeFile(root / "projects" / "codetracer.toml", "name = \"ct\"\n")
      discard git(gitBin, root, "add", "projects/codetracer.toml")
      discard git(gitBin, root, "commit", "-m", "add projects")

      # ...and a sibling checkout it does not.
      createDir(root / "sibling-checkout")
      writeFile(root / "sibling-checkout" / "file.txt", "hello\n")

      let first = refreshWorkspaceSiblingIgnores(gitBin, root)
      check first.ok
      let firstInside = managedBlock(readFile(excludePath(root)))

      # PRIMARY: a tracked directory never enters the set. If it did, it would
      # disappear from `git status` and its changes would go unnoticed.
      check "/projects/" notin firstInside
      check "/projects" notin firstInside
      check "/sibling-checkout/" in firstInside

      # Now the sibling BECOMES tracked. The next regeneration must drop it.
      discard git(gitBin, root, "add", "-f", "sibling-checkout/file.txt")
      discard git(gitBin, root, "commit", "-m", "absorb sibling")

      let second = refreshWorkspaceSiblingIgnores(gitBin, root)
      check second.ok
      let secondInside = managedBlock(readFile(excludePath(root)))

      # PRIMARY: it left the set.
      check "/sibling-checkout/" notin secondInside
      check "/sibling-checkout" notin secondInside
      check "/projects/" notin secondInside

  test "symlinked_checkout_uses_the_no_slash_form":
    let gitBin = findExe("git")
    if gitBin.len == 0 or defined(windows):
      skip()
    else:
      let scratch = createTempDir("repro-sibling-ignore-symlink-", "")
      defer: removeDir(scratch)
      let root = scratch / "workspace"
      seedWorkspaceRoot(gitBin, root)

      # A real checkout beside the manifests...
      createDir(root / "real-checkout")
      # ...and a worktree/shared-clone style checkout materialized as a
      # symlink to a directory living outside the workspace.
      let elsewhere = scratch / "elsewhere"
      createDir(elsewhere)
      createSymlink(elsewhere, root / "linked-checkout")

      let res = refreshWorkspaceSiblingIgnores(gitBin, root)
      check res.ok
      let inside = managedBlock(readFile(excludePath(root)))

      # PRIMARY: a symlinked checkout is named WITHOUT the trailing slash —
      # git's `name/` form matches directories only and would not match the
      # symlink entry at all.
      check "/linked-checkout" in inside
      check "/linked-checkout/" notin inside

      # PRIMARY (the other half of the distinction): a real directory keeps
      # the trailing slash.
      check "/real-checkout/" in inside
      check "/real-checkout" notin inside

  test "regeneration_is_idempotent":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-sibling-ignore-idempotent-", "")
      defer: removeDir(scratch)
      let root = scratch / "workspace"
      seedWorkspaceRoot(gitBin, root)
      for name in ["zeta-repo", "alpha-repo", "middle-repo"]:
        createDir(root / name)

      let first = refreshWorkspaceSiblingIgnores(gitBin, root)
      check first.ok
      check first.changed
      let firstBytes = readFile(excludePath(root))

      let second = refreshWorkspaceSiblingIgnores(gitBin, root)
      check second.ok
      let secondBytes = readFile(excludePath(root))

      # PRIMARY: byte-identical. Anything else churns the file on every
      # workspace command.
      check secondBytes == firstBytes
      # A third pass, because a duplicated block only shows up once a
      # previously-written block exists to be mishandled.
      let third = refreshWorkspaceSiblingIgnores(gitBin, root)
      check third.ok
      check readFile(excludePath(root)) == firstBytes

      # Secondary: an unchanged result does not rewrite the file at all.
      check not second.changed
      check not third.changed
      # Secondary: entries are sorted, which is what makes the bytes stable
      # independent of directory-iteration order.
      let inside = managedBlock(firstBytes)
      var entriesOnly: seq[string]
      for line in inside:
        if not line.startsWith("#"):
          entriesOnly.add(line)
      check "/alpha-repo/" in entriesOnly
      check "/middle-repo/" in entriesOnly
      check "/zeta-repo/" in entriesOnly
      check entriesOnly == entriesOnly.sorted()

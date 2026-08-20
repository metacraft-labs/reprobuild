## Workspace VCS — the per-clone sibling ignore set.
##
## A workspace root is itself a git checkout (it carries the manifests),
## and every participating repo is cloned *beside* those manifests. Left
## alone, git reports each sibling checkout as an untracked directory, so
## `git status`, `git add -A`, and every tool that reasons about a dirty
## tree has to work around a list that grows with the project set.
##
## This module maintains a marker-delimited block inside the workspace
## root's ``.git/info/exclude`` naming those siblings. It is a port of the
## routine that shipped in the retired ``repo-workspaces`` tool
## (``bin/workspace.nim``'s ``updateManagedGitExclude``); see
## ``reprobuild-specs/Workspace-Sibling-Ignore-Set.md``. Five properties
## are load-bearing and are preserved verbatim:
##
## 1. **Only what git is not already tracking is ignored.** Each candidate
##    is probed with ``git ls-files --error-unmatch`` and skipped when the
##    probe succeeds. A directory that later *becomes* tracked therefore
##    drops out of the set on the next regeneration instead of silently
##    vanishing from ``git status``.
## 2. **Symlinked checkouts use the no-slash form** (``/name``) and real
##    directories the trailing-slash form (``/name/``). Worktree-based and
##    shared-clone layouts materialize siblings as symlinks, and a
##    trailing slash does not match a symlink.
## 3. **The block is marker-delimited** and everything outside it is
##    preserved byte-for-byte. This is what makes "regenerate on every
##    workspace command" safe rather than destructive of hand-added
##    entries.
## 4. **Git's default header is seeded** when the file does not exist, so
##    the result reads like a normal ``info/exclude`` rather than a tool
##    artifact.
## 5. **Entries are sorted**, so regeneration is stable and produces no
##    spurious churn.
##
## The ignore set is deliberately per-clone (``.git/info/exclude``) rather
## than a tracked ``.gitignore``: which siblings exist is a property of
## *this machine's* workspace membership, not of the manifest, and a
## tracked file would churn whenever anyone enabled a different project
## set.
##
## Like ``shared_clones``, the module shells out to a caller-provided
## ``git`` binary path via ``execCmdEx`` — no new third-party dependency.
## Discovery of *declared* (possibly nested) checkout paths is NOT
## reimplemented here: callers pass the paths their existing workspace
## enumeration already resolved, which keeps this module free of manifest
## knowledge.

import std/[algorithm, os, osproc, strutils]

import git_tool

const
  SiblingIgnoreBeginMarker* = "# BEGIN managed workspace ignores"
    ## First line of the managed block. Matched exactly (after no
    ## trimming) when stripping a previous block.
  SiblingIgnoreEndMarker* = "# END managed workspace ignores"
    ## Last line of the managed block.
  SiblingIgnoreBannerLines*: array[3, string] = [
    "# This section is auto-maintained by reprobuild's workspace commands.",
    "# It names workspace sibling checkouts (manifest-managed, " &
      "worktree-based, and standalone clones).",
    "# Refresh it by rerunning `repro workspace sync` " &
      "(or enable/disable/pull/init)."]
    ## Explanatory comment lines emitted directly under the begin marker.
  GitDefaultExcludeHeader*: array[2, string] = [
    "# git ls-files --others --exclude-from=.git/info/exclude",
    "# Lines that start with '#' are comments."]
    ## Git's own seed header, written when ``info/exclude`` is absent.

type
  SiblingIgnoreResult* = object
    ## Outcome of one regeneration. Every caller is best-effort: the
    ## ignore set is an ergonomic convenience, so a failure to resolve the
    ## git dir or write the file must never fail the workspace command
    ## that triggered it. ``ok == false`` carries the reason in
    ## ``diagnostic``.
    ok*: bool
    excludeFile*: string
      ## Absolute path of the ``info/exclude`` that was written; empty
      ## when the git dir could not be resolved.
    entries*: seq[string]
      ## The sorted managed entries, exactly as written into the block.
    changed*: bool
      ## ``true`` when the on-disk bytes differ from what was already
      ## there. Idempotent re-runs report ``false`` and do not rewrite.
    diagnostic*: string

proc runGit(gitBin: string; args: openArray[string];
            workingDir = ""): tuple[code: int; output: string] =
  var cmd = quoteShell(gitBin)
  for arg in args:
    cmd.add(" ")
    cmd.add(quoteShell(arg))
  let res = execCmdEx(cmd, workingDir = workingDir,
    env = scrubbedGitRepositoryEnv())
  (code: res.exitCode, output: res.output)

proc isTracked(gitBin, workspaceRoot, relPath: string): bool =
  ## ``git ls-files --error-unmatch <path>`` exits 0 when the pathspec
  ## matches at least one tracked file — for a directory, when git tracks
  ## anything beneath it. Property (1): such a path is NOT ignored.
  runGit(gitBin, ["-C", workspaceRoot, "ls-files", "--error-unmatch",
    "--", relPath]).code == 0

proc ignoreEntryFor(relPath: string; symlinked: bool): string =
  ## Property (2). A leading ``/`` anchors the pattern at the repository
  ## root (so a sibling named ``build`` cannot also mask ``foo/build``);
  ## the trailing ``/`` restricts the match to real directories and is
  ## therefore omitted for a symlinked checkout, which git sees as a
  ## symlink entry rather than a directory.
  let normalized = relPath.strip(chars = {'/'}).replace('\\', '/')
  if symlinked: "/" & normalized
  else: "/" & normalized & "/"

proc collectSiblingIgnoreEntries*(gitBin, workspaceRoot: string;
    declaredPaths: openArray[string] = []): seq[string] =
  ## Sorted, de-duplicated managed entries for ``workspaceRoot``.
  ##
  ## Candidates are every top-level directory (or symlink-to-directory)
  ## in the workspace root, plus each path in ``declaredPaths`` — the
  ## repo-relative checkout paths the caller's own workspace enumeration
  ## resolved, which is how *nested* checkouts (``a/references/b``) are
  ## covered without reimplementing manifest discovery here. Paths that
  ## do not exist on disk, and paths git already tracks, are dropped.
  var seen: seq[string]
  var entries: seq[string]

  proc consider(relPath: string; symlinked: bool) =
    let key = relPath.strip(chars = {'/'})
    if key.len == 0 or key in seen:
      return
    seen.add(key)
    if isTracked(gitBin, workspaceRoot, key):
      return
    entries.add(ignoreEntryFor(key, symlinked))

  for kind, path in walkDir(workspaceRoot):
    if kind notin {pcDir, pcLinkToDir}:
      continue
    consider(extractFilename(path), kind == pcLinkToDir)

  for declared in declaredPaths:
    let rel = declared.strip().replace('\\', '/').strip(chars = {'/'})
    if rel.len == 0 or rel == ".":
      continue
    let abs = workspaceRoot / rel
    if not dirExists(abs):
      # Not present (or a dangling symlink / plain file): nothing to ignore.
      continue
    consider(rel, symlinkExists(abs))

  entries.sort()
  entries

proc renderSiblingIgnoreFile*(previous: string; hadFile: bool;
                              entries: openArray[string]): string =
  ## Pure renderer: given the previous ``info/exclude`` text (and whether
  ## the file existed at all) plus the managed entries, produce the new
  ## text.
  ##
  ## Property (3): everything outside a previously written managed block
  ## is carried through unchanged and the new block is appended at the
  ## end. Property (4): when the file did not exist, git's own header is
  ## seeded first.
  var blockLines = @[SiblingIgnoreBeginMarker]
  for line in SiblingIgnoreBannerLines:
    blockLines.add(line)
  for entry in entries:
    blockLines.add(entry)
  blockLines.add(SiblingIgnoreEndMarker)

  var remaining: seq[string] = @[]
  if hadFile:
    var skipping = false
    for line in previous.splitLines():
      if line == SiblingIgnoreBeginMarker:
        skipping = true
        continue
      if line == SiblingIgnoreEndMarker:
        skipping = false
        continue
      if not skipping:
        remaining.add(line)
    while remaining.len > 0 and remaining[^1].strip().len == 0:
      remaining.setLen(remaining.len - 1)
  else:
    for line in GitDefaultExcludeHeader:
      remaining.add(line)

  var finalLines = remaining
  if finalLines.len > 0 and finalLines[^1].strip().len != 0:
    finalLines.add("")
  finalLines.add(blockLines)
  finalLines.join("\n") & "\n"

proc refreshWorkspaceSiblingIgnores*(gitBin, workspaceRoot: string;
    declaredPaths: openArray[string] = []): SiblingIgnoreResult =
  ## Regenerate the managed block in ``<workspaceRoot>/.git/info/exclude``.
  ##
  ## Best-effort by construction: a workspace root that is not a git
  ## checkout, or an unreadable/unwritable exclude file, returns
  ## ``ok == false`` with a diagnostic rather than raising. Safe to call
  ## unconditionally from any workspace verb — the marker block makes it
  ## idempotent, and an unchanged result does not touch the file (so the
  ## mtime stays put and nothing re-triggers a watcher).
  result.ok = false
  if gitBin.len == 0:
    result.diagnostic = "no git binary resolved"
    return
  if workspaceRoot.len == 0 or not dirExists(workspaceRoot):
    result.diagnostic = "workspace root does not exist: " & workspaceRoot
    return

  let gitDir = runGit(gitBin, ["-C", workspaceRoot, "rev-parse",
    "--absolute-git-dir"])
  let gitDirPath = gitDir.output.strip()
  if gitDir.code != 0 or gitDirPath.len == 0:
    result.diagnostic = "workspace root is not a git checkout: " & workspaceRoot
    return

  let excludeFile = gitDirPath / "info" / "exclude"
  result.excludeFile = excludeFile

  try:
    result.entries = collectSiblingIgnoreEntries(gitBin, workspaceRoot,
      declaredPaths)
    let hadFile = fileExists(excludeFile)
    let previous = if hadFile: readFile(excludeFile) else: ""
    let rendered = renderSiblingIgnoreFile(previous, hadFile, result.entries)
    if hadFile and previous == rendered:
      result.ok = true
      result.changed = false
      return
    createDir(parentDir(excludeFile))
    writeFile(excludeFile, rendered)
    result.ok = true
    result.changed = true
  except CatchableError as err:
    result.ok = false
    result.diagnostic = "could not update " & excludeFile & ": " & err.msg

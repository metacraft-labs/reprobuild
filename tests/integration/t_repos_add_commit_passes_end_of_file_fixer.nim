## `repro workspace repos add` must leave every manifest it edits ending in
## exactly ONE newline, so the commit it then makes is not refused by the
## manifest repo's own `end-of-file-fixer` pre-commit hook.
##
## Regression origin (reprobuild-pm issue
## `2026-10-03-repos-add-writes-manifests-its-own-hook-rewrites.md`): five
## `repos add` runs against the metacraft manifest repo; the last three left
## their edits staged and uncommitted. The format-preserving editor keeps each
## line's original terminator, so it also kept a defective file END:
## `projects/agent-harbor.toml` ended in "\n\n" and still did after a
## `[[remote]]` block was appended; another project had no final newline and
## still had none after `member_repos` grew. `end-of-file-fixer` rewrote both
## files, the rewrite collided with the hook framework's stash, the framework
## rolled back, and the commit never landed.
##
## Both shapes are asserted here against a real `git commit`:
##
## * `projects/demo.toml` ends in "\n\n" after its last `[[remote]]` block,
##   and the added repo's URL is served by none of its remotes, so the verb
##   APPENDS a `[[remote]]` block (`ensureArrayTableEntry`) — the agent-harbor
##   shape;
## * `projects/other.toml` has no final newline and its declared remote
##   already serves the URL, so the only edit is the `member_repos` array —
##   the unterminated last line is untouched by the edit itself.
##
## MOCKS: one, justified. The repo's managed hook set runs `end-of-file-fixer`
## through the pre-commit framework, which this suite cannot assume is
## installed (and which would need network to fetch its hook repos). It is
## stood in for by a 10-line `pre-commit` shell hook enforcing the same rule
## — every staged added/modified file is empty or ends in exactly one "\n" —
## and REFUSING the commit otherwise, which is the observable effect the real
## hook had. Everything else is real: the real `repro` binary, a real git
## manifest repo, a real `git commit` running the hook through
## `core.hooksPath`. The repos' remotes are local bare repositories that carry
## the `main` branch, so the verb's `ls-remote` probe of `--branch` is answered
## without network.
##
## Skip rule: `git` missing on PATH.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_test_support/reasoned_skip

proc q(value: string): string = quoteShell(value)

proc runCmd(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  let res = runCmd(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc repoRoot(): string =
  result = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc endsInExactlyOneNewline(text: string): bool =
  ## `end-of-file-fixer`'s rule: an empty file, or one whose last byte is a
  ## newline that is not preceded by another (no trailing empty lines).
  text.len == 0 or (text.endsWith("\n") and not text.endsWith("\n\n"))

proc makeBareRemote(path: string) =
  ## A bare repository carrying a `main` branch, so `ls-remote --heads <url>
  ## main` answers locally.
  let seed = path & "-seed"
  createDir(seed)
  discard requireGit("git init -q -b main .", seed)
  discard requireGit("git -c user.email=t@example.com -c user.name=Test " &
    "-c core.hooksPath=/dev/null commit -q --allow-empty -m seed", seed)
  discard requireGit("git clone -q --bare " & q(seed) & " " & q(path))

const eofFixerHook = """#!/bin/sh
# Stand-in for pre-commit's end-of-file-fixer: refuse the commit when a staged
# added/modified file is non-empty and does not end in exactly one newline.
status=0
for f in $(git diff --cached --name-only --diff-filter=AM); do
  [ -s "$f" ] || continue
  last=$(tail -c 1 "$f" | od -An -c | tr -d ' ')
  last2=$(tail -c 2 "$f" | od -An -c | tr -d ' ')
  if [ "$last" != '\n' ] || [ "$last2" = '\n\n' ]; then
    echo "end-of-file-fixer: would fix $f" >&2; status=1
  fi
done
exit $status
"""

suite "repos add commits past end-of-file-fixer":

  test "edited project manifests end in exactly one newline and commit":
    if findExe("git").len == 0:
      skip("git is not on PATH")
      return

    let root = createTempDir("repro-repos-add-eof-", "")
    defer: removeDir(root)

    let remotes = root / "remotes"
    createDir(remotes)
    makeBareRemote(remotes / "one")
    makeBareRemote(remotes / "two")
    let remoteBase = "file://" & remotes

    let manifestRoot = root / "manifests"
    createDir(manifestRoot / "projects")
    let demoPath = manifestRoot / "projects" / "demo.toml"
    let otherPath = manifestRoot / "projects" / "other.toml"
    # Ends in "\n\n" after the last [[remote]] block; no remote serves
    # `remotes/one`, so `repos add` appends a block after this one.
    writeFile(demoPath, "schema = \"reprobuild.workspace.project.v1\"\n\n" &
      "member_repos = [\n  \"existing\",\n]\n\n[project]\nname = \"demo\"\n\n" &
      "[[remote]]\nname = \"elsewhere\"\n" &
      "fetch = \"https://example.invalid/elsewhere\"\n\n")
    # No final newline; the declared remote serves `remotes/two`, so the only
    # edit is the membership array.
    writeFile(otherPath, "schema = \"reprobuild.workspace.project.v1\"\n\n" &
      "member_repos = [\n  \"existing\",\n]\n\n[project]\nname = \"other\"\n" &
      "default_remote = \"local\"\n\n[[remote]]\nname = \"local\"\n" &
      "fetch = \"" & remoteBase & "\"")

    discard requireGit("git init -q .", manifestRoot)
    discard requireGit("git config user.email t@example.com", manifestRoot)
    discard requireGit("git config user.name Test", manifestRoot)
    discard requireGit("git add -A", manifestRoot)
    # The seed files are defective on purpose; only the verb's commits are
    # subject to the hook.
    discard requireGit("git -c core.hooksPath=/dev/null commit -q -m init",
      manifestRoot)
    let hooks = root / "hooks"
    createDir(hooks)
    writeFile(hooks / "pre-commit", eofFixerHook)
    setFilePermissions(hooks / "pre-commit",
      {fpUserRead, fpUserWrite, fpUserExec})
    discard requireGit("git config core.hooksPath " & q(hooks), manifestRoot)

    let repro = reproBinary()
    for (repo, project, path) in [("one", "demo", demoPath),
                                  ("two", "other", otherPath)]:
      let before = requireGit("git rev-list --count HEAD", manifestRoot).strip()
      let res = runCmd(q(repro) & " workspace repos add " & repo &
        " --remote=" & q(remoteBase & "/" & repo) &
        " --branch=main --project=" & project & " -m " & q("repo " & repo),
        manifestRoot)
      checkpoint(repo & ": exit=" & $res.code & "\n" & res.output)
      check res.code == 0
      let after = requireGit("git rev-list --count HEAD", manifestRoot).strip()
      check after.parseInt == before.parseInt + 1
      let rel = "projects/" & project & ".toml"
      check requireGit("git status --porcelain -- " & q(rel) & " " &
        q("repos/" & repo & ".toml") & " " & q("repos/" & repo & ".md"),
        manifestRoot).strip() == ""
      check requireGit("git show --name-only --format= HEAD",
        manifestRoot).contains(rel)
      let text = readFile(path)
      checkpoint(rel & ": " & text.escape)
      check endsInExactlyOneNewline(text)
      check ("\"" & repo & "\"") in text
      check endsInExactlyOneNewline(
        readFile(manifestRoot / "repos" / (repo & ".toml")))
    # The demo edit is the one that appended a remote block.
    check readFile(demoPath).count("[[remote]]") == 2
    check readFile(otherPath).count("[[remote]]") == 1

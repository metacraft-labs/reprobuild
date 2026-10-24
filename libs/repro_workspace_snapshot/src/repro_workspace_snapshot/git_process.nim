## Running git for snapshot capture and materialization — Distributed-Execution
## M1 (shared with the M7 materializer).
##
## Every git command here runs with an environment BUILT, not inherited: only
## `PATH`, `HOME`, `TMPDIR` and `SYSTEMROOT` pass through, system config is
## off and prompting is off, so a `GIT_DIR`, `GIT_INDEX_FILE` or
## `GIT_WORK_TREE` in the caller's environment (a hook, an editor) can never
## redirect a command at the user's real index. The binary is whatever the
## caller names (`gitExe`); nothing here runs a binary a remote caller
## supplied.
##
## stdout and stderr are read from separate pipes for commands whose output is
## parsed (an object id parsed out of a stream with a warning interleaved
## would be wrong rather than noisy). The commands parsed here (`rev-parse`,
## `ls-files`, `diff-index`, `write-tree`, `cat-file blob`)
## write next to nothing to stderr; commands that may warn per file (`add`)
## run with the streams merged.

import std/[os, osproc, streams, strtabs, strutils, tables]

import repro_core/ambient_execution

type
  GitRun* = object
    code*: int
    output*: string
      ## stdout (and stderr, when merged).
    errors*: string
      ## stderr, when not merged.

proc gitEnvironment*(extraEnv: openArray[(string, string)]): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for key in ["PATH", "HOME", "TMPDIR", "SYSTEMROOT"]:
    if existsEnv(key): result[key] = getEnv(key)
  result["GIT_CONFIG_NOSYSTEM"] = "1"
  result["GIT_TERMINAL_PROMPT"] = "0"
  # Read-only commands must not refresh (write) any index opportunistically.
  result["GIT_OPTIONAL_LOCKS"] = "0"
  # Read the objects the ids NAME, never a `refs/replace/*` substitute: a
  # replace ref in a cache would otherwise make `ls-tree` list another tree
  # for a base commit and `cat-file` return another blob's bytes
  # (https://git-scm.com/docs/git-replace).
  result["GIT_NO_REPLACE_OBJECTS"] = "1"
  for (k, v) in extraEnv: result[k] = v

proc runGit*(gitExe: string; args: openArray[string];
             extraEnv: openArray[(string, string)] = [];
             input = ""; cwd = ""; mergeStderr = true): GitRun =
  ## Runs `gitExe args` and waits for it. `input` is written to its stdin
  ## (then closed) before any output is read; keep it to what the command
  ## consumes without answering line by line (`--stdin` path lists).
  var options = {poUsePath}
  if mergeStderr: options.incl(poStdErrToStdOut)
  let p = uncontrolledStartProcess(gitExe, workingDir = cwd, args = @args,
    env = gitEnvironment(extraEnv), options = options)
  defer: p.close()
  let stdinStream = p.inputStream
  if input.len > 0:
    stdinStream.write(input)
  stdinStream.close()
  result.output = p.outputStream.readAll()
  if not mergeStderr:
    result.errors = p.errorStream.readAll()
  result.code = p.waitForExit()

proc runGitBounded*(gitExe: string; args: openArray[string];
                    maxBytes: int; input = ""; cwd = ""):
    tuple[run: GitRun; truncated: bool] =
  ## Like `runGit` (stderr kept apart), but stops reading stdout after
  ## `maxBytes + 1` bytes: the process is then killed and `truncated` is
  ## set, so an oversized output is never buffered whole.
  let p = uncontrolledStartProcess(gitExe, workingDir = cwd, args = @args,
    env = gitEnvironment([]), options = {poUsePath})
  defer: p.close()
  let stdinStream = p.inputStream
  if input.len > 0:
    stdinStream.write(input)
  stdinStream.close()
  let outStream = p.outputStream
  var buf = newString(64 * 1024)
  while true:
    let n = outStream.readData(addr buf[0], buf.len)
    if n <= 0:
      break
    result.run.output.add(buf[0 ..< n])
    if result.run.output.len > maxBytes:
      result.truncated = true
      p.kill()
      break
  if result.truncated:
    discard p.waitForExit()
    result.run.code = -1
  else:
    result.run.errors = p.errorStream.readAll()
    result.run.code = p.waitForExit()

proc describe*(run: GitRun): string =
  ## The diagnostic of a failed command, one line.
  let text = (if run.errors.len > 0: run.errors else: run.output).strip()
  "exit " & $run.code & (if text.len > 0: ": " & text.splitLines()[0] else: "")

proc nulRecords*(output: string): seq[string] =
  for rec in output.split('\0'):
    if rec.len > 0: result.add(rec)

proc gitDirOf*(repoCache: string): string =
  ## The git directory of a repository cache: `<cache>/.git` for a
  ## non-bare repository, the cache itself for a bare one.
  if dirExists(repoCache / ".git"): repoCache / ".git" else: repoCache

# ---------------------------------------------------------------------------
# Canonical checkouts (Distributed-Execution M1 review fix, 2026-10-22).
# ---------------------------------------------------------------------------

const
  EmptyTreeId* = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
    ## git's empty tree (every repository knows it without storing it).
  MinCanonicalGitVersion* = (2, 40)
    ## `git --attr-source` (attributes read from a tree) appeared in 2.40.

proc canonicalCheckoutArgs*(): seq[string] =
  ## Global options that make a checkout (`read-tree -u`, `checkout-index`)
  ## write the BLOB bytes, with no conversion: attributes come from the
  ## empty tree (`--attr-source`, so no `.gitattributes` in the commit, the
  ## index or the worktree applies — no `text`/`eol`, `ident`, `filter=`
  ## smudge or process, `working-tree-encoding`), no attributes file of the
  ## user's, and `core.autocrlf=false` (which converts even without any
  ## attribute). The system attributes file is off through the environment
  ## (`canonicalCheckoutEnv`). `$GIT_DIR/info/attributes` is still read by
  ## git, so a repository cache holding one is refused
  ## (`cacheAttributesRefusal`).
  @["--attr-source=" & EmptyTreeId, "-c", "core.attributesFile=/dev/null",
    "-c", "core.autocrlf=false", "-c", "core.safecrlf=false"]

proc canonicalCheckoutEnv*(): seq[(string, string)] =
  @[("GIT_ATTR_NOSYSTEM", "1")]

proc parseGitVersion*(text: string): tuple[ok: bool; major, minor: int] =
  ## `git version 2.54.0` (or `git version 2.39.5 (Apple Git-154)`).
  let words = text.strip().splitWhitespace()
  if words.len < 3 or words[0] != "git" or words[1] != "version":
    return (false, 0, 0)
  let parts = words[2].split('.')
  if parts.len < 2:
    return (false, 0, 0)
  try:
    (true, parseInt(parts[0]), parseInt(parts[1]))
  except ValueError:
    (false, 0, 0)

var canonicalSupportCache {.threadvar.}: Table[string, string]

proc canonicalCheckoutRefusal*(gitExe: string): string =
  ## "" when `gitExe` can make a canonical checkout (git >= 2.40), else the
  ## reason. Probed once per binary.
  if canonicalSupportCache.hasKey(gitExe):
    return canonicalSupportCache[gitExe]
  let res = runGit(gitExe, ["--version"], mergeStderr = false)
  let v = parseGitVersion(res.output)
  result =
    if res.code != 0 or not v.ok:
      "cannot determine the version of git (`" & gitExe &
        " --version`: " & describe(res) & ")"
    elif (v.major, v.minor) < MinCanonicalGitVersion:
      "git " & $v.major & "." & $v.minor & " is too old: a worker needs git " &
        $MinCanonicalGitVersion[0] & "." & $MinCanonicalGitVersion[1] &
        " or newer (`--attr-source`) to check a base commit out without " &
        "attribute conversions"
    else: ""
  canonicalSupportCache[gitExe] = result

proc cacheAttributesRefusal*(gitDir: string): string =
  ## A repository cache with `$GIT_DIR/info/attributes` is refused: git
  ## applies that file even with `--attr-source`, so a checkout from it
  ## could write converted bytes.
  if fileExists(gitDir / "info" / "attributes") or
      symlinkExists(gitDir / "info" / "attributes"):
    return "the repository cache " & gitDir & " has info/attributes, which " &
      "git applies to every checkout; a worker's repository cache must " &
      "not carry one (remove it)"
  ""

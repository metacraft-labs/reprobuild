## ``repro hooks ensure`` never replaces a managed hook body whose contract
## token it does not generate. Replacing one is the explicit
## ``--re-anchor``.
##
## Recorded in reprobuild-pm
## ``issues/2026-11-12-ambient-hooks-ensure-is-declared-safe-even-though-it-is-the-documented-self-concealing.md``;
## the contract is reprobuild-pm ``spec/CLI/hooks.md`` §"repro hooks ensure"
## and §"Contract Handshake And Stand-Down", bullet "Re-anchoring is
## explicit".
##
## The defect. ``ensure`` runs unattended (a dev shell's entry hook; until
## 2026-11-16 also the generated ``.envrc``). The writer/runner guard that
## protects an installed body only refused when the RESOLVED runner serviced the
## old body and not the new one. In the ambient case nothing sets
## ``REPROBUILD_REPRO`` and the build on ``PATH`` is the one running ``ensure``,
## so the runner IS the writer, the guard cannot fire, and every body another
## build wrote was silently re-authored to this build's contract, exit 0. A
## stale dev shell thereby replaced current hooks with an older body and
## deleted the refusal that would have reported the mismatch.
##
## The arms, each falsifiable against the code before the fix:
##
##   (A) SINGLE REPO, the exact reproduction of the issue: install, rewrite the
##       ``pre-push`` body's token to one this build does not generate, run a
##       plain ``ensure`` with no ``REPROBUILD_REPRO`` and only this build on
##       ``PATH``. It exits non-zero, says ``refused-foreign-contract``, names
##       both tokens, and leaves the body AND the dispatcher byte-identical.
##       Before the fix: exit 0 and the body rewritten.
##   (B) ``--re-anchor`` replaces that body with this build's. Without it (A)
##       would be satisfied by an ``ensure`` that can never re-anchor.
##   (C) WORKSPACE SWEEP, through ``--json``: a refusal in one repo is reported
##       as ``refused-foreign-contract`` with the installed token, this build's
##       token, this build and the remedy; the sweep still visits the other
##       repo, where a contract-less body is still rewritten
##       (``rewrote-contractless-body``) and a missing hook is still
##       ``installed``; the command exits non-zero. Then ``--re-anchor`` takes
##       the refused hook as an ordinary refresh and exits 0.
##   (D) SELF-HEAL. A ``git commit`` fires ``post-commit``, whose self-heal
##       re-asserts the sibling hooks. It follows plain ``ensure``'s rule: the
##       foreign-contract ``pre-push`` is reported, not rewritten.
##
## No stub is used: every arm runs the real built ``repro``, real git and the
## real hooks. The "body another build wrote" is this build's own body with
## only its contract token changed, which is the one property the rule is
## about; a second real build cannot be produced hermetically inside a test.
##
## Hermetic: one ``createTempDir``, local bare repositories only, no network.
## Skip rule: ``git`` missing on PATH.

from repro_core/process_streams import drainStream
import std/[json, os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import repro_core/cli_images
import repro_test_support
import repro_test_support/process_fixtures
import repro_test_support/reasoned_skip

proc q(value: string): string = quoteShell(value)

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc engineBinary(): string =
  ## The engine image. ``repro`` is the thin client and ``execv``s this one,
  ## so this is the path the engine names for itself.
  requireBinary(repoRoot() / "build" / "bin" / reprobuildEngineExeName(),
    "reprobuild.apps.repro")

const
  contractFlag = "--hook-contract="
  foreignDigest = "ffffffffffffffff"

proc pathWithoutAnyRepro(): string =
  ## The inherited PATH with every ``repro`` and ``reprobuild`` taken out of
  ## it, and nothing else. A directory that supplies one (a Nix profile's
  ## ``bin`` typically also supplies ``git`` and ``sh``) is replaced by a
  ## fixture-local SHADOW of it: a directory of symlinks to every other entry.
  ## Dropping such a directory whole would also drop the tools the hooks need.
  var kept: seq[string]
  var shadowIndex = 0
  for dir in getEnv("PATH").split(PathSep):
    if dir.len == 0 or not dirExists(dir):
      continue
    if not (fileExists(dir / addFileExt("repro", ExeExt)) or
        fileExists(dir / addFileExt("reprobuild", ExeExt))):
      kept.add(dir)
      continue
    let shadow = getTempDir() / ("repro-path-shadow-" & $getCurrentProcessId() &
      "-" & $shadowIndex)
    inc shadowIndex
    if not dirExists(shadow):
      # Released by the process that made it, whichever case that was.
      releaseDirAtProcessExit(shadow)
      createDir(shadow)
      for kind, entry in walkDir(dir):
        let name = extractFilename(entry)
        if name.startsWith("repro") or name.startsWith(".repro"):
          continue
        try:
          createSymlink(entry, shadow / name)
        except OSError:
          discard
    kept.add(shadow)
  kept.join($PathSep)

proc ambientEnv(): StringTableRef =
  ## No ``REPROBUILD_REPRO``, no launcher override, only this build on PATH.
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    result[key] = value
  for key in ["REPROBUILD_REPRO", "REPRO_PUBLIC_CLI_PATH", "REPRO_FULL_CLI",
      "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"]:
    result.del(key)
  result["PATH"] = parentDir(reproBinary()) & $PathSep & pathWithoutAnyRepro()

proc run(args: openArray[string]; cwd = getCurrentDir()): CmdResult =
  let process = startProcess(args[0], workingDir = cwd, args = args[1 .. ^1],
    env = ambientEnv(), options = {poStdErrToStdOut, poUsePath})
  defer: process.close()
  let output = drainStream(process.outputStream)
  (code: process.waitForExit(), output: output)

proc requireOk(args: openArray[string]; cwd = getCurrentDir()): string =
  let res = run(args, cwd)
  if res.code != 0:
    checkpoint("command failed: " & args.join(" ") & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc tokenIn(body: string): string =
  let at = body.find(contractFlag)
  if at < 0:
    return ""
  var i = at + contractFlag.len
  var j = i
  while j < body.len and (body[j] in {'a' .. 'z', 'A' .. 'Z', '0' .. '9'} or
      body[j] in {'.', '-', '_'}):
    inc j
  body[i ..< j]

proc foreignOf(token: string): string =
  ## The same namespace and hook name with a digest this build never
  ## generates: a token of the right shape, as a sibling build writes.
  token[0 .. token.rfind('.')] & foreignDigest

proc seedOrigin(gitBin, originPath, seedPath: string) =
  discard requireOk([gitBin, "init", "--bare", "-b", "main", originPath])
  discard requireOk([gitBin, "init", "-b", "main", seedPath])
  discard requireOk([gitBin, "-C", seedPath, "config", "user.email",
    "tester@example.invalid"])
  discard requireOk([gitBin, "-C", seedPath, "config", "user.name", "Tester"])
  writeFile(seedPath / "README.md", "fixture\n")
  discard requireOk([gitBin, "-C", seedPath, "add", "README.md"])
  discard requireOk([gitBin, "-C", seedPath, "commit", "-m", "fixture"])
  discard requireOk([gitBin, "-C", seedPath, "push", originPath, "main"])

proc cloneInto(gitBin, origin, dest: string) =
  discard requireOk([gitBin, "clone", fileUrl(origin), dest])
  discard requireOk([gitBin, "-C", dest, "config", "user.email",
    "tester@example.invalid"])
  discard requireOk([gitBin, "-C", dest, "config", "user.name", "Tester"])

proc hooksOf(repo: string): string = repo / ".git" / "hooks"

proc projectToml(names: openArray[string]; origins: openArray[string]): string =
  result = "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"pair\"\n\n"
  for i, name in names:
    result.add("[[remote]]\nname = \"" & name & "-origin\"\nfetch = \"" &
      fileUrl(origins[i]) & "\"\n\n")
  result.add("includes = [\n")
  for name in names:
    result.add("  \"repos/" & name & ".toml\",\n")
  result.add("]\n")

proc fragmentToml(name: string): string =
  "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\nname = \"" & name &
    "\"\npath = \"" & name & "\"\nremote = \"" & name &
    "-origin\"\nmainline = \"main\"\n"

proc entryOf(report: JsonNode; repo, hook: string): JsonNode =
  for entry in report["entries"]:
    if entry["repo"].getStr() == repo and entry["hook"].getStr() == hook:
      return entry
  nil

proc jsonOf(output: string): JsonNode =
  ## The ``--json`` document: stdout carries exactly one, stderr (merged
  ## here) carries the human refusal lines, none of which starts with ``{``.
  let start = output.find("{\n")
  doAssert start >= 0, "no JSON document in:\n" & output
  parseJson(output[start .. ^1])

suite "hooks ensure never replaces a body whose contract it does not generate":

  test "a plain ensure refuses a foreign-contract body in a single repo, and --re-anchor replaces it":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; the case needs a real repository to install " &
        "managed hooks into")
    else:
      let scratch = createTempDir("repro-foreign-contract-single-", "")
      defer: removeDir(scratch)
      let origin = scratch / "origin.git"
      seedOrigin(gitBin, origin, scratch / "seed")
      let repo = scratch / "repo"
      cloneInto(gitBin, origin, repo)
      let repro = reproBinary()

      let installed = run([repro, "hooks", "ensure", "--vcs", repo])
      checkpoint("install:\n" & installed.output)
      check installed.code == 0
      let managed = hooksOf(repo) / "pre-push.repro-managed"
      let dispatcher = hooksOf(repo) / "pre-push"
      let canonical = readFile(managed)
      let mine = tokenIn(canonical)
      check mine.len > 0
      let foreign = foreignOf(mine)
      check foreign != mine

      # ---- (A) ------------------------------------------------------------
      let foreignBody = canonical.replace(mine, foreign)
      writeFile(managed, foreignBody)
      let dispatcherBefore = readFile(dispatcher)
      let refused = run([repro, "hooks", "ensure", "--vcs", repo])
      checkpoint("(A) plain ensure over a foreign-contract body:\n" &
        refused.output)
      check refused.code != 0
      check "refused-foreign-contract" in refused.output
      check foreign in refused.output
      check mine in refused.output
      check engineBinary() in refused.output
      check "--re-anchor" in refused.output
      check readFile(managed) == foreignBody
      check readFile(dispatcher) == dispatcherBefore

      # ---- (B) ------------------------------------------------------------
      let reanchored = run([repro, "hooks", "ensure", "--vcs", "--re-anchor",
        repo])
      checkpoint("(B) ensure --re-anchor:\n" & reanchored.output)
      check reanchored.code == 0
      check readFile(managed) == canonical
      check tokenIn(readFile(managed)) == mine

  test "a workspace sweep reports the refusal and keeps visiting the other repos":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; the case needs real repositories to install " &
        "managed hooks into")
    else:
      let scratch = createTempDir("repro-foreign-contract-sweep-", "")
      defer: removeDir(scratch)
      let names = ["lib-a", "lib-b"]
      var origins: seq[string]
      for name in names:
        let origin = scratch / (name & ".git")
        seedOrigin(gitBin, origin, scratch / ("seed-" & name))
        origins.add(origin)
      let ws = scratch / "workspace"
      for dir in [ws, ws / ".repro", ws / "projects", ws / "repos"]:
        createDir(dir)
      writeFile(ws / "projects" / "pair.toml", projectToml(names, origins))
      for name in names:
        writeFile(ws / "repos" / (name & ".toml"), fragmentToml(name))
        cloneInto(gitBin, origins[names.find(name)], ws / name)
      let repro = reproBinary()

      let installed = run([repro, "hooks", "ensure", "--vcs", "--json",
        "--workspace-root=" & ws])
      checkpoint("install:\n" & installed.output)
      check installed.code == 0

      let aManaged = hooksOf(ws / "lib-a") / "pre-push.repro-managed"
      let aDispatcher = hooksOf(ws / "lib-a") / "pre-push"
      let canonical = readFile(aManaged)
      let mine = tokenIn(canonical)
      let foreign = foreignOf(mine)
      let foreignBody = canonical.replace(mine, foreign)
      writeFile(aManaged, foreignBody)
      let aDispatcherBefore = readFile(aDispatcher)

      # lib-b: a contract-less post-merge body (what a build that predates the
      # handshake writes) and a missing post-checkout hook.
      let bMerge = hooksOf(ws / "lib-b") / "post-merge.repro-managed"
      let bMergeCanonical = readFile(bMerge)
      let bMergeToken = tokenIn(bMergeCanonical)
      writeFile(bMerge, bMergeCanonical.replace(contractFlag & bMergeToken &
        " ", ""))
      check contractFlag notin readFile(bMerge)
      removeFile(hooksOf(ws / "lib-b") / "post-checkout.repro-managed")
      removeFile(hooksOf(ws / "lib-b") / "post-checkout")

      # ---- (C) plain ensure ----------------------------------------------
      let swept = run([repro, "hooks", "ensure", "--vcs", "--json",
        "--workspace-root=" & ws])
      checkpoint("(C) plain sweep:\n" & swept.output)
      check swept.code != 0
      let report = jsonOf(swept.output)
      let refusedEntry = entryOf(report, "lib-a", "pre-push")
      check not refusedEntry.isNil
      check refusedEntry["outcome"].getStr() == "refused-foreign-contract"
      check refusedEntry["installedContract"].getStr() == foreign
      check refusedEntry["buildContract"].getStr() == mine
      check engineBinary() in refusedEntry["build"].getStr()
      check sameFile(engineBinary(), refusedEntry["installedAuthor"].getStr())
      check "--re-anchor" in refusedEntry["remedy"].getStr()
      check (ws / "lib-a") in refusedEntry["remedy"].getStr()
      check report["exitCode"].getInt() != 0
      check report["summary"]["refused-foreign-contract"].getInt() == 1
      # Untouched, body and dispatcher.
      check readFile(aManaged) == foreignBody
      check readFile(aDispatcher) == aDispatcherBefore
      # The other hooks of lib-a and every hook of lib-b were still visited.
      check entryOf(report, "lib-a", "post-commit")["outcome"].getStr() ==
        "already-up-to-date"
      check entryOf(report, "lib-b", "post-merge")["outcome"].getStr() ==
        "rewrote-contractless-body"
      check readFile(bMerge) == bMergeCanonical
      check entryOf(report, "lib-b", "post-checkout")["outcome"].getStr() ==
        "installed"
      check fileExists(hooksOf(ws / "lib-b") / "post-checkout.repro-managed")
      # Said for a human too, on stderr.
      check "lib-a/pre-push: refused-foreign-contract" in swept.output

      # ---- --re-anchor ----------------------------------------------------
      let reanchored = run([repro, "hooks", "ensure", "--vcs", "--re-anchor",
        "--json", "--workspace-root=" & ws])
      checkpoint("(C) sweep with --re-anchor:\n" & reanchored.output)
      check reanchored.code == 0
      check entryOf(jsonOf(reanchored.output), "lib-a", "pre-push")[
        "outcome"].getStr() == "refreshed-drifted"
      check readFile(aManaged) == canonical

  test "the hooks' self-heal reports a foreign-contract body and does not rewrite it":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; the case needs a real commit to fire the " &
        "post-commit self-heal")
    else:
      let scratch = createTempDir("repro-foreign-contract-heal-", "")
      defer: removeDir(scratch)
      let origin = scratch / "origin.git"
      seedOrigin(gitBin, origin, scratch / "seed")
      let ws = scratch / "workspace"
      for dir in [ws, ws / ".repro", ws / "projects", ws / "repos"]:
        createDir(dir)
      writeFile(ws / "projects" / "pair.toml",
        projectToml(["lib-a"], [origin]))
      writeFile(ws / "repos" / "lib-a.toml", fragmentToml("lib-a"))
      let repo = ws / "lib-a"
      cloneInto(gitBin, origin, repo)
      let repro = reproBinary()
      discard requireOk([repro, "hooks", "ensure", "--vcs",
        "--workspace-root=" & ws])

      let managed = hooksOf(repo) / "pre-push.repro-managed"
      let canonical = readFile(managed)
      let mine = tokenIn(canonical)
      let foreignBody = canonical.replace(mine, foreignOf(mine))
      writeFile(managed, foreignBody)

      # post-commit's own body is current, so its handshake passes and its
      # dispatch runs the self-heal over the sibling hooks.
      let commit = run([gitBin, "-C", repo, "commit", "--allow-empty", "-m",
        "fire post-commit"])
      checkpoint("(D) git commit:\n" & commit.output)
      check commit.code == 0
      check "pre-push: refused-foreign-contract" in commit.output
      check "repaired pre-push" notin commit.output
      check readFile(managed) == foreignBody

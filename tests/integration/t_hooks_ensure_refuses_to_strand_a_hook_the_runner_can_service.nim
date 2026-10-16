## PG-14 deliverables 1 and 2 — ``repro hooks ensure`` must stop being able to
## do the thing its own generated hook body warns about.
##
## The warning, in reprobuild's own words, printed by every managed hook that
## meets an interpreter it cannot trust: *"Do NOT run `repro hooks ensure` with
## it: that rewrites this file with its own older body, the contract line
## disappears, and you silence this message instead of fixing it."* And the
## generated ``.envrc`` block runs ``"$repro_cmd" hooks ensure --vcs "$PWD"
## >/dev/null 2>&1 || true`` on **every directory entry**, output discarded,
## failure swallowed — so the silencing is ambient, unattended, and can happen
## at any moment.
##
## What a build carrying this code can and cannot do about that, stated honestly
## because the milestone does:
##
##   * It CANNOT make an older build behave. That build is already shipped and
##     predates the flag.
##   * It CAN refuse to perform the destructive rewrite itself. ``ensure``'s
##     ordinary job is re-anchoring a repository to the build the operator ran,
##     and that must stay allowed between two builds that both speak the
##     handshake (one of them simply generates a different body — probe exit 3).
##     The case that is never an upgrade is the one pinned here: the interpreter
##     the hooks will actually RESOLVE services the body that is installed and
##     does NOT service the body we would write. Rewriting then converts a
##     working pairing into a broken one, and §1.6c measures that nothing
##     afterwards reports it.
##   * It CAN name the state a non-speaking build leaves behind. A managed body
##     with no ``--hook-contract=`` line was written by a build that predates the
##     handshake; that is reported as its OWN outcome — not ``missing`` (wrong
##     remedy: the hook is there and running) and not ``already-up-to-date`` /
##     ``refreshed-drifted`` (which hide the one fact worth having, that
##     something on this machine strips contract lines and will do it again).
##
## Four arms, each falsifiable:
##
##   (A) REFUSAL. Runner services the installed token and not the new one →
##       ``ensure`` exits non-zero, names BOTH builds, and the managed body is
##       byte-for-byte what it was. A guard that merely warned would rewrite it.
##   (B) ABSENCE DEGRADES (§8). With no interpreter resolvable at all there is
##       no skew — a machine with no ``repro`` on PATH is unconfigured, not
##       skewed — so ``ensure`` proceeds. A guard that refused here would break
##       every first install.
##   (C) THE ORDINARY UPGRADE still works. Runner services the NEW token and not
##       the old one → ``ensure`` rewrites. Without this arm (A) would be
##       satisfied by a guard that refuses every rewrite, i.e. by breaking
##       ``ensure``.
##   (D) THE CONTRACT-LESS STATE is reported as itself:
##       ``outcome: rewrote-contractless-body``, never ``already-up-to-date``
##       and never ``installed``.
##
## The runner is a STUB, justified exactly as in the sibling PG-14 suites: the
## subject is a binary this workspace did not build (seventeen reprobuild store
## paths exist on the host this was measured on) and a second real build cannot
## be produced hermetically. The stub is behavioural — it answers the handshake
## by comparing tokens, which is all a real build does. The hooks, the real
## binary, git and ``ensure`` itself are real.
##
## Hermetic: one ``createTempDir``, local bares only, no network.
## Skip rule: ``git`` missing on PATH.

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_core/cli_images
import repro_test_support

proc q(value: string): string = quoteShell(value)
proc qsh(value: string): string = quoteShellPosix(value)

proc runCmd(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd,
    options = {poStdErrToStdOut, poUsePath})
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  let res = runCmd(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc engineBinary(): string =
  ## The FULL CLI image. ``repro`` on PATH is the thin daemon client and it
  ## ``execv``s this one, so ``getAppFilename()`` inside every diagnostic below
  ## is THIS path — asserting on the thin client's path would be asserting on a
  ## process that no longer exists by the time the message is written.
  requireBinary(repoRoot() / "build" / "bin" / reprobuildEngineExeName(),
    "reprobuild.apps.repro")

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

const
  contractFlag = "--hook-contract="
  # A token of the right SHAPE that this build does not generate: the namespace
  # and hook name are real (so it parses as one of ours) and the digest is not.
  foreignToken = "reprobuild.managed-hook.v1.post-commit.0123456789abcdef"

proc seedOrigin(gitBin, originPath, seedPath: string) =
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  discard requireGit(q(gitBin) & " init -b main " & q(seedPath))
  discard requireGit(q(gitBin) & " -C " & q(seedPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(seedPath) &
    " config user.name \"PG14 Tester\"")
  writeFile(seedPath / "README.md", "PG-14 fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(seedPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(seedPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(seedPath) & " remote add origin " &
    q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(seedPath) & " push origin main")

proc writeTokenStub(path, servicedToken: string) =
  ## A ``repro`` that confirms exactly ONE contract token and answers 3 ("I
  ## speak this handshake and generate a different body") for any other. That
  ## is what a sibling build does, and it keeps the arms below about the
  ## CONTRACT rather than about a build being old.
  writeFile(path,
    "#!/usr/bin/env sh\n" &
    "if [ \"${1:-}\" = \"hooks\" ] && [ \"${2:-}\" = \"protocol\" ]; then\n" &
    "  for arg in \"$@\"; do\n" &
    "    case \"$arg\" in\n" &
    "      --hook-contract=" & qsh(servicedToken) & ") echo 2; exit 0 ;;\n" &
    "      --hook-contract=*)\n" &
    "        echo 'repro hooks: this build generates a different body' >&2\n" &
    "        exit 3\n" &
    "        ;;\n" &
    "    esac\n" &
    "  done\n" &
    "  echo 2\n" &
    "  exit 0\n" &
    "fi\n" &
    "if [ \"${1:-}\" = \"--version\" ]; then echo 'repro 0.1.3'; exit 0; fi\n" &
    "exit 0\n")
  inclFilePermissions(path, {fpUserExec, fpGroupExec, fpOthersExec})

type
  Fixture = object
    scratch: string
    workspaceRoot: string
    repoPath: string
    reproBin: string
    managed: string

proc setupFixture(gitBin: string): Fixture =
  result.scratch = createTempDir("repro-pg14-ensure-", "")
  result.reproBin = reproBinary()
  let origin = result.scratch / "origin-lib-a.git"
  seedOrigin(gitBin, origin, result.scratch / "seed-lib-a")
  result.workspaceRoot = result.scratch / "workspace"
  createDir(result.workspaceRoot)
  createDir(result.workspaceRoot / ".repro")
  createDir(result.workspaceRoot / "projects")
  createDir(result.workspaceRoot / "repos")
  writeFile(result.workspaceRoot / "projects" / "lib-a.toml",
    projectToml.replace("LIB_A_URL", fileUrl(origin)))
  writeFile(result.workspaceRoot / "repos" / "lib-a.toml", libAFragmentToml)
  result.repoPath = result.workspaceRoot / "lib-a"
  discard requireGit(q(gitBin) & " clone " & q(fileUrl(origin)) & " " &
    q(result.repoPath))
  result.managed = result.repoPath / ".git" / "hooks" /
    "post-commit.repro-managed"

proc ensureHooks(fx: Fixture; runner: string): CmdResult =
  var env: seq[tuple[name, value: string]]
  if runner.len > 0:
    env.add((name: "REPROBUILD_REPRO", value: runner))
  runShell(shellCommand(
    @[fx.reproBin, "hooks", "ensure", "--vcs", "--json",
      "--workspace-root=" & fx.workspaceRoot], env))

proc outcomeOf(output, hookName: string): string =
  ## The reported outcome for one hook, out of the ``--json`` report. Returns
  ## "" when the hook is absent from the report (or the output is not JSON,
  ## which a refusal's stderr is not).
  let brace = output.find('{')
  if brace < 0:
    return ""
  var report: JsonNode
  try:
    report = parseJson(output[brace .. ^1])
  except CatchableError:
    return ""
  if "entries" notin report:
    return ""
  for entry in report["entries"]:
    if entry["hook"].getStr() == hookName:
      return entry["outcome"].getStr()
  ""

proc installedToken(managed: string): string =
  let body = readFile(managed)
  let at = body.find(contractFlag)
  if at < 0:
    return ""
  let rest = body[(at + contractFlag.len) .. ^1]
  var i = 0
  while i < rest.len and (rest[i] in {'a' .. 'z', 'A' .. 'Z', '0' .. '9'} or
      rest[i] in {'.', '-', '_'}):
    inc i
  rest[0 ..< i]

suite "PG-14 — hooks ensure refuses to strand a hook its runner can service":

  test "t_hooks_ensure_refuses_to_strand_a_hook_the_runner_can_service":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH; this case needs a real repository for " &
        "`hooks ensure` to install a managed hook into")
    else:
      let fx = setupFixture(gitBin)
      defer: removeDir(fx.scratch)

      # Install the real hooks with the real binary as both writer and runner.
      let first = ensureHooks(fx, fx.reproBin)
      checkpoint("first ensure:\n" & first.output)
      check first.code == 0
      check fileExists(fx.managed)
      let realToken = installedToken(fx.managed)
      checkpoint("token this build writes: " & realToken)
      check realToken.len > 0
      check realToken != foreignToken

      # Re-point the installed body at a token this build does NOT generate,
      # leaving every other byte alone. This is a stand-in for "a sibling build
      # installed these hooks", which is the state the guard is about.
      let canonical = readFile(fx.managed)
      let foreignBody = canonical.replace(realToken, foreignToken)
      check foreignBody != canonical
      writeFile(fx.managed, foreignBody)

      # ---- (A) REFUSAL ---------------------------------------------------
      # The runner services what is installed and not what we would write.
      let oldOnly = fx.scratch / "runner-services-old"
      writeTokenStub(oldOnly, foreignToken)
      let refused = ensureHooks(fx, oldOnly)
      checkpoint("(A) ensure under skew:\n" & refused.output)
      check refused.code != 0
      # Both builds named, with how the runner was resolved.
      check engineBinary() in refused.output
      check oldOnly in refused.output
      check foreignToken in refused.output
      check realToken in refused.output
      # The remedy reconciles the SUPPLY of repro; it never offers a bare
      # ``hooks ensure``, which is the command that deletes the diagnostic.
      check "direnv reload" in refused.output
      check "store paths" in refused.output
      # And nothing was written: the body is byte-for-byte what it was.
      check readFile(fx.managed) == foreignBody

      # ---- (B) ABSENCE DEGRADES ------------------------------------------
      # No interpreter resolvable → no skew, so `ensure` proceeds. (The env
      # var names a path that does not exist, which is how the generated body
      # resolves nothing too.)
      let absent = ensureHooks(fx, fx.scratch / "no-such-repro")
      checkpoint("(B) ensure with no interpreter:\n" & absent.output)
      check absent.code == 0
      check readFile(fx.managed) == canonical
      check installedToken(fx.managed) == realToken

      # ---- (C) THE ORDINARY UPGRADE --------------------------------------
      # Put the foreign token back, then give the runner the NEW token: the
      # rewrite is an upgrade and must be performed.
      writeFile(fx.managed, foreignBody)
      let newOnly = fx.scratch / "runner-services-new"
      writeTokenStub(newOnly, realToken)
      let upgraded = ensureHooks(fx, newOnly)
      checkpoint("(C) ensure as an upgrade:\n" & upgraded.output)
      check upgraded.code == 0
      check readFile(fx.managed) == canonical
      check outcomeOf(upgraded.output, "post-commit") == "refreshed-drifted"

      # ---- (D) THE CONTRACT-LESS STATE -----------------------------------
      # Strip the handshake from the installed body, exactly as a build that
      # predates it leaves things, and keep every marker line so the file is
      # still recognised as ours.
      let strippedBody = canonical.replace(contractFlag & realToken & " ", "")
      check strippedBody != canonical
      check contractFlag notin strippedBody
      writeFile(fx.managed, strippedBody)
      let repaired = ensureHooks(fx, fx.reproBin)
      checkpoint("(D) ensure over a contract-less body:\n" & repaired.output)
      check repaired.code == 0
      let outcome = outcomeOf(repaired.output, "post-commit")
      checkpoint("(D) reported outcome: " & outcome)
      check outcome == "rewrote-contractless-body"
      check outcome != "already-up-to-date"
      check outcome != "installed"
      check readFile(fx.managed) == canonical
      # And it is SAID, not only counted: an operator has to learn that
      # something on this machine strips contract lines.
      check "predates the handshake" in repaired.output

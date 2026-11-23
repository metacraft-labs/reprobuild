## A pre-commit or prek hook whose configuration file the repository deleted
## refuses every commit, and `repro health` and `repro hooks ensure` say so.
##
## THE DEFECT. A dev shell runs `pre-commit install` / `prek install` while the repository
## has a `.pre-commit-config.yaml`. A later commit deletes the file, and
## nothing removes the shim, so every `git commit` fails inside it ("No
## .pre-commit-config.yaml file was found"). The repository then also looks
## hooked while no Reprobuild gate is installed. Measured before this suite
## existed, with the pinned `repro 0.2.29`
## (`/nix/store/qbpp1f6ixr6jlijnbbpc1iivy2lwr3z3-reprobuild-0.2.29`) against a
## repository holding pre-commit 4.5.1's real shim and no config: `vcs-hooks`
## and `chained-hooks` were both `ok`, and `hooks ensure --vcs` chained the
## shim as `pre-commit.repro-local`, reported "updated" and said nothing, after
## which the commit was refused.
##
## WHAT IS ASSERTED
##
##   (A) CONTROLS. The same shim with its config present, a shim installed with
##       `--allow-missing-config` (`--skip-on-missing-config`), and a prek shim
##       that names no `--config` while the worktree has a `prek.toml`: the
##       `hook-configs` row is `ok`. Without these every assertion below is
##       satisfied by a row hardwired to `fail`.
##   (B) The issue's state, a pre-commit shim in the `pre-commit` slot of a
##       workspace repo with no dispatcher and no config: `hook-configs` is a
##       `fail` that names `<repo>/pre-commit`, the tool, the missing file and
##       both repairs. **Mutation guard: the shipped health has no such row
##       and reports `chained-hooks ok`.**
##   (C) Shapes that also refuse: prek's shim with a quoted `--config=`, in a
##       slot Reprobuild does not manage (`commit-msg`), and a prek shim that
##       names no `--config` in a worktree with none of the files prek would
##       discover, also when the directory above the repository (the
##       workspace root) has one: prek's discovery stops at the repository's
##       top level.
##   (D) `hooks ensure --vcs <workspace>` chains the shim as
##       `pre-commit.repro-local` (it keeps the body) and SAYS so on stderr,
##       naming the file, the missing config and both repairs. A commit through
##       the dispatcher is then refused by the chained shim, and the health row
##       keeps reporting it, now as the chained body. For a repository
##       outside any workspace, the single-repo forms of `health <repo>` and
##       `hooks ensure --vcs <repo>` report and say the same.
##   (E) Restoring the config is the repair: the row is `ok` again.
##
## TEST DOUBLES. The program the shims `exec` is a stub, not the real
## pre-commit or prek: neither is on the dev shell's PATH, and a test that
## pulled them in would download a Python or Rust toolchain to exercise a
## refusal that is one `if` in each tool. The stub implements exactly that
## `if`: with no file at its `--config` it prints the tool's message and exits
## 1, otherwise 0. The shim bodies are the ones the two installers generate,
## with the store paths replaced by the stub's. Everything else is real: `git`,
## a local bare remote over `file://`, the engine-built `build/bin/repro`
## installing real hooks and running the real `health`.
##
## Hermetic: one `createTempDir` per case, no network.
## Skip rule: `git` or `bash` missing on PATH.

import std/[json, os, osproc, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

import repro_test_support

proc q(value: string): string = quoteShell(value)

proc runCmd(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd,
    options = {poStdErrToStdOut, poUsePath})
  (code: res.exitCode, output: res.output)

proc requireCmd(command: string; cwd = ""): string =
  let res = runCmd(command, cwd)
  if res.code != 0:
    stderr.writeLine("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc writeExecutable(path, content: string) =
  writeFile(path, content)
  var perms = getFilePermissions(path)
  perms.incl({fpUserExec, fpGroupExec, fpOthersExec})
  setFilePermissions(path, perms)

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

proc preCommitShim(bash, tool, hookType: string; extra = ""): string =
  ## pre-commit 4.5.1's generated shim, as `pre-commit install` wrote it on
  ## this host, with its interpreter and program paths replaced.
  "#!" & bash & "\n" &
    "# File generated by pre-commit: https://pre-commit.com\n" &
    "# ID: 138fd403232d2ddd5efb44317e38bf03\n" &
    "\n" &
    "# start templated\n" &
    "INSTALL_PYTHON=/nonexistent/python3.13\n" &
    "ARGS=(hook-impl --config=.pre-commit-config.yaml --hook-type=" &
      hookType & extra & ")\n" &
    "# end templated\n" &
    "\n" &
    "HERE=\"$(cd \"$(dirname \"$0\")\" && pwd)\"\n" &
    "ARGS+=(--hook-dir \"$HERE\" -- \"$@\")\n" &
    "\n" &
    "exec " & tool & " \"${ARGS[@]}\"\n"

proc prekShim(tool, hookType, configArgs: string): string =
  ## prek 0.3.11's generated shim, as `prek install` wrote it on this host.
  ## `configArgs` is `--config=".pre-commit-config.yaml" ` when the installer
  ## was given `-c`, and empty otherwise.
  "#!/bin/sh\n" &
    "# File generated by prek: https://github.com/j178/prek\n" &
    "# ID: 182c10f181da4464a3eec51b83331688\n" &
    "\n" &
    "HERE=\"$(cd \"$(dirname \"$0\")\" && pwd)\"\n" &
    "PREK=\"" & tool & "\"\n" &
    "\n" &
    "# Check if the full path to prek is executable, otherwise fallback to PATH\n" &
    "if [ ! -x \"$PREK\" ]; then\n" &
    "    PREK=\"prek\"\n" &
    "fi\n" &
    "\n" &
    "exec \"$PREK\" hook-impl --hook-dir \"$HERE\" --script-version 4 " &
      "--hook-type=" & hookType & " " & configArgs & "-- \"$@\"\n"

const StubTool = """#!/bin/sh
# Test double for pre-commit / prek's `hook-impl` (see the file header): the
# one decision under test, refusing when the configuration file is absent.
config=.pre-commit-config.yaml
for arg in "$@"; do
  case "$arg" in
    --config=*) config="${arg#--config=}" ;;
  esac
done
if [ ! -f "$config" ]; then
  echo "No $config file was found" >&2
  echo "- To temporarily silence this, run \`PRE_COMMIT_ALLOW_NO_CONFIG=1 git ...\`" >&2
  exit 1
fi
exit 0
"""

type
  Fixture = object
    gitBin: string
    bash: string
    scratch: string
    workspaceRoot: string
    repoPath: string
    hooksDir: string
    reproBin: string
    tool: string

proc git(fx: Fixture; args: string): string =
  requireCmd(q(fx.gitBin) & " -C " & q(fx.repoPath) & " " & args)

proc setupFixture(gitBin, bash, slug: string): Fixture =
  ## A one-repo workspace whose repo has NO managed hooks: the state the issue
  ## found `runquota` and `io-mon` in.
  result.gitBin = gitBin
  result.bash = bash
  result.scratch = createTempDir("repro-hook-config-" & slug & "-", "")
  result.reproBin = reproBinary()
  result.tool = result.scratch / "bin" / "hook-tool"
  createDir(result.scratch / "bin")
  writeExecutable(result.tool, StubTool)
  let origin = result.scratch / "origin-lib-a.git"
  let seed = result.scratch / "seed-lib-a"
  discard requireCmd(q(gitBin) & " init -q --bare -b main " & q(origin))
  discard requireCmd(q(gitBin) & " init -q -b main " & q(seed))
  discard requireCmd(q(gitBin) & " -C " & q(seed) &
    " config user.email tester@example.invalid")
  discard requireCmd(q(gitBin) & " -C " & q(seed) & " config user.name Tester")
  writeFile(seed / "README.md", "hook-config fixture\n")
  discard requireCmd(q(gitBin) & " -C " & q(seed) & " add README.md")
  discard requireCmd(q(gitBin) & " -C " & q(seed) & " commit -q -m fixture")
  discard requireCmd(q(gitBin) & " -C " & q(seed) & " remote add origin " &
    q(origin))
  discard requireCmd(q(gitBin) & " -C " & q(seed) & " push -q origin main")
  result.workspaceRoot = result.scratch / "workspace"
  createDir(result.workspaceRoot / ".repro")
  createDir(result.workspaceRoot / "projects")
  createDir(result.workspaceRoot / "repos")
  writeFile(result.workspaceRoot / "projects" / "lib-a.toml",
    projectToml.replace("LIB_A_URL", fileUrl(origin)))
  writeFile(result.workspaceRoot / "repos" / "lib-a.toml", libAFragmentToml)
  result.repoPath = result.workspaceRoot / "lib-a"
  discard requireCmd(q(gitBin) & " clone -q " & q(fileUrl(origin)) & " " &
    q(result.repoPath))
  discard requireCmd(q(gitBin) & " -C " & q(result.repoPath) &
    " config user.email tester@example.invalid")
  discard requireCmd(q(gitBin) & " -C " & q(result.repoPath) &
    " config user.name Tester")
  result.hooksDir = result.repoPath / ".git" / "hooks"
  createDir(result.hooksDir)

proc repro(fx: Fixture; args: seq[string]; cwd = ""): CmdResult =
  ## `REPROBUILD_REPRO` is pinned to the binary under test so that every hook
  ## a git command fires measures this build. `cwd` defaults to the scratch
  ## directory, never this checkout, whose own workspace `health` would
  ## otherwise resolve.
  runShell(shellCommand(@[fx.reproBin] & args,
    @[(name: "REPROBUILD_REPRO", value: fx.reproBin)]),
    if cwd.len > 0: cwd else: fx.scratch)

proc hookConfigsRow(fx: Fixture; target = ""): JsonNode =
  ## The `hook-configs` row of a workspace health run, or of a single-repo
  ## run against `target`.
  let args =
    if target.len > 0: @["health", target, "--json"]
    else: @["health", "lib-a", "--json",
      "--workspace-root=" & fx.workspaceRoot]
  let res = fx.repro(args, target)
  let start = res.output.find('{')
  doAssert start >= 0, "health printed no JSON:\n" & res.output
  let doc = parseJson(res.output[start .. ^1])
  for entry in doc["checks"]:
    if entry["name"].getStr() == "hook-configs":
      return entry
  checkpoint("health --json output:\n" & res.output)
  newJNull()

proc fullDetail(row: JsonNode): string =
  if row.kind != JObject:
    return ""
  let full = row{"fullDetail"}.getStr()
  if full.len > 0: full else: row{"detail"}.getStr()

suite "a pre-commit or prek hook whose configuration is gone":

  test "t_hook_whose_config_is_gone_is_reported":
    let gitBin = findExe("git")
    let bash = findExe("bash")
    if gitBin.len == 0 or bash.len == 0:
      skip("git or bash not on PATH; this case installs hooks in a real " &
        "repository and commits through them")
    else:
      let fx = setupFixture(gitBin, bash, "ws")
      defer: removeDir(fx.scratch)
      let slot = fx.hooksDir / "pre-commit"
      let config = fx.repoPath / ".pre-commit-config.yaml"

      # ---- (A) controls ------------------------------------------------
      writeExecutable(slot, preCommitShim(bash, fx.tool, "pre-commit"))
      writeFile(config, "repos: []\n")
      var row = fx.hookConfigsRow()
      checkpoint("control, config present: " & $row)
      check row{"status"}.getStr() == "ok"

      removeFile(config)
      writeExecutable(slot, preCommitShim(bash, fx.tool, "pre-commit",
        " --skip-on-missing-config"))
      row = fx.hookConfigsRow()
      checkpoint("control, --skip-on-missing-config: " & $row)
      check row{"status"}.getStr() == "ok"

      writeExecutable(slot, prekShim(fx.tool, "pre-commit", ""))
      writeFile(fx.repoPath / "prek.toml", "repos = []\n")
      row = fx.hookConfigsRow()
      checkpoint("control, prek discovers prek.toml: " & $row)
      check row{"status"}.getStr() == "ok"
      removeFile(fx.repoPath / "prek.toml")

      # ---- (B) the issue's state ---------------------------------------
      writeExecutable(slot, preCommitShim(bash, fx.tool, "pre-commit"))
      row = fx.hookConfigsRow()
      checkpoint("dead pre-commit shim in the slot: " & $row)
      check row{"status"}.getStr() == "fail"
      check "lib-a/pre-commit" in row.fullDetail
      check "pre-commit shim" in row.fullDetail
      check config in row.fullDetail
      check "REFUSES" in row.fullDetail
      check "delete" in row{"remedy"}.getStr()
      check "restore" in row{"remedy"}.getStr()
      # A commit is refused, which is the state the row describes.
      writeFile(fx.repoPath / "a.txt", "a\n")
      discard fx.git("add a.txt")
      let refused = runCmd(q(gitBin) & " -C " & q(fx.repoPath) &
        " commit -q -m a")
      checkpoint("commit through the dead shim: " & refused.output)
      check refused.code != 0
      check "No .pre-commit-config.yaml file was found" in refused.output

      # ---- (C) other shapes that refuse --------------------------------
      writeExecutable(slot, prekShim(fx.tool, "pre-commit", ""))
      row = fx.hookConfigsRow()
      checkpoint("prek shim with no --config and nothing to discover: " &
        $row)
      check row{"status"}.getStr() == "fail"
      check "prek shim" in row.fullDetail
      # prek's discovery stops at the repository's top level, so a file in
      # the directory above it (here the workspace root, which holds every
      # participating repo) does not stop the refusal, and must not hide it.
      writeFile(fx.workspaceRoot / ".pre-commit-config.yaml", "repos: []\n")
      row = fx.hookConfigsRow()
      checkpoint("prek shim, config only above the repository: " & $row)
      check row{"status"}.getStr() == "fail"
      removeFile(fx.workspaceRoot / ".pre-commit-config.yaml")

      writeExecutable(slot, preCommitShim(bash, fx.tool, "pre-commit"))
      writeExecutable(fx.hooksDir / "commit-msg", prekShim(fx.tool,
        "commit-msg", "--config=\".pre-commit-config.yaml\" "))
      row = fx.hookConfigsRow()
      checkpoint("plus a dead prek commit-msg shim: " & $row)
      check row{"status"}.getStr() == "fail"
      check "lib-a/commit-msg" in row.fullDetail
      check "lib-a/pre-commit" in row.fullDetail
      removeFile(fx.hooksDir / "commit-msg")

      # ---- (D) ensure chains it and says so ----------------------------
      let ensured = fx.repro(@["hooks", "ensure", "--vcs", fx.workspaceRoot])
      checkpoint("hooks ensure (workspace): " & ensured.output)
      check ensured.code == 0
      let local = fx.hooksDir / "pre-commit.repro-local"
      check fileExists(local)
      check readFile(slot).contains("reprobuild hook dispatcher")
      check ("chained " & local) in ensured.output
      check config in ensured.output
      check "refuses every fire" in ensured.output
      check ("Delete " & local) in ensured.output
      check ("restore " & config) in ensured.output

      let refusedChained = runShell(shellCommand(@[gitBin, "-C", fx.repoPath,
        "commit", "-q", "-m", "a"],
        @[(name: "REPROBUILD_REPRO", value: fx.reproBin)]))
      checkpoint("commit through the dispatcher: " & refusedChained.output)
      check refusedChained.code != 0
      check "No .pre-commit-config.yaml file was found" in
        refusedChained.output

      row = fx.hookConfigsRow()
      checkpoint("dead shim chained under the dispatcher: " & $row)
      check row{"status"}.getStr() == "fail"
      check "lib-a/pre-commit" in row.fullDetail
      check "pre-commit.repro-local" in row.fullDetail
      check "dispatcher runs it first" in row.fullDetail


      # ---- (E) restoring the config is the repair ----------------------
      writeFile(config, "repos: []\n")
      row = fx.hookConfigsRow()
      checkpoint("config restored: " & $row)
      check row{"status"}.getStr() == "ok"

  test "t_single_repo_ensure_and_health_report_a_hook_whose_config_is_gone":
    let gitBin = findExe("git")
    let bash = findExe("bash")
    if gitBin.len == 0 or bash.len == 0:
      skip("git or bash not on PATH; this case installs hooks in a real " &
        "repository")
    else:
      # A repository outside any workspace, so `hooks ensure` and `health`
      # take their single-repo arms.
      let fx = setupFixture(gitBin, bash, "single")
      defer: removeDir(fx.scratch)
      proc soloRepo(name: string): string =
        result = fx.scratch / name
        discard requireCmd(q(gitBin) & " init -q -b main " & q(result))
        createDir(result / ".git" / "hooks")
      let solo = soloRepo("solo")
      let soloHooks = solo / ".git" / "hooks"
      writeExecutable(soloHooks / "pre-push", prekShim(fx.tool, "pre-push",
        "--config=\".pre-commit-config.yaml\" "))
      var row = fx.hookConfigsRow(solo)
      checkpoint("single-repo health, dead prek shim in the slot: " & $row)
      check row{"status"}.getStr() == "fail"
      check "solo/pre-push" in row.fullDetail

      let ensured = fx.repro(@["hooks", "ensure", "--vcs", solo])
      checkpoint("hooks ensure (single repo): " & ensured.output)
      check ensured.code == 0
      let local = soloHooks / "pre-push.repro-local"
      check fileExists(local)
      check ("chained " & local) in ensured.output
      check "prek shim" in ensured.output
      check (solo / ".pre-commit-config.yaml") in ensured.output

      row = fx.hookConfigsRow(solo)
      checkpoint("single-repo health, chained: " & $row)
      check row{"status"}.getStr() == "fail"
      check "pre-push.repro-local" in row.fullDetail

      # Control: ensure over a shim whose config exists says nothing.
      let working = soloRepo("working")
      writeFile(working / ".pre-commit-config.yaml", "repos: []\n")
      writeExecutable(working / ".git" / "hooks" / "pre-push",
        prekShim(fx.tool, "pre-push",
          "--config=\".pre-commit-config.yaml\" "))
      let quiet = fx.repro(@["hooks", "ensure", "--vcs", working])
      checkpoint("hooks ensure over a working shim: " & quiet.output)
      check quiet.code == 0
      check fileExists(working / ".git" / "hooks" / "pre-push.repro-local")
      check "refuses every fire" notin quiet.output
      row = fx.hookConfigsRow(working)
      check row{"status"}.getStr() == "ok"

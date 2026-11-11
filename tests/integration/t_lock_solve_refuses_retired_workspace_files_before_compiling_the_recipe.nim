## `repro lock solve` and `repro lock refresh` refuse a workspace root that
## keeps its settings file or its state file only under the retired name,
## and they refuse it BEFORE they compile the project's recipe.
##
## Every command refuses such a root and names the remedy
## (Workspace-Settings-Files.md §6). For the lock verbs the refusal is
## decided ahead of the provider probe, which compiles the project's recipe
## and every sibling recipe its `uses:` reach and needs nothing from the
## workspace files; in a large develop set that probe takes minutes.
##
## Two witnesses, each with a control under a migrated root:
##
##   * ORDER. The member's recipe does not compile. A run that reaches the
##     provider probe reports that ("could not read the solve of ..."), so
##     the retired-file refusal can only appear in its place if it was
##     decided first. The control shows the fixture reaches the probe.
##   * REFUSAL. The member has no recipe, only a `repro.solver` sidecar, so
##     no provider is compiled and the solve itself runs. Under a retired
##     root both verbs refuse and `refresh` writes no lock; the control
##     solves and writes one, which shows the fixture is a working solve.
##
## The refusal is reported by the `repro lock` dispatcher as
## `repro lock: error: <reader diagnostic>`, exit 1.
##
## No mocks: real directories, real git repositories, the real `repro`.

import std/[os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import repro_test_support
import repro_test_support/reasoned_skip

const RepoRoot = currentSourcePath().parentDir.parentDir.parentDir

const BrokenRecipe = """
import repro_project_dsl

package target:
  build:
    discard

this is not nim (((
"""

const SolverSidecar = "package app\nversions: 0.1.0\n"

const settingsV1 = "schema = \"reprobuild.workspace.settings.v1\"\n"
# The two retired files, exactly as an unmigrated workspace still carries
# them: their old names AND their old schemas.
const bootstrapV1 = "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
  "[manifest]\nurl = \"https://git.example.invalid/acme/records.git\"\n" &
  "branch = \"latest\"\n"
const stateV1Old = "schema = \"reprobuild.workspace.local.v1\"\n\n" &
  "[workspace]\nproject = \"demo\"\n"

const compileWitness = "could not read the solve of"
  ## The provider probe's failure for a recipe that does not compile
  ## (`unreadableRecipeLockRefusal`).

type MemberKind = enum
  mkBrokenRecipe  ## a `repro.nim` that does not compile
  mkSidecar       ## no recipe; a `repro.solver` sidecar only

proc git(args: string) =
  let res = execCmdEx(quoteShell(findExe("git")) & " " & args)
  if res.exitCode != 0:
    checkpoint("git " & args & "\n" & res.output)
    quit 1

proc seedWorkspace(root, marker, markerBody: string; kind: MemberKind):
    string =
  ## A workspace root marked by the file `marker` (relative to the root),
  ## holding a member git repository `member/` with one committed revision.
  ## Returns the member's path.
  createDir((root / marker).parentDir)
  writeFile(root / marker, markerBody)
  result = root / "member"
  createDir(result)
  git("init -q -b main " & quoteShell(result))
  case kind
  of mkBrokenRecipe: writeFile(result / "repro.nim", BrokenRecipe)
  of mkSidecar: writeFile(result / "repro.solver", SolverSidecar)
  writeFile(result / ".gitignore", ".repro/\n")
  git("-C " & quoteShell(result) & " add -A")
  git("-C " & quoteShell(result) & " -c user.email=t@example.invalid " &
    "-c user.name=t commit -q -m seed")

proc lockVerb(verb, member, scratch: string):
    tuple[code: int; output: string] =
  ## `repro lock <verb> <member>` with the caches inside the scratch
  ## directory, run from the member so discovery starts there.
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    env[k] = v
  env.del("REPRO_WORKSPACE_CONFIG")
  env["REPROBUILD_ACTION_CACHE_ROOT"] = scratch / "cache"
  env["REPROBUILD_STORE_ROOT"] = scratch / "store"
  env["REPRO_STORE_ROOT"] = scratch / "store"
  env["REPRO_DAEMON"] = "off"
  env["REPRO_TOOL_PROVISIONING"] = "path"
  let repro = requireBinary(getEnv("REPRO_BIN", reproBinaryPath(RepoRoot)),
    "reprobuild.apps.repro")
  let p = startProcess(repro, workingDir = member,
    args = ["lock", verb, member], env = env,
    options = {poStdErrToStdOut})
  p.inputStream.close()
  let o = p.outputStream.readAll()
  result = (code: p.waitForExit(), output: o)
  p.close()
  checkpoint("repro lock " & verb & " " & member & " -> " & $result.code &
    "\n" & result.output)

proc checkRetiredSettingsRefusal(run: tuple[code: int; output: string];
                                 root: string) =
  check run.code == 1
  check ("repro lock: error: [" & root / ".repro-workspace.toml" & "]") in
    run.output
  check "retired name of the workspace settings file" in run.output
  check "Rename it to `repro-workspace.toml`" in run.output

proc checkRetiredStateRefusal(run: tuple[code: int; output: string];
                              root: string) =
  check run.code == 1
  check ("repro lock: error: [" & root / ".repro" / "workspace.toml" & "]") in
    run.output
  check "retired name of the workspace state file" in run.output
  check "repro health --fix" in run.output

when not defined(windows):
  suite "lock verbs refuse retired workspace files before the provider probe":

    test "order control: under a migrated root the broken recipe is reached":
      if findExe("git").len == 0:
        skip("git is not on PATH; the member must be a real git repository")
      else:
        let scratch = createTempDir("lock-retired-order-control-", "")
        defer: removeDir(scratch)
        let member = seedWorkspace(scratch / "ws", "repro-workspace.toml",
          settingsV1, mkBrokenRecipe)
        let run = lockVerb("solve", member, scratch)
        check run.code != 0
        check compileWitness in run.output
        check "retired name" notin run.output

    test "a retired settings file is refused before the recipe compiles":
      if findExe("git").len == 0:
        skip("git is not on PATH; the member must be a real git repository")
      else:
        let scratch = createTempDir("lock-retired-settings-", "")
        defer: removeDir(scratch)
        let root = scratch / "ws"
        let member = seedWorkspace(root, ".repro-workspace.toml", bootstrapV1,
          mkBrokenRecipe)
        require not fileExists(root / "repro-workspace.toml")
        for verb in ["solve", "refresh"]:
          let run = lockVerb(verb, member, scratch)
          checkRetiredSettingsRefusal(run, root)
          check compileWitness notin run.output
        check not fileExists(member / "repro.lock")

    test "a retired state file is refused before the recipe compiles":
      if findExe("git").len == 0:
        skip("git is not on PATH; the member must be a real git repository")
      else:
        let scratch = createTempDir("lock-retired-state-", "")
        defer: removeDir(scratch)
        let root = scratch / "ws"
        let member = seedWorkspace(root, ".repro" / "workspace.toml",
          stateV1Old, mkBrokenRecipe)
        require not fileExists(root / ".repro" / "workspace-state.toml")
        for verb in ["solve", "refresh"]:
          let run = lockVerb(verb, member, scratch)
          checkRetiredStateRefusal(run, root)
          check compileWitness notin run.output
        check not fileExists(member / "repro.lock")

    test "refusal control: under a migrated root the sidecar solve writes":
      if findExe("git").len == 0:
        skip("git is not on PATH; the member must be a real git repository")
      else:
        let scratch = createTempDir("lock-retired-refusal-control-", "")
        defer: removeDir(scratch)
        let member = seedWorkspace(scratch / "ws", "repro-workspace.toml",
          settingsV1, mkSidecar)
        check lockVerb("solve", member, scratch).code == 0
        check lockVerb("refresh", member, scratch).code == 0
        check fileExists(member / "repro.lock")

    test "a retired root is refused when the solve needs no compile":
      if findExe("git").len == 0:
        skip("git is not on PATH; the member must be a real git repository")
      else:
        let scratch = createTempDir("lock-retired-sidecar-", "")
        defer: removeDir(scratch)
        let settingsRoot = scratch / "settings-ws"
        let settingsMember = seedWorkspace(settingsRoot,
          ".repro-workspace.toml", bootstrapV1, mkSidecar)
        let stateRoot = scratch / "state-ws"
        let stateMember = seedWorkspace(stateRoot, ".repro" / "workspace.toml",
          stateV1Old, mkSidecar)
        for verb in ["solve", "refresh"]:
          checkRetiredSettingsRefusal(lockVerb(verb, settingsMember, scratch),
            settingsRoot)
          checkRetiredStateRefusal(lockVerb(verb, stateMember, scratch),
            stateRoot)
        check not fileExists(settingsMember / "repro.lock")
        check not fileExists(stateMember / "repro.lock")

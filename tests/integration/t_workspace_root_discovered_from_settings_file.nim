## The workspace root is the nearest directory holding `repro-workspace.toml`.
##
## Workspace-Settings-Files.md §6: "The workspace root is the nearest ancestor
## directory containing `repro-workspace.toml`, unless
## `REPRO_WORKSPACE_CONFIG` names the file." Every root lookup in reprobuild
## goes through one walk, `repro_core/workspace_root.discoverWorkspaceRoot`,
## so this test pins that walk directly AND through the two kinds of caller
## that matter most:
##
##   * a workspace-wide verb run from inside a member repo — `repro workspace
##     repos list`, which ascends to the root and lists the root's own
##     `repos/*.toml`;
##   * the pre-push hook's resolution — `repro check --mode=pre-push
##     --current-repo=<member>`, exactly the call the managed hook makes,
##     which walks up from the member and names the root it found in its
##     verdict. The fixture root has no state yet, so the gate's verdict is
##     the documented no-op ("not a workspace; nothing to enforce (no
##     resolved manifest checkout at <root>)") — FINDING a root and the root
##     being INITIALIZED are separate questions, and the message names the
##     root that was found.
##
## The member repo is made deliberately tempting: it carries its own build
## `.repro/` directory and a committed `repro.lock` — the MO-2 marker that,
## absent anything above it, makes a repo its own single-repo workspace. A
## walk that does not treat `repro-workspace.toml` as a root marker therefore
## stops at the MEMBER, and both CLI legs fail.
##
## Legs:
##   1. the walk itself, from a directory nested two levels inside the member;
##   2. `workspace repos list` from the member finds the settings-marked root;
##   3. the pre-push resolution from the member names that root;
##   4. `REPRO_WORKSPACE_CONFIG` overrides discovery (both CLI legs and the
##      walk name the directory of the file it points at);
##   5. old roots are FOUND but REFUSED: a root marked only by the retired
##      settings file `.repro-workspace.toml`, and one marked only by the
##      retired state file `.repro/workspace.toml`, are each still discovered
##      from their member (so a command lands on the unmigrated root rather
##      than silently treating the member as its own workspace), and a
##      workspace-wide verb run there is refused naming the retired file and
##      its remedy — the rename for the settings file, `repro health --fix`
##      for the state file. Neither old file is read as settings or state;
##      the retired names and their replacements are listed in the
##      specification's Retired-Names.md;
##   6. precedence: a nested workspace root wins over the outer one for paths
##      under it, and a manifest checkout inside a marked root's `.repro/` is
##      that root's state, never a root of its own.
##
## Mutation check: dropping the settings-file marker from the shared helper
## (`workspaceMarkerIn`) fails legs 1–3 (the walk stops at the member's
## `repro.lock`).
##
## No mocks: real directories, a real git repository for the member, and the
## real `repro` binary.

import std/[os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import repro_test_support
import repro_test_support/reasoned_skip
import repro_core/workspace_root

proc reproBinary(): string =
  requireBinary(currentSourcePath().parentDir.parentDir.parentDir / "build" /
    "bin" / addFileExt("repro", ExeExt), "reprobuild.apps.repro")

proc runRepro(args: openArray[string]; cwd: string; config = ""):
    tuple[code: int; stdout, stderr: string] =
  ## The real binary run from `cwd`, with `REPRO_WORKSPACE_CONFIG` set to
  ## `config` (removed when empty) and nothing on stdin.
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    env[k] = v
  env.del("REPRO_WORKSPACE_CONFIG")
  if config.len > 0:
    env["REPRO_WORKSPACE_CONFIG"] = config
  let p = startProcess(reproBinary(), workingDir = cwd, args = @args,
    env = env, options = {})
  p.inputStream.close()
  let o = p.outputStream.readAll()
  let e = p.errorStream.readAll()
  result = (code: p.waitForExit(), stdout: o, stderr: e)
  p.close()

proc requireSuccess(command: string) =
  let res = execCmdEx(command)
  if res.exitCode != 0:
    checkpoint("command failed: " & command & "\n" & res.output)
    quit 1

proc fragmentToml(name: string): string =
  "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\nname = \"" & name &
    "\"\npath = \"" & name & "\"\nremote = \"acme\"\nmainline = \"main\"\n"

const settingsV1 = "schema = \"reprobuild.workspace.settings.v1\"\n"
# The two retired files, exactly as an unmigrated workspace still carries
# them: their old names AND their old schemas.
const bootstrapV1 = "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
  "[manifest]\nurl = \"https://git.example.invalid/acme/records.git\"\n" &
  "branch = \"latest\"\n"
const stateV1Old = "schema = \"reprobuild.workspace.local.v1\"\n\n" &
  "[workspace]\nproject = \"demo\"\n"

proc seedWorkspace(root, fragment, marker, markerBody: string): string =
  ## A workspace root whose own `repos/` holds `fragment`, marked by the file
  ## `marker` (relative to the root), with a member git repo `member/` that
  ## carries a build `.repro/` and a committed `repro.lock`. Returns the
  ## member's path.
  createDir(root / "repos")
  writeFile(root / "repos" / (fragment & ".toml"), fragmentToml(fragment))
  createDir((root / marker).parentDir)
  writeFile(root / marker, markerBody)
  let member = root / "member"
  createDir(member / ".repro" / "build")
  createDir(member / "src" / "deep")
  let git = findExe("git")
  requireSuccess(quoteShell(git) & " init -q -b main " & quoteShell(member))
  writeFile(member / "repro.lock", "# committed solved-graph lock\n")
  member

proc reposList(member: string; config = ""): tuple[code: int; listing: string] =
  let run = runRepro(["workspace", "repos", "list"], member, config)
  checkpoint("repos list from " & member & " -> " & $run.code & "\nstdout: " &
    run.stdout & "\nstderr: " & run.stderr)
  (run.code, run.stdout)

proc gateVerdict(member, scratch: string; config = ""): string =
  ## The pre-push resolution, invoked as the managed hook invokes it, from an
  ## unrelated directory so only `--current-repo` can lead it to the root.
  let refs = scratch / "pushed-refs"
  writeFile(refs, "")
  let run = runRepro(["check", "--mode=pre-push",
    "--current-repo=" & member, "--pushed-refs=" & refs], scratch, config)
  checkpoint("pre-push from " & member & " -> " & $run.code & "\nstderr: " &
    run.stderr)
  check run.code == 0
  run.stderr

suite "workspace root discovery keys on the settings file":

  test "t_workspace_root_discovered_from_settings_file":
    if findExe("git").len == 0:
      skip("git is not on PATH — the member repo must be a real git " &
        "repository, because the pre-push resolution is the managed hook's")
    else:
      let scratch = createTempDir("repro-root-discovery-", "")
      defer: removeDir(scratch)
      delEnv("REPRO_WORKSPACE_CONFIG")

      # The root is marked ONLY by repro-workspace.toml.
      let root = scratch / "ws"
      let member = seedWorkspace(root, "core", "repro-workspace.toml",
        settingsV1)
      require not dirExists(root / ".repro")
      require not fileExists(root / ".repro-workspace.toml")

      # Leg 1 — the walk.
      let found = discoverWorkspaceRoot(member / "src" / "deep")
      check found.root == root
      check found.marker == wrmSettingsFile
      check findWorkspaceRoot(member) == root

      # Leg 2 — a workspace-wide verb from inside the member.
      let listed = reposList(member)
      check listed.code == 0
      check listed.listing.startsWith("core\tcore\t")

      # Leg 3 — the pre-push hook's resolution names the root.
      let verdict = gateVerdict(member, scratch)
      check ("no resolved manifest checkout at " & root & ")") in verdict
      check ("at " & member & ")") notin verdict

      # Leg 4 — REPRO_WORKSPACE_CONFIG names another workspace's file.
      let other = scratch / "other"
      createDir(other / "repos")
      writeFile(other / "repos" / "elsewhere.toml", fragmentToml("elsewhere"))
      writeFile(other / "repro-workspace.toml", settingsV1)
      let overridden = reposList(member, other / "repro-workspace.toml")
      check overridden.code == 0
      check overridden.listing.startsWith("elsewhere\telsewhere\t")
      check ("no resolved manifest checkout at " & other & ")") in
        gateVerdict(member, scratch, other / "repro-workspace.toml")
      putEnv("REPRO_WORKSPACE_CONFIG", other / "repro-workspace.toml")
      check discoverWorkspaceRoot(member).root == other
      check discoverWorkspaceRoot(member).marker == wrmConfigEnv
      # Naming a file that does not exist means "no settings file": settings
      # files mark nothing, and the member's own lock is all that is left.
      putEnv("REPRO_WORKSPACE_CONFIG", scratch / "missing.toml")
      check discoverWorkspaceRoot(member).root == member
      check discoverWorkspaceRoot(member).marker == wrmCommittedLock
      delEnv("REPRO_WORKSPACE_CONFIG")

      # Leg 5 — old roots are found, and refused with the remedy.
      let legacy = scratch / "legacy"
      let legacyMember = seedWorkspace(legacy, "old", ".repro-workspace.toml",
        bootstrapV1)
      require not fileExists(legacy / "repro-workspace.toml")
      check discoverWorkspaceRoot(legacyMember).marker == wrmSettingsFile
      check discoverWorkspaceRoot(legacyMember).root == legacy
      let legacyRun = runRepro(["workspace", "repos", "list"], legacyMember)
      checkpoint("repos list from " & legacyMember & " -> " & $legacyRun.code &
        "\nstdout: " & legacyRun.stdout & "\nstderr: " & legacyRun.stderr)
      check legacyRun.code != 0
      check not legacyRun.stdout.contains("old\told\t")
      check (legacy / ".repro-workspace.toml") in legacyRun.stderr
      check "retired name of the workspace settings file" in legacyRun.stderr
      check "Rename it to `repro-workspace.toml`" in legacyRun.stderr

      let stateOnly = scratch / "state-only"
      let stateMember = seedWorkspace(stateOnly, "kept",
        ".repro" / "workspace.toml", stateV1Old)
      require not fileExists(stateOnly / ".repro" / "workspace-state.toml")
      check discoverWorkspaceRoot(stateMember).root == stateOnly
      check discoverWorkspaceRoot(stateMember).marker == wrmStateFile
      let stateRun = runRepro(["workspace", "repos", "list"], stateMember)
      checkpoint("repos list from " & stateMember & " -> " & $stateRun.code &
        "\nstdout: " & stateRun.stdout & "\nstderr: " & stateRun.stderr)
      check stateRun.code != 0
      check not stateRun.stdout.contains("kept\tkept\t")
      check (stateOnly / ".repro" / "workspace.toml") in stateRun.stderr
      check "retired name of the workspace state file" in stateRun.stderr
      check "repro health --fix" in stateRun.stderr

      # Leg 6 — precedence. A nested root wins for paths under it...
      let inner = root / "nested"
      createDir(inner)
      writeFile(inner / "repro-workspace.toml", settingsV1)
      createDir(inner / "lib")
      check findWorkspaceRoot(inner / "lib") == inner
      check findWorkspaceRoot(member) == root
      # ...and a manifest checkout under a marked root's `.repro/` (a layer
      # checkout carries `projects/`) is that root's state, not a root.
      let layerCheckout = root / ".repro" / "manifests-0-layer"
      createDir(layerCheckout / "projects")
      createDir(layerCheckout / ".repro")
      writeFile(layerCheckout / "projects" / "demo.toml", "")
      check workspaceMarkerIn(layerCheckout) == wrmManifestCheckout
      check findWorkspaceRoot(layerCheckout) == root

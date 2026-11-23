## The prompt-time no-op answer must notice an edit to what a flake
## activation actually read.
##
## Regression gate for `reprobuild-pm`
## `issues/2026-09-28-dev-env-prompt-key-ignores-flake-inputs.md`. The shell
## hook runs `repro dev-env export <shell>` on every prompt, and that command
## answers "no-op (cache key unchanged)" without touching the build engine
## when `computeDevEnvEdgeCacheKey` equals `$__REPRO_APPLIED`. The key hashed
## the project file and a handful of other inputs but none of the files a
## `useFlakeDevShell()` activation depends on, so in an activated shell an
## edit to `flake.nix`, or to the working tree of an `--override-input`
## sibling, was answered as a no-op on every prompt afterwards and the shell
## kept the previous environment indefinitely.
## `Nix-Flake-Coexistence.md` §2b requires re-entry to be decided against the
## OBSERVED manifest; `Shell-Direnv-Hook.md` §"Fast-Path Cache-Key Check" is
## the fast path this gate drives.
##
## The sequence is the one a person in an activated shell produces:
##
##   1. a full activation (no markers in the environment);
##   2. a prompt carrying the markers that activation emitted -> no-op;
##   3. an edit to `flake.nix`, then a prompt -> NOT a no-op: it re-activates
##      and the new script carries the edited value;
##   4. a prompt carrying the NEW markers -> no-op again (the fix must not
##      turn every prompt into an activation);
##   5. an edit to the override sibling's file, then a prompt -> NOT a no-op,
##      and the new script carries the sibling's new value.
##
## Both fast paths are exercised: the thin client (`build/bin/repro`) answers
## a confirmed no-op itself and hands every other case to the engine
## (`build/bin/reprobuild`), which re-checks the key before running the edge.
##
## MOCKS: none. `nix` is real, `git` is real, the flake and its `path:`
## sibling are real, and `repro` is the built binary. The fixture's `nixpkgs`
## input is the host's own registry entry resolved to the store path it
## already names, so nothing here needs the network once that entry has been
## fetched.
##
## `nix` is a hard requirement, not a skip, for the reason
## `t_e2e_nf4_flake_dev_shell.nim` gives: a gate whose subject is a foreign
## provisioner is worthless if that provisioner's absence reads as success.
## Unlike that test, this one does not use `/dev/shm` (absent on macOS), so it
## runs on both macOS and Linux.

import std/[json, os, strtabs, strutils, tempfiles, unittest]

import repro_test_support
import repro_test_support/process_fixtures

const NixSystem =
  when defined(macosx):
    when defined(arm64): "aarch64-darwin" else: "x86_64-darwin"
  else:
    when defined(arm64): "aarch64-linux" else: "x86_64-linux"

const NoOpBanner = "repro shell hook: no-op (cache key unchanged)"

const RaceGuardMarginMs = 2100
  ## How long to wait between writing a watched file and starting the
  ## activation that will read it. The activation refuses to emit a matchable
  ## marker when a watched path's mtime or ctime falls inside the window it
  ## cannot distinguish from "changed while the edge was running" (see
  ## `unsettledPromptWatchPaths` in `repro_dev_env_engine/cache_key`): up to
  ## two seconds before the edge started on a filesystem with whole-second
  ## timestamps. Without this wait, step 4 would legitimately fall through,
  ## because step 3's edit was made milliseconds before step 3's activation.
  ## A person who saves `flake.nix` and later presses Enter is not affected;
  ## this only makes the test's machine-speed sequence unambiguous.

proc reproBinary(repoRoot: string): string =
  requireBinary(repoRoot / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc nixExe(): string =
  let found = findExe("nix")
  doAssert found.len > 0,
    "this gate needs `nix` on PATH. Install nix (or run the suite inside " &
    "the repo dev shell); it must not pass without it."
  found

proc gitExe(): string =
  let found = findExe("git")
  doAssert found.len > 0, "this gate needs `git` on PATH."
  found

proc hostEnv(): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    result[key] = value

proc run(exe: string; args: openArray[string]; workDir: string;
         env: StringTableRef = nil): CmdSplitResult =
  runProgramSplit(exe, @args, workDir, if env == nil: hostEnv() else: env)

proc nixArgs(rest: openArray[string]): seq[string] =
  # The host may not enable flakes in nix.conf; a gate that depends on the
  # host's nix.conf reports the host.
  result = @["--extra-experimental-features", "nix-command flakes"]
  for item in rest:
    result.add(item)

proc resolveLocalNixpkgs(): string =
  ## The host's `nixpkgs` registry entry as a store path, so the fixture can
  ## name it as a `path:` input and evaluate offline.
  ##
  ## Two routes, because nix releases disagree. `nix flake metadata --json`
  ## carries a top-level `path` on CppNix (what the NF-4 gate reads), and
  ## does not on Determinate Nix 3.x, whose lazy trees no longer copy the
  ## source to the store just to describe it. `nix flake prefetch --json`
  ## reports `storePath` on both, at the cost of copying the tree once.
  let metadata = run(nixExe(), nixArgs(["flake", "metadata", "nixpkgs",
    "--json"]), getCurrentDir())
  if metadata.code == 0:
    try:
      let node = parseJson(metadata.stdout)
      if node.hasKey("path") and node["path"].getStr().len > 0 and
          dirExists(node["path"].getStr()):
        return node["path"].getStr()
    except CatchableError:
      discard
  let prefetch = run(nixExe(), nixArgs(["flake", "prefetch", "nixpkgs",
    "--json"]), getCurrentDir())
  doAssert prefetch.code == 0,
    "this gate needs a resolvable `nixpkgs` flake registry entry:\n" &
    metadata.stderr & "\n" & prefetch.stderr
  let path = parseJson(prefetch.stdout)["storePath"].getStr()
  doAssert dirExists(path), "`nix flake prefetch nixpkgs` named " & path &
    ", which is not a directory"
  path

proc gitEnv(): StringTableRef =
  ## A fixed identity so the fixture does not depend on the host's git
  ## configuration being complete.
  result = hostEnv()
  result["GIT_AUTHOR_NAME"] = "repro-prompt-key"
  result["GIT_AUTHOR_EMAIL"] = "repro-prompt-key@example.invalid"
  result["GIT_COMMITTER_NAME"] = "repro-prompt-key"
  result["GIT_COMMITTER_EMAIL"] = "repro-prompt-key@example.invalid"

proc git(workDir: string; args: openArray[string]) =
  let res = run(gitExe(), args, workDir, gitEnv())
  doAssert res.code == 0,
    "git " & args.join(" ") & " failed in " & workDir & ":\n" & res.stderr

type
  Fixture = object
    root: string
    project: string
    sibling: string
    repoRoot: string
    reproBin: string

proc flakeText(nixpkgs, sibling, probe: string): string =
  "{\n" &
  "  inputs.nixpkgs.url = \"path:" & nixpkgs & "\";\n" &
  "  inputs.sib.url = \"path:" & sibling & "\";\n" &
  "  outputs = { self, nixpkgs, sib }:\n" &
  "    let pkgs = import nixpkgs { system = \"" & NixSystem & "\"; };\n" &
  "    in {\n" &
  "      devShells." & NixSystem & ".default = pkgs.mkShellNoCC {\n" &
  "        PROMPT_KEY_PROBE = \"" & probe & "\";\n" &
  "        PROMPT_KEY_SIB_MARKER = sib.marker;\n" &
  "      };\n" &
  "    };\n" &
  "}\n"

proc recipeText(sibling: string): string =
  ## `useFlakeDevShell` with an override sibling: the shape whose inputs the
  ## old key could not see. `workspaceOverrides = false` keeps the fixture
  ## independent of whatever workspace the test happens to run inside.
  "import repro_project_dsl\n" &
  "import repro_dsl_stdlib/foreign_env\n" &
  "\n" &
  "package promptkey:\n" &
  "  devEnv:\n" &
  "    useFlakeDevShell(flakeRef = \".\",\n" &
  "      overrideInputs = @[(\"sib\", \"" & sibling & "\")],\n" &
  "      workspaceOverrides = false)\n"

proc prepareFixture(): Fixture =
  result.repoRoot = getCurrentDir()
  result.reproBin = reproBinary(result.repoRoot)
  # `expandFilename`: macOS hands out `/var/folders/...`, which the monitor
  # reports as `/private/var/folders/...`. Use the spelling the kernel uses.
  result.root = expandFilename(createTempDir("repro-prompt-key", ""))
  releaseDirAtProcessExit(result.root)
  result.sibling = result.root / "sib"
  createDir(result.sibling)
  writeFile(result.sibling / "flake.nix",
    "{ outputs = { self }: { marker = builtins.readFile ./marker.txt; }; }\n")
  writeFile(result.sibling / "marker.txt", "sibA")
  result.project = result.root / "proj"
  createDir(result.project)
  writeFile(result.project / "flake.nix",
    flakeText(resolveLocalNixpkgs(), result.sibling, "v1"))
  writeFile(result.project / "repro.nim", recipeText(result.sibling))
  git(result.project, ["init", "-q", "-b", "main", "."])
  # A git flake sees only what git tracks.
  git(result.project, ["add", "flake.nix", "repro.nim"])
  let locked = run(nixExe(), nixArgs(["flake", "lock"]), result.project)
  doAssert locked.code == 0, "`nix flake lock` failed:\n" & locked.stderr
  git(result.project, ["add", "flake.lock"])
  git(result.project, ["commit", "-qm", "prompt-key fixture"])

proc exportEnv(f: Fixture; applied, manifest: string): StringTableRef =
  ## The environment of a shell whose hook is about to run. `HOME` and the
  ## nix configuration are the host's: nix needs its registry, its
  ## `nix.conf` and its daemon. Everything Reprobuild keeps per user is
  ## redirected into the fixture so the gate measures this fixture, not the
  ## developer's caches.
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    if key.startsWith("__REPRO_"):
      continue
    result[key] = value
  result["REPRO_FULL_CLI"] = ""
  result["REPRO_PUBLIC_CLI_PATH"] = ""
  result["REPROBUILD_REPRO"] = ""
  result["REPROBUILD_SOURCE_ROOT"] = f.repoRoot
  result["REPROBUILD_REPO_ROOT"] = f.repoRoot
  result["REPRO_DEV_ENV_AUTO_ALLOW"] = "1"
  result["REPROBUILD_ACTION_CACHE_ROOT"] = f.root / "action-cache"
  result["REPRO_ACTION_CACHE_SHM"] = "0"
  result["REPRO_DAEMON"] = "off"
  result["REPRO_DAEMON_ENDPOINT"] = daemonSocketEndpoint("repro-prompt-key-" &
    $getCurrentProcessId())
  result["REPRO_DAEMON_STATE_DIR"] = f.root / "daemon-state"
  result["REPROBUILD_USER_CONFIG"] = f.root / "no-such-user-config.toml"
  result["REPROBUILD_SYSTEM_CONFIG"] = f.root / "no-such-system-config.toml"
  result["REPROBUILD_VCS_PRIVATE_CONFIG"] =
    f.root / "no-such-private-config.toml"
  createDir(f.root / "action-cache")
  createDir(f.root / "daemon-state")
  if applied.len > 0:
    result["__REPRO_APPLIED"] = applied
  if manifest.len > 0:
    result["__REPRO_ACTIVE_MANIFEST"] = manifest

proc markerValue(script, name: string): string =
  ## The LAST `export NAME='value'` line in a bash activation script.
  let needle = "export " & name & "='"
  for line in script.splitLines():
    let at = line.find(needle)
    if at >= 0:
      let rest = line[at + needle.len .. ^1]
      let closing = rest.find('\'')
      if closing >= 0:
        result = rest[0 ..< closing]

type Prompt = object
  stdout, stderr: string
  code: int
  applied, manifest: string

proc prompt(f: Fixture; applied, manifest: string): Prompt =
  let res = run(f.reproBin, ["dev-env", "export", "bash", "--project-root",
    f.project], f.project, f.exportEnv(applied, manifest))
  result = Prompt(stdout: res.stdout, stderr: res.stderr, code: res.code)
  result.applied = markerValue(res.stdout, "__REPRO_APPLIED")
  result.manifest = markerValue(res.stdout, "__REPRO_ACTIVE_MANIFEST")
  if res.code != 0:
    echo "=== repro dev-env export exit=", res.code, " stderr ===\n",
      res.stderr

proc isNoOp(p: Prompt): bool =
  p.code == 0 and p.stdout.contains(NoOpBanner)

proc isActivation(p: Prompt): bool =
  p.code == 0 and p.applied.len > 0 and p.manifest.len > 0 and
    not p.stdout.contains(NoOpBanner)

suite "e2e_shell_hook_prompt_key_sees_flake_inputs":

  test "edits_to_flake_nix_and_an_override_sibling_reactivate":
    let f = prepareFixture()
    sleep(RaceGuardMarginMs)

    let first = f.prompt("", "")
    check first.isActivation()
    check first.stdout.contains("PROMPT_KEY_PROBE='v1'")
    check first.stdout.contains("PROMPT_KEY_SIB_MARKER='sibA'")

    let unchanged = f.prompt(first.applied, first.manifest)
    if not unchanged.isNoOp():
      echo "=== unchanged prompt stdout ===\n", unchanged.stdout
    check unchanged.isNoOp()

    # Same length on purpose: the edit has to be seen by more than a size.
    writeFile(f.project / "flake.nix",
      readFile(f.project / "flake.nix").replace(
        "PROMPT_KEY_PROBE = \"v1\"", "PROMPT_KEY_PROBE = \"v2\""))
    sleep(RaceGuardMarginMs)
    let afterFlakeEdit = f.prompt(first.applied, first.manifest)
    if afterFlakeEdit.isNoOp():
      echo "BUG: an edit to flake.nix was answered as a prompt-time no-op"
    check afterFlakeEdit.isActivation()
    check afterFlakeEdit.stdout.contains("PROMPT_KEY_PROBE='v2'")
    check afterFlakeEdit.applied != first.applied

    let settled = f.prompt(afterFlakeEdit.applied, afterFlakeEdit.manifest)
    if not settled.isNoOp():
      echo "=== settled prompt stdout ===\n", settled.stdout
    check settled.isNoOp()

    writeFile(f.sibling / "marker.txt", "sibB")
    sleep(RaceGuardMarginMs)
    let afterSiblingEdit = f.prompt(afterFlakeEdit.applied,
      afterFlakeEdit.manifest)
    if afterSiblingEdit.isNoOp():
      echo "BUG: an edit to the override sibling was answered as a no-op"
    check afterSiblingEdit.isActivation()
    check afterSiblingEdit.stdout.contains("PROMPT_KEY_SIB_MARKER='sibB'")

    let settledAgain = f.prompt(afterSiblingEdit.applied,
      afterSiblingEdit.manifest)
    check settledAgain.isNoOp()

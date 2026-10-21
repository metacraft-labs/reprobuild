## Shared fixture of the ReproOS-Agent-Harbor-Integration end-to-end gates
## (M3 `t_e2e_agent_harbor_modifies_installed_source_package`, M4
## `t_e2e_agent_harbor_preview_accept_reject`, M5
## `t_e2e_agent_harbor_change_to_generation_and_remix`).
##
## A one-file C package, `greeter`, built from a local recipe by the built
## `./build/bin/repro` and installed into a scratch store; an agent host
## with `ReprobuildBackend`; and, for the gates that activate generations,
## `HomeSeamDriver`.
##
## `HomeSeamDriver` is the one stand-in, and it is a TEST SEAM, not a mock:
## it drives the real `repro home apply` / `repro home rollback` into real
## home generations, but it hands `repro home apply` the staged prefix
## through `REPRO_TEST_PACKAGE_SOURCE`, the test seam the home e2e gates
## use. Production has no way yet to put an already-realized from-source
## prefix into a home generation (campaign question Q8); the seam stands
## in for exactly that one step, and it lives here, in the test, so no
## product code depends on it.

import std/[algorithm, os, osproc, sequtils, strutils, tables, tempfiles]

import repro_agent_protocol
import repro_agent_backend
import repro_project_dsl/install_mirror_resolver
import repro_peer_cache/auth as peerAuth

const
  ReprobuildRepoRoot* = currentSourcePath().parentDir.parentDir.parentDir.parentDir
  reproBinary* = ReprobuildRepoRoot / "build/bin/repro"
  InstallTarget* = "install-mirror-greeter"
    ## The build edge that installs the package. A bare `repro build`
    ## builds every edge, the `test` action included, so a build would fail
    ## on a stale expectation; the agent builds and tests as separate steps.

  greeterV1* = """
#include <stdio.h>
#include <string.h>
int main(int argc, char **argv) {
  if (argc > 1 && strcmp(argv[1], "serve") == 0) {
    while (getchar() != EOF) {}
    return 0;
  }
  puts("hello from greeter v1");
  return 0;
}
"""
  greeterV2* = greeterV1.replace("greeter v1", "greeter v2")
  greeterBroken* = greeterV1.replace("return 0;\n}\n", "return 3;\n}\n")
    ## Builds and runs, but exits non-zero: fails a command-exit-zero check.

  MirrorTools = ["repro-install-mirror-publish", "rm", "cp", "touch",
    "sed", "chmod", "find", "head", "od", "tr", "sort", "grep", "dirname",
    "basename", "wc", "patchelf", "readlink", "mktemp", "mv", "readelf", "cat"]

proc recipe*(): string =
  result = """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh
import repro_dsl_stdlib/types/package_result

package greeter:
  defaultToolProvisioning "path"

  versions:
    "1.0.0":
      sourceRevision = "local"

  uses:
    "sh"
    "mkdir"
    "cc"
"""
  for t in MirrorTools:
    result.add "    \"" & t & "\"\n"
  result.add """

  build:
    let compile = shell(
      command = "mkdir -p build/out/usr/bin && cc -O2 -o build/out/usr/bin/greeter src/main.c",
      actionId = "greeter.build.compile",
      extraOutputs = @["build/out/usr/bin/greeter"])
    appendRegisteredActionToolIdentityRefs(compile.id, ["mkdir", "cc"])
    emitInstallTreeMirror(compile, "build", "out", "greeter", "shell")
    let selftest = shell(
      command = "build/out/usr/bin/greeter > build/selftest.out && grep -qxF \"$(cat tests/expected.txt)\" build/selftest.out",
      actionId = "test", after = @[compile],
      extraInputs = @["tests/expected.txt"],
      extraOutputs = @["build/selftest.out"])
    appendRegisteredActionToolIdentityRefs(selftest.id, ["grep", "cat"])
"""

proc fixtureRunnable*(): bool =
  ## The gates need Linux (`/proc/<pid>/exe`), the built repro and cc.
  when defined(linux):
    fileExists(reproBinary) and findExe("cc").len > 0
  else:
    false

proc cleanup*(dir: string) =
  ## Published prefixes are read-only by design.
  discard execCmd("chmod -R u+w " & quoteShell(dir))
  removeDir(dir)

proc op*(kind: OperationKind; target: string;
         args: openArray[(string, string)] = []): Operation =
  result = Operation(kind: kind, target: target)
  for (n, v) in args:
    result.args.add OpArg(name: n, value: v)
  result.args = result.args.sortedByIt(it.name)

proc runEnv(env: openArray[(string, string)]; cwd: string;
            args: openArray[string]): tuple[output: string; code: int] =
  var cmd = "cd " & quoteShell(cwd) & " && env"
  for (k, v) in env:
    cmd.add " " & k & "=" & quoteShell(v)
  cmd.add " " & quoteShell(reproBinary)
  for a in args:
    cmd.add " " & quoteShell(a)
  let (output, code) = execCmdEx(cmd)
  (output, code)

# ---------------------------------------------------------------------
# The home-generation test seam (see the header).

type HomeSeamDriver* = ref object of GenerationDriver
  stateDir*, profileDir*, homeDir*, storeRoot*: string
  toolPath*: string
  lastOutput*: string

proc homeEnv(d: HomeSeamDriver; exe: string): seq[(string, string)] =
  @[("PATH", d.toolPath), ("REPRO_DAEMON", "off"),
    ("REPRO_HOME_PROFILE_DIR", d.profileDir),
    ("REPRO_HOME_STATE_DIR", d.stateDir), ("REPRO_STORE_ROOT", d.storeRoot),
    ("HOME", d.homeDir), ("REPRO_HOST", "agent-harbor-gate"),
    ("REPRO_HOME_POSIX_PATH_RC", d.homeDir / ".profile"),
    ("REPRO_CACHE_DISABLE", "1"),
    ("REPRO_HOME_PACKAGE_CATALOG", "greeter"),
    ("REPRO_TEST_PACKAGE_SOURCE", "greeter=" & exe)]

method current*(d: HomeSeamDriver): string =
  let link = d.stateDir / "current"
  if not symlinkExists(link): "" else: expandSymlink(link).extractFilename

proc applyExe*(d: HomeSeamDriver; exe: string): string =
  let (output, code) = runEnv(d.homeEnv(exe), d.profileDir, ["home", "apply"])
  d.lastOutput = output
  if code != 0:
    raise newException(StageError, "repro home apply exited " & $code &
      ": " & output)
  d.current()

method switchTo*(d: HomeSeamDriver; change: StagedChange): string =
  d.applyExe(change.prefixPath / "usr" / "bin" / "greeter")

method rollbackTo*(d: HomeSeamDriver; generation: string) =
  let (output, code) = runEnv(d.homeEnv(""), d.profileDir,
                              ["home", "rollback", generation])
  d.lastOutput = output
  if code != 0:
    raise newException(StageError, "repro home rollback exited " & $code &
      ": " & output)

method launcherDir*(d: HomeSeamDriver): string = d.stateDir / "current" / "bin"

# ---------------------------------------------------------------------
# The installed package, the host and an agent session.

type Fixture* = ref object
  tmp*, catalog*, store*, previewStore*, recipeDir*: string
  installedRel*, installedExe*, installedRecipeTree*: string
  toolPath*: string
  backend*: ReprobuildBackend
  host*: Host
  consent*, agent*: Connection
  sid*: string

proc newFixture*(name: string; grants: seq[string];
                 withGenerations = false): Fixture =
  ## Install greeter v1 from source and open an agent session holding
  ## `grants`. With `withGenerations`, also make v1 the current home
  ## generation and give the backend a `HomeSeamDriver`.
  let f = Fixture(tmp: createTempDir("agent-" & name & "-", ""))
  f.catalog = f.tmp / "catalog"
  f.store = f.tmp / "store"
  f.previewStore = f.tmp / "preview-store"
  f.recipeDir = f.catalog / "greeter"
  createDir(f.recipeDir / "src")
  createDir(f.recipeDir / "tests")
  writeFile(f.recipeDir / "repro.nim", recipe())
  writeFile(f.recipeDir / "src" / "main.c", greeterV1)
  writeFile(f.recipeDir / "tests" / "expected.txt", "hello from greeter v1\n")
  # The repro binary's directory carries repro-install-mirror-publish,
  # which the install mirror runs by name.
  f.toolPath = reproBinary.parentDir & ":" & getEnv("PATH")
  let (output, code) = runEnv([("PATH", f.toolPath),
    ("REPRO_STORE_ROOT", f.store), ("REPRO_INSTALL_MIRROR_MODE", "hashed"),
    ("REPRO_DAEMON", "off")], f.recipeDir, ["build"])
  if code != 0:
    raise newException(CatchableError, "installing the fixture failed: " &
      output)
  f.installedRel = readRealizationInfoFile(f.catalog, "greeter").storeRelativePath
  f.installedExe = f.store / f.installedRel / "usr" / "bin" / "greeter"
  f.installedRecipeTree = recipeTreeDigest(f.recipeDir)
  f.backend = newReprobuildBackend(reproBinary, f.store, @[f.catalog],
                                   f.previewStore, timeoutSeconds = 900)
  f.backend.extraEnv = @[("PATH", f.toolPath), ("REPRO_DAEMON", "off")]
  f.backend.overlayRoot = f.tmp / "overlays"
  f.backend.remixKey = generateKeypair()
  if withGenerations:
    let d = HomeSeamDriver(stateDir: f.tmp / "home-state",
      profileDir: f.tmp / "profile", homeDir: f.tmp / "home",
      storeRoot: f.tmp / "home-store", toolPath: f.toolPath)
    for dir in [d.stateDir, d.profileDir, d.homeDir, d.storeRoot]:
      createDir(dir)
    writeFile(d.profileDir / "home.nim",
      "import repro_profile\n\nprofile \"agent-gate\":\n  activity default:\n    `greeter`\n")
    discard d.applyExe(f.installedExe)
    f.backend.driver = d
  f.host = newHost(f.backend, f.tmp / "workspaces")
  f.consent = newConnection(chConsent)
  discard f.host.hello(f.consent, ProtocolVersion, {low(Family) .. high(Family)})
  let (sid, secret) = f.host.createSession(f.consent, "agent-harbor",
                                           grants.mapIt(parseGrant(it)))
  f.sid = sid
  f.agent = newConnection(chProvider)
  discard f.host.hello(f.agent, ProtocolVersion, {low(Family) .. high(Family)})
  f.host.attach(f.agent, sid, secret)
  f

proc reinstall*(f: Fixture) =
  ## Rebuild the catalog's greeter into the installed store, as an upstream
  ## update would; the catalog's sidecar then names the new output.
  let (output, code) = runEnv([("PATH", f.toolPath),
    ("REPRO_STORE_ROOT", f.store), ("REPRO_INSTALL_MIRROR_MODE", "hashed"),
    ("REPRO_DAEMON", "off")], f.recipeDir, ["build", InstallTarget])
  if code != 0:
    raise newException(CatchableError, "reinstalling the fixture failed: " &
      output)
  f.installedRel = readRealizationInfoFile(f.catalog, "greeter").storeRelativePath
  f.installedExe = f.store / f.installedRel / "usr" / "bin" / "greeter"
  f.installedRecipeTree = recipeTreeDigest(f.recipeDir)

proc submit*(f: Fixture; intent: Intent; ops: seq[Operation];
             declared: seq[string]; evidence: seq[Digest32] = @[]): PlanReceipt =
  f.host.submitPlan(f.agent, Plan(sessionId: f.sid,
    intentId: intentId(intent), baseGeneration: f.backend.activeGeneration(),
    operations: ops, declaredCapabilities: declared.mapIt(parseGrant(it)),
    evidence: evidence))

proc runPlan*(f: Fixture; intent: Intent; ops: seq[Operation];
              declared: seq[string]): seq[OpResult] =
  ## Submit and execute a plan that needs no approval.
  let r = f.submit(intent, ops, declared)
  doAssert r.approvalRequired.len == 0, "plan unexpectedly needs approval"
  f.host.execute(f.agent, r.planId.hex).results

proc checkoutGreeter*(f: Fixture; intent: Intent): string =
  ## Check out the installed greeter; returns the workspace id.
  let rs = f.runPlan(intent, @[op(okCheckoutCreate, "greeter")],
                     @["workspace.create:greeter"])
  doAssert rs[0].status == osCompleted, rs[0].detail
  rs[0].detail

proc exeOutput*(path: string): string =
  execProcess(path).strip

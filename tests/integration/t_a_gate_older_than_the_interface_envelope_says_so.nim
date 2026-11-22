## A pre-push gate whose engine is OLDER than the interface envelope the
## recipe's SDK writes says so: its own property, both versions, and a remedy
## that can work — not "make the recipe readable". `repro lock refresh`, which
## fails the same way, says the same.
##
## Spec: Unified-Locking-And-Hooks.md §13.5, "An engine older than the
## interface envelope" (amended 2026-11-22); CLI/hooks.md §"Contract Handshake
## And Stand-Down", "Re-anchoring is explicit" (amended 2026-11-22). Observed
## 2026-11-22: hooks anchored to a 0.2.27 that reads
## envelope 33 refused every reprobuild push (the checkout writes 36) with
##
##   committed_lock_dependency_set_unverified — make the recipe readable — …
##   repro interface extract: error: unsupported interface envelope version
##
## and `repro lock refresh` with the same build failed identically, so the
## named remedy could not work and nothing said the engine was the problem.
##
## ## The shape
##
## A one-repo workspace (`app`, a recipe with no dependencies). Its recipe is
## compiled against an SDK at `<scratch>/sdk` named by `REPROBUILD_LIBS_DIR`:
## every library of this checkout, symlinked, except
## `repro_interface_artifacts`, whose main module is a copy declaring
## `EnvelopeVersion` ONE HIGHER than this build's. That is exactly the field
## shape — a checkout one envelope bump ahead of the engine running the gate —
## produced without a second build of the engine. The runner compiled against
## it writes the newer envelope, and the real `./build/bin/repro` (gate and
## refresh) cannot read it.
##
## Asserted:
##   1. the gate refuses with `gate_engine_older_than_interface_envelope`, not
##      `committed_lock_dependency_set_unverified`; its evidence names both
##      versions and the SDK; its remedy names a build of that SDK and
##      `hooks ensure --vcs --re-anchor <workspace>`, and not "make the recipe
##      readable";
##   2. `repro lock refresh` fails, and its report says the engine is older,
##      with both versions and a remedy that runs the refresh with a build of
##      the SDK;
##   3. control: with `REPROBUILD_LIBS_DIR` pointing at this checkout's own
##      libs (same envelope as the engine), the refresh succeeds — so the
##      refusal above is about the envelope and nothing else in the fixture.
##
## Fails before the fix: (1) the property is
## `committed_lock_dependency_set_unverified` with "make the recipe readable";
## (2) the refresh's report carries no version and no "OLDER".
##
## Test-double policy: NO mocks. The SDK copy is a real reprobuild source tree
## (this one's files) with one constant changed — the only way to have an SDK
## newer than the engine under test without building a second engine. Real
## git, real origin, the real provider and interface compiles, the real gate.
##
## Skip rule: `git` missing on PATH.

import std/[json, os, strutils, tempfiles, unittest]

import repro_test_support
import repro_test_support/reasoned_skip

proc repoRoot(): string =
  result = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

const InterfaceModule = "repro_interface_artifacts"

proc makeNewerSdk(sdk: string): tuple[written, readable: int] =
  ## ``sdk``: this checkout's libraries, with the interface module's
  ## ``EnvelopeVersion`` raised by one. Returns both versions.
  let libs = repoRoot() / "libs"
  createDir(sdk / "libs")
  for kind, path in walkDir(libs):
    if kind notin {pcDir, pcLinkToDir}: continue
    let name = path.extractFilename
    if name == InterfaceModule: continue
    createSymlink(path, sdk / "libs" / name)
  # The remedy builds an engine from the SDK's flake; the test reads that
  # command, it does not run it.
  createSymlink(repoRoot() / "flake.nix", sdk / "flake.nix")
  let srcDir = sdk / "libs" / InterfaceModule / "src"
  createDir(srcDir)
  createSymlink(libs / InterfaceModule / "src" / InterfaceModule,
    srcDir / InterfaceModule)
  let original = readFile(libs / InterfaceModule / "src" /
    (InterfaceModule & ".nim"))
  var patched: seq[string]
  for line in original.splitLines():
    let stripped = line.strip()
    if result.readable == 0 and stripped.startsWith("EnvelopeVersion = ") and
        stripped.endsWith("'u16"):
      result.readable = parseInt(stripped["EnvelopeVersion = ".len ..
        ^("'u16".len + 1)])
      result.written = result.readable + 1
      patched.add(line.replace($result.readable & "'u16",
        $result.written & "'u16"))
    else:
      patched.add(line)
  doAssert result.readable > 0, "EnvelopeVersion not found in " & InterfaceModule
  writeFile(srcDir / (InterfaceModule & ".nim"), patched.join("\n"))

const projectToml = """
schema = "reprobuild.workspace.project.v1"

[project]
name = "app"

[[remote]]
name = "app-origin"
fetch = "$1"

includes = [
  "repos/app.toml",
]
"""

const workspaceLocalToml = """
schema = "reprobuild.workspace.state.v1"

[workspace]
project = "app"
branch = "main"
"""

const appFragment = """
schema = "reprobuild.workspace.repo.v2"

[repo]
name = "app"
path = "app"
remote = "app-origin"
mainline = "main"
"""

const appRecipe = """
import repro_project_dsl

package app:
  defaultToolProvisioning "path"
  build:
    discard aggregate("app-aggregate", actions = @[])
"""

type Fixture = object
  scratch, ws, sdk, reproBin, gitBin: string
  written, readable: int

proc git(fx: Fixture; args: varargs[string]): string =
  var argv = @[fx.gitBin, "-C", fx.ws / "app"]
  for a in args: argv.add(a)
  let res = runShell(shellCommand(argv))
  if res.code != 0:
    checkpoint("git " & args.join(" ") & " failed:\n" & res.output)
    quit 1
  res.output.strip()

proc buildFixture(): Fixture =
  result.gitBin = findExe("git")
  result.reproBin = reproBinary()
  result.scratch = createTempDir("repro-envelope-skew-", "")
  result.ws = result.scratch / "workspace"
  result.sdk = result.scratch / "sdk"
  let versions = makeNewerSdk(result.sdk)
  result.written = versions.written
  result.readable = versions.readable
  createDir(result.ws / "projects")
  createDir(result.ws / "repos")
  createDir(result.ws / ".repro")
  writeFile(result.ws / ".repro" / "workspace-state.toml", workspaceLocalToml)
  let origin = result.scratch / "origin-app.git"
  discard runShell(shellCommand(@[result.gitBin, "init", "-q", "--bare", "-b",
    "main", origin]))
  discard runShell(shellCommand(@[result.gitBin, "clone", "-q",
    fileUrl(origin), result.ws / "app"]))
  discard result.git("config", "user.email", "tester@example.invalid")
  discard result.git("config", "user.name", "Gate Tester")
  discard result.git("config", "commit.gpgsign", "false")
  discard result.git("symbolic-ref", "HEAD", "refs/heads/main")
  writeFile(result.ws / "app" / "repro.nim", appRecipe)
  writeFile(result.ws / "app" / ".gitignore", ".repro/\n")
  discard result.git("add", "-A")
  discard result.git("commit", "-q", "-m", "seed app")
  discard result.git("push", "-q", "origin", "HEAD:main")
  writeFile(result.ws / "projects" / "app.toml", projectToml % [fileUrl(origin)])
  writeFile(result.ws / "repos" / "app.toml", appFragment)

proc sdkEnv(libsDir: string): seq[(string, string)] =
  @[("REPROBUILD_NO_RUNQUOTA", "1"), ("REPROBUILD_LIBS_DIR", libsDir)]

proc runGate(fx: Fixture): tuple[code: int; report: JsonNode] =
  let refsFile = fx.scratch / "pushed-refs.txt"
  writeFile(refsFile, "refs/heads/main " & fx.git("rev-parse", "HEAD") &
    " refs/heads/main 0000000000000000000000000000000000000000\n")
  let res = runShell(shellCommand(@[
    fx.reproBin, "check", "--mode=pre-push",
    "--workspace-root=" & fx.ws,
    "--current-repo=" & fx.ws / "app",
    "--pushed-refs=" & refsFile,
    "--json",
  ], sdkEnv(fx.sdk / "libs")))
  checkpoint("gate exit " & $res.code & ":\n" & res.output)
  let start = res.output.find('{')
  if start < 0:
    return (res.code, newJObject())
  (res.code, parseJson(res.output[start .. ^1]))

proc failureOf(report: JsonNode; property: string): JsonNode =
  if report.hasKey("failures"):
    for f in report["failures"]:
      if f["property"].getStr() == property: return f
  newJNull()

proc properties(report: JsonNode): seq[string] =
  if report.hasKey("failures"):
    for f in report["failures"]: result.add(f["property"].getStr())

suite "a gate older than the interface envelope says so":

  test "the gate and the refresh name the engine, both versions and a remedy":
    if findExe("git").len == 0:
      skip("git is not on PATH")
    else:
      let fx = buildFixture()
      defer: removeDir(fx.scratch)
      checkpoint("SDK writes envelope " & $fx.written & "; engine reads " &
        "through " & $fx.readable)

      # ---- (1) the gate ---------------------------------------------------
      let gate = fx.runGate()
      check gate.code == 2
      checkpoint("properties: " & $gate.report.properties)
      check "committed_lock_dependency_set_unverified" notin
        gate.report.properties
      let refusal = gate.report.failureOf(
        "gate_engine_older_than_interface_envelope")
      require refusal.kind == JObject
      let evidence = refusal["evidence"].getStr()
      let remedy = refusal["remediation"].getStr()
      checkpoint("evidence: " & evidence)
      checkpoint("remediation: " & remedy)
      check evidence.contains("envelope-written=" & $fx.written)
      check evidence.contains("envelope-readable=" & $fx.readable)
      check evidence.contains("sdk=" & fx.sdk)
      check evidence.contains("OLDER")
      check remedy.contains("nix build --no-link --print-out-paths")
      check remedy.contains(fx.sdk & "#default")
      check remedy.contains("hooks ensure --vcs --re-anchor " & fx.ws)
      check not remedy.contains("make the recipe readable")

      # ---- (2) the refresh ------------------------------------------------
      let refresh = runShell(shellCommand(@[fx.reproBin, "lock", "refresh"],
        sdkEnv(fx.sdk / "libs")), cwd = fx.ws / "app")
      checkpoint("refresh exit " & $refresh.code & ":\n" & refresh.output)
      check refresh.code != 0
      check refresh.output.contains("OLDER")
      check refresh.output.contains("up to version " & $fx.readable)
      check refresh.output.contains("writes version " & $fx.written)
      check refresh.output.contains("lock refresh " & fx.ws / "app")
      check not fileExists(fx.ws / "app" / "repro.lock")

      # ---- (3) control: the same fixture at this checkout's own envelope --
      let control = runShell(shellCommand(@[fx.reproBin, "lock", "refresh"],
        sdkEnv(repoRoot() / "libs")), cwd = fx.ws / "app")
      checkpoint("control refresh exit " & $control.code & ":\n" &
        control.output)
      check control.code == 0

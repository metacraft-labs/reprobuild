## `repro test` runs a package's run-edges in the dev environment its recipe
## declares, whatever shell `repro` was started from.
##
## The defect this guards: a recipe declared `devEnv:` (a library on the
## loader path, a tool on `PATH`), `repro exec` applied it, and the actions of
## `repro test` did not -- they inherited the shell `repro` came from. Started
## inside the dev shell a suite passed; started from a plain shell, as CI
## starts it, the same suite failed with `could not load: libwebp.so.7` and
## `nim: command not found`.
##
## The fixture's `devEnv:` contributes the three kinds of op a captured flake
## shell produces: a `setEnv`, a `prependPath` onto `PATH`, and a
## `prependPath` onto a variable the invoking shell also sets. The run-edge
## runs a tool that exists ONLY in the dev environment's `PATH` entry, so it
## fails outright when the environment does not reach it.
##
## Claims:
##
##   1. a `test` member gets the environment, from a shell that has none of
##      it, with the composition rules `repro exec` uses;
##   2. an edge outside `test` / `bench` does not (the control: the same
##      command line, run under the same parent environment, cannot find the
##      tool -- so claim 1 is the mechanism and not the parent environment);
##   3. the contribution is part of the run-edge's key: an unchanged
##      environment re-runs nothing, a changed one re-runs the edge, although
##      nothing the edge itself reads changed.
##
## MOCKS: none. The real `repro` binary of this build runs a real recipe
## through the real provider compile, the real dev-env introspection edge and
## the real engine, with the io-mon shim the suite builds.

import std/[json, os, strtabs, strutils, tempfiles, times, unittest]

import repro_test_support
import repro_test_support/process_fixtures

const
  MarkFile = "dev-env-mark.txt"
  ProbeOutput = "build/run-edge.txt"
  ControlOutput = "build/control.txt"

proc probeScript(output: string): string =
  ## The same body for both edges: run the dev-env-only tool (or record that
  ## it is absent), then the two variables the contribution sets.
  "mkdir -p build && " &
    "{ if command -v fixture-devtool >/dev/null 2>&1; then fixture-devtool; " &
    "else echo tool=absent; fi; " &
    "printf 'mark=%s\\nlist=%s\\n' \"$FIXTURE_RUN_EDGE_MARK\" " &
    "\"$FIXTURE_RUN_EDGE_LIST\"; } > " & output

proc recipeText(devtoolsDir: string): string =
  "import std/strutils\n" &
    "import repro_project_dsl\n\n" &
    "package devEnvRunEdgeFixture:\n" &
    "  defaultToolProvisioning \"path\"\n" &
    "  devEnv:\n" &
    "    setEnv \"FIXTURE_RUN_EDGE_MARK\", readDevEnvFile(\"" & MarkFile &
      "\").strip()\n" &
    "    prependPath \"PATH\", \"" & devtoolsDir & "\"\n" &
    "    prependPath \"FIXTURE_RUN_EDGE_LIST\", \"devenv-entry\"\n" &
    "  build:\n" &
    "    let probe = buildAction(\"fixture.run_edge_probe\",\n" &
    "      inlineExecCall([\"/bin/sh\", \"-c\", " &
      escape(probeScript(ProbeOutput)) & "]),\n" &
    "      outputs = [\"" & ProbeOutput & "\"])\n" &
    "    let control = buildAction(\"fixture.control_probe\",\n" &
    "      inlineExecCall([\"/bin/sh\", \"-c\", " &
      escape(probeScript(ControlOutput)) & "]),\n" &
    "      outputs = [\"" & ControlOutput & "\"])\n" &
    "    discard collect(\"test\", [probe])\n" &
    "    discard collect(\"probes\", [control])\n"

type Fixture = object
  repoRoot: string
  reproBin: string
  shim: string
  root: string
  project: string
  workRoot: string

proc prepareFixture(): Fixture =
  result.repoRoot = getCurrentDir()
  result.reproBin = requireBinary(reproBinaryPath(result.repoRoot),
    "reprobuild.apps.repro")
  when isIoMonitorSupported:
    result.shim = prepareMonitorTools(result.repoRoot, "", "").shim
  result.root = expandFilename(createTempDir("repro-run-edge-dev-env", ""))
  releaseDirAtProcessExit(result.root)
  result.project = result.root / "project"
  result.workRoot = result.root / "work"
  let devtools = result.root / "devtools" / "bin"
  createDir(result.project)
  createDir(result.workRoot)
  createDir(devtools)
  let tool = devtools / "fixture-devtool"
  writeFile(tool, "#!/bin/sh\necho tool=present\n")
  setFilePermissions(tool, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})
  writeFile(result.project / MarkFile, "alpha\n")
  writeFile(result.project / "repro.nim", recipeText(devtools))

proc parentEnv(f: Fixture): StringTableRef =
  ## The environment `repro` is started from: this process's, with every
  ## name the fixture's dev environment contributes removed or reset, and
  ## nothing of `devtools/bin` on `PATH`. `FIXTURE_RUN_EDGE_LIST` is SET, so
  ## the prepend has an inherited value to compose onto.
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    if key.startsWith("FIXTURE_") or key.startsWith("REPRO_DEV_ENV"):
      continue
    result[key] = value
  result["FIXTURE_RUN_EDGE_LIST"] = "inherited-entry"
  result["REPROBUILD_SOURCE_ROOT"] = f.repoRoot
  if f.shim.len > 0:
    result["REPRO_MONITOR_SHIM_LIB"] = f.shim
  result.del("LD_PRELOAD")

proc runRepro(f: Fixture; args: openArray[string]): CmdSplitResult =
  var full = @args
  full.add(["--work-root=" & f.workRoot, "--tool-provisioning=path",
    "--no-runquota", "--progress=quiet", "--write-report"])
  result = runProgramSplit(f.reproBin, full, f.project, f.parentEnv())
  checkpoint("repro " & full.join(" ") & " -> exit " & $result.code)
  if result.code != 0:
    checkpoint(result.stdout & result.stderr)

proc reportAction(f: Fixture; id: string): JsonNode =
  ## The newest build report's entry for ``id``.
  var newest = ""
  var newestTime = 0.0
  for path in walkDirRec(f.workRoot):
    if path.endsWith("build-report.json"):
      let t = getLastModificationTime(path).toUnixFloat()
      if newest.len == 0 or t >= newestTime:
        newest = path
        newestTime = t
  if newest.len == 0:
    return newJNull()
  for entry in parseJson(readFile(newest)){"actions"}:
    if entry{"id"}.getStr() == id:
      return entry
  newJNull()

suite "repro test: run-edges get the package's dev environment":
  test "a test member gets it, an edge outside test does not, and it keys":
    let f = prepareFixture()
    check not f.parentEnv().getOrDefault("PATH").contains(
      f.root / "devtools")

    # Claim 1.
    let first = f.runRepro(["test", "--no-certify"])
    check first.code == 0
    let probe = readFile(f.project / ProbeOutput).splitLines()
    check "tool=present" in probe
    check "mark=alpha" in probe
    # `prependPath` composes onto the inherited value, as `repro exec` does.
    check "list=devenv-entry:inherited-entry" in probe

    # Claim 2: same parent environment, an edge that is not a run-edge.
    let control = f.runRepro(["build", ".#probes"])
    check control.code == 0
    let controlLines = readFile(f.project / ControlOutput).splitLines()
    check "tool=absent" in controlLines
    check "mark=" in controlLines
    check "list=inherited-entry" in controlLines

    # Claim 3, the stable half: nothing changed, nothing re-runs.
    let again = f.runRepro(["test", "--no-certify"])
    check again.code == 0
    let warm = f.reportAction("fixture.run_edge_probe")
    checkpoint("warm: " & $warm)
    check warm.kind == JObject
    check not warm{"launched"}.getBool(true)

    # Claim 3, the invalidating half. The mark file is read by the dev-env
    # body and by nothing the run-edge reads: only the contribution changed.
    writeFile(f.project / MarkFile, "beta\n")
    let changed = f.runRepro(["test", "--no-certify"])
    check changed.code == 0
    let rerun = f.reportAction("fixture.run_edge_probe")
    checkpoint("after the dev env changed: " & $rerun)
    check rerun{"launched"}.getBool(false)
    check "mark=beta" in readFile(f.project / ProbeOutput).splitLines()

## t_measurement_flags_cli — the measurement flags as the real ``repro``
## binary sees them.
##
## What this test owns
## -------------------
## The argv surface: which flags exist, which are gone, and what a build
## actually gathers, prints, and writes. Runs against the real binary with no
## mocks. Two layers:
##
##   * **Parse layer** (always runs). Every retired flag name must fail as an
##     unknown flag rather than being silently tolerated — a stale script or a
##     half-remembered flag must produce an error, never a build that measures
##     something other than what was asked for. The new flags must be
##     accepted, and bad category values rejected.
##
##   * **Build layer** (skips with a documented limitation when this host
##     cannot complete a build). Asserts the ABSENCE of the trace and evidence
##     artifacts under ``--measure=none`` — not merely that the flag parsed —
##     that presentation is independent of collection, that ``--write-report``
##     and ``--write-report=PATH`` land where they say, and that the
##     outcome-dependent persist default holds in both directions: a failing
##     build writes its failure report unasked, a succeeding one writes
##     nothing.
##
## See ``reprobuild-specs/CLI/README.md`` §"Measurement: Collect, Present,
## Persist" and ``reprobuild-specs/CLI/build.md`` §"Measurement Flags".

import std/[json, os, osproc, strutils, tempfiles, unittest]

const RepoMarker = "repro.nim"

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoMarker) and
        fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

let repoRoot = findRepoRoot()
let reproBin = getEnv("REPROBUILD_REPRO",
  repoRoot / "build" / "bin" / addFileExt("repro", ExeExt))

proc runRepro(args: openArray[string]; cwd = repoRoot):
    tuple[output: string; exitCode: int] =
  var argv = @[quoteShell(reproBin)]
  for arg in args:
    argv.add(quoteShell(arg))
  let res = execCmdEx(argv.join(" "), workingDir = cwd)
  (output: res.output, exitCode: res.exitCode)

proc hostCannotBuild(output: string): bool =
  ## Environmental limitations that stop a build before any action runs. The
  ## build-layer assertions are meaningless in that state, so they skip rather
  ## than pass vacuously.
  for needle in [
      "libclingo",
      "could not load:",
      "tool-resolution failed",
      "typed tool provisioning is required",
      "could not locate executable",
      "is not on PATH",
      "runquotad"]:
    if output.contains(needle):
      return true
  false

# ---------------------------------------------------------------------------
# Parse layer.
# ---------------------------------------------------------------------------

suite "measurement flags: retired names are gone":

  test "every retired build flag fails as an unknown flag":
    # Not accepted-with-a-warning: accepted-with-a-warning is how a stale
    # script keeps running while measuring the wrong thing.
    if not fileExists(reproBin):
      checkpoint("skipped — " & reproBin & " is missing; run `just build`")
      skip()
    else:
      for retired in [
          "--report=full", "--report=none", "--report",
          "--stats", "--stats=text", "--stats=none",
          "--stats-capture=timing", "--stats-db=/tmp/s.db",
          "--diagnostics=/tmp/d.txt", "--benchmark=/tmp/b.json"]:
        let res = runRepro(["build", "--dry-run", retired, "."])
        checkpoint(retired & " -> exit=" & $res.exitCode)
        check res.exitCode != 0
        check res.output.contains("unsupported build flag: " & retired)

  test "the retired workspace report flag fails as an unknown flag":
    if not fileExists(reproBin):
      skip()
    else:
      let res = runRepro(["workspace", "status", "--report"])
      check res.exitCode != 0
      check not res.output.contains("wrote report")

suite "measurement flags: the new surface parses":

  test "--measure, --show and the --write-* family are accepted":
    if not fileExists(reproBin):
      skip()
    else:
      for accepted in [
          @["--measure=none"], @["--measure=all"],
          @["--measure=trace", "--measure=timing"],
          @["--measure=none,timing"],
          @["--show=timing"], @["--show=all"], @["--show=none"],
          @["--write-report"], @["--no-write-report"],
          @["--write-diagnostics=" & (getTempDir() / "repro-measure-d.txt")],
          @["--write-benchmark=" & (getTempDir() / "repro-measure-b.json")]]:
        var args = @["build", "--dry-run", "--progress=quiet"]
        for a in accepted:
          args.add(a)
        args.add(".")
        let res = runRepro(args)
        checkpoint(accepted.join(" ") & " -> exit=" & $res.exitCode)
        # A parse rejection is the specific thing under test here; a build
        # that cannot complete on this host is not.
        check not res.output.contains("unsupported build flag")
        check not res.output.contains("unsupported --measure")
        check not res.output.contains("unsupported --show")

  test "an unknown measurement category is rejected, with the vocabulary":
    if not fileExists(reproBin):
      skip()
    else:
      for bad in ["--measure=bogus", "--show=bogus",
                  "--measure=full", "--show=text"]:
        let res = runRepro(["build", "--dry-run", bad, "."])
        checkpoint(bad & " -> exit=" & $res.exitCode)
        check res.exitCode != 0
        check res.output.contains("trace")
        check res.output.contains("cache-evidence")
        check res.output.contains("timing")

  test "--stats-groups keeps its own vocabulary and rejects strangers":
    if not fileExists(reproBin):
      skip()
    else:
      let res = runRepro(["build", "--dry-run", "--stats-groups=invalid", "."])
      check res.exitCode != 0
      check res.output.contains("unsupported --stats-groups=invalid")
      # A measurement category is NOT a store section, and vice versa: the
      # two vocabularies are deliberately separate.
      let crossed = runRepro(["build", "--dry-run",
        "--stats-groups=cache-evidence", "."])
      check crossed.exitCode != 0

# ---------------------------------------------------------------------------
# Build layer.
# ---------------------------------------------------------------------------

const
  OkProject = """
import repro_project_dsl

package measok:
  uses:
    "nim >=2.2 <3.0"

  executable measTool:
    build:
      discard nim.c(source = "src/measTool.nim", binary = "measTool")
"""

  BrokenProject = """
import repro_project_dsl

package measbad:
  uses:
    "nim >=2.2 <3.0"

  executable measBroken:
    build:
      discard nim.c(source = "src/measBroken.nim", binary = "measBroken")
"""

proc materializeProject(dir, recipe, sourceName, sourceBody: string) =
  createDir(dir / "src")
  writeFile(dir / "repro.nim", recipe)
  writeFile(dir / "src" / sourceName, sourceBody)

proc buildIn(dir: string; extra: openArray[string]):
    tuple[output: string; exitCode: int] =
  var args = @["build", "--tool-provisioning=path", "--daemon=off",
    "--no-runquota", "--progress=quiet"]
  for a in extra:
    args.add(a)
  args.add(dir)
  runRepro(args, cwd = dir)

proc outDirOf(dir: string): string =
  dir / ".repro" / "build" / "repro"

suite "measurement flags: collection, presentation and persistence":

  setup:
    let scratch = createTempDir("repro-measure-cli-", "")

  teardown:
    removeDir(scratch)

  test "--measure=none omits the trace and the cache evidence entirely":
    if not fileExists(reproBin):
      skip()
    else:
      let project = scratch / "ok"
      materializeProject(project, OkProject, "measTool.nim",
        "echo \"measurement fixture\"\n")

      let full = buildIn(project, ["--measure=all", "--write-report"])
      if full.exitCode != 0 and hostCannotBuild(full.output):
        checkpoint("skipped — this host cannot complete a build: " &
          full.output.strip()[0 .. min(200, full.output.strip().high)])
        skip()
      else:
        check full.exitCode == 0
        let reportPath = outDirOf(project) / "build-report.json"
        check fileExists(reportPath)
        let measured = parseJson(readFile(reportPath))
        # Collected: the scheduler trace and the timing metrics are present.
        check measured["trace"].len > 0
        check measured["stats"]["metrics"].len > 0

        # Now the same build with nothing measured. The report is still
        # written because PERSIST is a separate axis, but the measured
        # artefacts must be ABSENT from it.
        removeFile(reportPath)
        let bare = buildIn(project, ["--measure=none", "--write-report"])
        check bare.exitCode == 0
        check fileExists(reportPath)
        let unmeasured = parseJson(readFile(reportPath))
        check unmeasured["trace"].len == 0
        check unmeasured["stats"]["metrics"].len == 0
        # The build's own outcome is NOT optional measurement and survives.
        check unmeasured["actions"].len > 0
        for action in unmeasured["actions"]:
          check action["evidence"]["declaredInputs"].len == 0
          check action["evidence"]["monitorReads"].len == 0

  test "presentation is independent of collection":
    if not fileExists(reproBin):
      skip()
    else:
      let project = scratch / "show"
      materializeProject(project, OkProject, "measTool.nim",
        "echo \"measurement fixture\"\n")

      let collected = buildIn(project, ["--measure=all", "--no-write-report"])
      if collected.exitCode != 0 and hostCannotBuild(collected.output):
        checkpoint("skipped — this host cannot complete a build")
        skip()
      else:
        # Measuring everything prints nothing: the terminal is a separate axis.
        check collected.exitCode == 0
        check not collected.output.contains("metric ")
        check not collected.output.contains("scheduler trace")

        # Showing prints, and implies its own collection.
        let shown = buildIn(project, ["--show=timing", "--no-write-report"])
        check shown.exitCode == 0
        check shown.output.contains("metric")

        let tracing = buildIn(project, ["--show=trace", "--no-write-report"])
        check tracing.exitCode == 0
        check tracing.output.contains("scheduler trace")

  test "--write-report honours the conventional path and an exact path":
    if not fileExists(reproBin):
      skip()
    else:
      let project = scratch / "persist"
      materializeProject(project, OkProject, "measTool.nim",
        "echo \"measurement fixture\"\n")

      let conventional = buildIn(project, ["--write-report"])
      if conventional.exitCode != 0 and hostCannotBuild(conventional.output):
        checkpoint("skipped — this host cannot complete a build")
        skip()
      else:
        check conventional.exitCode == 0
        check fileExists(outDirOf(project) / "build-report.json")

        let exact = scratch / "elsewhere" / "r.json"
        let redirected = buildIn(project, ["--write-report=" & exact])
        check redirected.exitCode == 0
        check fileExists(exact)
        check parseJson(readFile(exact)).hasKey("actions")

  test "a successful build writes nothing without being asked":
    if not fileExists(reproBin):
      skip()
    else:
      let project = scratch / "silent"
      materializeProject(project, OkProject, "measTool.nim",
        "echo \"measurement fixture\"\n")
      let res = buildIn(project, [])
      if res.exitCode != 0 and hostCannotBuild(res.output):
        checkpoint("skipped — this host cannot complete a build")
        skip()
      else:
        check res.exitCode == 0
        check not fileExists(outDirOf(project) / "build-report.json")
        check not fileExists(outDirOf(project) / "build-failure-report.json")

  test "a FAILED build writes its failure report unasked":
    if not fileExists(reproBin):
      skip()
    else:
      let project = scratch / "broken"
      materializeProject(project, BrokenProject, "measBroken.nim",
        "let x: int = \"this does not compile\"\n")
      let res = buildIn(project, [])
      if res.exitCode == 0:
        checkpoint("unexpected success building a deliberately broken source")
        check res.exitCode != 0
      elif hostCannotBuild(res.output):
        checkpoint("skipped — this host cannot complete a build")
        skip()
      else:
        let failurePath = outDirOf(project) / "build-failure-report.json"
        check fileExists(failurePath)
        let node = parseJson(readFile(failurePath))
        check node["schemaId"].getStr == "reprobuild.build.failure-report.v1"
        check node["failedActions"].len > 0
        check node["counts"]["failed"].getInt > 0
        # The full document was NOT requested, so it must not appear.
        check not fileExists(outDirOf(project) / "build-report.json")

  test "--no-write-report suppresses the failure report too":
    if not fileExists(reproBin):
      skip()
    else:
      let project = scratch / "broken-quiet"
      materializeProject(project, BrokenProject, "measBroken.nim",
        "let x: int = \"this does not compile\"\n")
      let res = buildIn(project, ["--no-write-report"])
      if res.exitCode == 0:
        check res.exitCode != 0
      elif hostCannotBuild(res.output):
        checkpoint("skipped — this host cannot complete a build")
        skip()
      else:
        check not fileExists(outDirOf(project) / "build-failure-report.json")
        check not fileExists(outDirOf(project) / "build-report.json")

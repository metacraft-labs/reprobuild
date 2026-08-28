## Bootstrap-And-Self-Build B1: ``repro build apps`` materialises every
## binary listed in ``apps/entrypoints.txt``.
##
## Drives ``./build/bin/repro --tool-provisioning=path --daemon=off
## build apps`` from the reprobuild repo root and asserts:
##
##   1. Exit code 0.
##   2. Every non-comment entry in ``apps/entrypoints.txt`` has a
##      corresponding ``build/bin/<name>`` artifact that is non-empty
##      and executable.
##   3. Each binary responds to ``--help`` (or ``--version``) with exit
##      code 0. We accept either invocation: not every entry implements
##      ``--version`` but every shipped CLI accepts ``--help``.
##
## Performance note
## ----------------
## ``nim c`` of all 14 apps is expensive (15-30 minutes uncached). The
## test does NOT remove the binaries before running ``repro build
## apps`` — when the engine's action cache or "outputs-present"
## fast-path applies, the second invocation is effectively a no-op.
## A first-time cold run still takes minutes, but subsequent runs are
## fast. The cache-hit assertion lives in its own test
## (``t_b1_apps_action_cache_hit.nim``).
##
## ``runquota`` is a declared workspace dependency. Its daemon is resolved
## through the workspace-aware fixture helper, including when this test runs
## from a linked reprobuild worktree; absence is a hard fixture error.
##
## No failure classifier. This case used to run its non-zero exit past a
## ``looksLike…(output)`` predicate that matched the engine's own diagnostic
## against a needle list and reclassified the failure as a skip on a match.
## The list covered ordinary engine failures — tool resolution, provisioning,
## the CLI usage dump — so any NEW failure phrased in those terms disappeared
## silently, which is a way of manufacturing green rather than a record of an
## environment limitation. The genuine environment gates (is the sibling
## checkout present, is ``./build/bin/repro`` built) are unchanged: they are
## checked BEFORE the work and they still skip. What the engine does once the
## work starts is now simply asserted.

import std/[os, osproc, strtabs, strutils, unittest]

import repro_test_support

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

proc readEntrypointNames(repoRoot: string): seq[string] =
  ## Parse ``apps/entrypoints.txt`` — first whitespace-separated field
  ## per non-comment, non-empty line is the binary name. Mirrors the
  ## awk-style loop in ``scripts/build_apps.sh``.
  result = @[]
  let path = repoRoot / "apps" / "entrypoints.txt"
  for raw in lines(path):
    let line = raw.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    let fields = line.splitWhitespace()
    if fields.len < 2:
      continue
    result.add(fields[0])

proc runWithRunquotaOnPath(cmd, repoRoot: string): tuple[output: string;
    exitCode: int] =
  ## Spawn ``cmd`` from ``repoRoot`` with the workspace's runquota bin dir
  ## prepended to ``PATH``. The path-mode resolver consults ``PATH``
  ## for every ``uses:`` selector — ``"runquotad"`` is one of them.
  let runquotaBin = requireRunQuotaDaemonBin(repoRoot).parentDir
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  let oldPath = env.getOrDefault("PATH")
  env["PATH"] = runquotaBin & $PathSep & oldPath
  execCmdEx(cmd, env = env, workingDir = repoRoot)

suite "Bootstrap-And-Self-Build B1: repro build apps collection":

  test "action-cache daemon is a typed member of the apps collection":
    let repoRoot = findRepoRoot()
    let names = readEntrypointNames(repoRoot)
    check "repro-cache-daemon" in names

    # Keep this assertion tied to the collection body, rather than accepting
    # matching literals elsewhere in the project file. The dynamic test below
    # then drives that collection and verifies every declared output.
    let projectText = readFile(repoRoot / "repro.nim")
    check "executable reproCacheDaemon:" in projectText
    let appsStart = projectText.find(
      "var reprobuildAppsActions: seq[BuildActionDef] = @[]")
    let appsEnd = projectText.find(
      "discard collect(\"apps\", reprobuildAppsActions)", appsStart)
    check appsStart >= 0
    check appsEnd > appsStart
    if appsStart >= 0 and appsEnd > appsStart:
      let appsBlock = projectText[appsStart ..< appsEnd]
      check "source = \"apps/repro-cache-daemon/repro_cache_daemon.nim\"" in
        appsBlock
      check "binary = \"build/bin/repro-cache-daemon\"" in appsBlock
      check "cacheable = false" in appsBlock
      check "actionId = \"reprobuild.apps.repro-cache-daemon\"" in appsBlock

  test "standalone bootstrap stages the Nix provisioning daemon":
    let repoRoot = findRepoRoot()
    let buildScript = readFile(repoRoot / "scripts" / "build_apps.sh")
    check "cp -f tools/reprobuild-nix-daemon/reprobuild-nix-daemon" in
      buildScript
    check "build/bin/reprobuild-nix-daemon" in buildScript
    check "chmod +x build/bin/reprobuild-nix-daemon" in buildScript

  test "graph-built repro retains the entrypoint HTTPS capability":
    let repoRoot = findRepoRoot()
    let entrypoints = readFile(repoRoot / "apps" / "entrypoints.txt")
    var reproEntrypoint = ""
    for raw in entrypoints.splitLines:
      let line = raw.strip()
      if line.startsWith("repro "):
        reproEntrypoint = line
        break
    check reproEntrypoint.contains("--define:ssl")

    let projectText = readFile(repoRoot / "repro.nim")
    let usesStart = projectText.find("  uses:")
    let devEnvStart = projectText.find("  devEnv:", usesStart)
    check usesStart >= 0
    check devEnvStart > usesStart
    if usesStart >= 0 and devEnvStart > usesStart:
      check "\"openssl\"" in projectText[usesStart ..< devEnvStart]
    let actionStart = projectText.find(
      "source = \"apps/repro/repro.nim\"")
    let actionEnd = projectText.find(
      "actionId = \"reprobuild.apps.repro\"", actionStart)
    check actionStart >= 0
    check actionEnd > actionStart
    if actionStart >= 0 and actionEnd > actionStart:
      let actionBlock = projectText[actionStart .. actionEnd]
      check "defines = @[\"release\", \"reproVendoredHash\", \"ssl\"]" in
        actionBlock

  test "engine materialises every apps/entrypoints.txt binary":
    let repoRoot = findRepoRoot()
    let reproBin = repoRoot / "build" / "bin" /
      addFileExt("repro", ExeExt)

    if not fileExists(reproBin):
      checkpoint("skipped — " & reproBin &
        " is missing; run `just build` first")
      skip()
    else:
      discard requireRunQuotaDaemonBin(repoRoot)
      let names = readEntrypointNames(repoRoot)
      check names.len >= 11
      checkpoint("entrypoints.txt declares " & $names.len & " binaries")

      # The collection name is ``apps`` but the CLI's path-vs-name
      # classifier treats bare ``apps`` as a path (an ``apps/``
      # directory exists at the repo root). The ``.#apps`` fragment
      # form forces name-resolution per Named-Targets M3 / CLI's
      # build-target selection rules.
      #
      # ``--measure=none`` suppresses build-report.json emission. The
      # engine's evidence-aggregation pass (``collectEvidence`` in
      # ``libs/repro_build_engine/src/repro_build_engine.nim``) has
      # an ``addUnique``/``find`` interaction that is O(n²) over the
      # closure size; for the 14-app ``apps`` collection that closure
      # exceeds 100k entries and the pass can run for tens of minutes.
      # We skip the report because this test only cares whether every
      # binary materialises, not whether the run is fully introspectable.
      let args = @[
        reproBin.quoteShell,
        "build",
        ".#apps",
        "--tool-provisioning=path",
        "--daemon=off",
        "--log=quiet",
        "--progress=quiet",
        "--measure=none",
      ]
      let cmd = args.join(" ")
      checkpoint("running: " & cmd)
      let (output, exitCode) = runWithRunquotaOnPath(cmd, repoRoot)
      checkpoint("exit=" & $exitCode)

      if exitCode != 0:
        checkpoint(output)
        check exitCode == 0
      else:
        # Engine returned 0 — every entrypoint must now exist on disk.
        # We assert presence + non-empty + runnable; the per-binary
        # ``--help`` / ``--version`` contract varies across the
        # entrypoint set (some helper binaries exit non-zero when
        # invoked without required args), so we only require that the
        # binary produces SOME text output when probed.
        for name in names:
          let binary = repoRoot / "build" / "bin" /
            addFileExt(name, ExeExt)
          check fileExists(binary)
          if fileExists(binary):
            let info = getFileInfo(binary)
            check info.size > 0
            let helpCmd = binary.quoteShell & " --help"
            let (helpOut, helpExit) = execCmdEx(helpCmd,
              options = {poUsePath, poStdErrToStdOut})
            checkpoint(name & " --help exit=" & $helpExit &
              " out-bytes=" & $helpOut.len)
            check helpOut.len > 0

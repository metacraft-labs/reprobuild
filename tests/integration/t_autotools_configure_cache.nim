import std/[json, os, strutils, tempfiles, unittest]
import repro_test_support

const RepoRoot = currentSourcePath().parentDir.parentDir.parentDir
const Recipe = """
import repro_project_dsl
import repro_dsl_stdlib/constructors

package cacheProbe:
  nativeBuildDeps:
    "sh"
    "make"
    "gcc"
    "cat"
    "mkdir"
    "rm"
  build:
    discard autotools_package(srcDir = "src", configureOptions = @["first"])
"""

# A real configure/make pipeline: make reads the generated include while
# configuring, then replaces it with compiler-generated dependencies.
const Configure = """#!/bin/sh
set -eu
mkdir -p .deps
printf '# empty dependency file\n' > .deps/probe.Po
printf 'configured %s\n' "$*" > configured.txt
cat ../src/settings.txt >> configured.txt
cat > Makefile <<'MAKEFILE'
.PHONY: all
include .deps/probe.Po
all: probe
probe: ../src/probe.c
	$(CC) -MMD -MF .deps/probe.Po -o $@ $<
MAKEFILE
make -s -n all > /dev/null
"""

proc configureAction(report: JsonNode): JsonNode =
  for item in report["actions"]:
    if item["id"].getStr.startsWith("exec-"):
      return item
  raise newException(ValueError, "missing configure action")

when not defined(windows):
  suite "Autotools discarded build-tree inputs":
    test "warm configure reuse retains source, option and missing-output invalidation":
      let repro = requireBinary(getEnv("REPRO_BIN",
        RepoRoot / "build" / "bin" / "repro"), "reprobuild.apps.repro")
      let root = createTempDir("repro-autotools-configure-cache-", "")
      defer: removeDir(root)
      let project = root / "project"
      createDir(project / "src")
      createDir(root / "reports")
      writeFile(project / "repro.nim", Recipe)
      writeFile(project / "src" / "configure", Configure)
      setFilePermissions(project / "src" / "configure",
        {fpUserRead, fpUserWrite, fpUserExec})
      writeFile(project / "src" / "settings.txt", "source-one\n")
      writeFile(project / "src" / "probe.c", "int main(void) { return 0; }\n")

      proc build(label: string): JsonNode =
        let reportPath = root / "reports" / (label & ".json")
        let response = runShell(shellCommand(@[
          repro, "build", ".#autotools-make-build-cacheProbe-build",
          "--daemon=off", "--tool-provisioning=path",
          "--write-report=" & reportPath], @[
          ("REPROBUILD_WORK_ROOT", root / "work"),
          ("REPROBUILD_ACTION_CACHE_ROOT", root / "action-cache"),
          ("REPROBUILD_STORE_ROOT", root / "store"),
          ("REPRO_STORE_ROOT", root / "store"),
          ("REPRO_LOCAL_STORE", root / "store"),
          ("REPRO_DAEMON_ENDPOINT", root / "daemon.sock"),
          ("REPRO_DAEMON_STATE_DIR", root / "daemon-state"),
          ("REPRO_LOCK_PATH", project / "repro.lock")]), project)
        checkpoint label & ": " & response.output
        require response.code == 0
        result = parseFile(reportPath)
        require result["actions"].len == 2
        var launched = false
        for item in result["actions"]:
          check item["status"].getStr in ["asSucceeded", "asUpToDate"]
          check item["exitCode"].getInt == 0
          launched = launched or item["launched"].getBool
        if launched:
          # Action children inherit the outer test's lease. A fully cached
          # run launches no processes, so it has no bypassed launch to report.
          let nested = getEnv("REPROBUILD_NO_RUNQUOTA").normalize in
            ["1", "true", "yes", "on"]
          check result["runQuota"]["bypassed"].getBool == nested
          check result["runQuota"]["authority"].getStr ==
            (if nested: "local-engine-pool-gate-only" else: "runquota")
        check fileExists(project / "build" / "probe")
        check readFile(project / "build" / ".deps" / "probe.Po").contains("probe.c")

      let cold = build("cold").configureAction()
      check cold["launched"].getBool
      check readFile(project / "build" / "configured.txt").contains("source-one")

      let warm = build("warm").configureAction()
      check not warm["launched"].getBool
      check warm["cacheDecision"].getStr in ["cdHit", "cdHybridCutoff"]

      removeFile(project / "build" / "Makefile")
      let missingMakefile = build("missing-makefile").configureAction()
      check missingMakefile["launched"].getBool
      check fileExists(project / "build" / "Makefile")

      writeFile(project / "build" / "Makefile", "broken make syntax\n")
      let corruptMakefile = build("corrupt-makefile").configureAction()
      check corruptMakefile["launched"].getBool
      check readFile(project / "build" / "Makefile").contains("include .deps/probe.Po")

      writeFile(project / "src" / "settings.txt", "source-two-longer\n")
      let sourceChanged = build("source-changed").configureAction()
      check sourceChanged["launched"].getBool
      check readFile(project / "build" / "configured.txt").contains("source-two-longer")

      writeFile(project / "repro.nim", Recipe.replace("first", "second"))
      let optionsChanged = build("options-changed").configureAction()
      check optionsChanged["launched"].getBool
      check readFile(project / "build" / "configured.txt").contains("second")

      writeFile(project / "src" / "configure", Configure.replace("Makefile", "GNUmakefile"))
      writeFile(project / "repro.nim", Recipe.replace("first", "second").replace(
        "configureOptions = @[\"second\"]",
        "configureOptions = @[\"second\"], configureOutputFiles = @[\"GNUmakefile\"]"))
      let customMakefile = build("custom-makefile").configureAction()
      check customMakefile["launched"].getBool
      check fileExists(project / "build" / "GNUmakefile")
      check not fileExists(project / "build" / "Makefile")

      removeFile(project / "build" / "GNUmakefile")
      let missingCustomMakefile = build("missing-custom-makefile").configureAction()
      check missingCustomMakefile["launched"].getBool
      check fileExists(project / "build" / "GNUmakefile")

      removeDir(project / "build")
      let missingOutput = build("missing-output").configureAction()
      check missingOutput["launched"].getBool
      check readFile(project / "build" / "configured.txt").contains("second")

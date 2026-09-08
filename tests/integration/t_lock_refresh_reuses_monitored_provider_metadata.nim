## Named-Lock-Files section 5.6 and Reprobuild-Monitored-Cache:
## compile reuse must retain transitive evidence, not cache a previous solve.

import std/[os, sequtils, strutils, tempfiles, unittest]
import repro_test_support

const RepoRoot = currentSourcePath().parentDir.parentDir.parentDir
const Recipe = """
import repro_project_dsl
import constraints

defineCliInterface forbiddenTool, "lock-target-must-not-run":
  call:
    flag output is string, role = output, required = true
    outputs output

package target:
  uses:
    "lock-target-must-not-run >=1.0 <2.0"
  build:
    forbiddenTool(output = "build/target.txt")
"""

const Constraints = """
import std/os
import repro_project_dsl

package app:
  uses:
    "nim >=2.4.0 <3.0.0"

when defined(reproProviderMode):
  let witness = open(getEnv("LOCK_METADATA_PROBE_LOG"), fmAppend)
  witness.writeLine("provider-init")
  witness.close()
"""

proc executable(path, body: string) =
  writeFile(path, body)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})

proc linesAt(path: string): seq[string] =
  if fileExists(path):
    for line in readFile(path).splitLines():
      if line.len > 0:
        result.add(line)

when not defined(windows):
  suite "lock refresh monitored metadata cache":
    test "warm compiles, transitive invalidation, and fresh unpinned solves":
      let repro = requireBinary(getEnv("REPRO_BIN",
        RepoRoot / "build" / "bin" / "repro"), "reprobuild.apps.repro")
      let nim = requireBinary(findExe("nim"), "Nim bootstrap compiler")
      let root = createTempDir("lock-provider-cache-", "")
      defer: removeDir(root)
      let project = root / "project"
      let binDir = root / "bin"
      let cache = root / "user-cache"
      createDir(project)
      createDir(binDir)
      writeFile(project / "repro.nim", Recipe)
      writeFile(project / "constraints.nim", Constraints)
      let compileLog = root / "compiler-launches"
      let probeLog = root / "provider-launches"
      let targetLog = root / "target-tool-used"
      let compiler = binDir / "witness-nim"
      executable(compiler, "#!/bin/sh\n" &
        "case \"$*\" in\n" &
        "  *--define:reproInterfaceMode*) printf 'interface\\n' >> " &
          quoteShell(compileLog) & " ;;\n" &
        "  *--define:reproProviderMode*) printf 'provider\\n' >> " &
          quoteShell(compileLog) & " ;;\n" &
        "esac\nexec " & quoteShell(nim) & " \"$@\"\n")
      executable(binDir / "lock-target-must-not-run", "#!/bin/sh\n" &
        "printf 'called\\n' >> " & quoteShell(targetLog) & "\nexit 99\n")
      # Start with a committed lock, as an authoritative refresh does. Creating
      # a new directory entry after compilation legitimately invalidates the
      # compiler's observed project-directory dependency.
      let oldInputs = root / "old-solver-inputs"
      writeFile(oldInputs, "package app\nversions: 0.1.0\n" &
        "depends: nim >=2.2.0 <3.0.0\n\npackage nim\nversions: 2.2.0\n")
      let seeded = runShell(shellCommand(@[repro, "lock", "refresh", project,
        "--inputs", oldInputs], @[
        ("REPROBUILD_ACTION_CACHE_ROOT", cache),
        ("REPROBUILD_STORE_ROOT", root / "store"),
        ("REPRO_STORE_ROOT", root / "store")]), project)
      checkpoint seeded.output
      require seeded.code == 0
      require readFile(project / "repro.lock").contains("version = \"2.2.0\"")
      proc refresh(): string =
        let response = runShell(shellCommand(@[repro, "lock", "refresh",
          project], @[
          ("PATH", binDir & $PathSep & getEnv("PATH")),
          ("REPRO_NIM_COMPILER", compiler),
          ("REPROBUILD_ACTION_CACHE_ROOT", cache),
          ("REPROBUILD_STORE_ROOT", root / "store"),
          ("REPRO_STORE_ROOT", root / "store"),
          ("REPRO_DAEMON", "off"),
          ("REPRO_TOOL_PROVISIONING", "path"),
          ("REPRO_LOCK_PINS", "pkg:nim=2.2.0"),
          ("REPRO_LOCK_PATH", project / "repro.lock"),
          ("LOCK_METADATA_PROBE_LOG", probeLog)]), project)
        checkpoint response.output
        require response.code == 0
        check not fileExists(targetLog)
        check not dirExists(project / "build")
        check not dirExists(project / ".repro")
        readFile(project / "repro.lock")

      let coldLock = refresh()
      check coldLock.contains("version = \"2.4.0\"")
      check not coldLock.contains("version = \"2.2.0\"")
      let cold = linesAt(compileLog)
      check "interface" in cold
      check "provider" in cold
      let coldProbes = linesAt(probeLog).len
      check coldProbes > 0
      check dirExists(cache / "lock-provider-metadata")

      # Poison the previous output too: a warm refresh must emit/solve again.
      writeFile(project / "repro.lock", coldLock.replace("2.4.0", "2.2.0"))
      let warmLock = refresh()
      check warmLock == coldLock
      check linesAt(compileLog) == cold
      check linesAt(probeLog).len > coldProbes

      # Only an imported source changes; the recipe and compiler stay fixed.
      writeFile(project / "constraints.nim",
        Constraints.replace("2.4.0", "2.5.0"))
      let changedLock = refresh()
      check changedLock.contains("version = \"2.5.0\"")
      check not changedLock.contains("version = \"2.2.0\"")
      let changed = linesAt(compileLog)
      check changed.count("interface") > cold.count("interface")
      check changed.count("provider") > cold.count("provider")

## The add-on's static entry point type-checks for every architecture the
## release builds it for (`scripts/build_addon_static.sh`: amd64, arm64 and
## armhf), not only for the host's.
##
## Why: the add-on binary is compiled for a 32-bit target (armhf, Nim
## `--cpu:arm`), where `int` is 32 bits. Code that is correct on a 64-bit
## host can be a COMPILE error there -- the v0.2.27 release's "Static add-on
## binaries" job failed on
## `broker.nim(855, 36) Error: cannot convert 4294967295 to int`
## (`int(high(uint32))` in `parseBrokerModeArgs`, reprobuild-pm issue
## `2026-11-18-the-armhf-add-on-does-not-compile-int-of-high-uint32-in-the-broker-argument-parser.md`).
## Nothing below the release ran the 32-bit compile, so the defect was found
## by the release, after it was tagged.
##
## What this runs: the real Nim compiler's `nim check` of
## `apps/repro-addon/repro_addon_main.nim` under the repository's own
## `config.nims`, with `--os:linux --cpu:<arch> --define:release` as the
## release build passes them. `nim check` stops after semantic analysis, so
## it needs no cross C toolchain and catches exactly the class of defect
## above (constant conversions, `when sizeof(int)` branches, target-only
## symbols). It does not prove the C compile or the static link, which the
## release's own job still does.
##
## MOCK POLICY: nothing is mocked; the subject is the compiler's verdict.

from repro_core/process_streams import drainStream
import std/[os, osproc, streams, strutils, unittest]

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / "repro.nim") and fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate the reprobuild repository root from " &
    currentSourcePath())

const ReleaseArchitectures = [
  # (Debian architecture, Nim --cpu), as scripts/build_addon_static.sh maps
  # them (`nim_cpu`).
  ("amd64", "amd64"),
  ("arm64", "arm64"),
  ("armhf", "arm"),
]

suite "the add-on entry point type-checks for every release architecture":

  test "nim check --os:linux --cpu:<arch> of apps/repro-addon succeeds":
    let root = findRepoRoot()
    let nim = findExe("nim")
    if nim.len == 0:
      # Never a silent pass: without the compiler this test says nothing.
      checkpoint("nim is not on PATH; run inside the reprobuild dev shell")
      fail()
    else:
      let scratch = getTempDir() / ("repro-addon-arch-check-" &
        $getCurrentProcessId())
      createDir(scratch)
      defer: removeDir(scratch)
      # The three checks are independent; run them side by side.
      var running: seq[(string, Process)] = @[]
      for (arch, cpu) in ReleaseArchitectures:
        let process = startProcess(nim, workingDir = root, args = [
          "check", "--hints:off", "--warnings:off",
          "--os:linux", "--cpu:" & cpu, "--define:release",
          "--nimcache:" & scratch / ("nimcache-" & arch),
          "apps/repro-addon/repro_addon_main.nim"],
          options = {poStdErrToStdOut})
        running.add((arch, process))
      for (arch, process) in running:
        let output = drainStream(process.outputStream)
        let exitCode = process.waitForExit()
        process.close()
        if exitCode != 0:
          var errors: seq[string] = @[]
          for line in output.splitLines():
            if "Error:" in line:
              errors.add(line)
              if errors.len >= 10:
                break
          checkpoint(arch & ": nim check exited " & $exitCode & "\n" &
            errors.join("\n"))
        check exitCode == 0

## Exercise the built public CLI and real POSIX signals, without mocks.
## The Python driver owns and cleans a private process group for every case,
## including the orphan that the regression deliberately creates before fixing.
import std/[os, osproc, tempfiles, unittest]
import repro_test_support

# Embed the driver so its bytes participate in the test binary's build input
# identity; a changed Python probe cannot reuse a previously cached test pass.
const ProbeSource = staticRead("repro_exec_signal_probe.py")

suite "repro exec POSIX command lifetime":
  when defined(posix):
    test "replacement preserves argv environment cwd status and four signals":
      let cli = requireBinary(getCurrentDir() / "build/bin/repro",
        "reprobuild.apps.repro")
      let root = createTempDir("repro-exec-signal-driver-", "")
      defer: removeDir(root)
      let driver = root / "probe.py"
      writeFile(driver, ProbeSource)
      let run = execCmdEx(quoteShell(findExe("python3")) & " " &
        quoteShell(driver) & " " & quoteShell(cli))
      checkpoint(run.output)
      check run.exitCode == 0

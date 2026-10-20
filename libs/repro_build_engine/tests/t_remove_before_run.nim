## `BuildAction.removeBeforeRun` — declared outputs the engine removes before
## the action runs.
##
## Some tools refuse to write over an existing output: create-dmg's final
## `hdiutil convert -o <dmg>` fails `File exists`, so a `create_dmg` edge
## re-run after any input change failed BECAUSE the previous run had
## succeeded (seen building CodeTracer's macOS dmg). An action whose tool
## behaves like that declares those outputs, and the engine removes them
## before launch -- without following a link, and never a path the action
## does not declare as its output.
##
## The cases run real process actions (`sh`) through `runBuild` against a
## real temporary tree. The stand-in for `hdiutil` is the shell's own
## `set -C` (noclobber), a real command that refuses to overwrite an existing
## file the same way; nothing is mocked. The directory-link case uses a
## directory junction on Windows, which needs no privilege, so the Windows
## branch of the no-follow removal is exercised there too.

import std/[os, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

import repro_build_engine
import repro_hash

const NoShell = "no `sh` on PATH; the action under test is a shell script"

proc refusingWriter(sh, root, output: string): BuildAction =
  ## Writes `output` with noclobber set: it FAILS when the file exists.
  result = action("tool/refusing-writer",
    [sh, "-c", "set -C; echo built > " & output],
    cwd = root,
    outputs = [output],
    cacheable = false,
    weakFingerprint = weakFingerprintFromText("remove-before-run.writer"),
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

proc run(root: string; a: BuildAction): ActionResult =
  var config = defaultBuildEngineConfig(root / "cache")
  config.bypassRunQuota = true
  config.maxParallelism = 1'u32
  let res = runBuild(graph([a]), config)
  require res.results.len == 1
  result = res.results[0]
  checkpoint("status=" & $result.status & " stderr=" & result.stderr)

suite "outputs removed before the action runs":

  test "a tool that refuses to overwrite its output re-runs over it":
    let sh = findExe("sh")
    if sh.len == 0:
      skip(NoShell)
    else:
      let root = createTempDir("repro-remove-before-run-", "")
      defer: removeDir(root)
      createDir(root / "out")
      var a = refusingWriter(sh, root, "out/result.txt")
      # The control: without the declaration the second run fails over the
      # first run's output. That is the tool's behaviour this exists for,
      # and it shows the command really does refuse.
      check run(root, a).status == asSucceeded
      check run(root, a).status == asFailed
      a.removeBeforeRun = @["out/result.txt"]
      for attempt in 1 .. 2:
        check run(root, a).status == asSucceeded
        check readFile(root / "out" / "result.txt").strip() == "built"

  test "an output that is a symlink is removed, not followed":
    let sh = findExe("sh")
    if sh.len == 0:
      skip(NoShell)
    elif defined(windows):
      skip("creating a symlink on Windows needs a privilege the suite " &
        "does not assume")
    else:
      let root = createTempDir("repro-remove-before-run-link-", "")
      let outside = createTempDir("repro-remove-before-run-outside-", "")
      defer:
        removeDir(outside)
        removeDir(root)
      createDir(root / "out")
      writeFile(outside / "victim.txt", "outside, must not change\n")
      createSymlink(outside / "victim.txt", root / "out" / "result.txt")
      var a = refusingWriter(sh, root, "out/result.txt")
      a.removeBeforeRun = @["out/result.txt"]
      check run(root, a).status == asSucceeded
      check not symlinkExists(root / "out" / "result.txt")
      check readFile(root / "out" / "result.txt").strip() == "built"
      check readFile(outside / "victim.txt") == "outside, must not change\n"

  test "a directory output is removed without following links inside it":
    let root = createTempDir("repro-remove-before-run-dir-", "")
    let outside = createTempDir("repro-remove-before-run-outside-", "")
    defer:
      removeDir(outside)
      removeDir(root)
    writeFile(outside / "keep.txt", "outside\n")
    createDir(root / "out" / "bundle" / "sub")
    writeFile(root / "out" / "bundle" / "sub" / "old.txt", "old\n")
    let link = root / "out" / "bundle" / "linked"
    when defined(windows):
      require execShellCmd("cmd /c mklink /J \"" & link & "\" \"" &
        outside & "\" > NUL") == 0
    else:
      createSymlink(outside, link)
    var a = action("tool/dir", ["tool"], cwd = root,
      outputs = ["out/bundle"],
      weakFingerprint = weakFingerprintFromText("remove-before-run.dir"),
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    a.removeBeforeRun = @["out/bundle"]
    check removeOutputsBeforeRun(a) == ""
    check not dirExists(root / "out" / "bundle")
    check not symlinkExists(root / "out" / "bundle")
    check readFile(outside / "keep.txt") == "outside\n"

  test "an output that is a directory link is unlinked, its target kept":
    let root = createTempDir("repro-remove-before-run-dirlink-", "")
    let outside = createTempDir("repro-remove-before-run-outside-", "")
    defer:
      removeDir(outside)
      removeDir(root)
    writeFile(outside / "keep.txt", "outside\n")
    createDir(root / "out")
    let link = root / "out" / "bundle"
    when defined(windows):
      require execShellCmd("cmd /c mklink /J \"" & link & "\" \"" &
        outside & "\" > NUL") == 0
    else:
      createSymlink(outside, link)
    require symlinkExists(link)
    var a = action("tool/dirlink", ["tool"], cwd = root,
      outputs = ["out/bundle"],
      weakFingerprint = weakFingerprintFromText("remove-before-run.dirlink"),
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    a.removeBeforeRun = @["out/bundle"]
    check removeOutputsBeforeRun(a) == ""
    check not symlinkExists(link)
    check not dirExists(link)
    check readFile(outside / "keep.txt") == "outside\n"

  test "a path that is not one of the action's outputs is refused":
    let sh = findExe("sh")
    if sh.len == 0:
      skip(NoShell)
    else:
      let root = createTempDir("repro-remove-before-run-refused-", "")
      defer: removeDir(root)
      createDir(root / "src")
      createDir(root / "out")
      writeFile(root / "src" / "input.txt", "source\n")
      var a = refusingWriter(sh, root, "out/result.txt")
      a.inputs = @["src/input.txt"]
      a.removeBeforeRun = @["src/input.txt"]
      check "not a declared output" in removeBeforeRunProblem(a)
      let res = run(root, a)
      check res.status == asFailed
      check "not a declared output" in res.stderr
      check readFile(root / "src" / "input.txt") == "source\n"
      # A declared output's PARENT is not the output either.
      a.removeBeforeRun = @["out"]
      check "not a declared output" in removeBeforeRunProblem(a)
      # declaredOutputs count as the action's own.
      a.declaredOutputs = @["out/extra"]
      a.removeBeforeRun = @["out/extra", "out/result.txt"]
      check removeBeforeRunProblem(a) == ""

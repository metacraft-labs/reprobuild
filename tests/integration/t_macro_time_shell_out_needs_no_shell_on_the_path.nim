## A macro that shells out AT COMPILE TIME must work on an action `PATH` that
## contains no shell — because that is the only `PATH` a Nim compile edge has.
##
## ## The defect this exists to catch
##
## `Compose an action's PATH from what the edge declares, not from the host`
## removed the host tail from every action's runtime `PATH`. A Nim compile
## edge declares `nim` (its own tool) and `gcc` (the C backend, declared at
## `nim.c` and at `buildNimUnittest.build`'s call site in `repro.nim`), so its
## `PATH` is exactly `<nim>/bin:<gcc-wrapper>/bin`. MEASURED on this
## repository's `.#test` graph with `repro graph --view=actions
## --format=json`: 2803 actions, of which 1400 are Nim compiles, and ALL 1400
## carry a `PATH` on which `sh` does not resolve (1399 carry that exact
## two-directory value).
##
## The DSL's resource-accessor generator shelled out with a BARE `sh`:
##
##     "sh -c " & quoteShell("cd " & quoteShell(root) & " && exec " & nimCmd)
##
## and stopped working:
##
##     action: nim-c-38207e51df9ca624 status=asFailed
##     macros_a.nim(3778, 18) Error: resource accessor generation failed for
##     'prodres5a': expected an IFP frame, got:
##     /bin/sh: line 1: sh: command not found
##
## The OUTER `/bin/sh` in that message is `staticExec`'s own — on POSIX it
## starts its argument with `poEvalCommand`, i.e. `execv("/bin/sh", ["sh",
## "-c", cmd])`. The INNER bare `sh` is the one that was missing. So the
## deficient thing was the action `PATH`, and the wrapper it could not satisfy
## was buying nothing: `staticExec` had already supplied a shell.
##
## ## Why the gate is shaped like this and not like the failure
##
## The failure was observed on exactly one in-repo source
## (`t_rp5a_consumer_imports_resource_contract_no_driver.nim`, the only test
## whose own `package … uses:` names a `resourceType` producer at macro time).
## Pinning that source would pin an instance, not the rule.
##
## The RULE is `compileTimeShellCommand` — the one place that decides how a
## compile-time shell-out is spelled. No copy of that composition lives in
## this file; both live cases import the real proc.
##
## ## Why the assertion is on the OUTPUT and not on the exit code
##
## `staticExec` SWALLOWS a non-zero exit and returns the failing shell's
## stderr as if it were the program's output. A compile whose shell-out failed
## therefore still SUCCEEDS. `macros_a` only turned it into an error because
## it went on to demand an `IFP:` frame; `repro.nim`'s two uses of the same
## shape do not, and would have silently adopted the string
## `/bin/sh: line 1: sh: command not found` as a `--path:` directory. An
## exit-code check here would be vacuous. The sentinel must be seen.
##
## ## Anti-vacuity
##
## Case 1 asserts the synthesised `PATH` really has no shell on it. If a
## future toolchain put one in the gcc wrapper's directory, cases 2 and 3
## would pass no matter what `compileTimeShellCommand` returned and this file
## would silently stop testing anything. It fails instead.
##
## Note `exec` forces a `PATH` lookup even for names that are shell builtins
## (`/bin/sh -c 'exec printf x'` on an empty `PATH` is
## `exec: printf: not found`), so the probe commands below are absolute paths
## to real programs. That is also why the composition can prepend `exec` at
## all: its one production caller passes an absolute compiler path.
##
## ## NO MOCKS
##
## No mocks are used in this file and none may be added. The subject is the
## real exported proc; case 2 runs its output through the same
## `/bin/sh -c`-with-`poEvalCommand` mechanism `staticExec` itself uses, and
## case 3 runs it from inside a real `nim c` under a real restricted `PATH`.

import std/[os, osproc, strtabs, strutils, tempfiles, unittest]

import repro_project_dsl/compile_time_shell

const RepoMarker = "repro.nim"

const Sentinel = "MACRO-SHELL-OUT-RAN"

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoMarker) and fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

proc requireExe(tool: string): string =
  result = findExe(tool)
  if result.len == 0:
    raise newException(OSError,
      "no `" & tool & "` on PATH; a Nim compile edge declares it, so a host " &
      "without it cannot host this gate")

proc compileEdgePathDirs(): seq[string] =
  ## The directories a Nim compile edge's `PATH` is composed of: the one the
  ## graph resolved `nim` into and the one it resolved `gcc` into. Read off
  ## `findExe` rather than hard-coded, so this tracks whatever toolchain the
  ## dev shell or the CI runner actually supplies.
  result = @[]
  for tool in ["nim", "gcc"]:
    let dir = requireExe(tool).parentDir
    if dir notin result:
      result.add(dir)

proc shellOnPathDirs(dirs: openArray[string]): string =
  ## The first shell that would resolve if `dirs` were the whole `PATH`.
  ## Empty when none would — the condition the whole file rests on.
  for dir in dirs:
    for name in ["sh", "bash", "dash", "busybox"]:
      if fileExists(dir / name):
        return dir / name
  ""

proc withPath(pathValue: string): StringTableRef =
  result = newStringTable()
  for k, v in envPairs():
    result[k] = v
  result["PATH"] = pathValue

proc framed(output: string): string =
  ## The payload between `PROBE-BEGIN[` and `]PROBE-END`, or `""` when the
  ## frame is absent. Reading a frame rather than searching the whole output
  ## is what stops a compile that emitted NOTHING from satisfying a `notin`
  ## assertion.
  let opened = output.find("PROBE-BEGIN[")
  if opened < 0:
    return ""
  let start = opened + len("PROBE-BEGIN[")
  let closed = output.find("]PROBE-END", start)
  if closed < start:
    return ""
  output[start ..< closed]

const ProbeTemplate = """
import repro_project_dsl/compile_time_shell

const Probe = staticExec(compileTimeShellCommand(@DIR@, @CMD@))

static:
  echo "PROBE-BEGIN[" & Probe & "]PROBE-END"
"""

suite "a macro-time shell-out needs no shell on the action PATH":

  let repoRoot = findRepoRoot()
  let edgeDirs = compileEdgePathDirs()
  let hermeticPath = edgeDirs.join($PathSep)
  let nimExe = requireExe("nim")

  test "the synthesised compile-edge PATH really carries no shell":
    ## Without this, cases 2 and 3 are unfalsifiable.
    checkpoint("compile-edge PATH: " & hermeticPath)
    let found = shellOnPathDirs(edgeDirs)
    checkpoint("shell on it: " & (if found.len > 0: found else: "<none>"))
    check found.len == 0

  test "the composed command runs on that PATH, in the requested directory":
    ## The subject, driven through the SAME mechanism `staticExec` uses:
    ## `execCmdEx` starts its argument with `poEvalCommand`, which on POSIX is
    ## `execv("/bin/sh", ["sh", "-c", cmd])` — byte for byte what the Nim VM
    ## does for `staticExec`. So this is the compile-time shell-out, minus the
    ## compile; case 3 adds the compile back.
    ##
    ## `printf` is reached as `<abs sh> -c 'printf …'` rather than directly,
    ## because the composition prepends `exec`, and `exec` refuses a builtin.
    ## The shell it names is an absolute path OUTSIDE the hermetic `PATH`,
    ## which is the point: `staticExec`'s own `/bin/sh` is absolute too.
    let dir = createTempDir("repro-macro-shellout-", "")
    defer: removeDir(dir)
    let absSh = requireExe("sh")
    let probeCmd = quoteShell(absSh) & " -c " &
      quoteShell("printf '" & Sentinel & " %s' \"$PWD\"")

    let composed = compileTimeShellCommand(dir, probeCmd)
    checkpoint("composed: " & composed)
    let (output, exitCode) = execCmdEx(composed, env = withPath(hermeticPath))
    checkpoint("output: " & output & " exit=" & $exitCode)

    check exitCode == 0
    check output.startsWith(Sentinel)
    # It ran in the directory it was asked to run in — so the composition did
    # not merely drop the `workDir` it could not honour.
    check output.contains(dir)
    check "command not found" notin output
    check "not found" notin output

  test "…and from inside a real `nim c` on that same PATH":
    ## The compile-edge arm. A throwaway module `staticExec`s the composed
    ## command during ITS macro expansion, and the compiler runs with `PATH`
    ## REPLACED by the hermetic one — the environment the engine hands a Nim
    ## compile action.
    ##
    ## The probe command is `nim --version` by absolute path: `nim` is one of
    ## the two things a compile edge's `PATH` does carry, and its banner is a
    ## sentinel that cannot be produced by a shell that failed to start.
    ##
    ## `--path:` is passed explicitly and is not an override of anything:
    ## the throwaway module lives outside the checkout, so the repo's
    ## `config.nims` is not loaded for it and this is the only thing that
    ## resolves `repro_project_dsl/compile_time_shell` — to the real module in
    ## the real source tree, which is what makes a mutation of that file
    ## visible here.
    let dir = createTempDir("repro-macro-shellout-c-", "")
    defer: removeDir(dir)
    let source = dir / "shellout_probe.nim"
    writeFile(source, ProbeTemplate
      .replace("@DIR@", escape(dir))
      .replace("@CMD@", escape(quoteShell(nimExe) & " --version")))

    let dslSrc = repoRoot / "libs" / "repro_project_dsl" / "src"
    check fileExists(dslSrc / "repro_project_dsl" / "compile_time_shell.nim")

    let cmd = quoteShell(nimExe) & " c --hints:off --warnings:off" &
      " --path:" & quoteShell(dslSrc) &
      " --nimcache:" & quoteShell(dir / "nc") &
      " --out:" & quoteShell(dir / "probe") &
      " " & quoteShell(source)
    checkpoint("running: " & cmd)
    let (output, exitCode) = execCmdEx(cmd, env = withPath(hermeticPath),
                                       workingDir = dir)
    checkpoint(output)
    check exitCode == 0

    let probe = framed(output)
    checkpoint("probe payload: [" & probe & "]")
    check probe.len > 0
    check probe.contains("Nim Compiler Version")
    check "command not found" notin probe

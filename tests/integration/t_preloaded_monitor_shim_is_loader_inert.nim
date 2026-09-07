## A preloaded monitor shim is observationally inert for the loader.
##
## Automatic monitoring exports
## `LD_PRELOAD=<repo>/build/lib/librepro_monitor_shim.so` into every process a
## build action starts. Those processes are not ours. They are the compilers,
## linkers, archivers and wrapper scripts of whatever project is being built —
## including projects in OTHER repositories, driven by an engine built here —
## and each of them is linked against whatever C runtime produced it. The shim
## is a guest in every one of them.
##
## A guest must not bring its own C runtime. When the shim carries a
## DT_RUNPATH naming a directory that holds `libc.so.6` and its satellites, the
## loader resolves the shim's own `libm` / `librt` / `libpthread` OUT OF THAT
## DIRECTORY inside a process whose `libc.so.6` came from somewhere else. The
## satellites carry symbol versions their sibling `libc.so.6` defines, so the
## loader refuses the process before it reaches `main`:
##
##   …/bash: …/glibc-A/lib/libc.so.6: version `GLIBC_ABI_DT_X86_64_PLT'
##     not found (required by …/glibc-B/lib/libm.so.6)
##
## What that cost, measured on the host this file was written on: an engine
## built from this tree could not run `repro build` in a consumer repository at
## all. Every compile it started through a `gcc` wrapper — a shell script whose
## interpreter came from a different C runtime — died with three of those lines
## and an `execution of an external program failed` naming the compiler. The
## shim, which was the cause, appeared nowhere in the output. A packaged engine
## on the same host worked, because ITS shim happened to name a runtime the
## wrapper's could satisfy: a near miss, not a safety margin.
##
## The four cases are deliberately of four kinds, because no one of them is a
## gate on its own:
##
##   1. STRUCTURAL, and the only one that holds by construction. The shipped
##      shim's RUNPATH must name no directory that provides a C runtime. True
##      or false on every host, decidable from the artifact alone, and
##      independent of which runtimes a given machine happens to carry.
##   2. BEHAVIOURAL, with real subjects. Start, under the shim, every compiler
##      driver on this machine that an imposing shim WOULD break — chosen by
##      the same symbol-version comparison the gate uses, not by name — and
##      require each to run.
##   3. NEGATIVE, synthetic. Fabricate a shim that imposes a runtime and a
##      subject that cannot satisfy it, and require the check to REFUSE,
##      naming both. Then move ONE thing and require it to accept. This is the
##      case that keeps its value when the pins move: 1 and 2 both pass on a
##      host whose runtimes happen to agree, which is exactly the state this
##      defect survived in.
##   4. INTEGRATION. A source-built engine builds a project OUTSIDE its own
##      tree whose action spawns one of case 2's subjects — the thing that was
##      impossible, end to end, through the engine.
##
## Mocks, and why (per the repository policy on justifying every mock): NONE.
## Case 3 FABRICATES its pair — it copies a real shared object and rewrites its
## RUNPATH to a real C runtime already in the store, and copies a real ELF
## executable and rewrites its PT_INTERP to a real, different one — but nothing
## is simulated. The resulting files are exactly the kind of pair the defect is
## made of, and the checks read them the same way they read the shipped shim.
## Case 4's project is generated rather than fixtured only because it must live
## outside this repository to mean anything; the engine, the compiler wrapper,
## the monitoring and the loader are all real.
##
## Skip rules, each announced:
##   * not Linux — DT_RUNPATH is an ELF concept; macOS carries LC_RPATH and
##     Windows resolves DLLs by search order.
##   * `patchelf` / `readelf` / `bash` missing from PATH.
##   * cases 2 and 4: this machine carries no compiler driver that an imposing
##     shim could break, so there is no foreign-runtime subject to be right or
##     wrong about.
##   * case 3: this machine's store holds no two C runtimes where one fails to
##     define a version the other requires.
##   * cases 1 and 4: the shim / `build/bin/repro` is not built.

import std/[os, strutils, tempfiles, unittest]

import repro_test_support

const
  LoaderVersionErrorNeedle = "version `GLIBC_"
    ## The loader's own wording when a satellite library requires a symbol
    ## version the process's `libc.so.6` does not define. Asserted on in
    ## addition to the exit code because a wrapper script can swallow a
    ## non-zero status from something it started.

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc shimLib(): string =
  repoRoot() / "scripts" / "lib" / "preloaded_shim_loader.sh"

proc checkScript(): string = repoRoot() / "scripts" / "check_dev_shell_env.sh"

proc devShellLib(): string =
  repoRoot() / "scripts" / "lib" / "dev_shell_overrides.sh"

proc toolOnPath(name: string): string = findExe(name)

proc haveElfTools(): bool =
  toolOnPath("patchelf").len > 0 and toolOnPath("readelf").len > 0 and
    toolOnPath("bash").len > 0

proc shimPath(): string = monitorShimPath(repoRoot())

## --- bash-library bridge ---------------------------------------------------
##
## Every fact below is computed by the SAME shell functions the build script
## and the lint gate use, driven through bash, rather than reimplemented here.
## A second implementation in Nim could agree with the ELF files while
## disagreeing with the code that actually ships, which is the one outcome this
## file must not have.
proc bashLib(call: string; libPath = ""): seq[string] =
  let lib = if libPath.len > 0: libPath else: shimLib()
  let cmd = "set -u; source " & lib.quoteShell & "; " & call
  let res = runShell(shellCommand(@[toolOnPath("bash"), "-c", cmd]))
  for line in res.output.splitLines:
    let trimmed = line.strip()
    if trimmed.len > 0: result.add(trimmed)

type VulnerableDriver = object
  driver*: string       ## the compiler wrapper as the engine would run it
  interpreter*: string  ## the `#!` interpreter — the process that must survive
  runtime*: string      ## the C runtime that interpreter is linked against
  missing*: string      ## versions it could not satisfy if a shim imposed one

proc vulnerableDrivers(): seq[VulnerableDriver] =
  ## Compiler drivers on this machine that an imposing shim would break,
  ## one per distinct C runtime. See
  ## `preload_shim_vulnerable_toolchain_wrappers`.
  for line in bashLib("preload_shim_vulnerable_toolchain_wrappers"):
    let parts = line.split('\t')
    if parts.len != 4: continue
    result.add(VulnerableDriver(driver: parts[0], interpreter: parts[1],
      runtime: parts[2], missing: parts[3]))

type RuntimePair = object
  older*: string
  newer*: string
  missing*: seq[string]
  examined*: int
  readable*: int

proc findIncompatibleRuntimePair(): RuntimePair =
  for line in bashLib("preload_shim_find_incompatible_glibc_pair"):
    let parts = line.split('\t')
    case parts[0]
    of "examined":
      if parts.len == 2: result.examined = parseInt(parts[1])
    of "readable":
      if parts.len == 2: result.readable = parseInt(parts[1])
    of "pair":
      if parts.len == 4:
        result.older = parts[1]
        result.newer = parts[2]
        result.missing = parts[3].split(',')
    else: discard

proc loaderIn(runtime: string): string =
  ## The interpreter a C runtime ships. Its basename is architecture-specific
  ## (`ld-linux-x86-64.so.2`, `ld-linux-aarch64.so.1`, …), so take whichever
  ## one is actually there rather than naming one.
  for found in walkFiles(runtime / "lib" / "ld-linux-*.so.*"):
    return found
  runtime / "lib" / "ld-linux-x86-64.so.2"

suite "the preloaded monitor shim is inert for the loader":

  test "the shim imposes no C runtime on the processes it is preloaded into":
    when not defined(linux):
      checkpoint("skipped — DT_RUNPATH is an ELF concept; on " & hostOS &
        " this repository's libraries carry LC_RPATH or resolve by search " &
        "order instead")
      skip()
    else:
      if not haveElfTools():
        checkpoint("skipped — patchelf, readelf and bash are all required " &
          "to read the shim's dynamic section")
        skip()
      elif not fileExists(shimPath()):
        checkpoint("skipped — " & shimPath() &
          " is not built; run `just build`")
        skip()
      else:
        let runpath = bashLib("preload_shim_runpath_dirs " &
          shimPath().quoteShell)
        checkpoint("shim DT_RUNPATH: " &
          (if runpath.len == 0: "(none)" else: runpath.join(" : ")))
        let imposed = bashLib("preload_shim_imposed_runtime_dirs " &
          shimPath().quoteShell)
        if imposed.len > 0:
          checkpoint("the shim would hand its own C runtime to every process " &
            "it is preloaded into, from:\n  " & imposed.join("\n  "))
        check imposed.len == 0

        # The positive half of the same assertion. A RUNPATH read that came
        # back empty because the reader is broken looks exactly like a clean
        # shim, so require the reader to have actually read the file: every
        # ELF here has a dynamic section, and the shim's DT_NEEDED is the C
        # runtime it must take from its host.
        let needed = runShell(shellCommand(
          @[toolOnPath("patchelf"), "--print-needed", shimPath()]))
        check needed.code == 0
        check "libc.so.6" in needed.output

  test "a preloaded shim starts every driver an imposing one would break":
    when not defined(linux):
      checkpoint("skipped — see the first case; this channel is linux-only")
      skip()
    else:
      if not haveElfTools():
        checkpoint("skipped — patchelf, readelf and bash are all required")
        skip()
      elif not fileExists(shimPath()):
        checkpoint("skipped — " & shimPath() &
          " is not built; run `just build`")
        skip()
      else:
        let drivers = vulnerableDrivers()
        if drivers.len == 0:
          # Announced, and NOT a pass: every driver reachable here runs on a
          # C runtime that satisfies everything else on the machine, so
          # preloading the shim into one of them demonstrates nothing about
          # the invariant. Case 1 still holds, and case 3 fabricates what this
          # host does not have.
          checkpoint("skipped — no compiler driver on this machine runs on a " &
            "C runtime that another runtime here could break, so there is no " &
            "foreign-runtime subject to exercise")
          skip()
        else:
          for d in drivers:
            checkpoint(d.driver & "\n      interpreter: " & d.interpreter &
              "\n      runs on:     " & d.runtime &
              "\n      would fail on: " & d.missing)
            # Bare first: a driver that cannot run on its own is not evidence
            # about the shim, and this is the only thing that separates
            # "the preload broke it" from "it was already broken".
            let bare = runShell(shellCommand(@[d.driver, "--version"]))
            if bare.code != 0:
              checkpoint("skipped for this driver — it does not run even " &
                "without the shim:\n" & bare.output)
            else:
              let preloaded = runShell(shellCommand(@[d.driver, "--version"],
                @[("LD_PRELOAD", shimPath())]))
              if preloaded.code != 0:
                checkpoint(preloaded.output)
              check LoaderVersionErrorNeedle notin preloaded.output
              check preloaded.code == 0

  test "the check refuses a shim that imposes a runtime, naming both":
    when not defined(linux):
      checkpoint("skipped — see the first case; this channel is linux-only")
      skip()
    else:
      if not haveElfTools():
        checkpoint("skipped — patchelf, readelf and bash are all required " &
          "to build and read the fabricated pair")
        skip()
      else:
        let pair = findIncompatibleRuntimePair()
        checkpoint("store C runtimes examined: " & $pair.examined &
          ", version tables the gate's own extractor could read: " &
          $pair.readable)
        if pair.examined > 0 and pair.readable == 0:
          # A FAILURE, not a skip, and the distinction is the whole point: an
          # extractor that reads nothing out of every runtime on the machine is
          # broken, and "no incompatible pair could be built here" is exactly
          # how that would present. Nothing below would mean anything in that
          # state, so the case stops rather than skipping into a green run.
          checkpoint("the symbol-version extractor could not read ANY of the " &
            $pair.examined & " C runtimes in the store. The comparison this " &
            "gate rests on cannot tell a compatible pair from an " &
            "incompatible one; fix the extractor in " &
            "scripts/lib/dev_shell_overrides.sh.")
          fail()
        elif pair.older.len == 0:
          checkpoint("skipped — this machine's store holds no two C runtimes " &
            "where one fails to define a symbol version the other requires, " &
            "so the conflict this case is about cannot be built here out of " &
            "real files")
          skip()
        else:
          checkpoint("fabricating from real store paths: cannot-satisfy=" &
            pair.older & " imposed=" & pair.newer & " missing=" &
            pair.missing.join(","))
          let tempRoot = createTempDir("repro-shim-inert-", "")
          defer: removeDirEventually(tempRoot)

          # The imposing shim: a real shared object whose RUNPATH names the
          # runtime the subject cannot satisfy. That is what a shim linked by
          # a wrapper that adds rpath entries looks like.
          let fabDir = tempRoot / "lib"
          createDir(fabDir)
          let fabShim = fabDir / "librepro_monitor_shim.so"
          copyFile(pair.newer / "lib" / "libm.so.6", fabShim)
          setFilePermissions(fabShim, {fpUserRead, fpUserWrite, fpUserExec})
          discard requireSuccess(shellCommand(@[toolOnPath("patchelf"),
            "--set-rpath", pair.newer / "lib", fabShim]))

          # The subject: a real dynamic ELF that runs on the runtime which
          # cannot satisfy it.
          let donor = toolOnPath("true")
          check donor.len > 0
          let subject = tempRoot / "cc"
          proc pointSubjectAt(runtime: string) =
            copyFile(donor, subject)
            setFilePermissions(subject,
              {fpUserRead, fpUserWrite, fpUserExec})
            discard requireSuccess(shellCommand(@[toolOnPath("patchelf"),
              "--set-interpreter", loaderIn(runtime), subject]))

          proc conflicts(): seq[string] =
            bashLib("preload_shim_loader_conflicts " & fabShim.quoteShell &
              " " & subject.quoteShell)

          # NEGATIVE polarity. The structural finding must fire, and so must
          # the symbol-version one — the second is what makes this a statement
          # about the MISMATCH rather than about one host's symptom of it.
          let imposed = bashLib("preload_shim_imposed_runtime_dirs " &
            fabShim.quoteShell)
          checkpoint("imposed: " & imposed.join(" | "))
          check imposed.len == 1
          check pair.newer in imposed[0]

          pointSubjectAt(pair.older)
          let refused = conflicts()
          checkpoint("conflicts: " & refused.join("\n"))
          check refused.len >= 1
          # Naming BOTH runtimes is the requirement: a message that says only
          # "mismatch" leaves the reader to work out which two things.
          let refusedText = refused.join("\n")
          check refusedText.startsWith("conflict\t")
          check pair.older in refusedText
          check pair.newer in refusedText
          check subject in refusedText
          for want in pair.missing:
            check want in refusedText

          # POSITIVE polarity, same fabricated pair: move ONLY the subject's
          # interpreter onto the imposed runtime and the same comparison must
          # accept. One thing changed, both answers — which is what separates
          # a gate from something that always says no. Note that the shim is
          # unchanged and still imposes: a different runtime is not the
          # finding, an unsatisfiable one is.
          pointSubjectAt(pair.newer)
          let accepted = conflicts()
          checkpoint("conflicts after moving the subject onto the imposed " &
            "runtime: " & (if accepted.len == 0: "(none)"
                           else: accepted.join("\n")))
          check accepted.len == 0

          # And the gate script itself must refuse, not just the library it
          # calls. Driven against a scratch tree carrying the fabricated shim
          # where the real one lives, so what is exercised is the wiring.
          let scratch = tempRoot / "workspace" / "repo"
          createDir(scratch / "scripts" / "lib")
          createDir(scratch / "build" / "lib")
          copyFile(checkScript(), scratch / "scripts" /
            "check_dev_shell_env.sh")
          copyFile(devShellLib(), scratch / "scripts" / "lib" /
            "dev_shell_overrides.sh")
          copyFile(shimLib(), scratch / "scripts" / "lib" /
            "preloaded_shim_loader.sh")
          copyFile(repoRoot() / ".envrc", scratch / ".envrc")
          copyFile(repoRoot() / "flake.nix", scratch / "flake.nix")
          copyFile(repoRoot() / "scripts" / "dev-shell-pinned-siblings.tsv",
            scratch / "scripts" / "dev-shell-pinned-siblings.tsv")
          copyFile(fabShim, scratch / "build" / "lib" /
            "librepro_monitor_shim.so")
          let gate = runShell(shellCommand(
            @[toolOnPath("bash"),
              scratch / "scripts" / "check_dev_shell_env.sh"],
            @[("LD_LIBRARY_PATH", "")]), scratch)
          checkpoint(gate.output)
          check gate.code != 0
          check "carries a C runtime on its own DT_RUNPATH" in gate.output
          check pair.newer in gate.output
          check "imposes no C runtime" notin gate.output

  test "engine: a source-built repro builds a project outside its own tree":
    when not defined(linux):
      checkpoint("skipped — see the first case; this channel is linux-only")
      skip()
    else:
      let root = repoRoot()
      let reproBin = root / "build" / "bin" / addFileExt("repro", ExeExt)
      if not haveElfTools():
        checkpoint("skipped — patchelf, readelf and bash are all required " &
          "to choose a foreign-runtime subject")
        skip()
      elif not fileExists(reproBin):
        checkpoint("skipped — " & reproBin & " is missing; run `just build`")
        skip()
      elif not fileExists(shimPath()):
        checkpoint("skipped — " & shimPath() &
          " is not built, so no action would be monitored and this case " &
          "would prove nothing")
        skip()
      else:
        let drivers = vulnerableDrivers()
        if drivers.len == 0:
          checkpoint("skipped — no compiler driver on this machine runs on a " &
            "C runtime that another runtime here could break; see case 2")
          skip()
        else:
          let subject = drivers[0]
          checkpoint("subject driver: " & subject.driver &
            "\n      interpreter: " & subject.interpreter &
            "\n      runs on:     " & subject.runtime)
          let scratch = createTempDir("repro-shim-inert-engine-", "")
          defer: removeDirEventually(scratch)

          # The project is OUTSIDE this repository on purpose: it has no flake,
          # no `.envrc` and no dev shell, which is the shape every consumer
          # repository has and the shape a gate confined to this tree would
          # never see. The driver is written into the source rather than passed
          # through the environment so nothing about the action's environment
          # composition can quietly change what is spawned.
          const fixtureTemplate = """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package shimLoaderInertProbe:
  defaultToolProvisioning "path"

  uses:
    "sh"

  build:
    let probe = shell(
      command = "mkdir -p build && printf 'LD_PRELOAD=%s\n' \"$LD_PRELOAD\" > build/probe.txt && @@DRIVER@@ --version >> build/probe.txt",
      actionId = "shim-loader-inert.probe",
      extraOutputs = @["build/probe.txt"],
      cacheable = false)
    discard target("probe", probe)
"""
          writeFile(scratch / "repro.nim",
            fixtureTemplate.replace("@@DRIVER@@",
              subject.driver.quoteShell))
          let run = runShell(shellCommand(@[reproBin, "build", "probe",
            "--tool-provisioning=path", "--daemon=off", "--no-runquota",
            "--log=actions", "--progress=quiet", "--measure=none"]), scratch)
          if run.code != 0:
            checkpoint(run.output)
            # The engine writes an action's stdout to the failure report rather
            # than to the console; surface it so a red run says why instead of
            # showing an empty stderr.
            let failureReport = scratch / ".repro" / "build" / "repro" /
              "build-failure-report.json"
            if fileExists(failureReport):
              checkpoint("build-failure-report.json:\n" &
                readFile(failureReport))
          check LoaderVersionErrorNeedle notin run.output
          check run.code == 0

          # The case must not be able to pass by NOT monitoring. The action
          # records the LD_PRELOAD it actually ran with, and it has to name
          # this repository's shim: without that, "the compiler ran" says
          # nothing about a preloaded library.
          let probeOut = scratch / "build" / "probe.txt"
          check fileExists(probeOut)
          let recorded = readFile(probeOut)
          checkpoint(recorded)
          check ("LD_PRELOAD=" & shimPath()) in recorded

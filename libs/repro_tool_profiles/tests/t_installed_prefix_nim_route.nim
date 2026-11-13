## The provider compiler of an installed prefix is the Nim it ships
## (reprobuild-pm Distribution-And-Packaging.md §5.3, amendment N3, approved
## by Zahary Karadjov, 2026-11-04; the provider-toolchain rule 2 in the
## Distribution-And-Packaging milestone names this route first).
##
## ## The defects this pins
##
## * The armv7 installed prefix ships the Nim fork under `nim/`, because the
##   appliance compiles providers and profiles itself. Substituted on rpi2,
##   its `repro exec -- true` ignored that compiler and provisioned
##   `nim-source@2.2.10`, a source build of stock Nim (2026-11-04).
## * A prefix from `scripts/cross/build_linux_cross.sh` shipped `nim/bin/nim`
##   with no `nim/.nim-fork-revision` and recorded
##   `nim_fork=flake:nim-fork-src@<sha>`, so the route refused it and every
##   provider compile failed (A15 re-review, 2026-11-05). The script now
##   writes the record through `scripts/cross/nim_fork_record.sh`; the
##   script-shaped cases below run that very function.
##
## ## What is pinned, each case falsified by removing its guard
##
## * a prefix shipping the recorded fork resolves to it, and the bootstrap
##   uses it and provisions no Nim (no tool-store prefix appears);
## * the shipped compiler must be the recorded fork: a revision mismatch, a
##   missing revision file, a missing build record are each refused with
##   their own sentence;
## * a release outside the required range is refused, not replaced, and the
##   range is read by the `uses:` grammar, each of its forms both ways;
## * an image with no `nim/` keeps the per-host routes;
## * a prefix written by the script's record function passes, and one in the
##   script's old shape is refused.
##
## That a compiler already chosen (a project pin) wins is pinned through the
## pin's own publisher in `repro_cli_support/tests/t_installed_prefix_nim_pin_wins.nim`.
##
## NO MOCKS of the route: real directories in the installed layout. The
## shipped `bin/nim` is a stand-in file: the route reads the compiler's
## release from its `lib/system/compilation.nim`, as the installation records
## it, and never runs it.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_core/installed_prefix_nim
import repro_test_support/reasoned_skip
import repro_interface_artifacts
import repro_tool_profiles

const
  ForkRev = "197089cda27f656f8010e2b31b40e0e12f3f209b"
  RepoRoot = currentSourcePath().parentDir.parentDir.parentDir.parentDir

template withEnv(names: openArray[string]; body: untyped) =
  var saved: seq[tuple[name: string; present: bool; value: string]]
  for name in names:
    saved.add((name: name, present: existsEnv(name), value: getEnv(name)))
  try:
    body
  finally:
    for entry in saved:
      if entry.present: putEnv(entry.name, entry.value)
      else: delEnv(entry.name)

template requireGcc(gcc: untyped; body: untyped) =
  ## The bootstrap probes the C compiler it is given. A gate run
  ## (`REPROBUILD_GATE_RUN=1`, exported by `scripts/run_tests.sh`) must have
  ## one, so a missing gcc fails the case there; anywhere else the case is
  ## reported SKIPPED, never passed on a checkpoint alone.
  let gcc = findExe("gcc")
  if gcc.len == 0:
    if getEnv("REPROBUILD_GATE_RUN") == "1":
      checkpoint("gcc is not on PATH in a gate run; the bootstrap probes " &
        "its C compiler")
      check false
    else:
      skip("gcc is not on PATH; the bootstrap probes its C compiler")
  else:
    body

proc installedPrefix(root: string; rev = ForkRev; recorded = ForkRev;
                     major = 2, minor = 3, patch = 1;
                     record = true; revisionFile = true): string =
  ## An installed prefix at `root/prefix`: the engine image, the shipped
  ## Nim and the build record.
  result = root / "prefix"
  createDir(result / "bin")
  writeFile(result / "bin" / "reprobuild", "")
  createDir(result / "nim" / "bin")
  createDir(result / "nim" / "lib" / "system")
  writeFile(result / "nim" / "bin" / addFileExt("nim", ExeExt),
    "#!/bin/sh\nexit 0\n")
  if revisionFile:
    writeFile(result / "nim" / ".nim-fork-revision", rev & "\n")
  writeFile(result / "nim" / "lib" / "system" / "compilation.nim",
    "const\n" &
    "  NimMajor* {.intdefine.}: int = " & $major & "\n" &
    "  NimMinor* {.intdefine.}: int = " & $minor & "\n" &
    "  NimPatch* {.intdefine.}: int = " & $patch & "\n")
  if record:
    createDir(result / "share" / "repro")
    writeFile(result / "share" / "repro" / "cross-build-info",
      "triple=armv7-unknown-linux-gnueabihf\nnim_fork=" & recorded & "\n")

proc refusal(prefix: string): string =
  try:
    discard installedPrefixNim(@[prefix])
    "no refusal"
  except BootstrapNimError as err:
    err.msg

suite "an installed prefix compiles providers with the Nim it ships":

  test "a prefix shipping the recorded fork resolves to it":
    let root = createTempDir("prefix-nim-ok-", "")
    defer: removeDir(root)
    let prefix = installedPrefix(root)
    check installedPrefixNim(@[root / "elsewhere", prefix]) ==
      prefix / "nim" / "bin" / addFileExt("nim", ExeExt)

  test "an image with no nim/ keeps the per-host routes":
    let root = createTempDir("prefix-nim-none-", "")
    defer: removeDir(root)
    createDir(root / "checkout" / "bin")
    check installedPrefixNim(@[root / "checkout"]) == ""

  test "a shipped Nim that is not the recorded fork is refused by name":
    let root = createTempDir("prefix-nim-rev-", "")
    defer: removeDir(root)
    let other = repeat('b', 40)
    let msg = refusal(installedPrefix(root, rev = other))
    checkpoint(msg)
    check "not the fork it records" in msg
    check other in msg
    check ForkRev in msg

  test "a shipped Nim without its revision file is refused":
    let root = createTempDir("prefix-nim-norev-", "")
    defer: removeDir(root)
    let msg = refusal(installedPrefix(root, revisionFile = false))
    checkpoint(msg)
    check "not the fork it records" in msg
    check "(missing)" in msg

  test "a shipped Nim without the build record is refused":
    let root = createTempDir("prefix-nim-norec-", "")
    defer: removeDir(root)
    let msg = refusal(installedPrefix(root, record = false))
    checkpoint(msg)
    check "no build record" in msg

  test "a shipped Nim outside the bootstrap's range is refused, not replaced":
    let root = createTempDir("prefix-nim-range-", "")
    defer: removeDir(root)
    let msg = refusal(installedPrefix(root, major = 3, minor = 0, patch = 0))
    checkpoint(msg)
    check "ships Nim 3.0.0, outside the range" in msg
    check ">=2.2" in msg

  test "the release is read by the uses: grammar, every form both ways":
    # Each form the `uses:` grammar (`repro_solver/uses_constraints`) reads,
    # once admitting 2.3.1 and once excluding it. A private parser that read
    # only `>=`/`<`/`==` refused the caret, tilde, spaced and `v` forms
    # (A15 round-3 verification, 2026-11-06).
    for c in ["nim >=2.2 <3.0", "nim >=2.2,<3", "nim >= 2.2", "nim ^2.2",
              "nim ~2.3", "nim v2.3.1", "nim 2.3.1", "nim ==2.3.1",
              "nim =2.3.1", "nim >2.3.0", "nim <=2.3.1", "nim"]:
      checkpoint(c)
      check nimReleaseAdmitted("2.3.1", c)
    for c in ["nim >=2.0 <2.3", "nim >=2.4,<3", "nim >= 2.4", "nim ^2.4",
              "nim ~2.2", "nim v2.3.0", "nim 2.2.10", "nim ==2.2.10",
              "nim >2.3.1", "nim <2.3.1", "nim >=3.0", "nim >=two"]:
      checkpoint(c)
      check not nimReleaseAdmitted("2.3.1", c)

  test "the prefix route's range is read by the same grammar":
    let root = createTempDir("prefix-nim-caret-", "")
    defer: removeDir(root)
    let prefix = installedPrefix(root)
    check findInstalledPrefixNim([prefix], "nim ^2.2").exe ==
      prefix / "nim" / "bin" / addFileExt("nim", ExeExt)
    expect InstalledPrefixNimError:
      discard findInstalledPrefixNim([prefix], "nim ~2.2")

  test "a project's own uses: range is checked against the prefix's release":
    withEnv([InstalledPrefixNimEnvVar]):
      putEnv(InstalledPrefixNimEnvVar, "2.3.1")
      let uses = @[InterfaceToolUse(rawConstraint: "nim >=2.0 <2.3",
        packageSelector: "nim", executableName: "nim")]
      expect BootstrapNimError:
        requireProjectNimAdmitsInstalledPrefixNim(uses)
      requireProjectNimAdmitsInstalledPrefixNim(@[InterfaceToolUse(
        rawConstraint: "nim >=2.2 <3.0", packageSelector: "nim",
        executableName: "nim")])
      for c in ["nim ^2.2", "nim ~2.3", "nim >= 2.2", "nim v2.3.1"]:
        checkpoint(c)
        requireProjectNimAdmitsInstalledPrefixNim(@[InterfaceToolUse(
          rawConstraint: c, packageSelector: "nim", executableName: "nim")])
      expect BootstrapNimError:
        requireProjectNimAdmitsInstalledPrefixNim(@[InterfaceToolUse(
          rawConstraint: "nim ^2.4", packageSelector: "nim",
          executableName: "nim")])
      # A tool that is not the compiler is not its business.
      requireProjectNimAdmitsInstalledPrefixNim(@[InterfaceToolUse(
        rawConstraint: "nimble >=0.1 <0.2", packageSelector: "nimble",
        executableName: "nimble")])
      delEnv(InstalledPrefixNimEnvVar)
      # Without the prefix route there is nothing to check.
      requireProjectNimAdmitsInstalledPrefixNim(uses)

  test "the bootstrap uses the prefix's Nim and provisions none":
    requireGcc(gcc):
      let root = createTempDir("prefix-nim-env-", "")
      defer: removeDir(root)
      let prefix = installedPrefix(root)
      let store = root / "tool-store"
      withEnv(["REPRO_NIM_COMPILER", "REPRO_BOOTSTRAP_CC",
               "REPRO_PUBLIC_CLI_PATH", "CC", InstalledPrefixNimEnvVar]):
        delEnv("REPRO_NIM_COMPILER")
        delEnv(InstalledPrefixNimEnvVar)
        putEnv("REPRO_BOOTSTRAP_CC", gcc)
        # The image the portable launcher names (the second anchor of
        # `runningImagePrefixCandidates`); this test binary's own image
        # lives in no prefix.
        putEnv("REPRO_PUBLIC_CLI_PATH", prefix / "bin" / "reprobuild")
        ensureBootstrapToolchainEnv(tpmPathOnly, store)
        check getEnv("REPRO_NIM_COMPILER") ==
          prefix / "nim" / "bin" / addFileExt("nim", ExeExt)
        check getEnv(InstalledPrefixNimEnvVar) == "2.3.1"
        check not dirExists(store / "prefixes")

suite "both producers write the record the route checks":

  test "a prefix written by the script's record function passes":
    let root = createTempDir("prefix-nim-script-", "")
    defer: removeDir(root)
    let prefix = installedPrefix(root, record = false, revisionFile = false)
    createDir(prefix / "share" / "repro")
    let script = RepoRoot / "scripts" / "cross" / "nim_fork_record.sh"
    require fileExists(script)
    let r = execCmdEx("bash -c " & quoteShell(". " & quoteShell(script) &
      " && nim_fork_record " & quoteShell(prefix) & " " & ForkRev &
      " >> " & quoteShell(prefix / "share" / "repro" / "cross-build-info")))
    checkpoint(r.output)
    require r.exitCode == 0
    check readFile(prefix / "share" / "repro" / "cross-build-info").
      strip() == "nim_fork=" & ForkRev
    check installedPrefixNim(@[prefix]) ==
      prefix / "nim" / "bin" / addFileExt("nim", ExeExt)

  test "a prefix in the script's old shape is refused, not used":
    let root = createTempDir("prefix-nim-oldscript-", "")
    defer: removeDir(root)
    let msg = refusal(installedPrefix(root, revisionFile = false,
      recorded = "flake:nim-fork-src@" & ForkRev))
    checkpoint(msg)
    check "not the fork it records" in msg

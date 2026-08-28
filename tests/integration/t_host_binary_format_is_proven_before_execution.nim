## W15 — the property is the machine FORMAT of the binary about to run,
## not its presence.
##
## ``build/`` is gitignored and shared between platforms on this host: the
## Windows checkout at ``M:\m\dev\reprobuild`` is reached from WSL as
## ``/mnt/m/m/dev/reprobuild``, so a ``nix develop`` build drops an ELF
## beside the PE. 12 names in ``build/bin`` exist in both forms. Under that
## condition every extension-less path in the suite names *whichever
## platform built last*, and on Windows:
##
##   * ``fileExists("./build/bin/repro")``            -> true  (the ELF)
##   * ``repro_test_support.executableFile(same)``    -> true  (no mode bit
##                                                              to consult)
##   * executing it                                   -> "%1 is not a valid
##                                                       Win32 application"
##
## which reads as a product refusal. That is what ``t_dev_env_allow`` did
## from the repo root, and what ``t_repro_build_target_matching_project_
## file_stem`` did before W14. Presence and executability both answered
## "yes" to a question nobody asked.
##
## This file pins the property one layer below the tests that consume it:
## ``binaryFormatOf`` classifies by header bytes, ``hostBinaryFormat``
## states what this kernel can load, and ``requireHostBinary`` refuses the
## mismatch with a diagnostic that names both.

import std/[algorithm, os, sets, strutils, unittest]

import repro_test_support

const
  ElfHeader = "\x7FELF\x02\x01\x01\x00"
  BuildBinDir = ReprobuildRepoRoot / "build" / "bin"

proc peImage(): string =
  var s = newString(0x44)
  s[0] = 'M'
  s[1] = 'Z'
  s[0x3C] = '\x40'
  s[0x40] = 'P'
  s[0x41] = 'E'
  result = s

proc scratch(slug: string): string =
  result = getTempDir() / ("w15-format-" & slug & "-" & testCaseScratchSlug())
  removeDirEventually(result)
  createDir(result)

proc dualFormNames(): seq[string] =
  ## Names under ``build/bin`` that exist BOTH with and without ``.exe``.
  ## This is the hazard surface, measured rather than assumed.
  if not dirExists(BuildBinDir):
    return @[]
  var bare = initHashSet[string]()
  var exed = initHashSet[string]()
  for kind, path in walkDir(BuildBinDir):
    if kind != pcFile: continue
    let name = path.extractFilename()
    if name.endsWith(".exe"): exed.incl(name[0 ..< name.len - 4])
    elif name.splitFile().ext.len == 0: bare.incl(name)
  for n in bare:
    if n in exed: result.add(n)
  result.sort()

suite "W15 host binary format":

  test "the format is decided by header bytes, not by name or mode":
    let root = scratch("classify")
    defer: removeDirEventually(root)
    # Every one of these is named so that a name-based rule gets it wrong.
    writeFile(root / "looks-like-an-exe.exe", ElfHeader & newString(56))
    writeFile(root / "looks-native", peImage())
    writeFile(root / "mach.exe", "\xCF\xFA\xED\xFE" & newString(60))
    writeFile(root / "stub.exe", "MZ" & newString(64))
    writeFile(root / "prose.exe", "this is not a machine image\n")

    check binaryFormatOf(root / "looks-like-an-exe.exe") == hbfElf
    check binaryFormatOf(root / "looks-native") == hbfPe
    check binaryFormatOf(root / "mach.exe") == hbfMachO
    # A DOS stub carries the right first two bytes and no ``PE\0\0`` at the
    # offset its own header points to. Accepting it would make the check a
    # name check in disguise.
    check binaryFormatOf(root / "stub.exe") == hbfUnknown
    check binaryFormatOf(root / "prose.exe") == hbfUnknown
    check binaryFormatOf(root / "absent") == hbfMissing
    check binaryFormatOf("") == hbfMissing

    # And the two properties the class actually turns on: presence and
    # executability both say "yes" to the wrong file.
    check fileExists(root / "looks-like-an-exe.exe")
    when defined(windows):
      check executableFile(root / "looks-like-an-exe.exe")
      check binaryFormatOf(root / "looks-like-an-exe.exe") != hostBinaryFormat()

  test "hostBinaryFormat matches the binary that is running this case":
    # An independent witness that needs no build and no fixture: the image
    # executing this assertion is, necessarily, of the host's format.
    let self = getAppFilename()
    checkpoint("self = " & self & " -> " & describeBinaryFormat(self))
    check binaryFormatOf(self) == hostBinaryFormat()

  test "requireHostBinary refuses the other platform's artefact":
    let root = scratch("refuse")
    defer: removeDirEventually(root)
    let foreign = root / "repro".addFileExt(ExeExt)
    when defined(windows):
      writeFile(foreign, ElfHeader & newString(56))
    else:
      writeFile(foreign, peImage())

    var refused = false
    var diagnostic = ""
    try:
      requireHostBinary(foreign)
    except Exception as e:
      refused = true
      diagnostic = e.msg
    checkpoint(diagnostic)
    check refused
    # The diagnostic has to name BOTH formats, or the next reader repeats
    # the three sessions this class already cost.
    check "wrong machine format" in diagnostic
    check foreign in diagnostic

    var missingRefused = false
    try:
      requireHostBinary(root / "never-built".addFileExt(ExeExt))
    except Exception:
      missingRefused = true
    check missingRefused

    # And it accepts the real thing.
    check requireHostBinary(getAppFilename()) == getAppFilename()

  test "reproBinaryPath is source-anchored and extension-correct":
    let p = reproBinaryPath()
    checkpoint("reproBinaryPath() = " & p)
    check p.isAbsolute()
    check p == ReprobuildRepoRoot / "build" / "bin" / "repro".addFileExt(ExeExt)
    when defined(windows):
      check p.endsWith(".exe")
    else:
      check not p.endsWith(".exe")
    # The cwd is not an input. Prove it rather than assert it.
    let fromHere = reproBinaryPath()
    let previous = getCurrentDir()
    setCurrentDir(getTempDir())
    let fromElsewhere = reproBinaryPath()
    setCurrentDir(previous)
    check fromHere == fromElsewhere

  test "the built repro is this platform's, and the pair set is the hazard":
    ## This is the assertion that would have caught ``t_dev_env_allow``.
    let p = reproBinaryPath()
    let dual = dualFormNames()
    checkpoint("build/bin dual-form names (" & $dual.len & "): " & dual.join(", "))
    if binaryFormatOf(p) == hbfMissing:
      checkpoint("no built engine at " & p & " — run `just bootstrap`")
      skip()
    else:
      check binaryFormatOf(p) == hostBinaryFormat()
      # For every name that exists in BOTH forms, the helper must select the
      # one this kernel can load. That is the whole point of the helper.
      for name in dual:
        let selected = reproBinaryPath(stem = name)
        checkpoint(name & " -> " & selected & " (" &
          describeBinaryFormat(selected) & ")")
        check binaryFormatOf(selected) == hostBinaryFormat()

  test "the extension-less join survives only where it is correct":
    ## Census, not a sweep. ``x / "build" / "bin" / "repro"`` cannot carry an
    ## extension, so every LIVE occurrence is a site that names the other
    ## platform's artefact on some host. W15 removed the two that were live
    ## here; the rest are recorded by name so a NEW one is red and the known
    ## ones stay attributed.
    var offenders: seq[string] = @[]
    for dir in ["tests", "benchmarks", "libs", "apps", "tools", "scripts"]:
      let abs = ReprobuildRepoRoot / dir
      if not dirExists(abs): continue
      for path in walkDirRec(abs, relative = true):
        if not path.endsWith(".nim"): continue
        var content = ""
        try: content = readFile(abs / path)
        except CatchableError: continue
        const Join = "\"build\" / \"bin\" / \"repro\""
        for line in content.splitLines():
          let stripped = line.strip()
          if stripped.startsWith("#"): continue
          let idx = line.find(Join)
          if idx < 0: continue
          # ``… / "repro".addFileExt(ExeExt)`` is the CORRECT spelling of the
          # same join and must not be reported. Only the bare one names the
          # other platform's artefact.
          if line[idx + Join.len .. ^1].strip().startsWith(".addFileExt"):
            continue
          offenders.add(dir & "/" & path.replace('\\', '/'))
          break
    offenders.sort()
    checkpoint("live extension-less joins: " & offenders.join("\n  "))
    # macOS's native format has no executable extension, so on those files
    # the spelling is CORRECT for the platform they are registered for
    # (``soMacosArm64``); the residual hazard there is a shared
    # macOS/Linux tree, which this host is not. The benchmark is not a test
    # and does not gate anything.
    let expected = @[
      "benchmarks/lib/reprobuild_m23_bench.nim",
      # Origin's, and CORRECT: this one never names an artefact. It builds
      # the string under a fresh ``createTempDir`` and hands it to
      # ``reprobuildSourceRootFromBinaryLocation``, a pure path parser that
      # walks UP looking for checkout markers. The file is never created,
      # stat'ed or executed, so there is no artefact for an extension to be
      # wrong about — adding one would only make the fixture less like the
      # POSIX path the parser is documented against. Attributed here rather
      # than exempted by a rule, because the census is deliberately a list
      # of names: the next new join has to be argued for too.
      "libs/repro_interface_artifacts/tests/" &
        "t_reprobuild_source_root_from_binary_location.nim",
      "tests/e2e/macos-phase5/t_e2e_macos_phase5_launchd_system_daemon.nim",
      "tests/e2e/macos-phase5/t_e2e_macos_phase5_macos_system_default.nim",
      "tests/e2e/macos-phase5/t_e2e_macos_phase5_os_hostname.nim",
      "tests/e2e/macos-phase5/t_e2e_macos_phase5_os_timezone.nim",
      "tests/e2e/macos-phase5/t_e2e_macos_phase5_passwd_group.nim",
    ]
    check offenders == expected

  test "the two W15 files no longer make the cwd or the extension an input":
    ## The audit is over CODE, not over the file. Both files carry comments
    ## that quote the removed lines verbatim — that record is the point of
    ## the change and must not be what the audit measures. (The first draft
    ## of this case failed on its own explanatory comments, which is the
    ## same "measured something other than what was asked" shape the whole
    ## milestone is about, one level up.)
    proc codeOf(path: string): string =
      for line in readFile(path).splitLines():
        if line.strip().startsWith("#"): continue
        result.add(line)
        result.add('\n')

    let allow = codeOf(ReprobuildRepoRoot / "tests" / "integration" /
      "t_dev_env_allow.nim")
    check "getCurrentDir()" notin allow
    check "reproBinaryPath()" in allow
    check "requireHostBinary" in allow

    let shard = codeOf(ReprobuildRepoRoot / "tests" / "e2e" / "sharding" /
      "t_e2e_repro_test_shard_workspace_integration.nim")
    # The private root-walk is gone, along with its ``repro.tests.nim``
    # sentinel — a file that does not exist in this repository, so the walk
    # could never match at any level and ran to the drive root.
    check "getCurrentDir()" notin shard
    check "repro.tests.nim\"" notin shard
    check "repro_tests.nim" in shard
    check "requireShardingReproBinary" in shard

    let support = codeOf(ReprobuildRepoRoot / "tests" / "e2e" / "sharding" /
      "sharding_test_support.nim")
    check "requireHostBinary" in support

## W15 — ``just bootstrap``'s guard must be about THIS platform's artefact.
##
## The guard used to be three inline lines in the ``Justfile``:
##
##   if [ ! -x ./build/bin/repro ]; then needs_bootstrap=1;
##   elif find apps libs config.nims flake.nix repro.nim -type f \
##        -newer ./build/bin/repro -print -quit | grep -q .; then …
##
## ``./build/bin/repro`` is the LINUX artefact name. ``build/`` is
## gitignored and shared between this host's Windows checkout
## (``M:\m\dev\reprobuild``) and the WSL view of the same tree
## (``/mnt/m/m/dev/reprobuild``), so a ``nix develop`` build drops an ELF
## beside the PE and 12 names in ``build/bin`` exist in both forms.
##
## Both clauses were therefore wrong on Windows, in opposite directions,
## and which one you get is decided by the SHELL rather than by the file:
##
##   * when the extension-less file satisfies ``-x``, the guard concludes
##     the engine is built and ``repro.exe`` is never built or refreshed,
##     and the freshness ``find`` compares against the other platform's
##     mtime;
##   * when it does not, the guard rebuilds on every single invocation and
##     the fast path the recipe's own comment promises is dead.
##
## A guard that silently does nothing is how this class started, so it gets
## a test. The decision now lives in ``scripts/bootstrap_guard.sh``, which
## is driven here against staged fixture trees — no build required, and the
## fixtures are synthesized headers rather than copies of a 36 MB binary.
##
## Each case below records, in its own name and checkpoints, WHICH platform
## it discriminates the fix on. That is deliberate: the extension half of
## the defect is Windows-only (on Linux ``build/bin/repro`` already IS the
## host artefact), while the machine-format half bites both ways — a PE
## sitting at ``build/bin/repro`` made the pre-fix guard skip on LINUX.

import std/[os, strutils, times, unittest]

import repro_test_support

const GuardScript = ReprobuildRepoRoot / "scripts" / "bootstrap_guard.sh"

proc bashExe(): string =
  let found = findExe("bash")
  doAssert found.len > 0,
    "bash is required to drive scripts/bootstrap_guard.sh; the Justfile " &
    "runs every recipe under `set shell := [\"bash\", …]`, so a host " &
    "without it cannot run `just bootstrap` either."
  found

proc guard(args: varargs[string]): CmdResult =
  ## Run the guard script. ``doAssert`` (never ``check``) in this helper:
  ## the Windows toolchain pin is stock Nim 2.2.8, where a ``check`` outside
  ## a ``test`` body prints its failure and the case still reports ``[OK]``.
  var argv = @[bashExe(), GuardScript]
  for a in args: argv.add(a)
  result = runShell(shellCommand(argv), ReprobuildRepoRoot)
  doAssert result.code == 0,
    "bootstrap_guard.sh " & $(@args) & " exited " & $result.code &
    ": " & result.output

# ---------------------------------------------------------------------------
# Fixture construction
# ---------------------------------------------------------------------------

const
  ElfHeader = "\x7FELF\x02\x01\x01\x00"
  ## Enough of an ELF64 identification block to classify; nothing executes it.

proc peImage(): string =
  ## A minimal but STRUCTURALLY VALID PE: ``MZ``, a little-endian
  ## ``e_lfanew`` at 0x3C pointing at 0x40, and ``PE\0\0`` there. A bare
  ## ``MZ`` must not be accepted (see the "stub" case below), which is why
  ## this is built rather than being two bytes.
  var s = newString(0x44)
  for i in 0 ..< s.len: s[i] = '\0'
  s[0] = 'M'
  s[1] = 'Z'
  s[0x3C] = '\x40'
  s[0x40] = 'P'
  s[0x41] = 'E'
  result = s

proc hostImage(): string =
  when defined(windows): peImage()
  elif defined(macosx): "\xCF\xFA\xED\xFE" & newString(60)
  else: ElfHeader & newString(56)

proc foreignImage(): string =
  ## The image the OTHER platform leaves in the shared ``build/`` tree.
  when defined(windows): ElfHeader & newString(56)
  else: peImage()

const
  HostBinName = "repro".addFileExt(ExeExt)
  ForeignBinName = when defined(windows): "repro" else: "repro.exe"

proc stage(path, bytes: string; executable: bool) =
  createDir(path.parentDir())
  writeFile(path, bytes)
  when defined(posix):
    if executable:
      setFilePermissions(path,
        {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpGroupExec,
         fpOthersRead, fpOthersExec})
    else:
      setFilePermissions(path, {fpUserRead, fpUserWrite, fpGroupRead,
        fpOthersRead})
  else:
    # On Windows there is no mode bit to set: MSYS2/Git Bash mounts here are
    # ``noacl``, so ``-x`` is derived from the DOS attributes plus a magic
    # sniff — a ``.exe`` name, an ``MZ`` header or a ``#!`` line read as
    # executable and an ELF header does not. That is exactly the asymmetry
    # the defect lived in, so the fixtures reproduce it by CONTENT rather
    # than trying (and silently failing) to chmod.
    discard executable

proc touchAt(path: string; secondsAgo: int) =
  let t = getTime() + initDuration(seconds = -secondsAgo)
  setLastModificationTime(path, t)

proc newFixtureRoot(slug: string): string =
  result = getTempDir() / ("w15-guard-" & slug & "-" & testCaseScratchSlug())
  removeDirEventually(result)
  createDir(result)
  # The guard's source roots. Only the ones that exist are searched, so a
  # fixture needs just enough of them to make the freshness clause reachable.
  createDir(result / "apps")
  writeFile(result / "apps" / "entrypoints.txt", "repro\n")
  writeFile(result / "repro.nim", "# fixture\n")
  createDir(result / "build" / "bin")

proc ageSources(root: string; secondsAgo: int) =
  touchAt(root / "apps" / "entrypoints.txt", secondsAgo)
  touchAt(root / "repro.nim", secondsAgo)

proc decisionFor(root: string): string =
  guard("decide", root).output.strip()

suite "W15 bootstrap guard":

  test "the guard classifies machine formats by magic, not by name":
    let root = newFixtureRoot("format")
    defer: removeDirEventually(root)
    stage(root / "elf-blob", ElfHeader & newString(56), false)
    stage(root / "pe-blob.exe", peImage(), true)
    stage(root / "macho-blob", "\xCF\xFA\xED\xFE" & newString(60), false)
    stage(root / "mz-stub", "MZ" & newString(64), false)
    stage(root / "plain.txt", "not an executable at all\n", false)

    check guard("format", root / "elf-blob").output.strip() == "elf"
    check guard("format", root / "pe-blob.exe").output.strip() == "pe"
    check guard("format", root / "macho-blob").output.strip() == "macho"
    # A DOS stub is two right bytes and no PE signature. Accepting it would
    # make the format check a name check wearing a disguise.
    check guard("format", root / "mz-stub").output.strip() == "unknown"
    check guard("format", root / "plain.txt").output.strip() == "unknown"
    check guard("format", root / "absent").output.strip() == "missing"

    # The script and the Nim helper must agree, because the shell guard and
    # the test suite are two consumers of ONE property.
    check binaryFormatOf(root / "elf-blob") == hbfElf
    check binaryFormatOf(root / "pe-blob.exe") == hbfPe
    check binaryFormatOf(root / "macho-blob") == hbfMachO
    check binaryFormatOf(root / "mz-stub") == hbfUnknown
    check binaryFormatOf(root / "plain.txt") == hbfUnknown
    check binaryFormatOf(root / "absent") == hbfMissing

  test "host-exe and host-format agree with the running test binary":
    # An independent witness that needs no build: the binary executing this
    # case is, necessarily, of the host's machine format.
    let selfFormat = guard("format", getAppFilename()).output.strip()
    let hostFormat = guard("host-format").output.strip()
    checkpoint("self=" & getAppFilename() & " format=" & selfFormat)
    check selfFormat == hostFormat
    check guard("host-exe", "repro").output.strip() == HostBinName

  test "an artefact at the OTHER platform's name does not satisfy the guard":
    ## Discriminates the fix on WINDOWS. Pre-fix the guard tested
    ## ``-x ./build/bin/repro``; on Windows that is the foreign name, and
    ## an extension-less ``MZ`` image, a ``#!`` file or a directory sitting
    ## there is all ``-x`` under MSYS2's magic sniff, so the guard answers
    ## "already built" and ``repro.exe`` is never produced.
    ##
    ## NOT attributed to the two ``test-logs/s2-full*.log:20`` "already
    ## exists; skipping bootstrap" lines: those are explained without any
    ## artefact at that path at all, because MSYS2/Cygwin resolves an
    ## extension-less name to a sibling ``.exe`` when no exact match
    ## exists — so with only ``repro.exe`` on disk the pre-fix guard skips,
    ## correctly, by accident. Measured both ways; see W15.
    let root = newFixtureRoot("foreign-name")
    defer: removeDirEventually(root)
    ageSources(root, 600)
    # Host-format bytes at the FOREIGN name — the shape that fools a guard
    # which trusts ``-x`` and a name.
    stage(root / "build" / "bin" / ForeignBinName, hostImage(), true)
    let decision = decisionFor(root)
    checkpoint("decision = " & decision)
    check decision.startsWith("bootstrap")
    check "missing:" in decision
    check HostBinName in decision

  test "the wrong machine format at the host's own name forces a rebuild":
    ## Discriminates the fix on LINUX. Pre-fix, a Windows PE left at
    ## ``build/bin/repro`` by a shared checkout satisfied ``-x`` and the
    ## freshness ``find``, so ``build_apps.sh`` never ran and everything
    ## downstream executed a binary the kernel cannot load.
    let root = newFixtureRoot("wrong-format")
    defer: removeDirEventually(root)
    ageSources(root, 600)
    stage(root / "build" / "bin" / HostBinName, foreignImage(), true)
    let decision = decisionFor(root)
    checkpoint("decision = " & decision)
    check decision.startsWith("bootstrap")
    check "wrong-format:" in decision

  test "freshness is measured against the host artefact, not the other one":
    ## Discriminates the fix on WINDOWS. The pre-fix ``elif`` compared
    ## source mtimes against ``./build/bin/repro``; with a newer artefact of
    ## the other platform sitting there, a genuinely stale ``repro.exe``
    ## looked fresh.
    let root = newFixtureRoot("stale")
    defer: removeDirEventually(root)
    # host artefact oldest, then the source, then the foreign artefact
    stage(root / "build" / "bin" / HostBinName, hostImage(), true)
    touchAt(root / "build" / "bin" / HostBinName, 900)
    ageSources(root, 600)
    stage(root / "build" / "bin" / ForeignBinName, hostImage(), true)
    touchAt(root / "build" / "bin" / ForeignBinName, 60)
    let decision = decisionFor(root)
    checkpoint("decision = " & decision)
    check decision.startsWith("bootstrap")
    check "stale:" in decision

  test "a fresh host artefact skips, and the other platform's cannot change that":
    ## Discriminates the fix on WINDOWS in the OPPOSITE direction, and this
    ## is the state this checkout is in today: because the ELF at
    ## ``build/bin/repro`` is not ``-x`` under MSYS2's ``noacl`` mounts —
    ## and its presence also defeats the ``.exe`` name fallback that used
    ## to make the wrong spelling work — the pre-fix guard answers "needs
    ## bootstrap" every single time, so ``just bootstrap`` stopped being
    ## idempotent on Windows the moment a shared-tree ELF landed there.
    let root = newFixtureRoot("fresh")
    defer: removeDirEventually(root)
    ageSources(root, 600)
    stage(root / "build" / "bin" / HostBinName, hostImage(), true)
    touchAt(root / "build" / "bin" / HostBinName, 60)
    let before = decisionFor(root)
    checkpoint("without the other platform's artefact: " & before)
    check before.startsWith("skip")

    # Now drop the other platform's artefact beside it, NEWER than everything.
    stage(root / "build" / "bin" / ForeignBinName, foreignImage(), true)
    let after = decisionFor(root)
    checkpoint("with the other platform's artefact: " & after)
    check after.startsWith("skip")
    check after == before

  test "a missing artefact still bootstraps":
    let root = newFixtureRoot("empty")
    defer: removeDirEventually(root)
    ageSources(root, 600)
    let decision = decisionFor(root)
    checkpoint("decision = " & decision)
    check decision.startsWith("bootstrap")
    check "missing:" in decision

  test "the Justfile recipe delegates to the guard and keeps no copy of it":
    ## Structural audit. The defect was an inline guard; a fix that leaves
    ## the inline form reachable is a fix that can drift back.
    let justfile = readFile(ReprobuildRepoRoot / "Justfile")
    let start = justfile.find("\nbootstrap:\n")
    check start >= 0
    var stop = justfile.find("\n\n", start + 1)
    if stop < 0: stop = justfile.len
    let recipe = justfile[start ..< stop]
    checkpoint(recipe)
    check "scripts/bootstrap_guard.sh" in recipe
    # The extension-less spellings must not survive anywhere in the recipe.
    check not recipe.contains("-x ./build/bin/repro ")
    check not recipe.contains("-newer ./build/bin/repro ")
    # And the guard script must be the only place that decides.
    check not recipe.contains("needs_bootstrap")

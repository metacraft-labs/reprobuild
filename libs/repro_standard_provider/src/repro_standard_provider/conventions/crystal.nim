## Crystal language convention (Tier 2b) — M60.
##
## Crystal is an LLVM-based statically compiled language. The compiler
## (``crystal``) performs whole-program analysis for type inference, so
## a per-source ``-c`` DAG analogous to ``c-cpp-direct`` /
## ``fortran-direct`` / ``pascal-direct`` is NOT possible. The
## convention therefore emits ONE ``crystal build`` action per declared
## executable — Mode 3 is intentionally "monolithic".
##
## **Two modes from a single convention** (Option A per the M60
## hand-off). The convention's ``recognize`` fires on the presence of
## ``.cr`` sources + ``uses:`` naming a Crystal toolchain token, then
## inspects the workspace root for ``shard.yml`` to decide between:
##
##   * **Mode 2 (shards-managed)** — ``shard.yml`` present at the
##     workspace root. Hard precondition: ``shard.lock`` must also be
##     present (mirrors M42 csharp-dotnet / M55 haskell-cabal / M56
##     ruby-bundler / M57 php-composer lockfile-required pattern; the
##     reprobuild offline + reproducibility guarantee). The convention
##     emits a chained ``shards install --production --skip-postinstall``
##     followed by a single ``crystal build`` per executable.
##
##   * **Mode 3 (pure source, no shards)** — no ``shard.yml`` at the
##     workspace root. The convention emits a single ``crystal build``
##     per declared executable directly. No dependency-manager step.
##     Crystal's stdlib is always available; Mode 3 fixtures are
##     stdlib-only by spec scope-down.
##
## **Recognition contract**:
##   * ``<projectRoot>/repro.nim`` (or legacy ``reprobuild.nim``) exists
##     AND ``uses:`` lists a Crystal toolchain token. Recognised
##     tokens: ``crystal`` / ``shards``.
##   * at least one ``executable`` member declared (library targets
##     are DEFERRED to a follow-up M — Crystal libraries are
##     unusual; ``shards`` distributes source-only packages).
##   * ``crystal`` is on PATH at convention-emit time.
##   * **Mode 2 additionally** requires ``shard.yml`` AND ``shard.lock``
##     at the project root AND ``shards`` on PATH.
##   * If ``shard.yml`` is present but ``shard.lock`` is missing,
##     ``recognize`` returns false (the strict precondition pattern —
##     mirrors M42 / M55 / M56 / M57). The user must run ``shards
##     install`` once with network access to populate the lockfile
##     before reprobuild can dispatch the convention.
##
## **Emitted actions**:
##
##   Mode 2 (shards-managed) per executable ``<name>``:
##     1. ``crystal-shards-install-<name>`` — single ``shards install
##        --production --skip-postinstall`` action. Output: a sentinel
##        ``<root>/.repro/build/<name>/shards.stamp`` file (the
##        convention writes a stamp to keep cache invalidation working
##        — ``shards`` itself doesn't expose a single canonical
##        artefact).
##     2. ``crystal-shards-build-<name>`` — ``crystal build
##        src/<entry>.cr -o <out> --release --no-debug``. ``deps``
##        includes the install action; ``inputs`` include every ``.cr``
##        source under the project root (excluding ``lib/`` / ``.repro/``
##        / ``.git/``).
##
##   Mode 3 (pure source) per executable ``<name>``:
##     1. ``crystal-direct-build-<name>`` — ``crystal build
##        src/<entry>.cr -o <out> --release --no-debug``. Single
##        monolithic action; no install step. ``inputs`` include every
##        ``.cr`` source under the project root.
##
## **Output paths**:
##   * Executable: ``<projectRoot>/.repro/build/<name>/<name>[.exe]``.
##     The canonical scratch schema shared with the other Mode 3
##     conventions. ``.exe`` suffix on Windows; no suffix on POSIX.
##   * Mode 2 stamp file: ``<projectRoot>/.repro/build/<name>/shards.stamp``.
##
## **Entry-source resolution**:
##   * Layout A — ``<projectRoot>/src/<name>.cr``, ``<projectRoot>/src/main.cr``.
##   * Layout B — ``<projectRoot>/<name>/src/<name>.cr``,
##     ``<projectRoot>/<name>/src/main.cr``.
##   * The convention searches Layout A first (the canonical Crystal
##     layout — ``shards init`` produces ``src/<name>.cr``); falls back
##     to Layout B for multi-package workspaces.
##
## **Honest scope** (deferred per M60 spec):
##   * **Per-source Mode 3 DAG** — explicitly DEFERRED. Crystal's
##     whole-program analysis (type inference across the entire
##     compilation unit) prevents per-source ``-c`` compilation. The
##     convention emits ONE ``crystal build`` per executable; finer
##     granularity is impossible until Crystal grows a
##     ``-c``-equivalent flag.
##   * **Library targets** (``crystal build --emit obj`` + ``ar rcs``)
##     — DEFERRED. Crystal libraries are unusual (``shards``
##     distributes source-only packages that consumers re-compile from
##     scratch); the standard ``.cr`` distribution model doesn't map to
##     the staticlib pattern the other Mode 3 conventions use. M60
##     supports executables only.
##   * **Cross-language with C/C++** (``lib LibFoo`` FFI bindings) —
##     DEFERRED. Crystal can bind to C archives via ``lib LibFoo`` blocks
##     and ``--link-flags="-L<dir> <archive>"`` BUT M60 keeps the fixture
##     pure-Crystal per the honest-scope cut. A follow-up M may add a
##     cross-language sibling.
##   * **``require`` scanner** — DEFERRED. Cross-package edges are
##     hand-authored as ``depends_on`` in ``repro.nim``.
##   * **Crystal Windows port** — the upstream Crystal Windows binary
##     is preview-quality (signal handling / fork broken). M60
##     fixtures SKIP cleanly when ``crystal`` isn't on PATH; running on
##     a non-Windows host or via WSL is the expected production path.
##   * **``crystal spec``** discovery (test-target) — DEFERRED to a
##     follow-up M (mirrors M40 / M41 / M42 / M43 / M46 / M55 deferral
##     of test-task discovery).
##
## **Provisioning note**: on a development host that doesn't ship
## Crystal (the M60 default on Windows — the dev shell doesn't
## currently bundle Crystal), the canonical install paths are:
##   * scoop: ``scoop install crystal`` (the ``main`` bucket carries
##     ``crystal 1.20.2`` as of the M60 milestone).
##   * MSYS2: ``pacman -S mingw-w64-x86_64-crystal`` (when available
##     in the local pacman repo).
##   * Manual download of ``crystal-<ver>-windows-x86_64.zip`` from
##     ``https://github.com/crystal-lang/crystal/releases`` unpacked
##     under ``D:/metacraft-dev-deps/crystal/`` and the resulting
##     ``bin/`` prepended to PATH. ``shards`` is bundled with the
##     Crystal distribution so no separate install step is needed.
##
## env.ps1 doesn't yet provision Crystal; a follow-up provisioning
## milestone (deferred per the M60 honest-scope cut) will add a
## ``windows/ensure-crystal.ps1`` script.
##
## See ``reprobuild-specs/Provisioning-And-Languages-Expansion.milestones.org`` §M60.

import std/[algorithm, os, strutils]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention

const
  ScratchDirName* = ".repro/build"
    ## Top-level scratch directory under the project root. Identical to
    ## every other Mode 3 convention so a single ``rm -rf .repro/``
    ## sweeps all outputs.

  CrystalToolchainTokens = ["crystal", "shards"]
    ## ``uses:`` tokens that mark a workspace as Crystal-flavoured. The
    ## convention accepts either — ``crystal`` is the compiler driver,
    ## ``shards`` is the package manager (which transitively requires
    ## ``crystal``).

type
  CrystalMemberKind = enum
    cmkExecutable
    cmkLibrary
      ## Reserved for future use; the convention rejects library
      ## members at emit time today (DEFERRED per M60 honest-scope).

  CrystalMember = object
    name: string
    kind: CrystalMemberKind

  CrystalMode* = enum
    cmShards   ## Mode 2 — ``shard.yml`` present.
    cmDirect   ## Mode 3 — no ``shard.yml``.

  CrystalEmitTarget = object
    member: CrystalMember
    srcDir: string
    entrySource: string
    sourceFiles: seq[string]

proc readReprobuildSource(projectRoot: string): string =
  ## Read the project file (``repro.nim`` or legacy ``reprobuild.nim``).
  let match = resolveProjectFile(projectRoot)
  if match.path.len == 0:
    return ""
  try:
    readFile(extendedPath(match.path))
  except CatchableError:
    ""

proc isCrystalToolchainToken(token: string): bool =
  for entry in CrystalToolchainTokens:
    if token == entry:
      return true
  false

proc usesIncludesCrystal*(source: string): bool =
  ## True when ``uses:`` names a Crystal toolchain token
  ## (``crystal`` / ``shards``). Single-token accept pattern mirroring
  ## M30 Rust's ``rust``-or-``cargo``, M56 ruby-bundler's
  ## ``ruby``-or-``bundler``, and M57 php-composer's
  ## ``php``-or-``composer`` patterns.
  if source.len == 0:
    return false
  var sawCrystal = false
  var inBlock = false
  proc consume(token: string) {.closure.} =
    if isCrystalToolchainToken(token):
      sawCrystal = true
  for rawLine in source.splitLines():
    var line = rawLine
    let commentIdx = line.find('#')
    if commentIdx >= 0:
      line = line[0 ..< commentIdx]
    let stripped = line.strip()
    if stripped.len == 0:
      if inBlock:
        inBlock = false
      continue
    if inBlock:
      let leading = line.len > 0 and line[0] in {' ', '\t'}
      if not leading:
        inBlock = false
      else:
        for raw in stripped.split({',', ' ', '\t'}):
          let entry = raw.strip(chars = {' ', '\t', '"', '\'', ',', ';'})
          if entry.len == 0:
            continue
          let firstToken = entry.split({' ', '\t', '>', '<', '='})[0]
          consume(firstToken)
        continue
    if stripped.startsWith("uses:"):
      let payload = stripped[5 .. ^1].strip()
      if payload.len == 0:
        inBlock = true
      else:
        var clean = payload
        if clean.startsWith("["):
          clean = clean[1 .. ^1]
        if clean.endsWith("]"):
          clean = clean[0 ..< ^1]
        for raw in clean.split({',', ' ', '\t'}):
          let entry = raw.strip(chars = {' ', '\t', '"', '\'', ',', ';'})
          if entry.len == 0:
            continue
          let firstToken = entry.split({' ', '\t', '>', '<', '='})[0]
          consume(firstToken)
  sawCrystal

proc extractExecutables(source: string): seq[string] =
  for rawLine in source.splitLines():
    var line = rawLine
    let commentIdx = line.find('#')
    if commentIdx >= 0:
      line = line[0 ..< commentIdx]
    let stripped = line.strip()
    if not stripped.startsWith("executable"):
      continue
    if stripped.len > len("executable") and
        stripped[len("executable")] notin {' ', '\t'}:
      continue
    let rest = stripped[len("executable") .. ^1].strip()
    if rest.len == 0:
      continue
    var name = ""
    for ch in rest:
      if ch in {' ', '\t', ':', ','}:
        break
      name.add(ch)
    if name.len > 0:
      result.add(name)

proc extractLibraries(source: string): seq[string] =
  for rawLine in source.splitLines():
    var line = rawLine
    let commentIdx = line.find('#')
    if commentIdx >= 0:
      line = line[0 ..< commentIdx]
    let stripped = line.strip()
    if not stripped.startsWith("library"):
      continue
    if stripped.len > len("library") and
        stripped[len("library")] notin {' ', '\t'}:
      continue
    let rest = stripped[len("library") .. ^1].strip()
    if rest.len == 0:
      continue
    var name = ""
    for ch in rest:
      if ch in {' ', '\t', ':', ','}:
        break
      name.add(ch)
    if name.len > 0:
      result.add(name)

proc extractMembers(source: string): seq[CrystalMember] =
  for name in extractExecutables(source):
    result.add(CrystalMember(name: name, kind: cmkExecutable))
  for name in extractLibraries(source):
    result.add(CrystalMember(name: name, kind: cmkLibrary))

proc hasShardYml*(projectRoot: string): bool =
  ## True when ``<projectRoot>/shard.yml`` exists. Signals Mode 2
  ## (shards-managed) recognition.
  fileExists(extendedPath(projectRoot / "shard.yml"))

proc hasShardLock*(projectRoot: string): bool =
  ## True when ``<projectRoot>/shard.lock`` exists. The HARD
  ## precondition for Mode 2 — mirrors M42 / M55 / M56 / M57 lockfile
  ## requirement.
  fileExists(extendedPath(projectRoot / "shard.lock"))

proc detectMode*(projectRoot: string): CrystalMode =
  ## Mode 2 (shards-managed) when ``shard.yml`` is at the root; Mode 3
  ## (pure source) otherwise.
  if hasShardYml(projectRoot):
    cmShards
  else:
    cmDirect

proc crystalExecutable*(): string =
  ## Resolve a ``crystal`` driver on PATH.
  findExe("crystal")

proc shardsExecutable*(): string =
  ## Resolve a ``shards`` driver on PATH. ``shards`` is bundled with the
  ## Crystal distribution but the convention probes for it explicitly
  ## for Mode 2 dispatch.
  findExe("shards")

proc isCrystalSourceFile*(path: string): bool =
  path.toLowerAscii.endsWith(".cr")

proc dirHasCrystalSources(dir: string): bool =
  if not dirExists(extendedPath(dir)):
    return false
  for path in walkDirRec(dir):
    if isCrystalSourceFile(path):
      return true
  false

proc findEntrySource(dir, stem: string): string =
  ## Look for ``<dir>/<stem>.cr`` first, then fall back to
  ## ``<dir>/main.cr`` for the canonical executable layout.
  let memberCand = dir / (stem & ".cr")
  if fileExists(extendedPath(memberCand)):
    return memberCand
  let mainCand = dir / "main.cr"
  if fileExists(extendedPath(mainCand)):
    return mainCand
  ""

proc resolveCrystalMemberDirs(projectRoot, memberName: string):
    tuple[srcDir: string; entrySource: string] =
  ## Layout A first (``<root>/src/<name>.cr`` or ``<root>/src/main.cr``),
  ## then Layout B (``<root>/<member>/src/<name>.cr`` etc.). Crystal's
  ## canonical project shape is ``src/<name>.cr`` (the ``shards init``
  ## default) so Layout A is preferred.
  let candidatesA = projectRoot / "src"
  if dirHasCrystalSources(candidatesA):
    let entryA = findEntrySource(candidatesA, memberName)
    if entryA.len > 0:
      return (srcDir: candidatesA, entrySource: entryA)
    for path in walkDirRec(candidatesA):
      if isCrystalSourceFile(path):
        return (srcDir: candidatesA, entrySource: path)
  let candidatesB = projectRoot / memberName / "src"
  if dirHasCrystalSources(candidatesB):
    let entryB = findEntrySource(candidatesB, memberName)
    if entryB.len > 0:
      return (srcDir: candidatesB, entrySource: entryB)
    for path in walkDirRec(candidatesB):
      if isCrystalSourceFile(path):
        return (srcDir: candidatesB, entrySource: path)
  (srcDir: "", entrySource: "")

proc collectCrystalSources*(projectRoot: string): seq[string] =
  ## Conservative input enumeration: every ``.cr`` file under the
  ## project root, excluding ``lib/`` (the ``shards install`` output
  ## dir — its contents change every install and would cause spurious
  ## cache misses), ``.repro/`` (our own scratch dir), and ``.git/``.
  if not dirExists(extendedPath(projectRoot)):
    return @[]
  proc shouldSkipDir(name: string): bool =
    let lower = name.toLowerAscii
    lower in ["lib", ".repro", ".git", "node_modules", ".shards"]
  var stack: seq[string] = @[projectRoot]
  while stack.len > 0:
    let cur = stack[^1]
    stack.setLen(stack.len - 1)
    try:
      for kind, path in walkDir(cur):
        let basename = extractFilename(path)
        case kind
        of pcFile, pcLinkToFile:
          if isCrystalSourceFile(basename):
            result.add(path)
        of pcDir, pcLinkToDir:
          if shouldSkipDir(basename):
            continue
          stack.add(path)
    except OSError:
      discard
  result.sort(system.cmp[string])

proc resolveTarget(projectRoot: string; member: CrystalMember):
    CrystalEmitTarget =
  result.member = member
  let resolved = resolveCrystalMemberDirs(projectRoot, member.name)
  if resolved.srcDir.len == 0:
    return
  result.srcDir = resolved.srcDir
  result.entrySource = resolved.entrySource
  result.sourceFiles = collectCrystalSources(projectRoot)

proc crystalRecognize(projectRoot: string;
                      request: ProviderGraphRequest): bool {.gcsafe.} =
  ## Recognition contract — see module docstring.
  let source = readReprobuildSource(projectRoot)
  if source.len == 0:
    return false
  if not usesIncludesCrystal(source):
    return false
  let members = extractMembers(source)
  if members.len == 0:
    return false
  # At least one executable required (libraries are deferred at emit
  # time).
  var sawExecutable = false
  for m in members:
    if m.kind == cmkExecutable:
      sawExecutable = true
      break
  if not sawExecutable:
    return false
  if crystalExecutable().len == 0:
    return false
  let mode = detectMode(projectRoot)
  case mode
  of cmShards:
    # HARD precondition: ``shard.lock`` must be present.
    if not hasShardLock(projectRoot):
      return false
    if shardsExecutable().len == 0:
      return false
  of cmDirect:
    discard
  # At least one declared executable must resolve to a Crystal source
  # layout (otherwise the emit would fail anyway and surfacing the
  # rejection at ``recognize`` time is more helpful).
  var atLeastOneResolved = false
  for m in members:
    if m.kind != cmkExecutable:
      continue
    let resolved = resolveCrystalMemberDirs(projectRoot, m.name)
    if resolved.entrySource.len > 0:
      atLeastOneResolved = true
      break
  atLeastOneResolved

proc sanitizeNamePart(value: string): string =
  for ch in value:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = "x"

proc scratchPathFor(projectRoot, member: string): string =
  projectRoot / ScratchDirName / member

proc binaryPathFor(projectRoot, member: string): string =
  when defined(windows):
    scratchPathFor(projectRoot, member) / (member & ".exe")
  else:
    scratchPathFor(projectRoot, member) / member

proc shardsStampPathFor(projectRoot, member: string): string =
  scratchPathFor(projectRoot, member) / "shards.stamp"

proc emitShardsInstallAction(projectRoot, shardsExe: string;
                             member: CrystalMember;
                             sourceFiles: seq[string]): BuildActionDef =
  ## ``shards install --production --skip-postinstall`` chained
  ## (logically) before the ``crystal build`` action. We emit a
  ## per-executable install action because ``shards`` outputs nothing
  ## under our scratch tree — it writes to ``<root>/lib/`` directly —
  ## so we write a sentinel stamp under
  ## ``<root>/.repro/build/<name>/shards.stamp`` via ``cmd /c`` (a
  ## simple touch-style action) bundled into the same step.
  ##
  ## Implementation: a single composite ``cmd /c`` action that runs
  ## ``shards install`` and on success writes the stamp file. Mirrors
  ## the M56 ruby-bundler ``cmd /c`` wrapper pattern for the same
  ## "package manager has no canonical artefact" reason.
  let stamp = shardsStampPathFor(projectRoot, member.name)
  createDir(extendedPath(parentDir(stamp)))
  # Use ``cmd /c`` on Windows; ``sh -c`` on POSIX. The action shape is
  # the same: run shards install, then write the stamp.
  var argv: seq[string]
  when defined(windows):
    argv = @["cmd", "/c",
      shardsExe & " install --production --skip-postinstall && " &
      "echo. > \"" & stamp & "\""]
  else:
    argv = @["sh", "-c",
      shardsExe & " install --production --skip-postinstall && " &
      "touch '" & stamp & "'"]
  # Inputs: the shard.yml + shard.lock manifest pair (they drive the
  # install). The ``lib/`` output directory is intentionally NOT
  # declared as an output — the engine doesn't need to invalidate on
  # individual ``lib/`` files; ``shard.lock`` changes alone signal a
  # re-resolve.
  var inputs: seq[string] = @[]
  let shardYml = projectRoot / "shard.yml"
  let shardLock = projectRoot / "shard.lock"
  if fileExists(extendedPath(shardYml)):
    inputs.add(shardYml)
  if fileExists(extendedPath(shardLock)):
    inputs.add(shardLock)
  buildAction(
    id = "crystal-shards-install-" & sanitizeNamePart(member.name),
    call = inlineExecCall(argv, projectRoot),
    inputs = inputs,
    outputs = @[stamp],
    pool = "compile",
    # ``shards install`` spawns git / curl subprocesses whose FS reads
    # aren't reliably observed via Windows DLL-interpose. Same pattern
    # as M40 / M41 / M42 / M43 / M46 / M55 / M56 / M57 conventions.
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "crystal.shards.install")

proc emitBuildAction(projectRoot, crystalExe: string;
                     member: CrystalMember;
                     target: CrystalEmitTarget;
                     mode: CrystalMode;
                     installActionId: string): BuildActionDef =
  ## Single ``crystal build <entry> -o <out> --release --no-debug``
  ## action per executable. The same shape in both Mode 2 and Mode 3 —
  ## only the ``deps`` differ (Mode 2 includes the install stamp).
  let outputPath = binaryPathFor(projectRoot, member.name)
  createDir(extendedPath(parentDir(outputPath)))
  var argv = @[crystalExe, "build",
    target.entrySource,
    "-o", outputPath,
    "--release", "--no-debug"]
  var inputs = target.sourceFiles
  if mode == cmShards:
    let stamp = shardsStampPathFor(projectRoot, member.name)
    if inputs.find(stamp) < 0:
      inputs.add(stamp)
  var deps: seq[string] = @[]
  if mode == cmShards and installActionId.len > 0:
    deps.add(installActionId)
  let actionId =
    case mode
    of cmShards: "crystal-shards-build-" & sanitizeNamePart(member.name)
    of cmDirect: "crystal-direct-build-" & sanitizeNamePart(member.name)
  let statsId =
    case mode
    of cmShards: "crystal.shards.build"
    of cmDirect: "crystal.direct.build"
  buildAction(
    id = actionId,
    call = inlineExecCall(argv, projectRoot),
    deps = deps,
    inputs = inputs,
    outputs = @[outputPath],
    pool = "compile",
    # Crystal's whole-program analysis spawns its own compile pipeline
    # internally; the FS reads aren't reliably observed via Windows
    # DLL-interpose. ``declaredOnly`` policy + explicit ``inputs``
    # walk is the same pattern other Tier 2b conventions use.
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = statsId)

proc syntheticPackage(projectRoot: string;
                      members: seq[CrystalMember]): PackageDef =
  var name = "crystal_convention"
  if members.len > 0:
    name = sanitizeNamePart(members[0].name)
  let projectMatch = resolveProjectFile(projectRoot)
  let sourceFile =
    if projectMatch.path.len > 0: projectMatch.path
    else: projectRoot / LegacyProjectFileName
  PackageDef(
    packageName: name,
    sourceFile: sourceFile,
    hasDevEnv: false,
    devEnvBodyHash: "",
    toolUses: @[])

proc crystalEmitFragment(projectRoot: string;
                         request: ProviderGraphRequest):
                           GraphFragment {.gcsafe.} =
  ## Convention entry — emit per-executable build actions (plus the
  ## per-executable Mode 2 ``shards install`` prerequisite).
  {.cast(gcsafe).}:
    let source = readReprobuildSource(projectRoot)
    let allMembers = extractMembers(source)
    if allMembers.len == 0:
      let projectMatch = resolveProjectFile(projectRoot)
      let projectFile =
        if projectMatch.path.len > 0: projectMatch.path
        else: projectRoot / LegacyProjectFileName
      raise newException(ValueError,
        "crystal convention: no executable members declared in " &
          projectFile & " (M60 supports executable targets only — " &
          "library targets are deferred)")
    var execs: seq[CrystalMember] = @[]
    for m in allMembers:
      if m.kind == cmkExecutable:
        execs.add(m)
    if execs.len == 0:
      raise newException(ValueError,
        "crystal convention: no executable members declared — " &
          "M60 supports executables only (library targets are deferred)")
    let crystalExe = crystalExecutable()
    if crystalExe.len == 0:
      raise newException(ValueError,
        "crystal convention: 'crystal' not on PATH; cannot compile " &
          "Crystal sources (install via 'scoop install crystal' on " &
          "Windows, 'brew install crystal' on macOS, or download from " &
          "https://github.com/crystal-lang/crystal/releases)")
    let mode = detectMode(projectRoot)
    var shardsExe = ""
    if mode == cmShards:
      if not hasShardLock(projectRoot):
        raise newException(ValueError,
          "crystal convention (Mode 2 / shards): 'shard.lock' missing at " &
            projectRoot & " (HARD precondition — run 'shards install' " &
            "once with network access to populate the lockfile before " &
            "reprobuild can dispatch this convention; mirrors the M42 / " &
            "M55 / M56 / M57 lockfile-required pattern)")
      shardsExe = shardsExecutable()
      if shardsExe.len == 0:
        raise newException(ValueError,
          "crystal convention (Mode 2 / shards): 'shards' not on PATH " &
            "(shards is bundled with the Crystal distribution; install " &
            "Crystal via 'scoop install crystal' on Windows)")
    var targets: seq[CrystalEmitTarget] = @[]
    for m in execs:
      let target = resolveTarget(projectRoot, m)
      if target.entrySource.len == 0:
        raise newException(ValueError,
          "crystal convention: no Crystal source resolved for " &
            "executable '" & m.name & "' under " & projectRoot &
            " (looked for src/" & m.name & ".cr, src/main.cr, " &
            m.name & "/src/" & m.name & ".cr, " & m.name & "/src/main.cr)")
      targets.add(target)
    let pkg = syntheticPackage(projectRoot, execs)
    let registerAll = proc() =
      discard buildPool("compile", 8'u32)
      var allActions: seq[BuildActionDef] = @[]
      for target in targets:
        var installActionId = ""
        if mode == cmShards:
          let installAction = emitShardsInstallAction(projectRoot,
            shardsExe, target.member, target.sourceFiles)
          allActions.add(installAction)
          installActionId = installAction.id
        let buildAct = emitBuildAction(projectRoot, crystalExe,
          target.member, target, mode, installActionId)
        allActions.add(buildAct)
        discard target(target.member.name, allActions)
      if allActions.len > 0:
        defaultTarget(target("default", allActions))
    result = buildPackageFragment(pkg, request, registerAll,
      includeDefault = false)

proc crystalConvention*(): LanguageConvention =
  ## The single value the standard provider binary registers at
  ## startup. Registered AFTER ``pascal-direct`` per the M60 spec —
  ## the convention covers BOTH Mode 2 (shards-managed) AND Mode 3
  ## (pure source) Crystal workspaces via in-procedure mode detection.
  LanguageConvention(
    name: "crystal",
    recognize: crystalRecognize,
    emitFragment: crystalEmitFragment)

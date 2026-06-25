## Erlang / rebar3 language convention (Tier 2b) — M61.
##
## Seventh **Phase 2** language convention, immediately after M60
## crystal. Recognises a ``rebar.config`` Erlang term manifest at the
## project root and shells out to the stock ``rebar3`` driver for a
## single ``rebar3 escriptize`` invocation (which transitively runs
## ``rebar3 compile`` and then bundles the produced ``.beam`` files
## into a self-contained escript). Erlang is a BEAM bytecode VM so
## the "build" produces ``.beam`` files under
## ``_build/default/lib/<app>/ebin/`` plus an escript binary under
## ``_build/default/bin/<app>``; on Windows rebar3 additionally writes
## a ``_build/default/bin/<app>.cmd`` launcher script alongside the
## escript so the binary is invokable from cmd.exe / PowerShell
## without an explicit ``escript`` call.
##
## **Honest-scope cut — escriptize over release**. The original M61
## spec suggested ``rebar3 as prod release --include-erts true`` to
## ship a self-contained Erlang runtime (~50 MB ERTS bundled per
## release). The implementation deliberately picks the lighter
## ``rebar3 escriptize`` shape per the M61 hand-off's "pick simpler"
## directive — escriptize produces a single-file escript that depends
## on the host's Erlang runtime being on PATH (which the convention's
## ``recognize`` already gates on), avoiding the per-fixture
## ~50 MB / ~440 MB disk-footprint blowup release builds would
## cause. Real-world projects shipping standalone releases should opt
## into a future ``rebar3 release`` sibling convention (DEFERRED per
## the M61 honest-scope cut).
##
## **Recognition contract**:
##   * ``<projectRoot>/rebar.config`` exists (the rebar3 project manifest
##     filename — uniquely identifies a rebar3 project; no other
##     convention recognises this filename).
##   * ``<projectRoot>/rebar.lock`` exists (HARD precondition per the
##     M61 spec — mirrors M42 csharp-dotnet ``packages.lock.json``,
##     M55 haskell-cabal's ``cabal.project.freeze``, M56 ruby-bundler
##     ``Gemfile.lock``, M57 php-composer ``composer.lock``, M60
##     crystal-shards ``shard.lock`` strict-precondition pattern.
##     rebar3 always writes a ``rebar.lock`` on the first compile —
##     even for a zero-deps project, the lockfile is the empty term
##     ``[].`` — so requiring it at recognise time is a cheap
##     reproducibility gate).
##   * ``<projectRoot>/repro.nim`` (or legacy ``reprobuild.nim``) exists
##     AND ``uses:`` lists an Erlang/rebar3 token (``erlang`` / ``erl``
##     / ``rebar3``). rebar3 ships with Erlang/OTP in most distribution
##     channels (scoop ``rebar3`` pulls in OTP transitively; the
##     Adoptium-style Erlang Solutions installer bundles rebar3) so any
##     of the three tokens is acceptable — single-token accept pattern
##     mirroring M30 Rust's ``rust``-or-``cargo``, M56 ruby-bundler's
##     ``ruby``-or-``bundler``, M57 php-composer's ``php``-or-``composer``
##     and M60 crystal's ``crystal``-or-``shards`` patterns.
##   * at least one ``executable`` member declared (library / OTP
##     application targets are DEFERRED to a follow-up M — see Honest
##     scope below).
##   * an ``erl`` driver is on PATH (the Erlang runtime — required to
##     execute the escript the convention produces).
##   * a ``rebar3`` driver is on PATH (the rebar3 build tool — separate
##     from Erlang itself; rebar3 is a standalone escript distributed
##     either alongside Erlang/OTP or via ``scoop install rebar3`` on
##     Windows).
##
## **Offline mode** (M61 keeps builds hermetic):
##   * The action runs ``rebar3 escriptize``. Rebar3 honours the
##     ``rebar.lock`` for dependency resolution (it never re-resolves a
##     pinned version) but the *first* fetch of a Hex package still
##     touches the network. The M61 fixture has zero external dependencies
##     so the build runs fully offline.
##   * Real-world projects pulling external Hex packages should run
##     ``rebar3 get-deps`` (or equivalently a no-cache ``rebar3 compile``)
##     once with network access BEFORE invoking the convention to
##     populate the rebar3 hex cache (under ``~/.cache/rebar3/hex/``).
##     The convention itself never reaches the network when the cache
##     is warm — rebar3's offline path is implicit (it consults the
##     local cache and only escalates to the network on a cache miss).
##
## **Emitted actions**:
##   1. ``erlang-rebar3-escriptize-<name>`` — single ``<rebar3>
##      escriptize`` action under the project root per declared
##      executable. ``escriptize`` is rebar3-idempotent: subsequent
##      invocations are no-ops when nothing's changed under ``src/``,
##      so emitting one action per executable in a multi-executable
##      workspace is safe (rebar3 itself dedupes). Inputs: the
##      ``rebar.config`` + ``rebar.lock`` manifest pair plus every
##      ``.erl`` / ``.app.src`` / ``.hrl`` source file recursively
##      walked under the project root (excluding ``_build/`` /
##      ``.repro/`` / ``.git/``). Outputs:
##      ``<projectRoot>/_build/default/bin/<name>`` (the escript) plus,
##      on Windows, the sibling ``<name>.cmd`` launcher. Uses
##      ``automaticMonitorPolicy`` (automatic monitoring is the spec
##      baseline for opaque tools, Reprobuild-Development M17): ``rebar3``
##      spawns ``erl`` worker processes and the engine monitors their
##      real read-set instead of trusting only statically declared
##      inputs.
##
##   2. ``erlang-rebar3-wrapper-<name>`` — one ``fs.writeText`` action
##      per declared executable. Outputs:
##      ``<projectRoot>/.repro/build/<name>/<name>.cmd`` (Windows) or
##      ``<projectRoot>/.repro/build/<name>/<name>`` (POSIX). The
##      wrapper invokes the rebar3-produced escript (or its sibling
##      ``.cmd`` on Windows) so callers see the same
##      ``<root>/.repro/build/<name>/<name>[.cmd]`` launcher path as
##      every other Phase 2 Tier 2b convention (M55-M57 / M60). The
##      wrapper depends on the escriptize action so the produced escript
##      is guaranteed to exist before the launcher fires.
##
## **Entry-point resolution**:
##   * The M61 fixture pins the canonical rebar3 layout
##     (``src/<name>.app.src`` + ``src/<name>.erl`` exporting a
##     ``main/1`` callback). The escriptize action figures out the
##     entry module via the ``rebar.config`` ``{escript_main_app, ...}``
##     stanza — the convention itself doesn't parse rebar.config terms
##     (Erlang term parsing is non-trivial; deferred to a future M if
##     finer dispatch becomes necessary). The executable name in
##     ``repro.nim`` MUST match the OTP application name declared in
##     ``src/<name>.app.src`` for the produced escript path
##     ``_build/default/bin/<name>`` to align with the wrapper's
##     expected path.
##
## **Honest scope** (deferred per the M61 honest-scope cut):
##   * **``rebar3 release`` with ``--include-erts true``** — DEFERRED.
##     The original M61 spec called for release packaging (~50 MB
##     ERTS bundled per release; ~440 MB total dev-shell footprint
##     across the M9 harness fixtures). Picked escriptize instead per
##     the M61 hand-off's "pick the simpler" directive — escriptize is
##     a single-file artefact that depends on the host's ``erl`` (which
##     the convention's recognise already gates on).
##   * **erlang.mk sibling convention** — DEFERRED. The other major
##     Erlang build tool (``erlang.mk``) targets per-project Makefiles
##     and is uncommon outside the Cowboy/Ninenines ecosystem; the
##     standard provider focuses on rebar3 (the de-facto OTP tooling).
##   * **``rebar3 ct`` (Common Test) discovery** — DEFERRED to a
##     follow-up M (mirrors M40/M41/M42/M43/M46/M55/M56/M57/M60
##     test-task deferral).
##   * **OTP releases (``rebar3 release``)** — DEFERRED. See the
##     escriptize-vs-release note above.
##   * **NIFs (Erlang C API)** — DEFERRED. NIFs are runtime-loaded
##     shared libraries (``.so`` / ``.dll``) that don't fit the
##     archive-schema the obj+linker Mode 3 conventions use. Cross-
##     language Erlang↔C would need a separate FFI design.
##   * **Library targets** (OTP applications without an escript main)
##     — DEFERRED. M61 supports executables only; library-only OTP
##     applications are usually consumed via ``deps`` in another
##     project's ``rebar.config``, not built standalone.
##   * **External Hex deps** — the M61 fixture has zero deps; real-
##     world projects pulling Hex packages should warm rebar3's cache
##     once with network access before invoking the convention (mirrors
##     the haskell-cabal / ruby-bundler / php-composer cache-warm
##     pattern).
##
## **Provisioning note**: on a development host that doesn't ship
## Erlang+rebar3, the canonical install paths on Windows are:
##   * ``scoop install erlang`` (the ``main`` bucket carries Erlang/OTP
##     27.x+ as of mid-2025) and ``scoop install rebar3`` (the ``main``
##     bucket carries rebar3 3.27.x+). Both shims land under
##     ``%USERPROFILE%\scoop\shims\`` and resolve via PATH.
##   * Manual download of the Erlang/OTP Windows installer from
##     ``https://www.erlang.org/downloads`` plus the standalone
##     ``rebar3`` escript from ``https://s3.amazonaws.com/rebar3/rebar3``
##     (chmod +x; place on PATH; Windows users place ``rebar3.cmd``
##     alongside it).
##
## ``env.ps1`` doesn't yet provision Erlang+rebar3 dedicatedly (the
## scoop-managed install is the M61 default on Windows); a follow-up
## provisioning milestone (deferred per the M61 honest-scope cut) will
## add ``windows/ensure-erlang.ps1`` + ``windows/ensure-rebar3.ps1``
## modules. The convention SKIPs cleanly when either tool is missing.
##
## See ``reprobuild-specs/Provisioning-And-Languages-Expansion.milestones.org`` §M61.

import std/[algorithm, os, strutils]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention

const
  ScratchDirName* = ".repro/build"
    ## Top-level scratch directory under the project root for launcher
    ## shim emission. Mirrors the M40 / M41 / M42 / M43 / M46 / M55 /
    ## M56 / M57 / M60 conventions' value.

  RebarBuildSubdir* = "_build/default/bin"
    ## Rebar3's escriptize output directory. On Windows rebar3 writes
    ## ``<name>`` (the escript) plus ``<name>.cmd`` (the launcher).
    ## The convention treats the ``.cmd`` form as the canonical Windows
    ## artefact (it's directly invokable from cmd.exe / PowerShell
    ## without an ``escript`` prefix).

type
  ErlangRebar3MemberKind = enum
    erbmExecutable
    erbmLibrary

  ErlangRebar3Member = object
    name: string
    kind: ErlangRebar3MemberKind

proc readReprobuildSource(projectRoot: string): string =
  ## Read the project file (``repro.nim`` or legacy ``reprobuild.nim``)
  ## or return the empty string.
  let match = resolveProjectFile(projectRoot)
  if match.path.len == 0:
    return ""
  try:
    readFile(extendedPath(match.path))
  except CatchableError:
    ""

proc usesIncludesErlang*(source: string): bool =
  ## True when ``uses:`` lists an Erlang/rebar3 token (``erlang`` /
  ## ``erl`` / ``rebar3``). rebar3 ships alongside Erlang in most
  ## distribution channels so any single token is acceptable —
  ## single-token accept pattern mirroring M30 Rust's
  ## ``rust``-or-``cargo``, M56 ruby-bundler's ``ruby``-or-``bundler``,
  ## M57 php-composer's ``php``-or-``composer`` and M60 crystal's
  ## ``crystal``-or-``shards`` patterns.
  if source.len == 0:
    return false
  var sawErlang = false
  var inBlock = false
  proc consume(token: string) {.closure.} =
    if token == "erlang" or token == "erl" or token == "rebar3":
      sawErlang = true
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
  sawErlang

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

proc extractMembers(source: string): seq[ErlangRebar3Member] =
  for name in extractExecutables(source):
    result.add(ErlangRebar3Member(name: name, kind: erbmExecutable))
  for name in extractLibraries(source):
    result.add(ErlangRebar3Member(name: name, kind: erbmLibrary))

proc hasRebarConfig*(projectRoot: string): bool =
  ## True when ``<projectRoot>/rebar.config`` exists.
  fileExists(extendedPath(projectRoot / "rebar.config"))

proc hasRebarLock*(projectRoot: string): bool =
  ## True when ``<projectRoot>/rebar.lock`` exists. HARD precondition
  ## per the M61 spec — rebar3 always writes a ``rebar.lock`` on the
  ## first compile (even a zero-deps project gets ``[].`` as the
  ## lockfile), so requiring it at recognise time is a cheap
  ## reproducibility gate mirroring M42 / M55 / M56 / M57 / M60.
  fileExists(extendedPath(projectRoot / "rebar.lock"))

proc erlExecutable*(): string =
  ## Resolve an ``erl`` interpreter on PATH (the Erlang runtime).
  findExe("erl")

proc rebar3Executable*(): string =
  ## Resolve a ``rebar3`` driver on PATH. On Windows the canonical
  ## form is ``rebar3.cmd`` (scoop shim or standalone batch wrapper);
  ## ``findExe`` resolves both shapes via PATHEXT.
  findExe("rebar3")

proc sanitizeNamePart(value: string): string =
  for ch in value:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = "x"

proc erlangRebar3Recognize(projectRoot: string;
                           request: ProviderGraphRequest): bool {.gcsafe.} =
  ## Recognition contract — see module docstring.
  if not hasRebarConfig(projectRoot):
    return false
  if not hasRebarLock(projectRoot):
    # HARD precondition (M61 spec): the lockfile is rebar3's
    # reproducibility guarantee. The convention refuses to recognise
    # a project missing it; ``emitFragment`` raises with a clear
    # diagnostic on the off-chance recognise is bypassed.
    return false
  let source = readReprobuildSource(projectRoot)
  if source.len == 0:
    return false
  if not usesIncludesErlang(source):
    return false
  let members = extractMembers(source)
  if members.len == 0:
    return false
  # Only executables are supported in M61 — library-only projects
  # (OTP applications consumed via ``deps`` elsewhere) are deferred.
  var sawExecutable = false
  for m in members:
    if m.kind == erbmExecutable:
      sawExecutable = true
      break
  if not sawExecutable:
    return false
  if erlExecutable().len == 0:
    return false
  if rebar3Executable().len == 0:
    return false
  true

proc producedEscriptPath*(projectRoot, exeName: string): string =
  ## Predicted path of the rebar3-produced escript. On Windows rebar3
  ## additionally writes a sibling ``<exeName>.cmd`` launcher — see
  ## ``producedEscriptCmdPath`` below.
  projectRoot / RebarBuildSubdir / exeName

proc producedEscriptCmdPath*(projectRoot, exeName: string): string =
  ## Predicted path of the sibling ``<name>.cmd`` launcher rebar3
  ## writes on Windows. Returns the same path on POSIX (the file
  ## doesn't exist there — the convention's emit code only declares
  ## this output on Windows).
  projectRoot / RebarBuildSubdir / (exeName & ".cmd")

proc producedWrapperPath*(projectRoot, exeName: string): string =
  ## Predicted output path for the launcher wrapper script under the
  ## canonical ``<root>/.repro/build/<name>/<name>[.cmd]`` location.
  ## Mirrors the M55-M57 / M60 wrapper-path convention so callers see
  ## a stable launcher path regardless of the underlying ecosystem.
  when defined(windows):
    projectRoot / ScratchDirName / exeName / (exeName & ".cmd")
  else:
    projectRoot / ScratchDirName / exeName / exeName

proc renderWrapperScript(projectRoot, exeName: string): string =
  ## Build the launcher shim content. On Windows the wrapper calls
  ## the rebar3-produced ``_build/default/bin/<name>.cmd`` directly.
  ## On POSIX the wrapper invokes ``escript`` against
  ## ``_build/default/bin/<name>``.
  let escriptCmdPath = producedEscriptCmdPath(projectRoot, exeName)
  let escriptPath = producedEscriptPath(projectRoot, exeName)
  when defined(windows):
    var lines: seq[string] = @[]
    lines.add("@echo off")
    lines.add("setlocal")
    lines.add("cd /d \"" & projectRoot & "\"")
    # Invoke the rebar3-produced .cmd launcher; forward args.
    lines.add("call \"" & escriptCmdPath & "\" %*")
    lines.add("set \"WRAPPER_EXIT=%ERRORLEVEL%\"")
    lines.add("endlocal & exit /b %WRAPPER_EXIT%")
    return lines.join("\r\n") & "\r\n"
  else:
    var lines: seq[string] = @[]
    lines.add("#!/usr/bin/env sh")
    lines.add("set -e")
    lines.add("cd '" & projectRoot & "'")
    # POSIX path: invoke escript against the produced binary.
    lines.add("exec escript '" & escriptPath & "' \"$@\"")
    return lines.join("\n") & "\n"

proc collectErlangInputs(projectRoot: string): seq[string] =
  ## Conservative input enumeration for the escriptize action: the
  ## ``rebar.config`` + ``rebar.lock`` + every ``.erl`` / ``.hrl`` /
  ## ``.app.src`` / ``.app`` source file recursively walked under the
  ## project root (excluding ``_build/`` / ``.repro/`` / ``.git/`` /
  ## ``node_modules/``).
  if not dirExists(extendedPath(projectRoot)):
    return @[]
  for extra in @["rebar.config", "rebar.lock"]:
    let extraPath = projectRoot / extra
    if fileExists(extendedPath(extraPath)):
      result.add(extraPath)
  proc shouldSkipDir(name: string): bool =
    let lower = name.toLowerAscii
    lower in ["_build", ".repro", ".git", "node_modules", "deps"]
  var stack: seq[string] = @[projectRoot]
  while stack.len > 0:
    let cur = stack[^1]
    stack.setLen(stack.len - 1)
    try:
      for kind, path in walkDir(cur):
        let basename = extractFilename(path)
        case kind
        of pcFile, pcLinkToFile:
          let lower = basename.toLowerAscii
          if lower.endsWith(".erl") or lower.endsWith(".hrl") or
              lower.endsWith(".app.src") or lower.endsWith(".app"):
            result.add(path)
        of pcDir, pcLinkToDir:
          if shouldSkipDir(basename):
            continue
          stack.add(path)
    except OSError:
      discard
  # De-dup while preserving order.
  var seen: seq[string] = @[]
  for path in result:
    if path notin seen:
      seen.add(path)
  result = seen
  result.sort(system.cmp[string])

proc emitEscriptizeAction(projectRoot, rebar3Exe, exeName: string;
                          inputs: seq[string]): BuildActionDef =
  ## Emit the single ``rebar3 escriptize`` action under the project
  ## root for ``exeName``. The escript lands at
  ## ``<projectRoot>/_build/default/bin/<exeName>`` (plus a sibling
  ## ``<exeName>.cmd`` on Windows). ``escriptize`` transitively runs
  ## ``rebar3 compile`` so we don't need a separate compile step.
  let escriptPath = producedEscriptPath(projectRoot, exeName)
  let escriptCmdPath = producedEscriptCmdPath(projectRoot, exeName)
  createDir(extendedPath(parentDir(escriptPath)))
  var outputs: seq[string] = @[escriptPath]
  when defined(windows):
    outputs.add(escriptCmdPath)
  let argv = @[rebar3Exe, "escriptize"]
  buildAction(
    id = "erlang-rebar3-escriptize-" & sanitizeNamePart(exeName),
    call = inlineExecCall(argv, projectRoot),
    inputs = inputs,
    outputs = outputs,
    pool = "compile",
    # ``rebar3 escriptize`` spawns ``erl`` worker processes whose FS
    # reads aren't reliably observed via the Windows DLL-interpose
    # path. Same constraint M40/M41/M42/M43/M46/M55/M56/M57/M60 face.
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "erlang-rebar3.escriptize")

proc emitWrapperAction(projectRoot, exeName, escriptizeActionId: string):
    BuildActionDef =
  ## ``fs.writeText`` action that materialises the launcher shim. The
  ## wrapper depends on the escriptize action so the produced escript
  ## is guaranteed to exist before the launcher fires.
  let wrapperPath = producedWrapperPath(projectRoot, exeName)
  createDir(extendedPath(parentDir(wrapperPath)))
  let script = renderWrapperScript(projectRoot, exeName)
  fs.writeText(
    output = wrapperPath,
    text = script,
    actionId = "erlang-rebar3-wrapper-" & sanitizeNamePart(exeName),
    deps = @[escriptizeActionId],
    commandStatsId = "erlang-rebar3.executable.wrapper")

proc syntheticPackage(projectRoot: string;
                      members: seq[ErlangRebar3Member]): PackageDef =
  var name = "erlang_rebar3_convention"
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

proc erlangRebar3EmitFragment(projectRoot: string;
                              request: ProviderGraphRequest):
                                GraphFragment {.gcsafe.} =
  ## Convention entry — emit one escriptize action + one wrapper per
  ## executable, hand the bundle to ``buildPackageFragment``.
  {.cast(gcsafe).}:
    let source = readReprobuildSource(projectRoot)
    let members = extractMembers(source)
    if members.len == 0:
      let projectMatch = resolveProjectFile(projectRoot)
      let projectFile =
        if projectMatch.path.len > 0: projectMatch.path
        else: projectRoot / LegacyProjectFileName
      raise newException(ValueError,
        "erlang-rebar3 convention: no executable members declared in " &
          projectFile & " (M61 supports executable targets only — " &
          "library / OTP-only targets are deferred)")
    var execs: seq[string] = @[]
    for m in members:
      if m.kind == erbmExecutable:
        execs.add(m.name)
    if execs.len == 0:
      raise newException(ValueError,
        "erlang-rebar3 convention: no executable members declared — " &
          "M61 supports executables only (library / OTP-only targets " &
          "are deferred)")
    let erlExe = erlExecutable()
    if erlExe.len == 0:
      raise newException(ValueError,
        "erlang-rebar3 convention: no 'erl' on PATH (Erlang runtime " &
          "required; on Windows install via 'scoop install erlang' or " &
          "download from https://www.erlang.org/downloads — M61 honest-" &
          "scope cut: env.ps1 doesn't yet provision Erlang)")
    let rebar3Exe = rebar3Executable()
    if rebar3Exe.len == 0:
      raise newException(ValueError,
        "erlang-rebar3 convention: no 'rebar3' on PATH (rebar3 is an " &
          "independent escript; install via 'scoop install rebar3' on " &
          "Windows or download from https://s3.amazonaws.com/rebar3/rebar3)")
    if not hasRebarConfig(projectRoot):
      raise newException(ValueError,
        "erlang-rebar3 convention: no 'rebar.config' at project root " &
          projectRoot)
    if not hasRebarLock(projectRoot):
      raise newException(ValueError,
        "erlang-rebar3 convention: 'rebar.lock' missing at " &
          projectRoot & "; this is a HARD PRECONDITION for the M61 " &
          "offline-build guarantee. Run 'rebar3 compile' once to " &
          "generate the lockfile (rebar3 writes an empty '[].' lockfile " &
          "even for zero-deps projects).")
    let pkg = syntheticPackage(projectRoot, members)
    let inputs = collectErlangInputs(projectRoot)
    let registerAll = proc() =
      discard buildPool("compile", 8'u32)
      var actions: seq[BuildActionDef] = @[]
      for exe in execs:
        let escriptizeAct = emitEscriptizeAction(projectRoot, rebar3Exe,
          exe, inputs)
        actions.add(escriptizeAct)
        let wrapperAct = emitWrapperAction(projectRoot, exe, escriptizeAct.id)
        actions.add(wrapperAct)
      defaultTarget(target("default", actions))
    result = buildPackageFragment(pkg, request, registerAll,
      includeDefault = false)

proc erlangRebar3Convention*(): LanguageConvention =
  ## The single value the standard provider binary registers at startup.
  ## Registered AFTER ``crystal`` per the M61 spec — the convention
  ## covers the Erlang/OTP ecosystem via the canonical rebar3 build
  ## tool.
  LanguageConvention(
    name: "erlang-rebar3",
    recognize: erlangRebar3Recognize,
    emitFragment: erlangRebar3EmitFragment)

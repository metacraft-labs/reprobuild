## Elixir / mix language convention (Tier 2b) — M62.
##
## **Campaign-closing milestone** (M49–M62 Provisioning &
## Languages Expansion). Eighth Phase 2 language convention,
## immediately after M61 erlang-rebar3. Recognises a ``mix.exs``
## Elixir project manifest at the project root and shells out to the
## stock ``mix`` driver for a single ``mix escript.build``
## invocation (which transitively runs ``mix deps.get`` + ``mix
## compile`` and then bundles the produced ``.beam`` files into a
## self-contained escript). Elixir runs on the BEAM VM (same VM as
## Erlang from M61) so the "build" produces ``.beam`` files under
## ``_build/dev/lib/<app>/ebin/`` plus an escript binary at
## ``<projectRoot>/<app>`` (mix's escript task emits at the project
## root, NOT under ``_build/`` like rebar3's escriptize).
##
## **Honest-scope cut — escript over release**. The original M62 spec
## referenced ``mix release --no-deps-check --quiet`` to ship a self-
## contained ERTS bundle (~50 MB ERTS bundled per release, mirroring
## the M61 escriptize-over-release decision). The implementation
## deliberately picks the lighter ``mix escript.build`` shape per
## the M62 hand-off's "pick simpler" directive (and to mirror M61's
## escriptize choice) — escript produces a single-file artefact that
## depends on the host's ``escript`` driver (which the convention's
## ``recognize`` already gates on via ``erl`` + ``mix`` presence),
## avoiding the per-fixture ~50 MB / ~440 MB disk-footprint blowup
## release builds would cause. Real-world projects shipping
## standalone releases should opt into a future ``elixir-mix-release``
## sibling convention (DEFERRED per the M62 honest-scope cut).
##
## **Recognition contract**:
##   * ``<projectRoot>/mix.exs`` exists (the Elixir project manifest
##     filename — uniquely identifies a mix project; no other
##     convention recognises this filename).
##   * ``<projectRoot>/mix.lock`` exists (HARD precondition per the
##     M62 spec — mirrors M42 csharp-dotnet ``packages.lock.json``,
##     M55 haskell-cabal ``cabal.project.freeze``, M56 ruby-bundler
##     ``Gemfile.lock``, M57 php-composer ``composer.lock``, M60
##     crystal-shards ``shard.lock``, M61 erlang-rebar3 ``rebar.lock``
##     strict-precondition pattern. mix writes a ``mix.lock`` on the
##     first ``mix deps.get`` invocation — even for a zero-deps
##     project, the lockfile is the empty map ``%{}`` — so requiring
##     it at recognise time is a cheap reproducibility gate. The
##     fixture under ``reprobuild-examples/elixir-mix/hello-binary/``
##     ships ``mix.lock`` containing ``%{}``).
##   * ``<projectRoot>/rebar.config`` is NOT present (defer to M61's
##     erlang-rebar3 convention's territory). mix CAN compile rebar
##     deps but a top-level ``rebar.config`` means the project is
##     primarily an Erlang/rebar3 project; the M61 convention claims
##     dispatch first.
##   * ``<projectRoot>/repro.nim`` (or legacy ``reprobuild.nim``) exists
##     AND ``uses:`` lists an Elixir/mix token (``elixir`` / ``mix``).
##     mix ships bundled with Elixir (the ``mix.bat`` shim resolves
##     alongside ``elixir.bat`` in any standard install — scoop, asdf,
##     manual binary install, etc.) so any of the two tokens is
##     acceptable — single-token accept pattern mirroring M30 Rust's
##     ``rust``-or-``cargo``, M56 ruby-bundler's ``ruby``-or-``bundler``,
##     M57 php-composer's ``php``-or-``composer``, M60 crystal's
##     ``crystal``-or-``shards`` and M61 erlang-rebar3's
##     ``erlang``-or-``rebar3`` patterns.
##   * at least one ``executable`` member declared (library / Hex
##     library targets are DEFERRED to a follow-up M — see Honest
##     scope below).
##   * an ``elixir`` driver is on PATH (the Elixir compiler — required
##     to compile ``.ex`` source files into BEAM bytecode).
##   * a ``mix`` driver is on PATH (the Elixir build tool — bundled
##     with the Elixir distribution; ``mix.bat`` on Windows).
##
## **Offline mode** (M62 keeps builds hermetic):
##   * The action runs ``mix escript.build``. mix honours the
##     ``mix.lock`` for dependency resolution (it never re-resolves a
##     pinned Hex package version) but the *first* fetch of a Hex
##     package still touches the network. The M62 fixture has zero
##     external dependencies so the build runs fully offline.
##   * Real-world projects pulling external Hex packages should run
##     ``mix deps.get`` (or equivalently ``MIX_ENV=prod mix deps.get
##     --only prod``) once with network access BEFORE invoking the
##     convention to populate the mix dep cache (under
##     ``~/.hex/packages/`` / ``deps/``). The convention itself never
##     reaches the network when the cache is warm — mix's offline path
##     is implicit (it consults the local cache and only escalates to
##     the network on a cache miss; ``mix escript.build`` doesn't
##     re-fetch when the lockfile already pins everything).
##
## **Emitted actions**:
##   1. ``elixir-mix-escript-build-<name>`` — single ``<mix>
##      escript.build`` action under the project root per declared
##      executable. ``mix escript.build`` is mix-idempotent: subsequent
##      invocations are no-ops when nothing's changed under ``lib/``
##      so emitting one action per executable in a multi-executable
##      workspace is safe (mix itself dedupes). Inputs: the
##      ``mix.exs`` + ``mix.lock`` manifest pair plus every ``.ex`` /
##      ``.exs`` source file recursively walked under the project root
##      (excluding ``_build/`` / ``.repro/`` / ``.git/`` / ``deps/``).
##      Outputs: ``<projectRoot>/<name>`` (the escript). Uses
##      ``automaticMonitorPolicy`` (automatic monitoring is the spec
##      baseline for opaque tools, Reprobuild-Development M17): ``mix``
##      spawns ``erl`` / ``escript`` worker processes and the engine
##      monitors their real read-set instead of trusting only statically
##      declared inputs.
##
##   2. ``elixir-mix-wrapper-<name>`` — one ``fs.writeText`` action
##      per declared executable. Outputs:
##      ``<projectRoot>/.repro/build/<name>/<name>.cmd`` (Windows) or
##      ``<projectRoot>/.repro/build/<name>/<name>`` (POSIX). The
##      wrapper invokes ``escript`` against the mix-produced escript
##      (``<projectRoot>/<name>``) so callers see the same
##      ``<root>/.repro/build/<name>/<name>[.cmd]`` launcher path as
##      every other Phase 2 Tier 2b convention (M55-M57 / M60 / M61).
##      The wrapper depends on the escript.build action so the
##      produced escript is guaranteed to exist before the launcher
##      fires.
##
## **Entry-point resolution**:
##   * The M62 fixture pins the canonical mix layout
##     (``lib/<name>.ex`` containing ``defmodule <Name> do def main
##     (_args), do: …``). The escript.build action figures out the
##     entry module via the ``mix.exs`` ``escript: [main_module:
##     <Name>]`` stanza — the convention itself doesn't parse mix.exs
##     (Elixir DSL parsing is non-trivial; deferred to a future M if
##     finer dispatch becomes necessary). The executable name in
##     ``repro.nim`` MUST match the ``app:`` atom declared in
##     ``mix.exs``'s ``def project`` for the produced escript path
##     ``<projectRoot>/<name>`` to align with the wrapper's expected
##     path.
##
## **Honest scope** (deferred per the M62 honest-scope cut):
##   * **``mix release`` packaging** — DEFERRED. The original M62
##     spec called for release packaging (~50 MB ERTS bundled per
##     release; ~540 MB total dev-shell footprint when stacked on
##     top of the M61 Erlang base). Picked ``mix escript.build``
##     instead per the M62 hand-off's "pick simpler" directive —
##     escript is a single-file artefact that depends on the host's
##     ``escript``/``erl`` (which the convention's recognise already
##     gates on via ``elixir`` + ``mix`` presence).
##   * **Mode 3 Elixir** (pure ``.ex`` without ``mix.exs``) —
##     DEFERRED per the M62 honest-scope cut. mix's compilation
##     model is workspace-driven (the entire ``lib/`` tree compiles
##     in one ``mix compile``-style pass), making per-source ``.ex``
##     DAGs impractical without a flag mix doesn't expose. A
##     dedicated ``elixir-direct`` Mode 3 convention would need to
##     drive ``elixirc`` directly (which is doable for a single
##     file but loses mix's app-discovery + dep handling).
##   * **Phoenix / LiveView web-framework deployment** — DEFERRED.
##     Phoenix projects ship through ``mix phx.new`` + ``mix
##     ecto.migrate`` + ``mix phx.gen.release``; the M62 convention
##     covers bare ``mix escript.build`` only.
##   * **Hex external deps cache-warm** — the M62 fixture has zero
##     deps; real-world projects pulling Hex packages should warm
##     mix's cache once with network access before invoking the
##     convention (mirrors the haskell-cabal / ruby-bundler /
##     php-composer / erlang-rebar3 cache-warm pattern).
##   * **``mix test`` discovery** — DEFERRED to a follow-up M
##     (mirrors M40/M41/M42/M43/M46/M55/M56/M57/M60/M61 test-task
##     deferral).
##   * **NIFs (Rustler / Zigler / C NIFs)** — DEFERRED. NIFs are
##     runtime-loaded shared libraries (``.so`` / ``.dll``) that
##     don't fit the archive-schema the obj+linker Mode 3 conventions
##     use. Cross-language Elixir↔C/Rust/Zig would need a separate
##     FFI design.
##   * **Library targets** (Hex packages without an escript main)
##     — DEFERRED. M62 supports executables only; library-only mix
##     projects (Hex packages consumed via ``deps`` in another
##     project's ``mix.exs``) are usually consumed via Hex, not
##     built standalone.
##   * **Hot code reload (``mix relup``)** — out of scope. Production
##     hot upgrades are an OTP-specific deployment concern outside
##     the scope of a per-project build convention.
##
## **Provisioning note**: on a development host that doesn't ship
## Elixir+mix, the canonical install paths on Windows are:
##   * ``scoop install elixir`` (the ``main`` bucket carries Elixir
##     1.17.x+ as of mid-2025; pulls in Erlang/OTP transitively). The
##     ``elixir.bat`` + ``mix.bat`` shims land under
##     ``%USERPROFILE%\scoop\shims\`` and resolve via PATH.
##   * Manual download of the Elixir Windows precompiled binary from
##     ``https://github.com/elixir-lang/elixir/releases``.
##   * Hex (Elixir's package manager) is installed via
##     ``mix local.hex --force`` as a one-time dev-shell setup step
##     (Hex archives land under ``$installRoot/elixir/<ver>/lib/hex/``).
##     The M62 convention does NOT auto-install Hex — it assumes
##     ``mix.lock`` is pre-populated for any project with external
##     deps.
##
## ``env.ps1`` doesn't yet provision Elixir+mix dedicatedly (the
## scoop-managed install is the M62 default on Windows); a follow-up
## provisioning milestone (deferred per the M62 honest-scope cut) will
## add ``windows/ensure-elixir.ps1``. The convention SKIPs cleanly
## when either tool is missing.
##
## See ``reprobuild-specs/Provisioning-And-Languages-Expansion.milestones.org`` §M62.

import std/[algorithm, os, strutils]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention

const
  ScratchDirName* = ".repro/build"
    ## Top-level scratch directory under the project root for launcher
    ## shim emission. Mirrors the M40 / M41 / M42 / M43 / M46 / M55 /
    ## M56 / M57 / M60 / M61 conventions' value.

type
  ElixirMixMemberKind = enum
    emmExecutable
    emmLibrary

  ElixirMixMember = object
    name: string
    kind: ElixirMixMemberKind

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

proc usesIncludesElixir*(source: string): bool =
  ## True when ``uses:`` lists an Elixir/mix token (``elixir`` /
  ## ``mix``). mix ships bundled with Elixir in every distribution
  ## channel so any single token is acceptable — single-token accept
  ## pattern mirroring M30 Rust's ``rust``-or-``cargo``, M56
  ## ruby-bundler's ``ruby``-or-``bundler``, M57 php-composer's
  ## ``php``-or-``composer``, M60 crystal's ``crystal``-or-``shards``
  ## and M61 erlang-rebar3's ``erlang``/``erl``/``rebar3`` patterns.
  if source.len == 0:
    return false
  var sawElixir = false
  var inBlock = false
  proc consume(token: string) {.closure.} =
    if token == "elixir" or token == "mix":
      sawElixir = true
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
  sawElixir

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

proc extractMembers(source: string): seq[ElixirMixMember] =
  for name in extractExecutables(source):
    result.add(ElixirMixMember(name: name, kind: emmExecutable))
  for name in extractLibraries(source):
    result.add(ElixirMixMember(name: name, kind: emmLibrary))

proc hasMixExs*(projectRoot: string): bool =
  ## True when ``<projectRoot>/mix.exs`` exists.
  fileExists(extendedPath(projectRoot / "mix.exs"))

proc hasMixLock*(projectRoot: string): bool =
  ## True when ``<projectRoot>/mix.lock`` exists. HARD precondition
  ## per the M62 spec — mix writes a ``mix.lock`` on the first
  ## ``mix deps.get`` invocation (even an empty-deps project gets
  ## ``%{}`` as the lockfile), so requiring it at recognise time is
  ## a cheap reproducibility gate mirroring M42 / M55 / M56 / M57 /
  ## M60 / M61.
  fileExists(extendedPath(projectRoot / "mix.lock"))

proc hasRebarConfigForDefer*(projectRoot: string): bool =
  ## True when ``<projectRoot>/rebar.config`` is present at the
  ## project root. M62 defers to the M61 erlang-rebar3 convention in
  ## this case (mix CAN compile rebar deps but a top-level
  ## ``rebar.config`` means the project is primarily an Erlang/rebar3
  ## project).
  fileExists(extendedPath(projectRoot / "rebar.config"))

proc elixirExecutable*(): string =
  ## Resolve an ``elixir`` driver on PATH (the Elixir compiler).
  findExe("elixir")

proc mixExecutable*(): string =
  ## Resolve a ``mix`` driver on PATH. On Windows the canonical form
  ## is ``mix.bat`` (the scoop / asdf / manual-install shim);
  ## ``findExe`` resolves both shapes via PATHEXT.
  findExe("mix")

proc sanitizeNamePart(value: string): string =
  for ch in value:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = "x"

proc elixirMixRecognize(projectRoot: string;
                        request: ProviderGraphRequest): bool {.gcsafe.} =
  ## Recognition contract — see module docstring.
  if not hasMixExs(projectRoot):
    return false
  if not hasMixLock(projectRoot):
    # HARD precondition (M62 spec): the lockfile is mix's
    # reproducibility guarantee. The convention refuses to recognise
    # a project missing it; ``emitFragment`` raises with a clear
    # diagnostic on the off-chance recognise is bypassed.
    return false
  if hasRebarConfigForDefer(projectRoot):
    # Defer to M61's erlang-rebar3 convention when rebar.config is
    # also at the root — that project is primarily an Erlang/rebar3
    # project.
    return false
  let source = readReprobuildSource(projectRoot)
  if source.len == 0:
    return false
  if not usesIncludesElixir(source):
    return false
  let members = extractMembers(source)
  if members.len == 0:
    return false
  # Only executables are supported in M62 — library-only projects
  # (Hex packages consumed via ``deps`` elsewhere) are deferred.
  var sawExecutable = false
  for m in members:
    if m.kind == emmExecutable:
      sawExecutable = true
      break
  if not sawExecutable:
    return false
  if elixirExecutable().len == 0:
    return false
  if mixExecutable().len == 0:
    return false
  true

proc producedEscriptPath*(projectRoot, exeName: string): string =
  ## Predicted path of the mix-produced escript. ``mix escript.build``
  ## emits at the project root (NOT under ``_build/`` like rebar3's
  ## escriptize). The filename matches the ``escript: [name: ...]``
  ## stanza in ``mix.exs`` — by convention this is the ``app:`` atom
  ## from ``def project``, which the M62 fixture aligns with the
  ## ``executable`` name in ``repro.nim``.
  projectRoot / exeName

proc producedWrapperPath*(projectRoot, exeName: string): string =
  ## Predicted output path for the launcher wrapper script under the
  ## canonical ``<root>/.repro/build/<name>/<name>[.cmd]`` location.
  ## Mirrors the M55-M57 / M60 / M61 wrapper-path convention so callers
  ## see a stable launcher path regardless of the underlying ecosystem.
  when defined(windows):
    projectRoot / ScratchDirName / exeName / (exeName & ".cmd")
  else:
    projectRoot / ScratchDirName / exeName / exeName

proc renderWrapperScript(projectRoot, exeName: string): string =
  ## Build the launcher shim content. The wrapper invokes ``escript``
  ## against the mix-produced escript binary so the BEAM VM picks up
  ## the bundled bytecode regardless of the working directory the
  ## caller invoked the wrapper from.
  let escriptPath = producedEscriptPath(projectRoot, exeName)
  when defined(windows):
    var lines: seq[string] = @[]
    lines.add("@echo off")
    lines.add("setlocal")
    lines.add("cd /d \"" & projectRoot & "\"")
    # Invoke escript against the mix-produced escript; forward args.
    lines.add("escript \"" & escriptPath & "\" %*")
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

proc collectElixirInputs(projectRoot: string): seq[string] =
  ## Conservative input enumeration for the escript.build action: the
  ## ``mix.exs`` + ``mix.lock`` + every ``.ex`` / ``.exs`` source file
  ## recursively walked under the project root (excluding ``_build/`` /
  ## ``.repro/`` / ``.git/`` / ``deps/`` / ``node_modules/``).
  if not dirExists(extendedPath(projectRoot)):
    return @[]
  for extra in @["mix.exs", "mix.lock"]:
    let extraPath = projectRoot / extra
    if fileExists(extendedPath(extraPath)):
      result.add(extraPath)
  proc shouldSkipDir(name: string): bool =
    let lower = name.toLowerAscii
    lower in ["_build", ".repro", ".git", "node_modules", "deps", "cover"]
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
          if lower.endsWith(".ex") or lower.endsWith(".exs"):
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

proc emitEscriptBuildAction(projectRoot, mixExe, exeName: string;
                            inputs: seq[string]): BuildActionDef =
  ## Emit the single ``mix escript.build`` action under the project
  ## root for ``exeName``. The escript lands at
  ## ``<projectRoot>/<exeName>``. ``mix escript.build`` transitively
  ## runs ``mix deps.get`` + ``mix compile`` so we don't need
  ## separate compile / deps-get steps.
  let escriptPath = producedEscriptPath(projectRoot, exeName)
  createDir(extendedPath(parentDir(escriptPath)))
  let outputs: seq[string] = @[escriptPath]
  let argv = @[mixExe, "escript.build"]
  buildAction(
    id = "elixir-mix-escript-build-" & sanitizeNamePart(exeName),
    call = inlineExecCall(argv, projectRoot),
    inputs = inputs,
    outputs = outputs,
    pool = "compile",
    # ``mix escript.build`` spawns ``erl`` / ``escript`` worker
    # processes whose FS reads aren't reliably observed via the
    # Windows DLL-interpose path. Same constraint
    # M40/M41/M42/M43/M46/M55/M56/M57/M60/M61 face.
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "elixir-mix.escript-build")

proc emitWrapperAction(projectRoot, exeName, escriptBuildActionId: string):
    BuildActionDef =
  ## ``fs.writeText`` action that materialises the launcher shim. The
  ## wrapper depends on the escript.build action so the produced
  ## escript is guaranteed to exist before the launcher fires.
  let wrapperPath = producedWrapperPath(projectRoot, exeName)
  createDir(extendedPath(parentDir(wrapperPath)))
  let script = renderWrapperScript(projectRoot, exeName)
  fs.writeText(
    output = wrapperPath,
    text = script,
    actionId = "elixir-mix-wrapper-" & sanitizeNamePart(exeName),
    deps = @[escriptBuildActionId],
    commandStatsId = "elixir-mix.executable.wrapper")

proc syntheticPackage(projectRoot: string;
                      members: seq[ElixirMixMember]): PackageDef =
  var name = "elixir_mix_convention"
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

proc elixirMixEmitFragment(projectRoot: string;
                           request: ProviderGraphRequest):
                             GraphFragment {.gcsafe.} =
  ## Convention entry — emit one escript.build action + one wrapper
  ## per executable, hand the bundle to ``buildPackageFragment``.
  {.cast(gcsafe).}:
    let source = readReprobuildSource(projectRoot)
    let members = extractMembers(source)
    if members.len == 0:
      let projectMatch = resolveProjectFile(projectRoot)
      let projectFile =
        if projectMatch.path.len > 0: projectMatch.path
        else: projectRoot / LegacyProjectFileName
      raise newException(ValueError,
        "elixir-mix convention: no executable members declared in " &
          projectFile & " (M62 supports executable targets only — " &
          "library / Hex-only targets are deferred)")
    var execs: seq[string] = @[]
    for m in members:
      if m.kind == emmExecutable:
        execs.add(m.name)
    if execs.len == 0:
      raise newException(ValueError,
        "elixir-mix convention: no executable members declared — " &
          "M62 supports executables only (library / Hex-only targets " &
          "are deferred)")
    let elixirExe = elixirExecutable()
    if elixirExe.len == 0:
      raise newException(ValueError,
        "elixir-mix convention: no 'elixir' on PATH (Elixir compiler " &
          "required; on Windows install via 'scoop install elixir' or " &
          "download from https://github.com/elixir-lang/elixir/releases " &
          "— M62 honest-scope cut: env.ps1 doesn't yet provision Elixir)")
    let mixExe = mixExecutable()
    if mixExe.len == 0:
      raise newException(ValueError,
        "elixir-mix convention: no 'mix' on PATH (mix ships bundled " &
          "with the Elixir distribution; install via 'scoop install " &
          "elixir' on Windows or download from https://github.com/" &
          "elixir-lang/elixir/releases)")
    if not hasMixExs(projectRoot):
      raise newException(ValueError,
        "elixir-mix convention: no 'mix.exs' at project root " &
          projectRoot)
    if not hasMixLock(projectRoot):
      raise newException(ValueError,
        "elixir-mix convention: 'mix.lock' missing at " &
          projectRoot & "; this is a HARD PRECONDITION for the M62 " &
          "offline-build guarantee. Run 'mix deps.get' once to " &
          "generate the lockfile (mix writes an empty '%{}' lockfile " &
          "even for zero-deps projects).")
    if hasRebarConfigForDefer(projectRoot):
      raise newException(ValueError,
        "elixir-mix convention: 'rebar.config' is also present at " &
          projectRoot & "; defer to the M61 erlang-rebar3 convention " &
          "(a project carrying both manifests is primarily an Erlang/" &
          "rebar3 project)")
    let pkg = syntheticPackage(projectRoot, members)
    let inputs = collectElixirInputs(projectRoot)
    let registerAll = proc() =
      discard buildPool("compile", 8'u32)
      var actions: seq[BuildActionDef] = @[]
      for exe in execs:
        let escriptBuildAct = emitEscriptBuildAction(projectRoot, mixExe,
          exe, inputs)
        actions.add(escriptBuildAct)
        let wrapperAct = emitWrapperAction(projectRoot, exe,
          escriptBuildAct.id)
        actions.add(wrapperAct)
      defaultTarget(target("default", actions))
    result = buildPackageFragment(pkg, request, registerAll,
      includeDefault = false)

proc elixirMixConvention*(): LanguageConvention =
  ## The single value the standard provider binary registers at
  ## startup. Registered AFTER ``erlang-rebar3`` per the M62 spec —
  ## the convention covers the Elixir ecosystem via the canonical mix
  ## build tool. **Campaign-closing milestone** of the M49-M62
  ## Provisioning & Languages Expansion campaign.
  LanguageConvention(
    name: "elixir-mix",
    recognize: elixirMixRecognize,
    emitFragment: elixirMixEmitFragment)

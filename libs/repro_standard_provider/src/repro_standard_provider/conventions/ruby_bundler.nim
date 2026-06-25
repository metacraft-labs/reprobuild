## Ruby / Bundler language convention (Tier 2b) — M56.
##
## Second **Phase 2** language convention, immediately after M55
## haskell-cabal. Recognises a Bundler ``Gemfile`` at the project root
## and shells out to the stock ``bundle`` driver for a single offline
## ``bundle install --deployment --local --quiet`` invocation (deploy
## mode = strict-lockfile, local = no network). Ruby is an interpreted
## language so there is no compile step per se — the "build" prepares
## ``vendor/bundle/`` with all gems vendored locally + emits a launcher
## ``.cmd`` shim that invokes ``bundle exec ruby <entrypoint>``.
##
## **Recognition contract**:
##   * ``<projectRoot>/Gemfile`` exists (the Bundler dependency manifest).
##   * ``<projectRoot>/Gemfile.lock`` exists (HARD precondition per the
##     M56 spec — the lockfile is Bundler's reproducibility guarantee,
##     mirroring M42 csharp-dotnet's ``packages.lock.json`` and the
##     ``--deployment`` flag's strict-lockfile contract: Bundler exits
##     non-zero in deployment mode if ``Gemfile.lock`` is missing or
##     out-of-sync with ``Gemfile``).
##   * ``<projectRoot>/repro.nim`` (or legacy ``reprobuild.nim``) exists
##     AND ``uses:`` lists a Ruby token (``ruby`` or ``bundler``).
##     Bundler ships with modern Ruby (≥ 2.6) so a single ``ruby``
##     token in ``uses:`` is sufficient; declaring ``bundler``
##     additionally is allowed but not required.
##   * at least one ``executable`` member declared (library targets +
##     gem-packaging via ``rake build`` are DEFERRED to a follow-up M;
##     see Honest scope below).
##   * a ``ruby`` driver is on PATH.
##   * a ``bundle`` driver is on PATH (Bundler — ships with Ruby ≥
##     2.6 but the convention probes for it explicitly so a Ruby
##     install with Bundler ripped out fails the gate honestly rather
##     than crashing at action time).
##
## **Offline mode** (M56 keeps builds hermetic):
##   * The action runs ``bundle install --deployment --local --quiet
##     --path vendor/bundle``. ``--deployment`` enforces strict-
##     lockfile mode (Bundler refuses to update the lockfile and exits
##     non-zero if ``Gemfile.lock`` is out-of-sync with ``Gemfile``).
##     ``--local`` enforces offline mode (Bundler refuses to consult
##     ``https://rubygems.org``; gems MUST be resolvable from the local
##     Bundler cache, typically under ``vendor/cache/`` or
##     ``~/.bundle/cache/``). ``--quiet`` suppresses the progress
##     output. ``--path vendor/bundle`` pins the install target to a
##     project-local directory so different projects don't trample
##     each other's gem trees.
##   * Real-world projects pulling external gem dependencies should
##     populate ``vendor/cache/`` once with network access via
##     ``bundle package`` BEFORE invoking the convention. The
##     convention itself never reaches the network.
##   * The M56 fixture is stdlib-only (the ``Gemfile`` declares zero
##     gem dependencies) so the offline install is a near-no-op for
##     the fixture; the convention can be exercised end-to-end without
##     provisioning external gems.
##
## **Emitted actions**:
##   1. ``ruby-bundler-install`` — single ``<bundle> install
##      --deployment --local --quiet --path vendor/bundle`` action under
##      the project root. Inputs: the ``Gemfile`` + ``Gemfile.lock``.
##      Outputs: ``<projectRoot>/vendor/bundle/.repro-bundle-stamp``
##      (a sentinel marker written by the wrapper — see below; the
##      ``vendor/bundle/`` tree itself isn't a stable output path
##      because Bundler embeds the Ruby ABI version in its directory
##      shape (``vendor/bundle/ruby/<ABI>/gems/...``), and the
##      convention can't predict the host's exact ABI version. The
##      sentinel works around the prediction problem cleanly).
##      Uses ``automaticMonitorPolicy`` (automatic monitoring is the
##      spec baseline for opaque tools, Reprobuild-Development M17):
##      ``bundle install`` spawns worker subprocesses and the engine
##      monitors their real read-set instead of trusting only
##      statically declared inputs.
##
##   2. ``ruby-bundler-wrapper-<name>`` — one ``fs.writeText`` action
##      per declared executable. Outputs:
##      ``<projectRoot>/.repro/build/<name>/<name>.cmd`` (Windows) or
##      ``<projectRoot>/.repro/build/<name>/<name>`` (POSIX). The
##      script invokes ``bundle exec ruby <entrypoint>`` with the
##      caller's CWD set to ``<projectRoot>`` so Bundler can locate
##      ``Gemfile`` + ``vendor/bundle/``. The wrapper depends on the
##      ``ruby-bundler-install`` action so the gem tree is guaranteed
##      populated by the time the launcher runs.
##
## **Entry-point resolution**:
##   * The M56 spec scopes down to ``bin/<name>.rb`` as the canonical
##     entry-point shape (the conventional location for Ruby script
##     entrypoints; mirrors npm's ``bin/`` convention). The wrapper's
##     ``ruby <entrypoint>`` argv pins
##     ``<projectRoot>/bin/<name>.rb``. Per-member custom entrypoints
##     are deferred to a follow-up M (would require a new DSL field).
##
## **Honest scope** (deferred per M56 spec):
##   * Library targets (Ruby gems shipped as ``library``) — DEFERRED.
##     Ruby's library shape is a ``.gemspec`` + ``lib/`` tree; M56
##     supports executables only.
##   * Gem packaging (``rake build`` producing ``pkg/<gem>-<ver>.gem``
##     for projects with a ``<gemname>.gemspec``) — DEFERRED. The
##     ``Gemfile``-only "app-style" path is M56's coverage; the
##     gem-style ``<gemname>.gemspec`` + ``rake build`` path is
##     mentioned in the M56 spec but explicitly NOT shipped in this
##     milestone (the M56 fixture is app-style).
##   * Native gem extensions (gems with C extensions built via
##     ``mkmf``) — work under MSYS2 but UNTESTED in the M56 fixture.
##     The convention's offline contract holds as long as the
##     compiled extension is pre-built and shipped in the gem.
##   * Rails / Rack / Sinatra application patterns — out of scope.
##   * ``bundle exec rake test`` test discovery — deferred to a
##     follow-up M (mirrors M40 / M41 / M42 / M43 / M46 / M55
##     deferral of test-task discovery).
##   * ``rbenv`` / ``RVM`` per-project Ruby management — out of scope.
##     The convention assumes the ``ruby`` on PATH is the project's
##     intended interpreter.
##   * Native packers (``mruby``, ``ruby-packer``) producing a single
##     standalone ``.exe`` — DEFERRED. M56 ships a launcher shim,
##     not a packed binary.
##
## **Provisioning note**: on a development host that doesn't ship Ruby
## (the M56 default on Windows — the dev shell doesn't currently
## bundle Ruby), the canonical install path on Windows is RubyInstaller
## (``https://rubyinstaller.org/``). M56 pins ``RUBY_VERSION=3.3.5``
## (latest stable as of 2024-09). Bundler ships with Ruby ≥ 2.6 so no
## separate install is required. Total dev-shell footprint ~120 MB.
##
## See ``reprobuild-specs/Provisioning-And-Languages-Expansion.milestones.org`` §M56.

import std/[algorithm, os, strutils]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention

const
  ScratchDirName* = ".repro/build"
    ## Top-level scratch directory under the project root for launcher
    ## shim emission. Mirrors the M40 / M41 / M42 / M43 / M46 / M55
    ## conventions' value.

  VendorBundleSubdir* = "vendor/bundle"
    ## Project-local Bundler install path. ``bundle install --path
    ## vendor/bundle`` instructs Bundler to vendor gems under this
    ## subdir rather than touching the system gem store. Bundler
    ## further nests its install tree under
    ## ``vendor/bundle/ruby/<ABI>/gems/<gem>-<ver>/`` keyed by the
    ## Ruby ABI version — which the convention can't predict at emit
    ## time (it varies per Ruby minor release). The install action
    ## emits a sentinel stamp file at
    ## ``vendor/bundle/.repro-bundle-stamp`` to give the engine a
    ## stable output path to fingerprint.

  BundleSentinelFile* = ".repro-bundle-stamp"
    ## Sentinel filename written under ``vendor/bundle/`` after the
    ## ``bundle install`` succeeds. See ``VendorBundleSubdir``.

  EntryScriptSubdir* = "bin"
    ## Project-local entry-script directory. The M56 convention pins
    ## the wrapper to invoke ``<projectRoot>/bin/<name>.rb`` as the
    ## entry point (mirrors npm's ``bin/`` convention). Custom
    ## entrypoints are deferred.

type
  RubyBundlerMemberKind = enum
    rbmExecutable
    rbmLibrary

  RubyBundlerMember = object
    name: string
    kind: RubyBundlerMemberKind

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

proc usesIncludesRuby(source: string): bool =
  ## True when ``uses:`` lists a Ruby token (``ruby`` or ``bundler``).
  ## Bundler ships with modern Ruby (≥ 2.6) so a single ``ruby``
  ## token suffices; ``bundler`` is accepted as an alias for tooling
  ## clarity.
  if source.len == 0:
    return false
  var sawRuby = false
  var inBlock = false
  proc consume(token: string) {.closure.} =
    if token == "ruby" or token == "bundler":
      sawRuby = true
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
  sawRuby

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

proc extractMembers(source: string): seq[RubyBundlerMember] =
  for name in extractExecutables(source):
    result.add(RubyBundlerMember(name: name, kind: rbmExecutable))
  for name in extractLibraries(source):
    result.add(RubyBundlerMember(name: name, kind: rbmLibrary))

proc hasGemfile*(projectRoot: string): bool =
  ## True when ``<projectRoot>/Gemfile`` exists.
  fileExists(extendedPath(projectRoot / "Gemfile"))

proc hasGemfileLock*(projectRoot: string): bool =
  ## True when ``<projectRoot>/Gemfile.lock`` exists. HARD precondition
  ## per the M56 spec — Bundler's ``--deployment`` mode requires the
  ## lockfile, and the convention's offline-build guarantee depends on
  ## it.
  fileExists(extendedPath(projectRoot / "Gemfile.lock"))

proc rubyExecutable(): string =
  ## Resolve a ``ruby`` interpreter on PATH. On Windows the binary is
  ## usually ``ruby.exe``; ``findExe`` resolves both shapes via PATHEXT.
  findExe("ruby")

proc bundleExecutable(): string =
  ## Resolve a ``bundle`` driver (Bundler) on PATH. On Windows the
  ## binary is usually ``bundle.bat`` (RubyInstaller shim) or
  ## ``bundle.cmd``; ``findExe`` resolves all shapes via PATHEXT.
  findExe("bundle")

proc sanitizeNamePart(value: string): string =
  for ch in value:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = "x"

proc rubyBundlerRecognize(projectRoot: string;
                          request: ProviderGraphRequest): bool {.gcsafe.} =
  ## Recognition contract — see module docstring.
  if not hasGemfile(projectRoot):
    return false
  if not hasGemfileLock(projectRoot):
    # HARD precondition (M56 spec): the lockfile is Bundler's
    # reproducibility + offline guarantee. The convention refuses to
    # recognise a project missing it; ``emitFragment`` raises with a
    # clear diagnostic on the off-chance recognise is bypassed.
    return false
  let source = readReprobuildSource(projectRoot)
  if source.len == 0:
    return false
  if not usesIncludesRuby(source):
    return false
  let members = extractMembers(source)
  if members.len == 0:
    return false
  # Only executables are supported in M56 — library-only projects
  # (gems) are deferred. ``recognize`` accepts the project as long as
  # at least one executable is declared (libraries alongside
  # executables are silently ignored at emit time).
  var sawExecutable = false
  for m in members:
    if m.kind == rbmExecutable:
      sawExecutable = true
      break
  if not sawExecutable:
    return false
  if rubyExecutable().len == 0:
    return false
  if bundleExecutable().len == 0:
    return false
  true

proc producedWrapperPath*(projectRoot, exeName: string): string =
  ## Predicted output path for the launcher wrapper script. On Windows
  ## the suffix is ``.cmd``; on POSIX no suffix (the script is a
  ## ``#!/usr/bin/env sh``-prefixed file). Mirrors the M32 python_direct
  ## wrapper-path convention.
  when defined(windows):
    projectRoot / ScratchDirName / exeName / (exeName & ".cmd")
  else:
    projectRoot / ScratchDirName / exeName / exeName

proc producedSentinelPath*(projectRoot: string): string =
  ## Sentinel marker file written under ``vendor/bundle/`` after a
  ## successful ``bundle install``. See ``VendorBundleSubdir`` for
  ## why a sentinel is used instead of predicting Bundler's actual
  ## install layout.
  projectRoot / VendorBundleSubdir / BundleSentinelFile

proc entryScriptPath*(projectRoot, exeName: string): string =
  ## Predicted entry-point path under ``<projectRoot>/bin/<name>.rb``.
  projectRoot / EntryScriptSubdir / (exeName & ".rb")

proc renderWrapperScript(bundleExe, projectRoot, entryScript: string): string =
  ## Build the launcher shim content. On Windows emit a ``.cmd``
  ## (cmd.exe) script; on POSIX emit a ``sh`` script. The wrapper
  ## changes CWD to ``<projectRoot>`` so Bundler can locate the
  ## ``Gemfile`` and project-local ``vendor/bundle/`` regardless of
  ## the caller's CWD.
  when defined(windows):
    var lines: seq[string] = @[]
    lines.add("@echo off")
    lines.add("setlocal")
    # cd /d switches drive + directory in one shot.
    lines.add("cd /d \"" & projectRoot & "\"")
    # ``bundle exec ruby <entry> %*`` — forward any caller args.
    lines.add("\"" & bundleExe & "\" exec ruby \"" & entryScript & "\" %*")
    lines.add("set \"WRAPPER_EXIT=%ERRORLEVEL%\"")
    lines.add("endlocal & exit /b %WRAPPER_EXIT%")
    return lines.join("\r\n") & "\r\n"
  else:
    var lines: seq[string] = @[]
    lines.add("#!/usr/bin/env sh")
    lines.add("set -e")
    lines.add("cd '" & projectRoot & "'")
    lines.add("exec '" & bundleExe & "' exec ruby '" & entryScript & "' \"$@\"")
    return lines.join("\n") & "\n"

proc collectRubyInputs(projectRoot: string): seq[string] =
  ## Conservative input enumeration for the launcher wrapper: the
  ## ``Gemfile`` + ``Gemfile.lock`` + every ``.rb`` source file
  ## recursively walked under the project root (excluding
  ## ``vendor/`` / ``.repro/`` / ``.git/`` / ``node_modules/``).
  if not dirExists(extendedPath(projectRoot)):
    return @[]
  for extra in @["Gemfile", "Gemfile.lock"]:
    let extraPath = projectRoot / extra
    if fileExists(extendedPath(extraPath)):
      result.add(extraPath)
  proc shouldSkipDir(name: string): bool =
    let lower = name.toLowerAscii
    lower in ["vendor", ".repro", ".git", ".bundle", "node_modules",
             "tmp", "log"]
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
          if lower.endsWith(".rb"):
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

proc emitInstallAction(projectRoot, bundleExe: string): BuildActionDef =
  ## Emit the single ``bundle install --deployment --local --quiet
  ## --path vendor/bundle`` action. The action's "output" is the
  ## sentinel file under ``vendor/bundle/.repro-bundle-stamp`` —
  ## Bundler's actual install tree shape is ABI-version-keyed and
  ## can't be predicted at emit time. The convention wraps the install
  ## in a single ``cmd /c`` (Windows) / ``sh -c`` (POSIX) so the
  ## sentinel touch + install run as one cacheable unit.
  ##
  ## ``--deployment`` enforces strict-lockfile mode (Bundler exits
  ## non-zero if ``Gemfile.lock`` is out-of-sync with ``Gemfile``).
  ## ``--local`` enforces offline mode (no rubygems.org access).
  ## ``--quiet`` suppresses progress chatter. ``--path vendor/bundle``
  ## pins the install target to a project-local dir.
  let sentinelPath = producedSentinelPath(projectRoot)
  let stampDir = parentDir(sentinelPath)
  createDir(extendedPath(stampDir))
  let inputs = @[projectRoot / "Gemfile", projectRoot / "Gemfile.lock"]
  when defined(windows):
    # Bundler install + sentinel touch chained in a single cmd /c so
    # the engine has a stable output to fingerprint. ``echo`` writes
    # a marker indicating the install succeeded.
    let bundleCmd = quoteShell(bundleExe) & " install --deployment " &
      "--local --quiet --path " & quoteShell(VendorBundleSubdir)
    let stampCmd = "echo installed > " & quoteShell(sentinelPath)
    let argv = @[
      "cmd", "/c",
      bundleCmd & " && " & stampCmd
    ]
    buildAction(
      id = "ruby-bundler-install",
      call = inlineExecCall(argv, projectRoot),
      inputs = inputs,
      outputs = @[sentinelPath],
      pool = "compile",
      # ``bundle install`` spawns Ruby worker subprocesses whose FS
      # reads aren't reliably observed via the Windows DLL-interpose
      # path. Same constraint M40/M41/M42/M43/M46/M55 face.
      dependencyPolicy = automaticMonitorPolicy(),
      commandStatsId = "ruby-bundler.install")
  else:
    let bundleCmd = "'" & bundleExe & "' install --deployment " &
      "--local --quiet --path '" & VendorBundleSubdir & "'"
    let stampCmd = "echo installed > '" & sentinelPath & "'"
    let argv = @[
      "sh", "-c",
      bundleCmd & " && " & stampCmd
    ]
    buildAction(
      id = "ruby-bundler-install",
      call = inlineExecCall(argv, projectRoot),
      inputs = inputs,
      outputs = @[sentinelPath],
      pool = "compile",
      dependencyPolicy = automaticMonitorPolicy(),
      commandStatsId = "ruby-bundler.install")

proc emitWrapperAction(projectRoot, bundleExe, exeName: string;
                       installActionId: string): BuildActionDef =
  ## ``fs.writeText`` action that materialises the launcher shim. The
  ## wrapper depends on the install action so ``vendor/bundle/`` is
  ## guaranteed populated before the launcher is invokable.
  let wrapperPath = producedWrapperPath(projectRoot, exeName)
  let entryScript = entryScriptPath(projectRoot, exeName)
  createDir(extendedPath(parentDir(wrapperPath)))
  let script = renderWrapperScript(bundleExe, projectRoot, entryScript)
  fs.writeText(
    output = wrapperPath,
    text = script,
    actionId = "ruby-bundler-wrapper-" & sanitizeNamePart(exeName),
    deps = @[installActionId],
    commandStatsId = "ruby-bundler.executable.wrapper")

proc syntheticPackage(projectRoot: string;
                      members: seq[RubyBundlerMember]): PackageDef =
  var name = "ruby_bundler_convention"
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

proc rubyBundlerEmitFragment(projectRoot: string;
                             request: ProviderGraphRequest):
                               GraphFragment {.gcsafe.} =
  ## Convention entry — emit the install action + one wrapper per
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
        "ruby-bundler convention: no executable members declared in " &
          projectFile & " (M56 supports executable targets only — " &
          "library / gem targets are deferred)")
    var execs: seq[string] = @[]
    for m in members:
      if m.kind == rbmExecutable:
        execs.add(m.name)
    if execs.len == 0:
      raise newException(ValueError,
        "ruby-bundler convention: no executable members declared — " &
          "M56 supports executables only (library / gem targets are " &
          "deferred)")
    let rubyExe = rubyExecutable()
    if rubyExe.len == 0:
      raise newException(ValueError,
        "ruby-bundler convention: no 'ruby' on PATH (Ruby toolchain " &
          "required; on Windows install via RubyInstaller from " &
          "https://rubyinstaller.org/ — M56 pins Ruby 3.3.5; Bundler " &
          "ships with Ruby ≥ 2.6 so no separate install is required)")
    let bundleExe = bundleExecutable()
    if bundleExe.len == 0:
      raise newException(ValueError,
        "ruby-bundler convention: no 'bundle' on PATH (Bundler ships " &
          "with Ruby ≥ 2.6 — re-install Ruby via RubyInstaller from " &
          "https://rubyinstaller.org/ if missing)")
    if not hasGemfile(projectRoot):
      raise newException(ValueError,
        "ruby-bundler convention: no 'Gemfile' at project root " &
          projectRoot)
    if not hasGemfileLock(projectRoot):
      raise newException(ValueError,
        "ruby-bundler convention: 'Gemfile.lock' missing at " &
          projectRoot & "; this is a HARD PRECONDITION for the M56 " &
          "offline-build guarantee. Run 'bundle lock' once with " &
          "network access to generate the lockfile.")
    let pkg = syntheticPackage(projectRoot, members)
    let registerAll = proc() =
      discard buildPool("compile", 8'u32)
      let installAct = emitInstallAction(projectRoot, bundleExe)
      var actions: seq[BuildActionDef] = @[installAct]
      for exe in execs:
        let wrapperAct = emitWrapperAction(projectRoot, bundleExe, exe,
          installAct.id)
        actions.add(wrapperAct)
      defaultTarget(target("default", actions))
    result = buildPackageFragment(pkg, request, registerAll,
      includeDefault = false)

proc rubyBundlerConvention*(): LanguageConvention =
  ## The single value the standard provider binary registers at startup.
  LanguageConvention(
    name: "ruby-bundler",
    recognize: rubyBundlerRecognize,
    emitFragment: rubyBundlerEmitFragment)

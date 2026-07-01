## JavaScript / TypeScript language convention (Tier 2b) — Mode A
## "fine-grained" plugin with M24 Mode B crude fallback.
##
## Recognises a project whose ``reprobuild.nim`` ``uses:`` block names
## ``node`` or ``typescript`` AND ships a conventional layout
## (``package.json`` with ``"type": "module"`` at the project root,
## optionally a ``tsconfig.json``, and at least one entry source under
## ``src/``). The convention spec
## (``reprobuild-specs/Language-Conventions/JavaScript-TypeScript.md``
## §"Mode A — Fine-grained build graph") prescribes a seven-action set
## (A1 npm ci, A2 per-``.ts`` swc/esbuild transform, A3 whole-project
## ``tsc --emitDeclarationOnly``, A4 ``tsc --noEmit`` typecheck,
## A5 per-bin ``esbuild --bundle``, A6 dist assembly, A7 per-test-file
## ``node --test --import=tsx``).
##
## **M21 graduations** (this milestone closes M16's deferred sub-graphs):
##
##   * **A1 npm ci** — when ``<projectRoot>/package-lock.json`` exists, the
##     convention emits a single ``npm ci --prefer-offline --no-audit
##     --no-fund --no-progress`` action BEFORE the tsc action. The action
##     declares ``package.json`` + ``package-lock.json`` as inputs, lists
##     ``node_modules/`` as an opaque directory output, and uses
##     ``automaticMonitorPolicy()`` because npm reads many internal files
##     that aren't worth enumerating. Downstream actions (tsc, esbuild)
##     list this action's id in their ``deps`` so the engine orders the
##     install before any consumer. When the lockfile is ABSENT the
##     convention falls back to the M16 ``npx --yes --package
##     typescript@5.6 tsc`` on-demand path.
##
##   * **A5 per-bin esbuild bundle** — for each entry in ``package.json``'s
##     ``"bin"`` map, the convention emits an ``esbuild --bundle <entry>
##     --format=esm --platform=node --outfile=<dist/bin/<name>.js>
##     --metafile=<dist/bin/<name>.js.meta.json>`` action. The metafile
##     lists every file esbuild touched; future incremental rebuild logic
##     can consume it for dep capture. The tsc action still runs (whole-
##     project type-check + ``.d.ts`` emit) but produces ``.js`` outputs
##     into a separate ``--outDir <scratch>/tsc-out`` so the per-bin
##     esbuild bundle (which writes into ``<scratch>/dist/bin/``) is the
##     authoritative consumer-runnable artefact.
##
##   * **A6 launcher shim** — for each bin entry, after esbuild produces
##     the bundle, the convention emits an ``fs.writeText`` shim action
##     under ``<scratch>/bin/<name>.cmd`` (Windows) or ``<scratch>/bin/
##     <name>`` (POSIX, hashbang + chmod-equivalent). The shim invokes
##     ``node "<dist/bin/<name>.js>" %*`` (Windows) / ``node
##     "<dist/bin/<name>.js>" "$@"`` (POSIX). The validate scripts run
##     the shim directly to prove the convention's runnable artefact
##     surface, not just the bundled JS.
##
##   * **A7 test runner** — the convention discovers ``test/**/*.test.{ts,
##     js}`` (and ``src/**/*.test.{ts,js}``, though the M21 fixtures keep
##     tests under ``test/`` only) and emits a single ``node --test
##     --import=tsx <test files>`` action under a NON-DEFAULT ``test``
##     target. ``repro build .#test`` builds the test target; the default
##     target stays bundle+shim-only. When the fixture has zero test
##     files the test target isn't emitted (current behaviour is
##     unchanged for the typescript-library + node-server fixtures).
##
## The M16 surface focuses on the headline "fixtures build to a runnable
## artifact":
##
##   * **TypeScript library / Node application**: a single
##     ``npx tsc -p tsconfig.json`` action compiles every ``.ts`` to a
##     matching ``.js`` and emits ``.d.ts`` next to it (A2 + A3 collapsed
##     because stable ``tsc`` has no true per-file emit mode — the
##     ``isolatedModules`` flag only restricts the *input* grammar; the
##     compiler still loads the whole program). One target per ``library``
##     member.
##   * **TypeScript CLI**: same whole-project ``tsc`` compile, which also
##     transpiles ``src/bin/<name>.ts`` to ``dist/bin/<name>.js`` (the
##     ``#!/usr/bin/env node`` hashbang at line 1 is preserved because
##     ``tsc`` copies it verbatim into the emitted JS). Mode A A5
##     (``esbuild --bundle``) is **deferred to a follow-up M**: the M16
##     fixtures don't carry runtime ``node_modules`` deps, so the simple
##     ``tsc`` emit is enough to produce a runnable ``dist/bin/<name>.js``
##     that the verification script invokes via ``node dist/bin/<name>.js``.
##     A6 launcher-shim emission (``.cmd`` on Windows, hashbang chmod +x
##     on POSIX) is also deferred — the validate scripts run the bundle
##     via ``node <path>`` directly, no shim required.
##   * **Node application (JS-only)**: no TypeScript. The convention
##     emits one ``fs.copyFile`` action per ``src/**/*.js`` file, copying
##     the source verbatim into ``dist/``. This matches the Mode A spec's
##     "pure-JS sources skip the transform and are file-copied to
##     ``dist/`` verbatim (one action per file, cheap, but still a cache
##     edge)".
##
## **Design decision (M16 — npx-on-demand for tsc).** Unlike the Python
## convention (which trusts the provisioning catalog to surface
## ``hatchling`` / ``flit_core`` / ``setuptools`` as importable modules)
## the M16 fixtures don't declare ``typescript`` in their
## ``devDependencies``. The convention's wheel-equivalent is therefore
## ``npx --yes typescript@<pin> tsc -p tsconfig.json``: ``npx`` resolves
## ``tsc`` from ``node_modules/.bin`` when a local install exists, falls
## back to an on-demand download into ``~/.npm/_npx/...`` otherwise. The
## ``--yes`` flag suppresses the "Need to install the following packages"
## confirmation prompt. A1 (``npm ci``) is emitted only when both
## ``package.json`` and ``package-lock.json`` are present at the project
## root; the M16 fixtures don't ship a lockfile so A1 is skipped today
## and the convention falls back to ``npx --yes``'s on-demand path.
##
## **Caveats**:
##   * Requires ``node`` (and therefore ``npm`` / ``npx``) on ``PATH``
##     at convention-emit time. ``recognize`` returns ``false`` when
##     ``node`` is missing so dispatch falls through to the no-match
##     diagnostic.
##   * Mode B (the crude ``npm ci && npm run build`` fallback) is **not**
##     wired up at M16. The convention rejects projects that look like
##     Mode-B-required shape (presence of ``vite.config.*`` /
##     ``webpack.config.*`` / ``rollup.config.*`` at the project root) at
##     ``recognize`` time. A future M will add the Mode B branch.
##   * The convention's recognise probe is intentionally permissive on
##     the ``tsconfig.json`` ``isolatedModules`` / ``verbatimModuleSyntax``
##     requirement: modern ``tsc`` (>=5.4) defaults
##     ``verbatimModuleSyntax`` to ``true`` when ``module`` is
##     ``NodeNext``. The convention accepts an absent flag the same way
##     it accepts ``true`` — the spec rule "(or these are defaults under
##     modern tsc)" applies.

import std/[algorithm, os, strutils]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/crude

const
  ScratchDirName* = ".repro/build"
    ## Top-level scratch directory under the project root the JS/TS
    ## convention writes into. Identical to the Nim/Rust/Go/Python
    ## conventions' ``ScratchDirName`` — every language convention owns a
    ## per-entry subdirectory under this prefix.

  ModeBConfigFiles = [
    "vite.config.js", "vite.config.mjs", "vite.config.cjs",
    "vite.config.ts", "vite.config.mts",
    "webpack.config.js", "webpack.config.mjs", "webpack.config.cjs",
    "webpack.config.ts",
    "rollup.config.js", "rollup.config.mjs", "rollup.config.cjs",
    "rollup.config.ts",
    "next.config.js", "next.config.mjs", "next.config.cjs",
    "next.config.ts",
    "nuxt.config.js", "nuxt.config.mjs", "nuxt.config.ts",
    "parcel.config.js", "parcel.config.json",
    "turbo.json",
    "nx.json",
    "lerna.json",
  ]
    ## Root-level config files that force Mode B per the spec
    ## §"Mode selector". M24: instead of declining the project, the
    ## convention claims it and routes to ``jsTsCrudeFallback`` which
    ## delegates to ``npm ci && npm run build`` (or ``npm install &&
    ## npm run build`` if no lockfile).

  ModeBBuildScriptTools = [
    "vite",
    "webpack",
    "rollup",
    "parcel",
    "next",
    "nuxt",
    "tsc -b",
  ]
    ## M24: substrings the convention scans for inside ``package.json``
    ## ``scripts.build``. When the build script invokes any of these
    ## tools, the project is routed to Mode B even if no top-level
    ## ``<tool>.config.*`` file is present (rare but possible — Vite
    ## works without a config file when the project layout matches
    ## defaults; ``tsc -b`` is the TypeScript project-references flag
    ## that drives a multi-package build outside what our Mode A
    ## single-``tsc -p`` action handles).

type
  JsTsMemberKind = enum
    jtmkLibrary
    jtmkExecutable

  JsTsMember = object
    ## Single ``library <name>`` or ``executable <name>`` declaration in
    ## ``reprobuild.nim``. The convention groups members by kind to decide
    ## the action shape: libraries (and node-applications declared as
    ## ``executable`` with no ``bin`` entry) compile via ``tsc -p .``,
    ## while ``executable`` members with a matching ``bin`` entry route
    ## through the per-bin path (also ``tsc -p .`` at M16; A5 esbuild
    ## bundle is deferred).
    name: string
    kind: JsTsMemberKind

  JsTsProjectInfo = object
    ## Parsed essentials from ``<projectRoot>/package.json``. The
    ## convention's action argv is derived from these.
    packageName: string
      ## ``"name"`` field — diagnostic only.
    version: string
      ## ``"version"`` field — diagnostic only.
    isModule: bool
      ## ``"type": "module"`` — required for Mode A recognition.
    binEntries: seq[tuple[name, target: string]]
      ## ``"bin"`` entries. For a single-string ``"bin"`` shape the entry
      ## name defaults to the package name; for the map shape each key is
      ## the binary name and each value is the relative target path.
    hasBuildScript: bool
      ## True when ``"scripts"."build"`` is non-empty — heuristic only.
      ## The M16 surface accepts any value but a future Mode A rule will
      ## reject anything beyond a bare ``tsc -p .`` / ``swc ...`` /
      ## ``esbuild ...`` per the spec.
    buildScriptText: string
      ## M24: literal value of ``scripts.build``. Inspected by
      ## ``buildScriptForcesModeB`` to detect bundler invocations
      ## (vite / webpack / rollup / parcel / next / nuxt / ``tsc -b``)
      ## even when no top-level config file is present.
    hasWorkspaces: bool
      ## M24: true when ``package.json`` carries a non-empty
      ## ``"workspaces"`` field (either the array shape ``["packages/*"]``
      ## or the object shape ``{"packages": ["packages/*"]}``).
      ## Workspaces force Mode B because the convention's Mode A graph
      ## is single-package-shaped.

  TsConfigInfo = object
    ## Subset of ``<projectRoot>/tsconfig.json`` relevant to recognition.
    present: bool
    isolatedModules: bool
    verbatimModuleSyntax: bool
    hasPathsAliases: bool
    hasReferences: bool

proc readReprobuildSource(projectRoot: string): string =
  ## Read the project file (``repro.nim`` or legacy ``reprobuild.nim``)
  ## under ``projectRoot``; return the empty string when neither is
  ## present. Used by both ``recognize`` and ``emitFragment``; never
  ## raises. See ``repro_core/project_file`` for the alias contract.
  let match = resolveProjectFile(projectRoot)
  if match.path.len == 0:
    return ""
  try:
    readFile(extendedPath(match.path))
  except CatchableError:
    ""

proc usesIncludesJsOrTs(source: string): bool =
  ## True when the ``uses:`` block names ``node`` or ``typescript``.
  ## Mirrors the Python/Nim conventions' ``usesIncludes*`` line-scan —
  ## diagnostic-grade, not a DSL evaluator. Accepts the same shapes:
  ##
  ##   uses: node                     # inline single
  ##   uses: [node, typescript]       # inline list
  ##   uses:                          # block form
  ##     "node >=20 <23"
  ##     "typescript >=5.6 <6.0"
  if source.len == 0:
    return false
  var inBlock = false
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
          if firstToken == "node" or firstToken == "typescript":
            return true
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
          if firstToken == "node" or firstToken == "typescript":
            return true
  false

proc extractExecutables(source: string): seq[string] =
  ## Heuristic line-scan for ``executable <name>`` declarations. Mirrors
  ## the Python convention's same-named helper. Accepts both bare
  ## ``executable foo`` and block-form ``executable foo:`` (the trailing
  ## colon is dropped before comparison).
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
  ## Heuristic line-scan for ``library <name>`` declarations.
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

proc extractMembers(source: string): seq[JsTsMember] =
  ## Combine libraries + executables into a single ordered seq.
  for name in extractLibraries(source):
    result.add(JsTsMember(name: name, kind: jtmkLibrary))
  for name in extractExecutables(source):
    result.add(JsTsMember(name: name, kind: jtmkExecutable))

proc skipJsonWhitespace(s: string; i: var int) =
  while i < s.len:
    case s[i]
    of ' ', '\t', '\r', '\n':
      inc i
    of '/':
      # JSON proper doesn't allow comments, but ``tsconfig.json`` is
      # JSONC and routinely carries ``//`` and ``/* */`` comments. The
      # parser tolerates both shapes — the alternative is a JSON5 lib we
      # don't ship.
      if i + 1 < s.len and s[i + 1] == '/':
        while i < s.len and s[i] != '\n':
          inc i
      elif i + 1 < s.len and s[i + 1] == '*':
        inc i, 2
        while i + 1 < s.len and not (s[i] == '*' and s[i + 1] == '/'):
          inc i
        if i + 1 < s.len:
          inc i, 2
      else:
        return
    else:
      return

proc parseJsonString(s: string; i: var int): string =
  ## Parse a double-quoted JSON string starting at ``s[i]``. Advances ``i``
  ## past the closing quote. Handles the small set of escapes the M16
  ## fixtures actually use (``\"``, ``\\``, ``\/``, ``\n``, ``\r``, ``\t``).
  ## On malformed input returns whatever's been collected so far and
  ## bails to the caller — the convention treats parse failures as "not
  ## recognised" rather than raising.
  if i >= s.len or s[i] != '"':
    return
  inc i
  while i < s.len:
    let c = s[i]
    if c == '"':
      inc i
      return
    if c == '\\' and i + 1 < s.len:
      let esc = s[i + 1]
      case esc
      of '"': result.add('"')
      of '\\': result.add('\\')
      of '/': result.add('/')
      of 'n': result.add('\n')
      of 'r': result.add('\r')
      of 't': result.add('\t')
      of 'b': result.add('\b')
      of 'f': result.add('\f')
      else: result.add(esc)
      inc i, 2
      continue
    result.add(c)
    inc i

proc skipJsonValue(s: string; i: var int)
  ## Forward decl — recursive together with the bracket-matchers below.

proc skipJsonObject(s: string; i: var int) =
  if i >= s.len or s[i] != '{':
    return
  inc i
  var depth = 1
  while i < s.len and depth > 0:
    skipJsonWhitespace(s, i)
    if i >= s.len: return
    case s[i]
    of '{':
      inc depth
      inc i
    of '}':
      dec depth
      inc i
    of '"':
      discard parseJsonString(s, i)
    else:
      inc i

proc skipJsonArray(s: string; i: var int) =
  if i >= s.len or s[i] != '[':
    return
  inc i
  var depth = 1
  while i < s.len and depth > 0:
    skipJsonWhitespace(s, i)
    if i >= s.len: return
    case s[i]
    of '[':
      inc depth
      inc i
    of ']':
      dec depth
      inc i
    of '"':
      discard parseJsonString(s, i)
    else:
      inc i

proc skipJsonValue(s: string; i: var int) =
  skipJsonWhitespace(s, i)
  if i >= s.len: return
  case s[i]
  of '"': discard parseJsonString(s, i)
  of '{': skipJsonObject(s, i)
  of '[': skipJsonArray(s, i)
  else:
    while i < s.len and s[i] notin {',', '}', ']', '\n', '\r', '\t', ' '}:
      inc i

proc readBoolLiteral(s: string; i: var int): tuple[ok: bool; value: bool] =
  skipJsonWhitespace(s, i)
  if i + 3 < s.len and s[i .. i + 3] == "true":
    inc i, 4
    return (true, true)
  if i + 4 < s.len and s[i .. i + 4] == "false":
    inc i, 5
    return (true, false)
  (false, false)

proc parsePackageJson(path: string): JsTsProjectInfo =
  ## Minimal JSON line-scan for the fields the convention needs from
  ## ``package.json``. The full JSON grammar isn't worth ingesting here —
  ## the M16 fixtures all fit a flat top-level object with at most one
  ## level of nesting (``"exports"``, ``"bin"``, ``"scripts"``). For
  ## anything fancier than that, the recogniser conservatively returns
  ## a partially-populated record and the convention declines to match.
  if not fileExists(extendedPath(path)):
    return
  var raw: string
  try:
    raw = readFile(extendedPath(path))
  except CatchableError:
    return
  var i = 0
  skipJsonWhitespace(raw, i)
  if i >= raw.len or raw[i] != '{':
    return
  inc i
  while i < raw.len:
    skipJsonWhitespace(raw, i)
    if i >= raw.len or raw[i] == '}':
      break
    if raw[i] == ',':
      inc i
      continue
    if raw[i] != '"':
      inc i
      continue
    let key = parseJsonString(raw, i)
    skipJsonWhitespace(raw, i)
    if i >= raw.len or raw[i] != ':':
      continue
    inc i
    skipJsonWhitespace(raw, i)
    case key
    of "name":
      result.packageName = parseJsonString(raw, i)
    of "version":
      result.version = parseJsonString(raw, i)
    of "type":
      let typeStr = parseJsonString(raw, i)
      if typeStr == "module":
        result.isModule = true
    of "bin":
      if i < raw.len and raw[i] == '"':
        # Single-string form: bin is the package name.
        let target = parseJsonString(raw, i)
        let entryName =
          if result.packageName.len > 0: result.packageName
          else: "main"
        result.binEntries.add((name: entryName, target: target))
      elif i < raw.len and raw[i] == '{':
        # Map form: each key is a binary name.
        inc i
        while i < raw.len:
          skipJsonWhitespace(raw, i)
          if i >= raw.len or raw[i] == '}':
            if i < raw.len: inc i
            break
          if raw[i] == ',':
            inc i
            continue
          if raw[i] != '"':
            inc i
            continue
          let binName = parseJsonString(raw, i)
          skipJsonWhitespace(raw, i)
          if i < raw.len and raw[i] == ':':
            inc i
            skipJsonWhitespace(raw, i)
            if i < raw.len and raw[i] == '"':
              let target = parseJsonString(raw, i)
              result.binEntries.add((name: binName, target: target))
            else:
              skipJsonValue(raw, i)
      else:
        skipJsonValue(raw, i)
    of "scripts":
      # Walk the scripts object looking for ``"build"``.
      if i < raw.len and raw[i] == '{':
        inc i
        while i < raw.len:
          skipJsonWhitespace(raw, i)
          if i >= raw.len or raw[i] == '}':
            if i < raw.len: inc i
            break
          if raw[i] == ',':
            inc i
            continue
          if raw[i] != '"':
            inc i
            continue
          let scriptName = parseJsonString(raw, i)
          skipJsonWhitespace(raw, i)
          if i < raw.len and raw[i] == ':':
            inc i
            skipJsonWhitespace(raw, i)
            if i < raw.len and raw[i] == '"':
              let scriptValue = parseJsonString(raw, i)
              if scriptName == "build" and scriptValue.len > 0:
                result.hasBuildScript = true
                result.buildScriptText = scriptValue
            else:
              skipJsonValue(raw, i)
      else:
        skipJsonValue(raw, i)
    of "workspaces":
      # M24: workspaces force Mode B. Accept both shapes:
      #   "workspaces": ["packages/*"]
      #   "workspaces": { "packages": ["packages/*"] }
      # Anything non-empty counts; we don't enumerate the entries.
      if i < raw.len and raw[i] == '[':
        let arrStart = i
        skipJsonArray(raw, i)
        for ch in raw[arrStart + 1 ..< min(i - 1, raw.len)]:
          if ch notin {' ', '\t', '\r', '\n'}:
            result.hasWorkspaces = true
            break
      elif i < raw.len and raw[i] == '{':
        let objStart = i
        skipJsonObject(raw, i)
        for ch in raw[objStart + 1 ..< min(i - 1, raw.len)]:
          if ch notin {' ', '\t', '\r', '\n'}:
            result.hasWorkspaces = true
            break
      else:
        skipJsonValue(raw, i)
    else:
      skipJsonValue(raw, i)

proc parseTsConfigJson(path: string): TsConfigInfo =
  ## Pull just the ``compilerOptions`` flags Mode A's recognise probe
  ## cares about. The line-scan walks until it lands on
  ## ``"compilerOptions"``, then reads the boolean keys we care about.
  ## ``references`` / ``paths`` short-circuit recognition.
  if not fileExists(extendedPath(path)):
    return
  result.present = true
  var raw: string
  try:
    raw = readFile(extendedPath(path))
  except CatchableError:
    return
  var i = 0
  skipJsonWhitespace(raw, i)
  if i >= raw.len or raw[i] != '{':
    return
  inc i
  while i < raw.len:
    skipJsonWhitespace(raw, i)
    if i >= raw.len or raw[i] == '}':
      break
    if raw[i] == ',':
      inc i
      continue
    if raw[i] != '"':
      inc i
      continue
    let key = parseJsonString(raw, i)
    skipJsonWhitespace(raw, i)
    if i >= raw.len or raw[i] != ':':
      continue
    inc i
    skipJsonWhitespace(raw, i)
    case key
    of "references":
      if i < raw.len and raw[i] == '[':
        # Non-empty references array trips Mode B.
        let arrStart = i
        skipJsonArray(raw, i)
        # Quick scan: did the array contain anything besides whitespace?
        for ch in raw[arrStart + 1 ..< min(i - 1, raw.len)]:
          if ch notin {' ', '\t', '\r', '\n'}:
            result.hasReferences = true
            break
      else:
        skipJsonValue(raw, i)
    of "compilerOptions":
      if i < raw.len and raw[i] == '{':
        inc i
        while i < raw.len:
          skipJsonWhitespace(raw, i)
          if i >= raw.len or raw[i] == '}':
            if i < raw.len: inc i
            break
          if raw[i] == ',':
            inc i
            continue
          if raw[i] != '"':
            inc i
            continue
          let optKey = parseJsonString(raw, i)
          skipJsonWhitespace(raw, i)
          if i < raw.len and raw[i] == ':':
            inc i
            skipJsonWhitespace(raw, i)
            case optKey
            of "isolatedModules":
              let (ok, value) = readBoolLiteral(raw, i)
              if ok and value:
                result.isolatedModules = true
              elif not ok:
                skipJsonValue(raw, i)
            of "verbatimModuleSyntax":
              let (ok, value) = readBoolLiteral(raw, i)
              if ok and value:
                result.verbatimModuleSyntax = true
              elif not ok:
                skipJsonValue(raw, i)
            of "paths":
              if i < raw.len and raw[i] == '{':
                let objStart = i
                skipJsonObject(raw, i)
                for ch in raw[objStart + 1 ..< min(i - 1, raw.len)]:
                  if ch notin {' ', '\t', '\r', '\n'}:
                    result.hasPathsAliases = true
                    break
              else:
                skipJsonValue(raw, i)
            else:
              skipJsonValue(raw, i)
      else:
        skipJsonValue(raw, i)
    else:
      skipJsonValue(raw, i)

proc nodeExecutable(): string =
  ## Resolve ``node`` on PATH or return ``""``.
  findExe("node")

proc npxExecutable(): string =
  ## Resolve ``npx`` on PATH or return ``""``. M16 routes ``tsc`` through
  ## ``npx --yes`` which auto-downloads typescript when the project doesn't
  ## declare it locally.
  findExe("npx")

proc npmExecutable(): string =
  ## Resolve ``npm`` on PATH or return ``""``. M21 A1 routes the dependency
  ## install through ``npm ci`` when a ``package-lock.json`` is present.
  findExe("npm")

proc hasModeBConfig(projectRoot: string): bool =
  for name in ModeBConfigFiles:
    if fileExists(extendedPath(projectRoot / name)):
      return true
  false

proc buildScriptForcesModeB(buildScript: string): bool =
  ## M24: True when ``buildScript`` (the literal value of
  ## ``package.json``'s ``scripts.build``) invokes a Mode B-only tool
  ## (vite / webpack / rollup / parcel / next / nuxt) OR carries the
  ## ``tsc -b`` project-references flag.
  ##
  ## Match shape: case-insensitive substring of a *space-delimited
  ## token*. Bare substring matching would false-positive on things
  ## like ``my-vite-plugin-foo``; we tokenise on whitespace and check
  ## each token against the catalog. ``tsc -b`` is handled specially
  ## (it's a flag-pair, not a single token) by a separate substring
  ## probe.
  if buildScript.len == 0:
    return false
  let lower = buildScript.toLowerAscii
  # Explicit ``tsc -b`` / ``tsc --build`` probe (flag-pair, not a token).
  if " tsc -b" in lower or lower.startsWith("tsc -b") or
     " tsc --build" in lower or lower.startsWith("tsc --build"):
    return true
  # Tokenise on whitespace + the shell separators that npm splits on
  # before exec. Each token is compared against the catalog modulo a
  # leading ``./node_modules/.bin/`` prefix that some projects use.
  for raw in lower.split({' ', '\t', '\n', '\r', '&', '|', ';'}):
    var token = raw
    # Strip leading shell-redirect / call markers.
    while token.len > 0 and token[0] in {'(', '`', '$'}:
      token = token[1 .. ^1]
    # Strip a ``./node_modules/.bin/`` (or ``node_modules/.bin/``) prefix
    # so the catalog match works regardless of how the project invokes
    # its tool.
    const NodeModulesBinPrefixes = [
      "./node_modules/.bin/",
      "node_modules/.bin/",
    ]
    for prefix in NodeModulesBinPrefixes:
      if token.startsWith(prefix):
        token = token[prefix.len .. ^1]
        break
    if token.len == 0:
      continue
    for tool in ModeBBuildScriptTools:
      # ``tsc -b`` was already handled above.
      if tool == "tsc -b":
        continue
      if token == tool:
        return true
  false

proc projectRequiresModeB(projectRoot: string;
                          info: JsTsProjectInfo): bool =
  ## M24: True when the project should be routed to ``jsTsCrudeFallback``
  ## instead of the Mode A sub-graph. Triggered by ANY of:
  ##   * a root-level ``<tool>.config.*`` config file (vite / webpack /
  ##     rollup / parcel / next / nuxt / turbo / nx / lerna)
  ##   * ``package.json``'s ``scripts.build`` invokes one of those tools
  ##     (or carries ``tsc -b`` for TypeScript project references)
  ##   * ``package.json`` declares a non-empty ``workspaces`` field
  if hasModeBConfig(projectRoot):
    return true
  if info.hasWorkspaces:
    return true
  if buildScriptForcesModeB(info.buildScriptText):
    return true
  false

proc collectTsSources(srcDir: string): seq[string] =
  ## Walk ``<projectRoot>/src`` for ``.ts`` / ``.tsx`` / ``.mts`` / ``.cts``
  ## files. The convention's compile action declares these as inputs so
  ## the engine's action cache invalidates the action on source edits.
  if not dirExists(extendedPath(srcDir)):
    return @[]
  for entry in walkDirRec(srcDir):
    let lower = entry.toLowerAscii
    if lower.endsWith(".ts") or lower.endsWith(".tsx") or
       lower.endsWith(".mts") or lower.endsWith(".cts"):
      result.add(entry)
  result.sort(system.cmp[string])

proc collectJsSources(srcDir: string): seq[string] =
  ## Walk ``<projectRoot>/src`` for ``.js`` / ``.mjs`` / ``.cjs`` files.
  if not dirExists(extendedPath(srcDir)):
    return @[]
  for entry in walkDirRec(srcDir):
    let lower = entry.toLowerAscii
    if lower.endsWith(".js") or lower.endsWith(".mjs") or
       lower.endsWith(".cjs"):
      result.add(entry)
  result.sort(system.cmp[string])

proc hasEntryPoint(projectRoot: string;
                   pkg: JsTsProjectInfo): bool =
  ## True when AT LEAST ONE of:
  ##   * ``src/index.ts`` exists
  ##   * ``src/index.js`` exists
  ##   * a ``bin`` entry resolves to ``src/bin/<name>.ts`` or
  ##     ``src/bin/<name>.js``
  if fileExists(extendedPath(projectRoot / "src" / "index.ts")):
    return true
  if fileExists(extendedPath(projectRoot / "src" / "index.js")):
    return true
  for entry in pkg.binEntries:
    # ``"bin"."name": "./dist/bin/<x>.js"`` — strip the ``./dist`` prefix
    # and probe the matching ``./src/bin/<x>.{ts,js}`` source.
    let target = entry.target.replace('\\', '/')
    if target.startsWith("./dist/") or target.startsWith("dist/"):
      var stem = target.replace("./dist/", "").replace("dist/", "")
      if stem.endsWith(".js"):
        stem = stem[0 ..< stem.len - 3]
      elif stem.endsWith(".mjs"):
        stem = stem[0 ..< stem.len - 4]
      let tsCandidate = projectRoot / "src" / stem & ".ts"
      let jsCandidate = projectRoot / "src" / stem & ".js"
      if fileExists(extendedPath(tsCandidate)) or
         fileExists(extendedPath(jsCandidate)):
        return true
  false

proc jsTsRecognize(projectRoot: string;
                   request: ProviderGraphRequest): bool {.gcsafe.} =
  ## Recognition contract (M16 Mode A + M24 Mode B):
  ##
  ## Common prerequisites (BOTH modes):
  ##   * ``<projectRoot>/package.json`` exists
  ##   * ``<projectRoot>/reprobuild.nim`` exists AND its ``uses:`` lists
  ##     ``node`` or ``typescript``
  ##   * the package declares at least one ``library`` or ``executable``
  ##     member
  ##   * ``node`` is on PATH (so emit can spawn the tooling)
  ##
  ## M24 Mode B (when ``projectRequiresModeB`` fires — vite/webpack/
  ## rollup/parcel/next/nuxt config file at root, ``scripts.build``
  ## invokes one of those tools, ``tsc -b`` for project references,
  ## or ``package.json`` carries a non-empty ``workspaces`` field):
  ##   * a non-empty ``scripts.build`` MUST be present so the crude
  ##     fallback knows what to invoke
  ##
  ## M16 Mode A (otherwise — pure-Node app or single-tsconfig.json TS
  ## library/CLI):
  ##   * ``package.json`` declares ``"type": "module"`` (ESM)
  ##   * ``tsconfig.json`` (if present) does NOT carry ``paths`` aliases
  ##     or non-empty ``references`` (both force Mode B per the spec)
  ##   * at least one entry source exists (``src/index.ts`` /
  ##     ``src/index.js`` / a ``bin`` entry resolving to
  ##     ``src/bin/<name>.{ts,js}``)
  if not fileExists(extendedPath(projectRoot / "package.json")):
    return false
  let source = readReprobuildSource(projectRoot)
  if source.len == 0:
    return false
  if not usesIncludesJsOrTs(source):
    return false
  let members = extractMembers(source)
  if members.len == 0:
    return false
  if nodeExecutable().len == 0:
    return false
  let pkg = parsePackageJson(projectRoot / "package.json")
  let ts = parseTsConfigJson(projectRoot / "tsconfig.json")
  let needsModeB = projectRequiresModeB(projectRoot, pkg) or
                   (ts.present and (ts.hasPathsAliases or ts.hasReferences))
  if needsModeB:
    # M24: Mode B claims the project. The convention needs a
    # ``scripts.build`` entry so the crude fallback knows what to run —
    # without it we can't synthesise a meaningful build command and
    # would just fail at apply time. Declining recognition keeps the
    # diagnostic clean ("no convention matched") rather than emitting
    # a fragment that's guaranteed to fail.
    if not pkg.hasBuildScript:
      return false
    return true
  # Mode A prerequisites:
  if not pkg.isModule:
    return false
  if not hasEntryPoint(projectRoot, pkg):
    return false
  true

proc scratchPathFor(projectRoot: string): string =
  projectRoot / ScratchDirName

proc distDirFor(projectRoot: string): string =
  ## M16 places the compiled output directly under ``.repro/build/dist``
  ## (a flat per-project tree). The Mode A spec's A6 step would later
  ## hardlink/symlink into ``<projectRoot>/dist`` via the package's
  ## ``"exports"`` map; the M16 surface points the validate scripts at
  ## the scratch dir directly.
  scratchPathFor(projectRoot) / "dist"

proc sanitizeNamePart(value: string): string =
  for ch in value:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = "x"

proc emitTscCompileAction(projectRoot, npxExe: string;
                          tsSources, jsSources: seq[string];
                          tsConfigPath: string;
                          distDir: string;
                          expectedOutputs: seq[string];
                          deps: seq[string] = @[]):
                            BuildActionDef =
  ## Emit the single ``npx tsc -p tsconfig.json --outDir <distDir>``
  ## action. ``--outDir`` on the command line wins over the
  ## ``compilerOptions.outDir`` from ``tsconfig.json`` so we can redirect
  ## the build into the convention's scratch dir without mutating the
  ## checked-in config.
  ##
  ## ``--declaration`` + ``--declarationMap`` ensure the ``.d.ts`` /
  ## ``.d.ts.map`` files are emitted regardless of what the project's
  ## ``tsconfig.json`` toggled. The fixture ``tsconfig.json`` already
  ## sets these so the explicit flag is defensive.
  ##
  ## ``--rootDir`` is pinned to ``<projectRoot>/src`` so ``tsc`` mirrors
  ## the source tree under ``distDir`` (otherwise ``tsc`` chooses the
  ## longest common path of all inputs and the output layout shifts when
  ## the source tree grows or shrinks).
  let argv = @[
    npxExe,
    "--yes",
    "--package", "typescript@5.6",
    "tsc",
    "-p", tsConfigPath,
    "--outDir", distDir,
    "--rootDir", projectRoot / "src",
    "--declaration",
    "--declarationMap",
  ]
  var inputs: seq[string] = @[]
  for src in tsSources:
    inputs.add(src)
  for src in jsSources:
    inputs.add(src)
  inputs.add(tsConfigPath)
  inputs.add(projectRoot / "package.json")
  let action = buildAction(
    id = "jsts-tsc-compile",
    call = inlineExecCall(argv, projectRoot),
    deps = deps,
    inputs = inputs,
    outputs = expectedOutputs,
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "jsts.tsc-compile")
  action

proc predictedTscOutputs(projectRoot, distDir: string;
                         tsSources, jsSources: seq[string]):
                           seq[string] =
  ## Predict the ``.js`` / ``.d.ts`` filenames ``tsc`` will emit. Mirrors
  ## tsc's path-rewriting rules: each ``src/<rel>.ts`` lands at
  ## ``<distDir>/<rel>.js`` (with ``--declaration`` also producing
  ## ``<distDir>/<rel>.d.ts``). ``.tsx`` becomes ``.jsx`` only when
  ## ``jsx: preserve`` is set in ``tsconfig.json`` — for the M16 fixtures
  ## we don't have ``.tsx`` so we keep the prediction simple.
  ##
  ## ``.js`` sources under ``src/`` are NOT copied by ``tsc`` unless
  ## ``allowJs`` is set, so the JS-only ``node-server`` fixture uses a
  ## separate file-copy code path. ``tsSources`` is therefore the only
  ## input the prediction loops over here.
  let srcDir = projectRoot / "src"
  for tsPath in tsSources:
    let rel = relativePath(tsPath, srcDir).replace('\\', '/')
    var stem = rel
    if stem.endsWith(".ts"):
      stem = stem[0 ..< stem.len - 3]
    elif stem.endsWith(".tsx"):
      stem = stem[0 ..< stem.len - 4]
    elif stem.endsWith(".mts"):
      stem = stem[0 ..< stem.len - 4]
    elif stem.endsWith(".cts"):
      stem = stem[0 ..< stem.len - 4]
    else:
      continue
    result.add(distDir / (stem & ".js"))
    result.add(distDir / (stem & ".d.ts"))
  discard jsSources  # reserved — see comment above
  result.sort(system.cmp[string])

proc hasLockfile(projectRoot: string): bool =
  ## M21 A1 gate: ``npm ci`` requires a ``package-lock.json`` (or
  ## ``npm-shrinkwrap.json``) at the project root. The convention only
  ## emits the A1 action when this gate fires; absent a lockfile the
  ## M16 ``npx --yes`` on-demand path remains in effect.
  fileExists(extendedPath(projectRoot / "package-lock.json")) or
    fileExists(extendedPath(projectRoot / "npm-shrinkwrap.json"))

proc emitNpmCiAction(projectRoot, npmExe: string): BuildActionDef =
  ## M21 A1: emit the dep-install action. ``npm ci`` is preferred over
  ## ``npm install`` because it bypasses the dependency solver and
  ## installs the exact tree the lockfile records. Flags:
  ##
  ##   * ``--prefer-offline`` — use the local npm cache when entries
  ##     exist; only hit the network for misses. Cheap on warm runs.
  ##   * ``--no-audit`` — skip the post-install vulnerability scan
  ##     (would phone home; not part of the build contract).
  ##   * ``--no-fund`` — skip the "please fund us" footer printed to
  ##     stdout. Reduces noise in repro logs.
  ##   * ``--no-progress`` — disable the progress bar (TTY mangling
  ##     under captured output).
  ##
  ## The action's declared output is the ``node_modules/`` directory at
  ## the project root. The engine treats directory outputs opaquely —
  ## the action's success condition is "directory exists after the
  ## command runs"; individual file enumeration happens via
  ## ``automaticMonitorPolicy()`` (the io-monitor attaches the actually-
  ## read/written file set after the fact). Consumer actions (tsc,
  ## esbuild) reference the action's id in their ``deps``.
  let nodeModulesDir = projectRoot / "node_modules"
  let argv = @[
    npmExe,
    "ci",
    "--prefer-offline",
    "--no-audit",
    "--no-fund",
    "--no-progress",
  ]
  let inputs = @[
    projectRoot / "package.json",
    projectRoot / "package-lock.json",
  ]
  buildAction(
    id = "jsts-npm-ci",
    call = inlineExecCall(argv, projectRoot),
    inputs = inputs,
    outputs = @[nodeModulesDir],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "jsts.npm-ci")

proc deriveEntrySourceForBin(projectRoot: string;
                             binTarget: string): string =
  ## Map a ``"bin": { "<name>": "./dist/bin/<x>.js" }`` value back to
  ## the corresponding ``src/bin/<x>.ts`` (preferred) or ``src/bin/<x>.js``
  ## source. Returns ``""`` when no source candidate exists on disk.
  let normalised = binTarget.replace('\\', '/')
  var stem = normalised
  if stem.startsWith("./"):
    stem = stem[2 .. ^1]
  if stem.startsWith("dist/"):
    stem = stem[5 .. ^1]
  if stem.endsWith(".js"):
    stem = stem[0 ..< stem.len - 3]
  elif stem.endsWith(".mjs"):
    stem = stem[0 ..< stem.len - 4]
  let tsCandidate = projectRoot / "src" / stem & ".ts"
  if fileExists(extendedPath(tsCandidate)):
    return tsCandidate
  let jsCandidate = projectRoot / "src" / stem & ".js"
  if fileExists(extendedPath(jsCandidate)):
    return jsCandidate
  ""

proc emitEsbuildAction(projectRoot, npxExe, entrySource, outFile,
                       metafile: string;
                       binName: string;
                       deps: seq[string]): BuildActionDef =
  ## M21 A5: emit one ``esbuild --bundle`` action per ``"bin"`` entry.
  ## The bundle collapses the entry source + every transitive import
  ## (from ``node_modules/`` and the rest of ``src/``) into a single
  ## self-contained ``.js`` file.
  ##
  ## Routed through ``npx --yes esbuild@0.24.0`` so the convention works
  ## both with a ``devDependency`` pin (``npm ci`` installed the matching
  ## bin under ``node_modules/.bin/esbuild``; npx prefers it) and on a
  ## fresh checkout that never ran ``npm ci`` (npx downloads
  ## ``esbuild@0.24.0`` into ``~/.npm/_npx/...``). The version pin keeps
  ## the bundle byte-stable across machines.
  ##
  ## ``--format=esm`` matches the ``"type": "module"`` package contract.
  ## ``--platform=node`` keeps node built-ins external (no shimming
  ## fs/path/etc. into the bundle). ``--metafile`` writes a JSON sidecar
  ## listing every file esbuild visited; a future incremental rebuild
  ## pass can consume this for fine-grained dep capture.
  let argv = @[
    npxExe,
    "--yes",
    "--package", "esbuild@0.24.0",
    "esbuild",
    "--bundle",
    entrySource,
    "--format=esm",
    "--platform=node",
    "--outfile=" & outFile,
    "--metafile=" & metafile,
  ]
  buildAction(
    id = "jsts-esbuild-bundle-" & sanitizeNamePart(binName),
    call = inlineExecCall(argv, projectRoot),
    deps = deps,
    inputs = @[entrySource, projectRoot / "package.json"],
    outputs = @[outFile, metafile],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "jsts.esbuild-bundle")

proc renderWindowsShim(bundlePath: string): string {.used.} =
  ## Render a ``.cmd`` launcher that ``node``-spawns ``bundlePath`` and
  ## forwards all command-line arguments. ``%*`` expands to the full
  ## argv after the script name. Quoted to handle paths with spaces.
  ## Uses ``@echo off`` so the shim doesn't echo each command to stdout
  ## under TTY (matches what npm's bin shims look like).
  "@echo off\r\nnode \"" & bundlePath.replace('/', '\\') & "\" %*\r\n"

proc renderPosixShim(bundlePath: string): string {.used.} =
  ## Render a POSIX hashbang shim. The shim exec-replaces itself with
  ## node so the launcher's process tree is single-level (no shell
  ## intermediate). ``"$@"`` passthrough quotes embedded spaces in the
  ## individual argv entries.
  "#!/usr/bin/env bash\nexec node \"" & bundlePath & "\" \"$@\"\n"

proc shimFilename(binName: string): string =
  when defined(windows):
    binName & ".cmd"
  else:
    binName

proc emitShimAction(projectRoot, shimDir, bundlePath: string;
                    binName: string;
                    esbuildActionId: string):
                      tuple[action: BuildActionDef; shimPath: string] =
  ## M21 A6: emit an ``fs.writeText`` action that materialises the
  ## launcher shim. The shim's text is fully resolved at convention-emit
  ## time (it embeds the absolute ``bundlePath``); the action exists so
  ## the engine tracks the file as a declared output and re-creates it
  ## after a scratch wipe.
  ##
  ## ``deps`` references the esbuild action so the engine schedules the
  ## shim AFTER the bundle is written; otherwise the shim could be
  ## emitted first and the launcher's target wouldn't exist at the
  ## moment of writeText (it does on second invocation but the action
  ## order is determined by the deps graph, not by FS state).
  let shimPath = shimDir / shimFilename(binName)
  createDir(extendedPath(parentDir(shimPath)))
  let text =
    when defined(windows): renderWindowsShim(bundlePath)
    else:                  renderPosixShim(bundlePath)
  let action = fs.writeText(
    output = shimPath,
    text = text,
    actionId = "jsts-shim-" & sanitizeNamePart(binName),
    deps = [esbuildActionId],
    commandStatsId = "jsts.shim")
  (action, shimPath)

proc collectTestFiles(projectRoot: string): seq[string] =
  ## M21 A7: walk ``<projectRoot>/test/`` and ``<projectRoot>/src/`` for
  ## files ending in ``.test.ts``, ``.test.tsx``, ``.test.mts``,
  ## ``.test.cts``, ``.test.js``, ``.test.mjs``, ``.test.cjs``. Files
  ## under ``node_modules/`` and ``.repro/`` are skipped. The result is
  ## deterministically sorted so the test-runner action's argv (and
  ## therefore its cache fingerprint) is stable across emits.
  let testRoots = @[projectRoot / "test", projectRoot / "src"]
  for root in testRoots:
    if not dirExists(extendedPath(root)):
      continue
    for entry in walkDirRec(root):
      let normalised = entry.replace('\\', '/')
      if "/node_modules/" in normalised:
        continue
      if "/.repro/" in normalised:
        continue
      let lower = entry.toLowerAscii
      if lower.endsWith(".test.ts") or lower.endsWith(".test.tsx") or
         lower.endsWith(".test.mts") or lower.endsWith(".test.cts") or
         lower.endsWith(".test.js") or lower.endsWith(".test.mjs") or
         lower.endsWith(".test.cjs"):
        result.add(entry)
  result.sort(system.cmp[string])

proc emitTestRunnerAction(projectRoot, nodeExe: string;
                          testFiles: seq[string];
                          deps: seq[string]): BuildActionDef =
  ## M21 A7: emit a single ``node --test --import=tsx <files...>`` action
  ## that runs every discovered test file under the node test runner with
  ## the ``tsx`` loader (so ``.test.ts`` files run without a separate
  ## tsc step).
  ##
  ## The action declares the test files as inputs and produces NO file
  ## outputs (it's a verification action — its success condition is
  ## ``exit 0``). ``automaticMonitorPolicy()`` covers transitive source
  ## reads under ``src/`` (the tests typically ``import`` the
  ## implementation under test).
  ##
  ## ``tsx`` is invoked via ``--import=tsx`` (the modern ``--loader``
  ## replacement) which registers tsx as the ESM loader hook. The
  ## convention assumes ``tsx`` is installed locally (via ``npm ci``)
  ## OR globally; the M21 typescript-cli fixture declares it as a
  ## devDependency so ``npm ci`` makes it available via
  ## ``node_modules/.bin/tsx``. node's --import resolves bare specifiers
  ## via Node's module-resolution algorithm so the local install lights
  ## up automatically.
  var argv = @[
    nodeExe,
    "--test",
    "--import=tsx",
  ]
  for f in testFiles:
    argv.add(f)
  var inputs = @[projectRoot / "package.json"]
  for f in testFiles:
    inputs.add(f)
  buildAction(
    id = "jsts-test-run",
    call = inlineExecCall(argv, projectRoot),
    deps = deps,
    inputs = inputs,
    outputs = @[],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "jsts.test-run")

proc filteredTscOutputs(rawOutputs: seq[string];
                        excludedJsOutputs: seq[string]): seq[string] =
  ## Drop entries in ``excludedJsOutputs`` from ``rawOutputs`` so the
  ## convention's tsc action doesn't redundantly declare a ``.js`` path
  ## that an esbuild bundle action also declares (the engine forbids
  ## two actions declaring the same output). Equality is path-string
  ## exact match — the predicted outputs and the excluded list are both
  ## generated by the convention, so the strings line up.
  for o in rawOutputs:
    if o in excludedJsOutputs:
      continue
    result.add(o)

proc syntheticPackage(projectRoot: string;
                      members: seq[JsTsMember];
                      info: JsTsProjectInfo): PackageDef =
  ## Build a minimal ``PackageDef`` the runtime helper wants.
  var name = "javascript_typescript_convention"
  if info.packageName.len > 0:
    name = sanitizeNamePart(info.packageName)
  elif members.len > 0:
    name = members[0].name
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

proc emitJsCopyAction(projectRoot, distDir: string;
                      jsSource: string;
                      copyIndex: int): tuple[action: BuildActionDef;
                                              dest: string] =
  ## Single-file copy from ``src/<rel>.js`` to ``<distDir>/<rel>.js``.
  ## Used for the JS-only ``node-server`` fixture; mirrors the spec's
  ## "pure-JS sources skip the transform and are file-copied to
  ## ``dist/`` verbatim (one action per file)".
  let srcDir = projectRoot / "src"
  let rel = relativePath(jsSource, srcDir).replace('\\', '/')
  let dest = distDir / rel
  createDir(extendedPath(parentDir(dest)))
  let action = fs.copyFile(
    source = jsSource,
    output = dest,
    actionId = "jsts-copy-js-" & $copyIndex & "-" & sanitizeNamePart(rel),
    commandStatsId = "jsts.copy-js")
  (action, dest)

proc jsTsCrudeFallback(projectRoot: string;
                       request: ProviderGraphRequest;
                       pkg: JsTsProjectInfo):
                         GraphFragment {.gcsafe.} =
  ## M24: Mode B emitter for JS/TS projects that exercise tooling
  ## outside the Mode A surface (vite / webpack / rollup / parcel /
  ## next / nuxt config files, ``tsc -b`` project references,
  ## non-empty ``workspaces`` field). Delegates to either
  ## ``npm ci && npm run build`` (when a ``package-lock.json`` is
  ## present) or ``npm install && npm run build`` (otherwise) under
  ## io-monitor monitoring per the M6 spec.
  ##
  ## **Design decision — npm ci vs npm install**:
  ##
  ##   * ``npm ci`` is strict-deterministic: it requires the lockfile
  ##     to be in sync with ``package.json``, refuses to mutate either,
  ##     and reinstalls ``node_modules/`` from scratch every time. This
  ##     is exactly what reproducible-build semantics want; whenever a
  ##     lockfile is available we prefer this path.
  ##   * ``npm install`` falls back when no lockfile is present. It WILL
  ##     resolve the dep tree freshly (potentially picking up patch
  ##     bumps within the declared ranges) and update the lockfile.
  ##     This loses some reproducibility but matches the project's
  ##     intent: a project that ships package.json without a lockfile
  ##     is explicitly opting out of pinning.
  ##
  ## The single argv runs ``cmd.exe /c "<install> && npm run build"`` on
  ## Windows and ``sh -c "<install> && npm run build"`` on POSIX so the
  ## two stages flow through a single shell process and ``&&`` chaining
  ## is honoured. An alternative would be to emit two separate actions
  ## (install + build) but that requires plumbing the install action's
  ## id into the build action's deps, and the crude_fallback API
  ## emits exactly one action by design — splitting would mean dropping
  ## down to ``buildPackageFragment`` directly, which is gratuitous
  ## complexity for the M24 scope.
  ##
  ## Outputs declared opaquely: ``dist`` (vite/webpack/rollup default),
  ## ``build`` (next/parcel/CRA default), ``.next`` (Next.js prod
  ## output), ``.nuxt`` (Nuxt prod output). The io-monitor monitor
  ## promotes whichever subset the build actually writes to.
  {.cast(gcsafe).}:
    let npmExe = npmExecutable()
    if npmExe.len == 0:
      raise newException(ValueError,
        "javascript-typescript convention: 'npm' not on PATH; cannot " &
          "run the Mode B crude fallback")
    var packageName = pkg.packageName
    if packageName.len == 0:
      packageName = projectRoot.extractFilename
    if packageName.len == 0:
      packageName = "jsts-crude"
    # Determine install verb based on lockfile presence.
    let installVerb =
      if hasLockfile(projectRoot): "ci"
      else: "install"
    # Construct a single shell command so the install + build chain
    # through a single child process. ``npm`` itself doesn't accept
    # chained subcommands; the shell does the chaining.
    let shellLine = npmExe & " " & installVerb & " && " & npmExe &
      " run build"
    let argv =
      when defined(windows):
        @["cmd.exe", "/d", "/s", "/c", shellLine]
      else:
        @["sh", "-c", shellLine]
    result = emitCrudeFragment(
      projectRoot = projectRoot,
      request = request,
      packageName = packageName,
      nativeBuildArgv = argv,
      outputDirs = ["dist", "build", ".next", ".nuxt", "node_modules"])

proc jsTsEmitFragment(projectRoot: string;
                      request: ProviderGraphRequest):
                        GraphFragment {.gcsafe.} =
  ## Convention entry — parse ``package.json`` + (optional)
  ## ``tsconfig.json``, classify the project as TS-bearing vs JS-only
  ## vs M24 Mode B, emit the appropriate sub-graph and hand it to
  ## ``buildPackageFragment``.
  ##
  ## **M24 routing**: when ``projectRequiresModeB`` fires (vite/webpack/
  ## rollup/parcel/next/nuxt config file, ``scripts.build`` invokes one
  ## of those tools, ``tsc -b``, or non-empty workspaces field) OR when
  ## ``tsconfig.json`` carries ``paths``/``references``, delegate to
  ## ``jsTsCrudeFallback`` rather than emit the Mode A sub-graph.
  {.cast(gcsafe).}:
    let source = readReprobuildSource(projectRoot)
    let members = extractMembers(source)
    if members.len == 0:
      let projectMatch = resolveProjectFile(projectRoot)
      let projectFile =
        if projectMatch.path.len > 0: projectMatch.path
        else: projectRoot / LegacyProjectFileName
      raise newException(ValueError,
        "javascript-typescript convention: no library or executable " &
          "members declared in " & projectFile)
    let pkg = parsePackageJson(projectRoot / "package.json")
    # M24: route Mode B projects to the crude fallback first. The
    # routing condition mirrors ``jsTsRecognize``'s Mode B branch so
    # any project that recognises as Mode B emits as Mode B.
    let tsModeB = block:
      let ts = parseTsConfigJson(projectRoot / "tsconfig.json")
      ts.present and (ts.hasPathsAliases or ts.hasReferences)
    if projectRequiresModeB(projectRoot, pkg) or tsModeB:
      return jsTsCrudeFallback(projectRoot, request, pkg)
    let tsConfigPath = projectRoot / "tsconfig.json"
    let hasTsConfig = fileExists(extendedPath(tsConfigPath))
    let tsSources = collectTsSources(projectRoot / "src")
    let jsSources = collectJsSources(projectRoot / "src")
    if tsSources.len == 0 and jsSources.len == 0:
      raise newException(ValueError,
        "javascript-typescript convention: no .ts/.tsx/.js sources " &
          "found under " & (projectRoot / "src"))
    let nodeExe = nodeExecutable()
    if nodeExe.len == 0:
      raise newException(ValueError,
        "javascript-typescript convention: 'node' executable not on " &
          "PATH; cannot run the tooling")
    let synthetic = syntheticPackage(projectRoot, members, pkg)
    let distDir = distDirFor(projectRoot)
    let shimDir = scratchPathFor(projectRoot) / "bin"
    let testFiles = collectTestFiles(projectRoot)
    let projectHasLockfile = hasLockfile(projectRoot)
    createDir(extendedPath(distDir))
    let registerAll = proc() =
      discard buildPool("compile", 8'u32)
      var allActions: seq[BuildActionDef] = @[]
      var testActions: seq[BuildActionDef] = @[]

      # M21 A1: npm ci action — only when a lockfile is present. The
      # action's id is referenced by every downstream consumer's
      # ``deps`` list so the engine schedules the install first.
      var npmCiActionId = ""
      if projectHasLockfile:
        let npmExe = npmExecutable()
        if npmExe.len == 0:
          raise newException(ValueError,
            "javascript-typescript convention: 'npm' not on PATH; " &
              "package-lock.json present but cannot run 'npm ci'")
        let action = emitNpmCiAction(projectRoot, npmExe)
        allActions.add(action)
        npmCiActionId = action.id

      var commonDeps: seq[string] = @[]
      if npmCiActionId.len > 0:
        commonDeps.add(npmCiActionId)

      if tsSources.len > 0:
        if not hasTsConfig:
          raise newException(ValueError,
            "javascript-typescript convention: TypeScript sources found " &
              "under " & (projectRoot / "src") &
              " but no tsconfig.json at project root")
        let npxExe = npxExecutable()
        if npxExe.len == 0:
          raise newException(ValueError,
            "javascript-typescript convention: 'npx' not on PATH; " &
              "cannot resolve tsc for TypeScript compile")

        # M21: pre-compute which ``.js`` outputs the bin-bundle actions
        # are about to declare so the tsc action's predicted-output list
        # can exclude them. tsc still writes the file to disk (no flag
        # to disable .js emit for a specific source); the engine's
        # output-declaration uniqueness check only inspects the
        # declared sets.
        var binBundleJsOutputs: seq[string] = @[]
        var binEsbuildPlans: seq[tuple[binName, entrySource, outFile,
          metafile: string]] = @[]
        for entry in pkg.binEntries:
          let entrySource = deriveEntrySourceForBin(projectRoot,
            entry.target)
          if entrySource.len == 0:
            continue
          # The bundle output mirrors the bin's declared
          # ``./dist/bin/<x>.js`` location under the convention's scratch.
          var stem = entry.target.replace('\\', '/')
          if stem.startsWith("./"):
            stem = stem[2 .. ^1]
          if stem.startsWith("dist/"):
            stem = stem[5 .. ^1]
          if not stem.endsWith(".js"):
            stem.add(".js")
          let outFile = distDir / stem
          let metafile = outFile & ".meta.json"
          binBundleJsOutputs.add(outFile)
          binEsbuildPlans.add((binName: entry.name,
                               entrySource: entrySource,
                               outFile: outFile,
                               metafile: metafile))

        let rawTscOutputs = predictedTscOutputs(projectRoot, distDir,
          tsSources, jsSources)
        let tscOutputs = filteredTscOutputs(rawTscOutputs, binBundleJsOutputs)

        let tscAction = emitTscCompileAction(projectRoot, npxExe,
          tsSources, jsSources, tsConfigPath, distDir, tscOutputs,
          deps = commonDeps)
        allActions.add(tscAction)

        # M21 A5 + A6: per-bin esbuild bundle + launcher shim. The
        # esbuild action depends on the npm-ci action (so the local
        # ``node_modules/.bin/esbuild`` is available when present) but
        # NOT on the tsc action — esbuild does its own type-stripping
        # via the bundler's TS support, so the two run in parallel on
        # the compile pool.
        for plan in binEsbuildPlans:
          createDir(extendedPath(parentDir(plan.outFile)))
          let esbuildAction = emitEsbuildAction(projectRoot, npxExe,
            plan.entrySource, plan.outFile, plan.metafile, plan.binName,
            deps = commonDeps)
          allActions.add(esbuildAction)
          let emitted = emitShimAction(projectRoot, shimDir,
            plan.outFile, plan.binName, esbuildAction.id)
          allActions.add(emitted.action)

      if jsSources.len > 0 and tsSources.len == 0:
        # JS-only: file-copy each .js into dist/. We skip JS copy when
        # TS sources are present because tsc already covers the project
        # under --rootDir=src in that case (with --allowJs the JS sources
        # would also flow through, but the M16 fixtures keep TS and JS
        # disjoint).
        var copyIndex = 0
        for jsSrc in jsSources:
          let emitted = emitJsCopyAction(projectRoot, distDir, jsSrc,
            copyIndex)
          allActions.add(emitted.action)
          inc copyIndex

      # M21 A7: test runner — emit only when the project ships test
      # files. The test target is non-default; ``repro build .#test``
      # runs it.
      if testFiles.len > 0:
        let testAction = emitTestRunnerAction(projectRoot, nodeExe,
          testFiles, deps = commonDeps)
        testActions.add(testAction)

      if allActions.len == 0:
        raise newException(ValueError,
          "javascript-typescript convention: produced no actions for " &
            projectRoot)
      defaultTarget(target("default", allActions))
      if testActions.len > 0:
        # The test target is independent from the default build target
        # so ``repro build .#test`` runs without waiting on the
        # bundle/shim sub-graph. Each test runner action is its own
        # sub-graph entry; the target alias is purely organisational.
        discard target("test", testActions)
    result = buildPackageFragment(synthetic, request, registerAll,
      includeDefault = false)

proc javaScriptTypeScriptConvention*(): LanguageConvention =
  ## The single value the standard provider binary registers at startup.
  ## Factory shape mirrors ``nimConvention`` / ``pythonConvention`` so
  ## tests can build isolated registries.
  LanguageConvention(
    name: "javascript-typescript",
    recognize: jsTsRecognize,
    emitFragment: jsTsEmitFragment)

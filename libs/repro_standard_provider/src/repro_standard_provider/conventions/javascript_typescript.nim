## JavaScript / TypeScript language convention (Tier 2b) — Mode A
## "fine-grained" plugin.
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
## ``node --test --import=tsx``). The M16 surface focuses on the headline
## "fixtures build to a runnable artifact":
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
  ]
    ## Root-level config files that force Mode B per the spec
    ## §"Mode selector". M16 doesn't implement Mode B, so the convention
    ## simply declines to recognise these projects and lets the next
    ## convention (or the no-match diagnostic) take over.

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

  TsConfigInfo = object
    ## Subset of ``<projectRoot>/tsconfig.json`` relevant to recognition.
    present: bool
    isolatedModules: bool
    verbatimModuleSyntax: bool
    hasPathsAliases: bool
    hasReferences: bool

proc readReprobuildSource(projectRoot: string): string =
  ## Read ``<projectRoot>/reprobuild.nim`` or return the empty string.
  ## Used by both ``recognize`` and ``emitFragment``; never raises.
  let path = projectRoot / "reprobuild.nim"
  if not fileExists(extendedPath(path)):
    return ""
  try:
    readFile(extendedPath(path))
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
            else:
              skipJsonValue(raw, i)
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

proc hasModeBConfig(projectRoot: string): bool =
  for name in ModeBConfigFiles:
    if fileExists(extendedPath(projectRoot / name)):
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
  ## Recognition contract (M16 Mode A subset):
  ##   * ``<projectRoot>/package.json`` exists
  ##   * ``<projectRoot>/reprobuild.nim`` exists AND its ``uses:`` lists
  ##     ``node`` or ``typescript``
  ##   * ``package.json`` declares ``"type": "module"`` (ESM)
  ##   * ``tsconfig.json`` (if present) does NOT carry ``paths`` aliases
  ##     or non-empty ``references`` (both force Mode B per the spec)
  ##   * the package declares at least one ``library`` or ``executable``
  ##     member
  ##   * at least one entry source exists (``src/index.ts`` /
  ##     ``src/index.js`` / a ``bin`` entry resolving to
  ##     ``src/bin/<name>.{ts,js}``)
  ##   * no Mode-B config file (vite / webpack / rollup) at the project
  ##     root
  ##   * ``node`` is on PATH (so emit can spawn the tooling)
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
  if hasModeBConfig(projectRoot):
    return false
  let pkg = parsePackageJson(projectRoot / "package.json")
  if not pkg.isModule:
    return false
  let ts = parseTsConfigJson(projectRoot / "tsconfig.json")
  if ts.present:
    if ts.hasPathsAliases or ts.hasReferences:
      return false
  if not hasEntryPoint(projectRoot, pkg):
    return false
  if nodeExecutable().len == 0:
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
                          expectedOutputs: seq[string]):
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
    inputs = inputs,
    outputs = expectedOutputs,
    pool = "compile",
    dependencyPolicy = declaredOnlyDependencyPolicy(),
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

proc syntheticPackage(projectRoot: string;
                      members: seq[JsTsMember];
                      info: JsTsProjectInfo): PackageDef =
  ## Build a minimal ``PackageDef`` the runtime helper wants.
  var name = "javascript_typescript_convention"
  if info.packageName.len > 0:
    name = sanitizeNamePart(info.packageName)
  elif members.len > 0:
    name = members[0].name
  PackageDef(
    packageName: name,
    sourceFile: projectRoot / "reprobuild.nim",
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

proc jsTsEmitFragment(projectRoot: string;
                      request: ProviderGraphRequest):
                        GraphFragment {.gcsafe.} =
  ## Convention entry — parse ``package.json`` + (optional)
  ## ``tsconfig.json``, classify the project as TS-bearing vs JS-only,
  ## emit either a single ``npx tsc`` action (TS) or one ``fs.copyFile``
  ## action per JS source (JS-only). Hand the whole thing to
  ## ``buildPackageFragment``.
  {.cast(gcsafe).}:
    let source = readReprobuildSource(projectRoot)
    let members = extractMembers(source)
    if members.len == 0:
      raise newException(ValueError,
        "javascript-typescript convention: no library or executable " &
          "members declared in " & projectRoot / "reprobuild.nim")
    let pkg = parsePackageJson(projectRoot / "package.json")
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
    createDir(extendedPath(distDir))
    let registerAll = proc() =
      discard buildPool("compile", 8'u32)
      var allActions: seq[BuildActionDef] = @[]
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
        let outputs = predictedTscOutputs(projectRoot, distDir,
          tsSources, jsSources)
        let action = emitTscCompileAction(projectRoot, npxExe,
          tsSources, jsSources, tsConfigPath, distDir, outputs)
        allActions.add(action)
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
      if allActions.len == 0:
        raise newException(ValueError,
          "javascript-typescript convention: produced no actions for " &
            projectRoot)
      defaultTarget(target("default", allActions))
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

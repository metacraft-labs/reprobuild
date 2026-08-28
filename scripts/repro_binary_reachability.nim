## Reachability analysis answering one question per test source:
##
##   "does running this test end up executing ``build/bin/repro``?"
##
## Why this is not a per-file substring scan
## -----------------------------------------
## ``scripts/generate_test_edges.nim`` used to answer that question by
## reading the test's OWN source and looking for the literal
## ``build/bin/repro``. That scan sees one file. A test that reaches the
## CLI through a shared helper — ``prepareMonitorTools`` in
## ``libs/repro_test_support``, the ``tests/e2e/**`` helper modules —
## contains no such literal, so it was classified ``false`` and its
## EXECUTE edge did not declare ``build/bin/repro`` as a typed input.
##
## An execute edge that does not declare the CLI cannot be invalidated by
## a change to the CLI. Two consequences, and only the first is
## observable on this branch today:
##
##   * NOW: the binary's producer edge (``reprobuild.apps.repro``) is not
##     in the execute edge's closure at all, so
##     ``repro build .#reprobuild.test_execute.<stem>`` does not build the
##     CLI. The test runs against whatever stale copy is on disk, or
##     fails on a missing fixture.
##   * LATENT: test execute edges are declared ``cacheable`` and the
##     action cache is content-keyed. As execute-edge caching starts
##     actually serving these zero-output edges, an edge whose
##     fingerprint does not cover the CLI is served as up to date after
##     the CLI is rebuilt — a real change to ``repro`` then produces a
##     green test that never ran against it. Under-declaration is a
##     stale-serve hole, and it gets strictly more dangerous the better
##     the caching works.
##
## What this module does instead
## -----------------------------
## Taint propagation over the repository's own symbol graph:
##
##   1. Every ``.nim`` file under the scanned roots is read, its comments
##      blanked (string literals kept), its ``import`` / ``include``
##      lines resolved to repo-relative paths, and its top-level
##      definitions (routines, and ``const`` / ``let`` / ``var`` entries)
##      split into named symbols.
##   2. SEED: a symbol whose body NAMES the binary's location is tainted
##      (see ``namesReproBinary`` for the two spellings recognised).
##      Most seeds sit in the tests themselves; the one that carries the
##      helper chain is ``libs/repro_test_support``'s ``reproBinaryPath``,
##      which ``prepareMonitorTools`` calls and ~30 tests reach through
##      it.
##   3. PROPAGATE: a symbol is tainted when its body mentions a tainted
##      symbol that is VISIBLE to it — its own module's symbols, plus the
##      exported symbols of its transitive import closure. Iterate to a
##      fixed point.
##   4. CLASSIFY: a test needs the repro binary when its own body spells
##      a literal, or when it mentions a tainted symbol visible to it.
##
## The import closure is what keeps this from being the same defect in a
## new costume. Nothing here is a list of helper names: a helper added
## tomorrow that resolves the binary is tainted by step 2 or 3 the moment
## it exists, and every caller of it is tainted by step 3 — the analysis
## has no table to keep in sync.
##
## Known limits (stated so the next reader does not over-trust it)
## ---------------------------------------------------------------
## * The visibility model is per-module, not per-symbol-origin: a name is
##   visible if ANY module in the import closure exports it. Two modules
##   in one closure exporting the same name are not disambiguated.
## * Indirection the token scan cannot see — a proc value passed as a
##   parameter, a dispatch table keyed by string, a method resolved at
##   runtime — breaks the chain.
## * Only Nim inside this repository is scanned. A helper in a sibling
##   checkout (``io-mon``, ``codetracer``) or a shell script that spawns
##   ``repro`` is invisible.
## * The seed is still a literal match. A helper that assembles the path
##   from pieces no seed pattern matches is missed;
##   ``libs/repro_test_support`` funnels the spelling through one proc
##   (``reproBinaryPath``) specifically so that there is one place to
##   look.
## * Over-approximation is the safe direction and is taken deliberately:
##   mentioning a tainted name in dead code, or naming it in a string,
##   classifies the test as needing the binary. The cost is a slightly
##   larger action-cache key on that edge; the cost of the other error is
##   a green test that never ran.

import std/[os, sets, strutils, tables]

const
  ReproBinaryLiterals* = ["build/bin/repro", "build\\bin\\repro"]
    ## The spellings that SEED the analysis. Kept as data so the seed set
    ## is one grep away, and so the test-support layer can be checked
    ## against it.

type
  Symbol = object
    name: string
    exported: bool
    body: string
    tokens: HashSet[string]   ## identifiers appearing in ``body``

  ModuleInfo = object
    rel: string             ## repo-relative, forward slashes
    stripped: string        ## comments blanked, string literals kept
    imports: seq[string]    ## resolved repo-relative module paths
    symbols: seq[Symbol]
    leftover: string        ## top-level code not inside any named symbol
    tokens: HashSet[string] ## identifiers appearing anywhere in the module

  Reachability* = object
    ## Result of one whole-repo analysis pass. Query it with
    ## ``needsReproBinary``.
    modules: Table[string, ModuleInfo]
    tainted: Table[string, HashSet[string]]
      ## module rel -> tainted symbol names defined in it
    closure: Table[string, seq[string]]
      ## module rel -> transitive import closure (module rels, self excluded)

proc toForwardSlashes(path: string): string =
  path.replace('\\', '/')

proc stripComments*(src: string): string =
  ## Blank every comment, keep string literals and every newline, so
  ## offsets and line structure survive. Prose that merely NAMES a helper
  ## must not taint the file that names it — several tests in this repo
  ## discuss ``prepareMonitorTools`` in a comment without calling it.
  result = newStringOfCap(src.len)
  var i = 0
  var blockDepth = 0
  while i < src.len:
    let c = src[i]
    if blockDepth > 0:
      if c == '#' and i + 1 < src.len and src[i + 1] == '[':
        inc blockDepth
        result.add("  ")
        i += 2
        continue
      if c == ']' and i + 1 < src.len and src[i + 1] == '#':
        dec blockDepth
        result.add("  ")
        i += 2
        continue
      result.add(if c == '\n': '\n' else: ' ')
      inc i
      continue
    if c == '#':
      if i + 1 < src.len and src[i + 1] == '[':
        blockDepth = 1
        result.add("  ")
        i += 2
        continue
      while i < src.len and src[i] != '\n':
        result.add(' ')
        inc i
      continue
    if c == '"':
      # Triple-quoted literals may contain '#' and newlines.
      if i + 2 < src.len and src[i + 1] == '"' and src[i + 2] == '"':
        result.add("\"\"\"")
        i += 3
        while i < src.len:
          if src[i] == '"' and i + 2 < src.len and src[i + 1] == '"' and
              src[i + 2] == '"':
            result.add("\"\"\"")
            i += 3
            break
          result.add(src[i])
          inc i
        continue
      result.add(c)
      inc i
      while i < src.len:
        if src[i] == '\\' and i + 1 < src.len:
          result.add(src[i])
          result.add(src[i + 1])
          i += 2
          continue
        result.add(src[i])
        if src[i] == '"' or src[i] == '\n':
          inc i
          break
        inc i
      continue
    if c == '\'' and not (i > 0 and (src[i - 1].isAlphaNumeric() or
                                     src[i - 1] == '_')):
      # A quote preceded by an identifier character is a literal suffix
      # (``1'u32``, ``0.5'f32``), not the start of a character literal.
      result.add(c)
      inc i
      while i < src.len:
        if src[i] == '\\' and i + 1 < src.len:
          result.add(src[i])
          result.add(src[i + 1])
          i += 2
          continue
        result.add(src[i])
        if src[i] == '\'' or src[i] == '\n':
          inc i
          break
        inc i
      continue
    result.add(c)
    inc i

proc isIdentChar(c: char): bool =
  c.isAlphaNumeric() or c == '_'

proc identifiers*(text: string): HashSet[string] =
  ## Every identifier-shaped token in ``text``, including the ones inside
  ## string literals. Membership in this set is the propagation test, so
  ## it is an exact word-boundary match by construction — ``requireBinary``
  ## can never match inside ``requireBinaryPath``.
  result = initHashSet[string]()
  var i = 0
  while i < text.len:
    if isIdentChar(text[i]) and not text[i].isDigit():
      let start = i
      while i < text.len and isIdentChar(text[i]):
        inc i
      result.incl(text[start ..< i])
    else:
      inc i

proc leadingSpaces(line: string): int =
  result = 0
  while result < line.len and line[result] == ' ':
    inc result

proc parseDefinedName(rest: string): tuple[name: string; exported: bool] =
  ## ``rest`` starts at the identifier. Returns the bare name and whether
  ## it carries the ``*`` export marker. Handles backtick-quoted operator
  ## names by returning an empty name (nothing depends on them here).
  var i = 0
  if i < rest.len and rest[i] == '`':
    return ("", false)
  var name = ""
  while i < rest.len and isIdentChar(rest[i]):
    name.add(rest[i])
    inc i
  if name.len == 0:
    return ("", false)
  let exported = i < rest.len and rest[i] == '*'
  (name, exported)

const RoutineKeywords = [
  "proc ", "func ", "template ", "macro ", "method ", "iterator ",
  "converter ",
]

proc splitSymbols(stripped: string): tuple[symbols: seq[Symbol];
    leftover: string] =
  ## Split top-level definitions out of a module. Anything at column 0
  ## that opens a routine, or a ``const`` / ``let`` / ``var`` entry (on
  ## the keyword line or indented one level under a section keyword),
  ## becomes a named symbol owning every line up to the next definition.
  ## Everything else lands in ``leftover``: module-initialisation code,
  ## which runs for every importer and therefore taints the whole module
  ## when it names the binary.
  var symbols: seq[Symbol] = @[]
  var leftover = ""
  var current = -1
  var inSection = false          ## inside a bare ``const`` / ``let`` / ``var``
  var inTopLevelWhen = false     ## inside a column-0 ``when`` / ``elif`` / ``else``
  for rawLine in stripped.splitLines():
    let line = rawLine
    let indent = leadingSpaces(line)
    let trimmed = line.strip()
    if trimmed.len == 0:
      if current >= 0: symbols[current].body.add("\n")
      else: leftover.add("\n")
      continue

    if indent == 0:
      # A column-0 ``when`` / ``elif`` / ``else`` opens a platform block
      # whose routines live one indent level in. They are still top-level
      # definitions and must be split out as symbols; folding them into
      # ``leftover`` would taint every importer of the module the moment
      # ONE of its platform variants named the binary.
      inTopLevelWhen = trimmed.startsWith("when ") or
        trimmed.startsWith("when(") or trimmed.startsWith("elif ") or
        trimmed == "else:" or trimmed.startsWith("else:")

      var opened = false
      for kw in RoutineKeywords:
        if line.startsWith(kw):
          let (name, exported) = parseDefinedName(line[kw.len .. ^1].strip())
          if name.len > 0:
            symbols.add(Symbol(name: name, exported: exported, body: line & "\n"))
            current = symbols.high
            inSection = false
            opened = true
          break
      if opened: continue

      var sectionKw = ""
      for kw in ["const", "let", "var"]:
        if line == kw or line.startsWith(kw & " "):
          sectionKw = kw
          break
      if sectionKw.len > 0:
        let rest = line[sectionKw.len .. ^1].strip()
        if rest.len == 0:
          # Bare section header; entries follow indented.
          inSection = true
          current = -1
          leftover.add(line & "\n")
        else:
          let (name, exported) = parseDefinedName(rest)
          if name.len > 0:
            symbols.add(Symbol(name: name, exported: exported, body: line & "\n"))
            current = symbols.high
          else:
            current = -1
            leftover.add(line & "\n")
          inSection = false
        continue

      # Any other column-0 line ends the previous definition.
      current = -1
      inSection = false
      leftover.add(line & "\n")
      continue

    if inSection and indent == 2:
      let (name, exported) = parseDefinedName(trimmed)
      if name.len > 0 and ("=" in trimmed or ":" in trimmed):
        symbols.add(Symbol(name: name, exported: exported, body: line & "\n"))
        current = symbols.high
        continue

    if inTopLevelWhen and indent == 2:
      var opened = false
      for kw in RoutineKeywords:
        if trimmed.startsWith(kw):
          let (name, exported) = parseDefinedName(trimmed[kw.len .. ^1].strip())
          if name.len > 0:
            symbols.add(Symbol(name: name, exported: exported,
                               body: line & "\n"))
            current = symbols.high
            opened = true
          break
      if opened: continue

    if current >= 0:
      symbols[current].body.add(line & "\n")
    else:
      leftover.add(line & "\n")
  (symbols, leftover)

proc parseImportSpecs(stripped: string): seq[string] =
  ## Every module path named by an ``import`` / ``from`` / ``include``
  ## statement, in the source's own spelling (dotted, slashed, or
  ## quoted). ``std/`` and ``pkg/`` prefixes are dropped: nothing outside
  ## this repository is scanned.
  result = @[]
  var pending = ""
  for rawLine in stripped.splitLines():
    var line = rawLine.strip()
    if line.len == 0:
      continue
    if pending.len > 0:
      pending.add(" ")
      pending.add(line)
      if line.endsWith(",") or line.endsWith("["):
        continue
      line = pending
      pending = ""
    else:
      var head = ""
      for kw in ["import ", "from ", "include ", "import\t", "from\t"]:
        if line.startsWith(kw):
          head = kw
          break
      if head.len == 0:
        continue
      if line.endsWith(",") or line.endsWith("["):
        pending = line
        continue

    # Normalise: strip the leading keyword and, for ``from X import Y``,
    # everything from `` import `` onwards.
    var body = line
    for kw in ["import ", "from ", "include "]:
      if body.startsWith(kw):
        body = body[kw.len .. ^1]
        break
    let fromCut = body.find(" import ")
    if line.startsWith("from ") and fromCut >= 0:
      body = body[0 ..< fromCut]

    # ``import a/[b, c]`` -> ``a/b``, ``a/c``
    let openBracket = body.find('[')
    if openBracket >= 0:
      let closeBracket = body.rfind(']')
      if closeBracket > openBracket:
        let prefix = body[0 ..< openBracket].strip()
        let inner = body[openBracket + 1 ..< closeBracket]
        for part in inner.split(','):
          let leaf = part.strip()
          if leaf.len > 0:
            result.add(prefix & leaf)
        continue

    for part in body.split(','):
      var spec = part.strip()
      if spec.len == 0: continue
      let asCut = spec.find(" as ")
      if asCut >= 0:
        spec = spec[0 ..< asCut].strip()
      spec = spec.strip(chars = {'"', ' '})
      if spec.len > 0:
        result.add(spec)

proc resolveImport(repoRoot, fromRel, spec: string;
                   searchRoots: seq[string]): string =
  ## Map one import spelling to a repo-relative ``.nim`` path, or "" when
  ## it does not resolve inside this repository.
  var s = spec.toForwardSlashes()
  if s.len == 0: return ""
  if s.startsWith("std/") or s.startsWith("pkg/") or s == "std" or
     s == "system" or s == "os":
    return ""
  if s.endsWith(".nim"):
    s = s[0 ..< s.len - 4]
  # Dotted module paths (``repro_core.paths``) are equivalent to slashed.
  if '/' notin s and '.' in s:
    s = s.replace('.', '/')

  var candidates: seq[string] = @[]
  let ownDir = fromRel.parentDir()
  if s.startsWith("./") or s.startsWith("../") or s == "." or s == "..":
    candidates.add((ownDir / s).toForwardSlashes())
  else:
    candidates.add((ownDir / s).toForwardSlashes())
    for root in searchRoots:
      candidates.add((root / s).toForwardSlashes())

  for cand in candidates:
    let normalized = cand.normalizedPath().toForwardSlashes()
    if normalized.len == 0 or normalized.startsWith(".."):
      continue
    let withExt = normalized & ".nim"
    if fileExists(repoRoot / withExt):
      return withExt
    # ``import foo`` may name ``foo/foo.nim`` (Nim's package-dir form).
    let nested = normalized / normalized.lastPathPart & ".nim"
    if fileExists(repoRoot / nested):
      return nested.toForwardSlashes()
  ""

proc searchRootsFor(repoRoot: string): seq[string] =
  ## The ``--path`` roots ``config.nims`` adds that matter here: the repo
  ## root itself and every ``libs/<name>/src``. Read off the filesystem
  ## rather than copied from a list, so a new library is covered without
  ## editing this file.
  result = @[""]
  let libsDir = repoRoot / "libs"
  if dirExists(libsDir):
    for kind, path in walkDir(libsDir):
      if kind notin {pcDir, pcLinkToDir}: continue
      let name = path.lastPathPart
      if dirExists(path / "src"):
        result.add("libs/" & name & "/src")

const ScannedRoots = ["tests", "libs", "tools", "apps", "recipes", "scripts"]

proc allRepoNimFiles(repoRoot: string): seq[string] =
  result = @[]
  for root in ScannedRoots:
    let abs = repoRoot / root
    if not dirExists(abs): continue
    for path in walkDirRec(abs, relative = true):
      if not path.endsWith(".nim"): continue
      result.add((root / path).toForwardSlashes())
  for kind, path in walkDir(repoRoot, relative = true):
    if kind in {pcFile, pcLinkToFile} and path.endsWith(".nim"):
      result.add(path.toForwardSlashes())

proc collectModules(repoRoot: string; seeds: openArray[string]):
    Table[string, ModuleInfo] =
  ## Parse ``seeds`` and, transitively, everything they import inside this
  ## repository. Passing an empty ``seeds`` scans every Nim file under
  ## ``ScannedRoots``; passing the discovered test list keeps the work
  ## proportional to what the tests actually reach, which is what the
  ## generator does.
  result = initTable[string, ModuleInfo]()
  let roots = searchRootsFor(repoRoot)
  var pending: seq[string] = @[]
  if seeds.len == 0:
    pending = allRepoNimFiles(repoRoot)
  else:
    for s in seeds: pending.add(s.toForwardSlashes())

  while pending.len > 0:
    let rel = pending.pop()
    if rel in result: continue
    var content = ""
    try:
      content = readFile(repoRoot / rel)
    except IOError, OSError:
      continue
    let stripped = stripComments(content)
    var (symbols, leftover) = splitSymbols(stripped)
    for i in 0 ..< symbols.len:
      symbols[i].tokens = identifiers(symbols[i].body)
    var info = ModuleInfo(rel: rel, stripped: stripped, symbols: symbols,
                          leftover: leftover, tokens: identifiers(stripped))
    var seen = initHashSet[string]()
    for spec in parseImportSpecs(stripped):
      let resolved = resolveImport(repoRoot, rel, spec, roots)
      if resolved.len > 0 and resolved != rel and resolved notin seen:
        seen.incl(resolved)
        info.imports.add(resolved)
        if resolved notin result:
          pending.add(resolved)
    result[rel] = info

proc importClosure(modules: Table[string, ModuleInfo]; start: string):
    seq[string] =
  var seen = initHashSet[string]()
  var stack = @[start]
  while stack.len > 0:
    let cur = stack.pop()
    if cur notin modules: continue
    for imp in modules[cur].imports:
      if imp notin seen:
        seen.incl(imp)
        stack.add(imp)
  result = @[]
  for m in seen: result.add(m)

proc collapseSpaces(text: string): string =
  result = newStringOfCap(text.len)
  for c in text:
    if c notin {' ', '\t', '\n', '\r'}:
      result.add(c)

proc namesReproBinary*(text: string): bool =
  ## The SEED predicate: does this chunk of Nim source name the
  ## graph-built CLI's location?
  ##
  ## Two spellings are recognised, and both are literal-based — this is
  ## the one place the analysis cannot be structural, because naming a
  ## path IS writing a string:
  ##
  ##   * the joined literal ``"build/bin/repro"``
  ##     (``ReproBinaryLiterals``), and
  ##   * the component form ``… / "build" / "bin" / … "repro" …``, which
  ##     is how most tests in this repo spell it
  ##     (``repoRoot / "build" / "bin" / addFileExt("repro", ExeExt)``).
  ##
  ## A helper that assembles the path some third way is invisible to the
  ## seed — which is why ``libs/repro_test_support`` funnels the spelling
  ## through ``ReproBinaryRelPath``: one const, one place to look.
  for lit in ReproBinaryLiterals:
    if lit in text:
      return true
  let dense = collapseSpaces(text)
  let hasDirPair = "\"build\"/\"bin\"" in dense or "\"build/bin\"" in dense
  if hasDirPair and ("\"repro\"" in dense or "\"repro.exe\"" in dense):
    return true
  false

proc analyze*(repoRoot: string; seeds: openArray[string] = []): Reachability =
  ## Run one pass over ``seeds`` (repo-relative paths) and their
  ## transitive in-repo import closure. An empty ``seeds`` scans every Nim
  ## file under the repository's source roots.
  result.modules = collectModules(repoRoot, seeds)
  result.closure = initTable[string, seq[string]]()
  result.tainted = initTable[string, HashSet[string]]()
  for rel in result.modules.keys:
    result.closure[rel] = importClosure(result.modules, rel)
    result.tainted[rel] = initHashSet[string]()

  # SEED.
  for rel, info in result.modules:
    for sym in info.symbols:
      if namesReproBinary(sym.body):
        result.tainted[rel].incl(sym.name)
    if namesReproBinary(info.leftover):
      # Module-initialisation code names the binary: every importer of
      # this module runs it, so taint the module as a whole.
      result.tainted[rel].incl("")

  # Exported tainted names per module, refreshed each round.
  proc exportedTainted(r: Reachability; rel: string): HashSet[string] =
    result = initHashSet[string]()
    let t = r.tainted[rel]
    if "" in t: result.incl("")
    for sym in r.modules[rel].symbols:
      if sym.exported and sym.name in t:
        result.incl(sym.name)

  # PROPAGATE to a fixed point.
  var changed = true
  var rounds = 0
  while changed and rounds < 64:
    changed = false
    inc rounds
    var exported = initTable[string, HashSet[string]]()
    for rel in result.modules.keys:
      exported[rel] = exportedTainted(result, rel)
    for rel, info in result.modules:
      # Names visible here: own tainted symbols + exported tainted
      # symbols of the transitive import closure.
      var visible = initHashSet[string]()
      var moduleTaintedByImport = false
      for name in result.tainted[rel]:
        if name.len > 0: visible.incl(name)
      for dep in result.closure[rel]:
        if dep notin exported: continue
        for name in exported[dep]:
          if name.len == 0: moduleTaintedByImport = true
          else: visible.incl(name)
      if visible.len == 0 and not moduleTaintedByImport: continue
      for i in 0 ..< info.symbols.len:
        let sym = info.symbols[i]
        if sym.name in result.tainted[rel]: continue
        var hit = moduleTaintedByImport
        if not hit:
          for name in sym.tokens:
            if name != sym.name and name in visible:
              hit = true
              break
        if hit:
          result.tainted[rel].incl(sym.name)
          changed = true

proc reachedThrough(r: Reachability; rel: string): seq[string] =
  ## Which visible tainted names the file at ``rel`` mentions. Empty when
  ## the file does not reach the binary through any helper.
  result = @[]
  if rel notin r.modules: return
  let info = r.modules[rel]
  for dep in r.closure[rel]:
    if dep notin r.modules: continue
    let depTainted = r.tainted[dep]
    if depTainted.len == 0: continue
    if "" in depTainted and ("<module-init of " & dep & ">") notin result:
      result.add("<module-init of " & dep & ">")
    for sym in r.modules[dep].symbols:
      if sym.exported and sym.name in depTainted and
          sym.name in info.tokens and sym.name notin result:
        result.add(sym.name)

proc needsReproBinary*(r: Reachability; rel: string): bool =
  ## Does the test at repo-relative ``rel`` end up executing
  ## ``build/bin/repro``?
  if rel notin r.modules:
    return false
  if namesReproBinary(r.modules[rel].stripped):
    return true
  reachedThrough(r, rel).len > 0

proc taintedSymbolsFor*(r: Reachability; rel: string): seq[string] =
  ## Diagnostic: the helper names through which ``rel`` reaches the
  ## binary. Consumed by the generator's ``--explain`` output and by the
  ## tests that hand-verify the classification.
  reachedThrough(r, rel)

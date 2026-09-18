## Canonical source/provider-closure identity for source-built packages.
##
## ## What this module binds (Reprobuild #171, campaign M13)
##
## A source package's cache identity must be a function of the COMPLETE
## solved instance, not of the entry recipe's bytes. Before #171 was
## fixed, ``sourceProviderRevisionHex`` hashed only
## ``resolveProjectFile(projectRoot).path``, so a project whose
## ``repro.nim`` contains ``import recipe`` kept the SAME identity when
## ``recipe.nim`` changed from ``const implementation = 1`` to
## ``const implementation = 2``. That aliases two different package
## implementations onto one key on the materialized-substitution and
## publication paths.
##
## The identity now binds:
##
##   * the **source closure** — the entry project file plus every local
##     Nim module reachable from it through ``import`` / ``from ...
##     import`` / ``include``, transitively, plus every compile-time
##     file read (``staticRead`` / ``slurp``) it performs, plus every
##     declared local non-Nim source input (SDK generator templates,
##     ``.c`` sources, data files, directories);
##   * the **selected options** actually solved for this instance;
##   * the **dependency instances** actually resolved for it (their
##     cache-entry-key hexes);
##   * the **target platform + ABI**;
##   * the **actual toolchain** (name AND version — an unidentified
##     toolchain is missing evidence, not an empty field).
##
## ## Relocation stability
##
## The closure digest is computed over ``(project-relative path,
## BLAKE3 of the bytes)`` pairs, sorted by the relative path with
## separators normalised to ``/``. No absolute path ever enters the
## digest: ``projectRelative`` answers "is this file inside the project
## root, and if so what is its relative spelling", and a file that is
## NOT inside the root never reaches the digest at all — it is either an
## external library (ignored) or missing evidence (refused). That closes
## the cross-drive hole in the previous ``relativePath`` fallback, which
## on Windows returns the ABSOLUTE path when the two paths sit on
## different drives (it does not raise), so an absolute path could enter
## the digest and break relocation stability silently. Hashing absolute
## paths would make the identity trivially "change on every mutation"
## while also changing on relocation — which is why the regression test
## pins relocation stability as the non-vacuity control.
##
## ## How a module spec is resolved
##
## Nim resolves an import against more than the importing file's own
## directory, and the scanner now models the same set:
##
##   * the importing file's own directory;
##   * the project root;
##   * the nimble ``srcDir`` declared by ``<root>/*.nimble``;
##   * every ``--path:`` / ``switch("path", "...")`` search root with a
##     STRING-LITERAL argument in ``<root>/nim.cfg``,
##     ``<root>/config.nims``, ``<root>/<entry>.nim.cfg`` or
##     ``<root>/<entry>.nims`` (``$projectDir`` / ``$projectPath`` /
##     ``$config`` expanded), restricted to roots that lie INSIDE the
##     project root.
##
## At each root the spec is tried as the literal path (so
## ``include "frag.inc"`` and ``include "frag.nim"`` resolve — the old
## scanner appended ``.nim`` unconditionally and dropped both), then
## with ``.nim``/``.nims`` appended, then as a package directory
## (``import pkgdir`` → ``pkgdir/pkgdir.nim``).
##
## ## External library vs unresolvable local module
##
## This is the load-bearing rule, and it is stated as a rule rather than
## a heuristic because both directions are safety-relevant: treating a
## local module as external re-creates the #171 aliasing class, and
## treating an external library as local makes every identity
## permanently PENDING and therefore useless.
##
## A spec that FAILS to resolve under the roots above is **missing
## evidence** (the identity refuses) when ANY of the following holds:
##
##   1. it is explicitly relative (``./x``, ``../x``) or absolute — it
##      names a file by construction;
##   2. it came from an ``include`` — Nim textually inlines the target,
##      and an ``include`` of a library is not a thing recipes do;
##   3. it carries a Nim source extension (``.nim``, ``.nims``,
##      ``.inc``) — it names a file, not a package;
##   4. the project declares search paths this scanner could not
##      evaluate (a non-literal ``switch("path", expr)``, a computed
##      ``--path``), so the search-root set itself is unknown and no
##      spec can be ruled out;
##   5. the spec's FIRST path segment matches an on-disk entry under one
##      of the search roots (a directory, or a ``.nim``/``.nims`` file) —
##      partial evidence that it points into this project.
##
## Otherwise it is an **external library** and is ignored. A spec
## starting ``std/`` or ``pkg/``, and ``system``, are external by
## Nim's own namespacing and short-circuit before any of the above.
## So does a spec that RESOLVES to a file outside the project root
## (a vendored sibling, an absolute import into another tree): it is
## not project source, and the code it contributes is bound through
## ``dependencyInstances`` instead.
##
## Why the negative direction is MOSTLY safe: a bare spec with no
## on-disk evidence anywhere under the project's own search roots is
## usually not a file this project ships, and Nim then satisfies it from
## OUTSIDE the project (stdlib, a nimble package, a ``--path`` into
## another tree). Why the positive direction is safe: rules 1-5 refuse
## rather than digest whenever the spec could be project source, so an
## under-approximated closure is never turned into a key.
##
## The residual, stated exactly because the argument above does NOT
## cover it: rule 4 fires only on a search path this scanner can SEE and
## cannot evaluate. A ``--path`` supplied on the command line, or
## contributed by a nimble dependency, leaves no trace in any scanned
## config file, so there is nothing to mark unknown; the spec resolves
## for the compiler and is dropped here, and two implementations
## differing only in that module alias onto one key. Measured: a tree
## whose ``internal/helper.nim`` is reachable only through a
## command-line ``--path`` keeps the same closure digest across a change
## to that file. A ``config.nims`` that computes ``--path`` in a loop or
## from an expression is the OTHER case — rule 4 does fire, and such a
## project (reprobuild's own tree among them) refuses rather than
## aliases.
##
## ## Commented-out and quoted imports
##
## The source text is masked before scanning: ``#`` line comments,
## nestable ``#[ ]#`` / ``##[ ]##`` block comments and triple-quoted
## string literals are blanked (newlines preserved). An ``import
## ./ghost`` inside a block comment or a ``"""..."""`` literal is
## therefore NOT seen.
##
## That is deliberately on the permissive side of fail-closed, and the
## reason is that it is not a weakening at all: Nim does not read those
## bytes, so they are provably not an input. Refusing on them is not
## "failing closed", it is failing ALWAYS — a correct project with a
## commented-out import would be permanently unkeyable, which is the
## same uselessness as making everything PENDING. Masking moves the
## scan CLOSER to what the compiler sees in both directions. Ordinary
## single-line ``"..."`` literals are kept verbatim, because
## ``import "./x"`` and the ``staticRead`` argument live in them.
##
## ## Compile-time reads
##
## ``staticRead`` / ``slurp`` with a string-literal argument are
## resolved against the reading file's directory and then the project
## root, and their bytes enter the closure. A non-literal argument, an
## argument that does not resolve, or an argument resolving outside the
## project root is missing evidence. ``gorge`` / ``gorgeEx`` /
## ``staticExec`` run a command at compile time whose output cannot be
## bound at all, so their mere presence is missing evidence.
##
## This is a textual whole-identifier scan, not a parse, and it
## over-refuses in the fail-closed direction: a recipe that defines its
## own ``slurp``, or that merely contains the word ``slurp`` or
## ``gorge`` inside a KEPT single-line string literal, is refused. (A
## mention inside a comment is masked and does not refuse.) That costs a
## correct project its key rather than aliasing two; no test covers it.
##
## ## Case-sensitivity
##
## The de-duplication key for a visited path folds case ONLY on
## Windows. Folding it unconditionally — as this scanner used to —
## merges two genuinely distinct files on a case-sensitive filesystem,
## which is Linux, which is the build target: that is exactly the
## aliasing class #171 is about, re-introduced by the dedup table.
##
## ## Why this scanner is local rather than shared
##
## ``repro_interface_artifacts.discoverNimSources`` resolves search
## roots and is the natural host for this logic, but
## ``repro_interface_artifacts`` IMPORTS ``repro_project_dsl`` and this
## module is part of ``repro_project_dsl`` — importing it back is a hard
## library cycle. ``macros_a.producerSourceStamp`` is inside this
## package but ``macros_a`` is included into ``repro_project_dsl.nim``,
## which imports THIS module, so that direction is a cycle too (its own
## docstring records the same constraint for the same reason).
## ``repro_profile_compile/sources.nim`` has the ``(relative path,
## blake3) -> digest`` pipeline, which is mirrored here, but its scanner
## follows only ``import ./...`` and only the first module on a line, so
## consolidating onto it would LOSE coverage.
##
## ## Fail-closed
##
## ``PendingCacheIdentityOptionKey`` is stamped whenever ANY required
## input is unavailable: no project file, an unreadable source file, an
## unresolved candidate-local import or include, an unbindable
## compile-time read, a declared source input that does not exist or
## lives outside the project root, unsolved options, unresolved
## dependency instances, a malformed dependency key, an unpopulated
## target triple, or a toolchain with no name/version. The marker makes
## ``deriveCacheEntryKey`` refuse, so an incomplete identity can neither
## look up nor publish a package. See ``docs/package-cache-identity.md``.
##
## ## Legacy constructor
##
## ``sourceCacheEntryIdentity(projectRoot, packageName, packageVersion,
## conventionTag)`` is retained for the call sites that cannot yet
## supply a solved instance (``dsl_port_runtime``, the DSL stdlib's
## ``nim.c`` alias and install-mirror stage-copy, the from-source
## conventions). It has no solved options, no resolved dependency
## instances and no detected toolchain version, so it stays PENDING by
## construction — the guard is unchanged for every production path that
## still uses it. Its ``providerRevision`` is now the full source-closure
## digest rather than the entry-file digest, so the diagnostic value it
## reports also moves when imported recipe code changes.
##
## This module deliberately accepts the selected package version as an
## argument. Provider/runtime layers own version selection; keeping that
## registry dependency out of this module lets both the standard provider
## and the Layer-1 package constructors share the exact same key logic.

import std/[algorithm, os, sets, strutils, tables]

import blake3
import repro_binary_cache_client/cache_key
import repro_binary_cache_server/types as bcs_types
import repro_core

type
  SourceClosure* = object
    ## The resolved local source closure of a project root.
    digestHex*: string
      ## BLAKE3 hex over the canonical ``(relative path, content
      ## digest)`` encoding. Empty when ``missing`` is non-empty.
    files*: seq[string]
      ## Project-relative paths of every file bound, sorted, with ``/``
      ## separators. Diagnostic; not part of the key beyond the digest.
    missing*: seq[string]
      ## Human-readable descriptions of evidence that could not be
      ## resolved. Non-empty means the closure is incomplete.

  SolvedSourceInstance* = object
    ## The complete solved instance a source package's cache identity is
    ## a function of. Every field is load-bearing: see the module
    ## docstring.
    projectRoot*: string
    packageName*: string
    packageVersion*: string
    declaredSourceInputs*: seq[string]
      ## Local non-Nim inputs the recipe consumes and the import scanner
      ## therefore cannot see: SDK/generator templates, ``.c``/``.rs``
      ## sources, data files, or whole directories. Project-relative
      ## paths (absolute paths are accepted and recorded relative to the
      ## project root so relocation stays stable; an absolute path
      ## OUTSIDE the project root is missing evidence, because there is
      ## no relocation-stable spelling for it).
    selectedOptions*: seq[(string, string)]
    optionsSolved*: bool
      ## Distinguishes "solved to the empty set" from "not solved yet".
      ## Only the former can produce a key.
    dependencyInstances*: seq[string]
      ## 64-char cache-entry-key hexes of the dependency INSTANCES this
      ## instance was solved against.
    dependenciesResolved*: bool
      ## As with ``optionsSolved``: an empty-but-resolved closure is
      ## complete evidence; an unresolved one is not.
    platform*: bcs_types.PlatformTriple
    toolchain*: bcs_types.ToolchainIdentity

const
  SourceClosureDigestChars = 64
    ## Full BLAKE3-256 hex. The ``providerRevision`` field is an opaque
    ## hex string to the canonical encoder, so there is no reason to
    ## truncate the closure digest the way the legacy entry-file digest
    ## was truncated.

  NimSourceExts = [".nim", ".nims", ".inc"]

  CompileTimeFileReaders = ["staticRead", "slurp"]
    ## Compile-time file reads whose argument CAN be bound.

  CompileTimeCommandRunners = ["gorgeEx", "gorge", "staticExec"]
    ## Compile-time command executions whose output can NOT be bound.

proc cacheIdentityExtendedPath*(path: string): string =
  when defined(windows):
    if path.len == 0 or path.startsWith("\\\\"):
      path
    else:
      "\\\\?\\" & os.normalizedPath(absolutePath(path)).replace('/', '\\')
  else:
    path

# ---------------------------------------------------------------------------
# Path identity
# ---------------------------------------------------------------------------

proc normSlash(path: string): string =
  ## Normalised absolute-or-relative path with ``/`` separators and no
  ## trailing separator. Never turns the empty string into ``"."``.
  if path.len == 0:
    return ""
  result = os.normalizedPath(path).replace('\\', '/')
  while result.len > 1 and result.endsWith("/"):
    result.setLen(result.len - 1)

proc foldPathCase(path: string): string =
  ## Case folding is a PLATFORM fact here, not a convenience: NTFS
  ## resolves two spellings to one file, ext4 does not.
  when defined(windows):
    path.toLowerAscii()
  else:
    path

proc pathKey(path: string): string =
  ## De-duplication identity of a filesystem path.
  foldPathCase(normSlash(path))

proc sourceClosurePathKey*(path: string): string =
  ## The de-duplication identity of a path, exposed so the platform rule
  ## itself is testable rather than only its consequences. Case folding
  ## here is a PLATFORM fact: see ``foldPathCase``.
  pathKey(path)

proc projectRelative(root, path: string): tuple[inside: bool, rel: string] =
  ## ``(true, <root-relative, '/'-separated spelling>)`` when ``path``
  ## lies inside ``root``; ``(false, _)`` otherwise. Deliberately does
  ## NOT use ``os.relativePath``: on Windows that returns the ABSOLUTE
  ## path for a cross-drive pair instead of raising, which is how an
  ## absolute path used to reach the digest.
  let r = normSlash(root)
  let p = normSlash(path)
  if r.len == 0 or p.len == 0:
    return (false, p)
  let foldedR = foldPathCase(r)
  let foldedP = foldPathCase(p)
  if foldedP == foldedR:
    return (true, extractFilename(p))
  if foldedP.startsWith(foldedR & "/"):
    return (true, p[r.len + 1 .. ^1])
  (false, p)

# ---------------------------------------------------------------------------
# Source-text masking
# ---------------------------------------------------------------------------

proc maskNimNonCode(source: string): string =
  ## Blank every region Nim's parser does NOT read as code: ``#`` line
  ## comments, nestable ``#[ ]#`` / ``##[ ]##`` block comments and
  ## triple-quoted string literals. Blanked characters become spaces;
  ## newlines are preserved so line structure is unchanged.
  ##
  ## Ordinary single-line ``"..."`` (and ``r"..."``) literals and char
  ## literals are KEPT verbatim — ``import "./x"`` and the
  ## ``staticRead`` argument live in them.
  result = newStringOfCap(source.len)
  var i = 0
  let n = source.len
  template blank(ch: char) =
    result.add(if ch == '\n': '\n' else: ' ')
  while i < n:
    let ch = source[i]
    if ch == '#':
      let blockComment =
        (i + 1 < n and source[i + 1] == '[') or
        (i + 2 < n and source[i + 1] == '#' and source[i + 2] == '[')
      if blockComment:
        var depth = 0
        while i < n:
          if source[i] == '#' and i + 1 < n and source[i + 1] == '[':
            inc depth
            blank(source[i]); blank(source[i + 1]); i += 2
          elif source[i] == ']' and i + 1 < n and source[i + 1] == '#':
            dec depth
            blank(source[i]); blank(source[i + 1]); i += 2
            if depth <= 0:
              break
          else:
            blank(source[i]); inc i
      else:
        while i < n and source[i] != '\n':
          blank(source[i]); inc i
      continue
    if ch == '"':
      if i + 2 < n and source[i + 1] == '"' and source[i + 2] == '"':
        blank('"'); blank('"'); blank('"'); i += 3
        while i < n:
          if source[i] == '"' and i + 2 < n and source[i + 1] == '"' and
              source[i + 2] == '"':
            blank('"'); blank('"'); blank('"'); i += 3
            break
          blank(source[i]); inc i
        continue
      let raw = i > 0 and source[i - 1] in {'r', 'R'} and
        (i < 2 or source[i - 2] notin IdentChars)
      result.add(ch); inc i
      while i < n and source[i] != '\n':
        if not raw and source[i] == '\\' and i + 1 < n:
          result.add(source[i]); result.add(source[i + 1]); i += 2
          continue
        if source[i] == '"':
          if raw and i + 1 < n and source[i + 1] == '"':
            result.add(source[i]); result.add(source[i + 1]); i += 2
            continue
          result.add(source[i]); inc i
          break
        result.add(source[i]); inc i
      continue
    if ch == '\'' and (i == 0 or source[i - 1] notin IdentChars):
      result.add(ch); inc i
      while i < n and source[i] != '\n':
        if source[i] == '\\' and i + 1 < n:
          result.add(source[i]); result.add(source[i + 1]); i += 2
          continue
        if source[i] == '\'':
          result.add(source[i]); inc i
          break
        result.add(source[i]); inc i
      continue
    result.add(ch); inc i

# ---------------------------------------------------------------------------
# Nim import scanning
# ---------------------------------------------------------------------------

type
  ImportRef = object
    spec: string
    isInclude: bool

  CompileTimeReadKind = enum
    ctFileRead, ctCommand

  CompileTimeRead = object
    kind: CompileTimeReadKind
    fn: string
    literal: string
    hasLiteral: bool

proc splitTopLevelCommas(text: string): seq[string] =
  ## Split on commas that are not nested inside ``[]``.
  var depth = 0
  var current = ""
  for ch in text:
    case ch
    of '[':
      inc depth
      current.add(ch)
    of ']':
      if depth > 0: dec depth
      current.add(ch)
    of ',':
      if depth == 0:
        result.add(current)
        current = ""
      else:
        current.add(ch)
    else:
      current.add(ch)
  if current.strip().len > 0:
    result.add(current)

proc expandImportSpec(spec: string): seq[string] =
  ## Normalise one import item into zero or more module paths.
  ## Handles ``foo``, ``"foo"``, ``foo/bar``, ``std/[os, strutils]``,
  ## ``foo as bar`` and ``foo except bar``.
  var item = spec.strip()
  if item.len == 0:
    return
  # ``x as y`` / ``x except y`` — only the left-hand module matters.
  for keyword in [" as ", " except "]:
    let idx = item.find(keyword)
    if idx >= 0:
      item = item[0 ..< idx].strip()
  let openIdx = item.find('[')
  if openIdx >= 0:
    let closeIdx = item.rfind(']')
    if closeIdx > openIdx:
      var prefix = item[0 ..< openIdx].strip()
      if prefix.endsWith("/"):
        prefix = prefix[0 ..< prefix.len - 1]
      for inner in splitTopLevelCommas(item[openIdx + 1 ..< closeIdx]):
        let leaf = inner.strip().strip(chars = {'"'})
        if leaf.len == 0:
          continue
        result.add(if prefix.len > 0: prefix & "/" & leaf else: leaf)
      return
  item = item.strip(chars = {'"'})
  if item.len > 0:
    result.add(item)

proc importRefsOf(masked: string): seq[ImportRef] =
  ## Every module spec named by ``import`` / ``from ... import`` /
  ## ``include`` statements in MASKED Nim source, including the
  ## multi-line continuation forms, tagged with whether the statement
  ## was an ``include`` (which carries its own file extension and is
  ## textually inlined by Nim).
  var pending = ""
  var pendingDepth = 0
  var inStatement = false
  var isInclude = false
  for rawLine in masked.splitLines():
    let trimmed = rawLine.strip()
    if inStatement:
      if trimmed.len == 0:
        continue
      pending.add(" ")
      pending.add(trimmed)
    else:
      var body = ""
      if trimmed == "import" or trimmed.startsWith("import "):
        body = trimmed[min(6, trimmed.len) .. ^1]
        isInclude = false
      elif trimmed == "include" or trimmed.startsWith("include "):
        body = trimmed[min(7, trimmed.len) .. ^1]
        isInclude = true
      elif trimmed.startsWith("from "):
        let rest = trimmed[5 .. ^1]
        let idx = rest.find(" import")
        body = if idx >= 0: rest[0 ..< idx] else: rest
        isInclude = false
      else:
        continue
      pending = body.strip()
      pendingDepth = 0
      inStatement = true
    for ch in trimmed:
      if ch == '[': inc pendingDepth
      elif ch == ']' and pendingDepth > 0: dec pendingDepth
    # A statement continues while a bracket group is open, while the
    # accumulated text ends in a comma, or while the keyword line
    # carried no module at all (Nim's multi-line ``import`` form).
    if pendingDepth > 0 or pending.strip().endsWith(",") or
        pending.strip().len == 0:
      continue
    for item in splitTopLevelCommas(pending):
      for spec in expandImportSpec(item):
        result.add(ImportRef(spec: spec, isInclude: isInclude))
    pending = ""
    pendingDepth = 0
    inStatement = false

proc stringLiteralAt(text: string; start: int):
    tuple[found: bool, value: string] =
  ## Read the string literal that begins at the first non-``(``,
  ## non-space character at or after ``start``. ``found`` is false when
  ## the argument is not a single-line string literal (a ``const``, a
  ## concatenation, an expression) — which is exactly the case the
  ## caller must fail closed on.
  var i = start
  while i < text.len and text[i] in {' ', '\t', '('}:
    inc i
  var raw = false
  if i + 1 < text.len and text[i] in {'r', 'R'} and text[i + 1] == '"':
    raw = true
    inc i
  if i >= text.len or text[i] != '"':
    return (false, "")
  inc i
  var value = ""
  while i < text.len and text[i] != '\n':
    if not raw and text[i] == '\\' and i + 1 < text.len:
      case text[i + 1]
      of '\\': value.add('\\')
      of '"': value.add('"')
      of 'n': value.add('\n')
      of 't': value.add('\t')
      else: value.add(text[i + 1])
      i += 2
      continue
    if text[i] == '"':
      if raw and i + 1 < text.len and text[i + 1] == '"':
        value.add('"')
        i += 2
        continue
      return (true, value)
    value.add(text[i])
    inc i
  (false, "")

proc identOccurrences(text, ident: string): seq[int] =
  ## Offsets of ``ident`` occurring as a whole identifier.
  var start = 0
  while true:
    let idx = text.find(ident, start)
    if idx < 0:
      break
    start = idx + ident.len
    let beforeOk = idx == 0 or text[idx - 1] notin IdentChars
    let afterOk = start >= text.len or text[start] notin IdentChars
    if beforeOk and afterOk:
      result.add(idx)

proc compileTimeReadsOf(masked: string): seq[CompileTimeRead] =
  ## Every compile-time file read / command execution in MASKED source.
  ## These have no import syntax at all, so without this the bytes they
  ## fold into the build are invisible to the closure.
  for fn in CompileTimeFileReaders:
    for idx in identOccurrences(masked, fn):
      let arg = stringLiteralAt(masked, idx + fn.len)
      result.add(CompileTimeRead(kind: ctFileRead, fn: fn,
        literal: arg.value, hasLiteral: arg.found))
  for fn in CompileTimeCommandRunners:
    for idx in identOccurrences(masked, fn):
      result.add(CompileTimeRead(kind: ctCommand, fn: fn))

proc isExternalModuleSpec(spec: string): bool =
  spec.len == 0 or spec == "system" or spec == "std" or spec == "pkg" or
    spec.startsWith("std/") or spec.startsWith("pkg/")

proc hasNimSourceExt(spec: string): bool =
  spec.splitFile().ext.toLowerAscii() in NimSourceExts

# ---------------------------------------------------------------------------
# Search roots
# ---------------------------------------------------------------------------

proc addSearchRoot(roots: var seq[string]; projectRoot, base, value: string) =
  ## Record ``value`` (relative to ``base``) as a search root when it is
  ## an existing directory INSIDE ``projectRoot``. A ``--path`` pointing
  ## outside the project names external code, which is bound through
  ## ``dependencyInstances``, not through this closure.
  if value.len == 0:
    return
  let abs = normSlash(if value.isAbsolute: value else: base / value)
  if not dirExists(cacheIdentityExtendedPath(abs)):
    return
  if not projectRelative(projectRoot, abs).inside:
    return
  for existing in roots:
    if pathKey(existing) == pathKey(abs):
      return
  roots.add(abs)

proc expandConfigValue(value, configDir: string): string =
  result = value
  for token in ["$projectDir", "$projectPath", "$config", "$projectdir",
                "$projectpath"]:
    result = result.replace(token, configDir)
  result = result.replace('\\', '/')

proc parseConfigPaths(configText, configDir, projectRoot: string;
                      roots: var seq[string]; dynamic: var bool) =
  ## Collect ``--path`` search roots declared by one config file.
  ## ``dynamic`` is set when a path switch is present whose argument
  ## this scanner cannot evaluate — the search-root set is then UNKNOWN
  ## and every unresolved spec must be treated as possibly local.
  for rawLine in configText.splitLines():
    var line = rawLine
    let hashIdx = line.find('#')
    if hashIdx >= 0:
      line = line[0 ..< hashIdx]
    line = line.strip()
    if line.len == 0:
      continue
    var arg = ""
    var quotedOnly = false
    var found = false
    if line.startsWith("switch("):
      var body = line[line.find('(') + 1 .. ^1]
      let closeIdx = body.rfind(')')
      if closeIdx >= 0:
        body = body[0 ..< closeIdx]
      let parts = splitTopLevelCommas(body)
      if parts.len >= 2:
        let key = parts[0].strip().strip(chars = {'"'})
        if key == "path" or key == "p":
          arg = parts[1].strip()
          quotedOnly = true
          found = true
    else:
      for prefix in ["--path", "--p", "-p", "path"]:
        if line.startsWith(prefix) and line.len > prefix.len and
            line[prefix.len] in {':', '='}:
          arg = line[prefix.len + 1 .. ^1].strip()
          found = true
          break
    if not found:
      continue
    var literal = ""
    var isLiteral = false
    if arg.len >= 2 and arg.startsWith("\"") and arg.endsWith("\""):
      literal = arg[1 ..< arg.len - 1]
      isLiteral = true
    elif not quotedOnly and arg.len > 0 and '&' notin arg and
        '(' notin arg and '"' notin arg:
      literal = arg
      isLiteral = true
    if not isLiteral:
      dynamic = true
      continue
    let expanded = expandConfigValue(literal, configDir)
    if '$' in expanded or expanded.len == 0:
      dynamic = true
      continue
    addSearchRoot(roots, projectRoot, configDir, expanded)

proc parseNimbleSrcDir(nimbleText: string): string =
  for rawLine in nimbleText.splitLines():
    var line = rawLine
    let hashIdx = line.find('#')
    if hashIdx >= 0:
      line = line[0 ..< hashIdx]
    line = line.strip()
    if not line.startsWith("srcDir"):
      continue
    let eq = line.find('=')
    if eq < 0:
      continue
    let value = line[eq + 1 .. ^1].strip().strip(chars = {'"'})
    if value.len > 0:
      return value
  ""

proc collectSearchRoots(projectRoot, entryPath: string;
                        roots: var seq[string]; dynamic: var bool) =
  addSearchRoot(roots, projectRoot, projectRoot, projectRoot)
  var configNames = @["nim.cfg", "config.nims"]
  if entryPath.len > 0:
    let stem = entryPath.splitFile().name
    configNames.add(stem & ".nim.cfg")
    configNames.add(stem & ".nims")
  for name in configNames:
    let path = projectRoot / name
    if not fileExists(cacheIdentityExtendedPath(path)):
      continue
    var text = ""
    try:
      text = readFile(cacheIdentityExtendedPath(path))
    except CatchableError:
      # A config file we cannot read is a search-root set we cannot know.
      dynamic = true
      continue
    parseConfigPaths(text, projectRoot, projectRoot, roots, dynamic)
  var nimbleFiles: seq[string] = @[]
  try:
    for kind, child in walkDir(projectRoot):
      if kind in {pcFile, pcLinkToFile} and child.toLowerAscii.endsWith(".nimble"):
        nimbleFiles.add(child)
  except CatchableError:
    discard
  nimbleFiles.sort(cmp)
  for nimbleFile in nimbleFiles:
    var text = ""
    try:
      text = readFile(cacheIdentityExtendedPath(nimbleFile))
    except CatchableError:
      dynamic = true
      continue
    let srcDir = parseNimbleSrcDir(text)
    if srcDir.len > 0:
      addSearchRoot(roots, projectRoot, projectRoot, srcDir)

# ---------------------------------------------------------------------------
# Spec resolution
# ---------------------------------------------------------------------------

proc specCandidates(base, spec: string; isInclude: bool): seq[string] =
  let joined = normSlash(if spec.isAbsolute: spec else: base / spec)
  if joined.len == 0:
    return
  # An ``include`` spec, and any spec carrying a Nim source extension,
  # names a file literally. Appending ``.nim`` to it (as this scanner
  # used to, unconditionally) drops it.
  if hasNimSourceExt(spec) or (isInclude and spec.splitFile().ext.len > 0):
    result.add(joined)
  result.add(joined & ".nim")
  result.add(joined & ".nims")
  # Package-directory import: ``import pkgdir`` -> ``pkgdir/pkgdir.nim``.
  let leaf = joined.lastPathPart
  if leaf.len > 0:
    result.add(joined & "/" & leaf & ".nim")

proc resolveSpec(spec: string; isInclude: bool; fromDir: string;
                 searchRoots: seq[string]): string =
  var bases: seq[string] = @[]
  if spec.isAbsolute:
    bases.add("")
  elif spec.startsWith("./") or spec.startsWith("../"):
    bases.add(fromDir)
  else:
    bases.add(fromDir)
    for root in searchRoots:
      if pathKey(root) != pathKey(fromDir):
        bases.add(root)
  for base in bases:
    for candidate in specCandidates(base, spec, isInclude):
      if fileExists(cacheIdentityExtendedPath(candidate)):
        return candidate
  ""

proc isCandidateLocalSpec(spec: string; isInclude: bool; fromDir: string;
                          searchRoots: seq[string];
                          dynamicSearchPath: bool): bool =
  ## See the module docstring, "External library vs unresolvable local
  ## module". True means "this could be project source" and therefore
  ## must refuse rather than be dropped.
  if spec.startsWith("./") or spec.startsWith("../") or spec.isAbsolute:
    return true
  if isInclude:
    return true
  if hasNimSourceExt(spec):
    return true
  if dynamicSearchPath:
    return true
  let firstSegment = spec.split('/')[0]
  if firstSegment.len == 0:
    return true
  var bases = @[fromDir]
  for root in searchRoots:
    if pathKey(root) != pathKey(fromDir):
      bases.add(root)
  for base in bases:
    if dirExists(cacheIdentityExtendedPath(base / firstSegment)):
      return true
    for ext in [".nim", ".nims"]:
      if fileExists(cacheIdentityExtendedPath(base / firstSegment & ext)):
        return true
  false

# ---------------------------------------------------------------------------
# Closure walk
# ---------------------------------------------------------------------------

proc readClosureFile(path: string; body: var string): bool =
  try:
    body = readFile(cacheIdentityExtendedPath(path))
    true
  except CatchableError:
    false

proc collectDeclaredInput(projectRoot, declared: string;
                          paths: var seq[string]): bool =
  ## Expand one declared source input into concrete file paths. Returns
  ## false when the declared input does not exist (fail closed).
  let resolved =
    if declared.isAbsolute: normSlash(declared)
    else: normSlash(projectRoot / declared)
  if fileExists(cacheIdentityExtendedPath(resolved)):
    paths.add(resolved)
    return true
  if dirExists(cacheIdentityExtendedPath(resolved)):
    var found: seq[string] = @[]
    for entry in walkDirRec(resolved, relative = false):
      found.add(normSlash(entry))
    found.sort(cmp)
    for entry in found:
      paths.add(entry)
    return true
  false

proc solvedSourceClosure*(projectRoot: string;
                          declaredSourceInputs: seq[string] = @[]):
    SourceClosure =
  ## Resolve the complete local source closure of ``projectRoot``.
  ##
  ## Walks the entry project file's transitive ``import`` / ``from`` /
  ## ``include`` graph across every search root the project declares,
  ## folds in every compile-time file read, and adds every declared
  ## non-Nim source input. Any input that could be project source but
  ## cannot be resolved lands in ``missing`` and suppresses the digest,
  ## so callers fail closed rather than keying over partial data. See
  ## the module docstring for the external-vs-local rule.
  var missing: seq[string] = @[]
  let root =
    if projectRoot.len == 0: ""
    else:
      try: normSlash(absolutePath(projectRoot))
      except CatchableError: normSlash(projectRoot)
  if root.len == 0:
    missing.add("project root is empty")
    return SourceClosure(missing: missing)

  var entryPath = ""
  try:
    entryPath = resolveProjectFile(root).path
  except CatchableError as e:
    missing.add("project file is unresolvable: " & e.msg)
  if missing.len == 0 and entryPath.len == 0:
    missing.add("project file in " & root)

  var searchRoots: seq[string] = @[]
  var dynamicSearchPath = false
  collectSearchRoots(root, entryPath, searchRoots, dynamicSearchPath)

  var contentByRel = initTable[string, string]()
  var queued = initHashSet[string]()
  var pending: seq[tuple[path: string, scan: bool]] = @[]

  if entryPath.len > 0:
    let normalizedEntry = normSlash(absolutePath(entryPath))
    pending.add((normalizedEntry, true))
    queued.incl(pathKey(normalizedEntry))

  while pending.len > 0:
    let current = pending.pop()
    var body = ""
    let located = projectRelative(root, current.path)
    if not located.inside:
      missing.add("source file outside the project root " & current.path)
      continue
    let rel = located.rel
    if not readClosureFile(current.path, body):
      missing.add("unreadable source file " & rel)
      continue
    contentByRel[rel] = blake3.toHex(blake3.digest(body))
    if not current.scan:
      continue
    let fromDir = normSlash(parentDir(current.path))
    let masked = maskNimNonCode(body)
    for reference in importRefsOf(masked):
      if isExternalModuleSpec(reference.spec):
        continue
      let resolved = resolveSpec(reference.spec, reference.isInclude,
        fromDir, searchRoots)
      if resolved.len > 0:
        if not projectRelative(root, resolved).inside:
          # Resolved, but not project source: an external library.
          continue
        let key = pathKey(resolved)
        if key notin queued:
          queued.incl(key)
          pending.add((resolved, true))
      elif isCandidateLocalSpec(reference.spec, reference.isInclude, fromDir,
          searchRoots, dynamicSearchPath):
        missing.add("unresolved local " &
          (if reference.isInclude: "include " else: "import ") &
          reference.spec & " from " & rel)
    for read in compileTimeReadsOf(masked):
      case read.kind
      of ctCommand:
        missing.add("compile-time command execution " & read.fn & "() in " &
          rel & " (its output cannot be bound)")
      of ctFileRead:
        if not read.hasLiteral:
          missing.add("compile-time file read " & read.fn &
            "() with a non-literal path in " & rel)
          continue
        var resolvedRead = ""
        for base in [fromDir, root]:
          let candidate =
            if read.literal.isAbsolute: normSlash(read.literal)
            else: normSlash(base / read.literal)
          if fileExists(cacheIdentityExtendedPath(candidate)):
            resolvedRead = candidate
            break
        if resolvedRead.len == 0:
          missing.add("compile-time file read " & read.fn & "(\"" &
            read.literal & "\") from " & rel)
        elif not projectRelative(root, resolvedRead).inside:
          missing.add("compile-time file read outside the project root: " &
            read.fn & "(\"" & read.literal & "\") from " & rel)
        else:
          let key = pathKey(resolvedRead)
          if key notin queued:
            queued.incl(key)
            pending.add((resolvedRead, false))

  for declared in declaredSourceInputs:
    var expanded: seq[string] = @[]
    if not collectDeclaredInput(root, declared, expanded):
      missing.add("declared source input " & declared)
      continue
    for path in expanded:
      let located = projectRelative(root, path)
      if not located.inside:
        # No relocation-stable spelling exists for a path outside the
        # project root, and an absolute path in the digest would break
        # relocation invariance. Refuse instead.
        missing.add("declared source input outside the project root " &
          declared)
        continue
      var body = ""
      if not readClosureFile(path, body):
        missing.add("unreadable source input " & located.rel)
        continue
      contentByRel[located.rel] = blake3.toHex(blake3.digest(body))

  var rels: seq[string] = @[]
  for rel in contentByRel.keys:
    rels.add(rel)
  rels.sort(cmp)
  missing.sort(cmp)
  result = SourceClosure(files: rels, missing: missing)
  if missing.len > 0:
    return
  var canonical = ""
  for rel in rels:
    canonical.add(rel)
    canonical.add('\0')
    canonical.add(contentByRel[rel])
    canonical.add('\n')
  let full = blake3.toHex(blake3.digest(canonical))
  result.digestHex =
    if full.len >= SourceClosureDigestChars:
      full[0 ..< SourceClosureDigestChars]
    else:
      full

proc sourceProviderRevisionHex*(projectRoot: string): string =
  ## Source-closure digest of ``projectRoot``, truncated to 32 lowercase
  ## hex chars for the callers that kept the historical width.
  ##
  ## Reprobuild #171: this used to hash ONLY the entry recipe's bytes, so
  ## editing an imported ``recipe.nim`` left it unchanged. It now moves
  ## with every local module the entry recipe reaches. Empty when the
  ## closure cannot be resolved.
  let closure = solvedSourceClosure(projectRoot)
  if closure.missing.len > 0:
    return ""
  if closure.digestHex.len >= 32: closure.digestHex[0 ..< 32]
  else: closure.digestHex

proc isHex64(value: string): bool =
  if value.len != 64:
    return false
  for ch in value:
    if ch notin {'0'..'9', 'a'..'f', 'A'..'F'}:
      return false
  true

proc sourceIdentity(instance: SolvedSourceInstance;
                    revisionChars: int): CacheEntryIdentity =
  ## THE canonical source-package identity. Every path that needs a
  ## source-package cache key — materialized substitution (lookup),
  ## the engine's automatic publication hook, explicit materialized
  ## publication, operator backfill and graph inspection — derives it
  ## from this one tuple, so all of them agree by construction.
  ##
  ## Returns a PENDING identity (one that ``deriveCacheEntryKey``
  ## refuses) whenever any required input is missing. Completeness means
  ## ALL of: a resolvable source closure, a package name, solved
  ## options, resolved dependency instances with well-formed keys, a
  ## fully populated target triple, and a toolchain with both a name and
  ## a version.
  let closure = solvedSourceClosure(instance.projectRoot,
    instance.declaredSourceInputs)
  var missing = closure.missing

  if instance.packageName.len == 0:
    missing.add("package name")
  if not instance.optionsSolved:
    missing.add("selected options")
  if not instance.dependenciesResolved:
    missing.add("dependency instances")
  if instance.platform.cpu.len == 0 or instance.platform.os.len == 0 or
      instance.platform.abi.len == 0:
    missing.add("target platform/ABI")
  if instance.toolchain.name.len == 0 or instance.toolchain.version.len == 0:
    missing.add("toolchain identity")
  for dep in instance.dependencyInstances:
    if not isHex64(dep):
      missing.add("malformed dependency instance key " & dep)

  let revision =
    if closure.digestHex.len >= revisionChars:
      closure.digestHex[0 ..< revisionChars]
    else:
      closure.digestHex
  result = newCacheEntryIdentity(
    packageName = instance.packageName,
    packageVersion = instance.packageVersion,
    platform = instance.platform,
    toolchain = instance.toolchain,
    providerRevision = revision)
  for (name, value) in instance.selectedOptions:
    if name == PendingCacheIdentityOptionKey:
      # A caller must not smuggle the reserved marker in through the
      # option channel; treat it as missing evidence, never as data.
      missing.add("reserved option " & PendingCacheIdentityOptionKey)
      continue
    result.addOption(name, value)
  for dep in instance.dependencyInstances:
    if isHex64(dep):
      result.addDep(dep)

  if missing.len > 0:
    missing.sort(cmp)
    result.addOption(PendingCacheIdentityOptionKey,
      "unbound solved source instance: " & missing.join("; "))

proc solvedSourceCacheEntryIdentity*(instance: SolvedSourceInstance):
    CacheEntryIdentity =
  ## THE canonical source-package identity — see ``sourceIdentity``.
  ## Carries the full-width source-closure digest.
  sourceIdentity(instance, SourceClosureDigestChars)

proc sourceCacheEntryIdentity*(projectRoot, packageName, packageVersion,
                               conventionTag: string): CacheEntryIdentity =
  ## Legacy constructor for the call sites that cannot yet supply a
  ## solved instance. It binds the source closure (so the diagnostic
  ## ``providerRevision`` now moves with imported recipe code) but has
  ## NO solved options, NO resolved dependency instances and NO detected
  ## toolchain version, so the returned identity is always PENDING and
  ## can neither authorize a substitute nor a publication. Use
  ## ``solvedSourceCacheEntryIdentity`` once those inputs are solved.
  ##
  ## Its ``providerRevision`` keeps the historical 32-hex width (the
  ## from-source convention tests pin it): on a PENDING identity that
  ## field is diagnostic metadata, never a key input, so the extra
  ## collision headroom of the full digest buys nothing here.
  sourceIdentity(SolvedSourceInstance(
    projectRoot: projectRoot,
    packageName: packageName,
    packageVersion: packageVersion,
    optionsSolved: false,
    dependenciesResolved: false,
    platform: publicInterfaceTriple(),
    toolchain: publicInterfaceToolchain(conventionTag)), 32)

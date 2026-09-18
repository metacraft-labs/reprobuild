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
##     import`` / ``include``, transitively, plus every declared local
##     non-Nim source input (SDK generator templates, ``.c`` sources,
##     data files, directories);
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
## digest, so moving the same tree to a different absolute location
## yields a byte-identical identity. Hashing absolute paths would make
## the identity trivially "change on every mutation" while also
## changing on relocation — which is why the regression test pins
## relocation stability as the non-vacuity control.
##
## ## Known resolution limits of the import scan
##
## The scanner resolves an import spec ONLY against the importing
## file's own directory (plus ``.nim``). Nim resolves more than that,
## and the following forms are therefore NOT bound, silently, with a
## digest still produced over the rest:
##
##   * a module reachable only through a ``--path`` search root
##     (``config.nims``, a nimble ``srcDir``, an ``--path:`` on the
##     command line);
##   * ``include "frag.nim"`` / ``include "frag.inc"`` — an include
##     whose spec already carries an extension, since ``.nim`` is
##     appended unconditionally;
##   * a package-directory import (``import pkg`` resolving to
##     ``pkg/pkg.nim``);
##   * compile-time file reads (``staticRead`` / ``slurp`` /
##     ``gorge``), which have no import syntax at all and must be
##     declared through ``declaredSourceInputs``.
##
## Only an explicitly relative spec (``./x``, ``../x``) that fails to
## resolve is treated as missing evidence. Everything else that fails
## to resolve is assumed to be an external library. Until these are
## closed, the closure is an under-approximation for projects that use
## a search path, and the #171 aliasing class survives for those
## inputs. ``repro_interface_artifacts.discoverNimSources`` and
## ``macros_a.producerSourceStamp`` already resolve search roots and
## are the obvious place to consolidate this onto.
##
## ## Fail-closed
##
## ``PendingCacheIdentityOptionKey`` is stamped whenever ANY required
## input is unavailable: no project file, an unreadable source file, an
## explicitly relative ``import ./x`` that does not resolve, a declared
## source input that does not exist, unsolved options, unresolved
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
      ## project root so relocation stays stable).
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

proc cacheIdentityExtendedPath*(path: string): string =
  when defined(windows):
    if path.len == 0 or path.startsWith("\\\\"):
      path
    else:
      "\\\\?\\" & os.normalizedPath(absolutePath(path)).replace('/', '\\')
  else:
    path

# ---------------------------------------------------------------------------
# Nim import scanning
# ---------------------------------------------------------------------------

proc stripLineComment(line: string): string =
  ## Drop a trailing ``#`` comment, respecting ``"``/``'`` string
  ## literals so a ``#`` inside a literal is not treated as a comment.
  var inStr = false
  var quoteCh = '\0'
  for i, ch in line:
    if inStr:
      if ch == '\\':
        continue
      if ch == quoteCh:
        inStr = false
    elif ch == '"' or ch == '\'':
      inStr = true
      quoteCh = ch
    elif ch == '#':
      return line[0 ..< i]
  line

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

proc importSpecsOf(source: string): seq[string] =
  ## Every module spec named by ``import`` / ``from ... import`` /
  ## ``include`` statements in a Nim source file, including the
  ## multi-line continuation forms.
  var pending = ""
  var pendingDepth = 0
  var inStatement = false
  for rawLine in source.splitLines():
    let line = stripLineComment(rawLine)
    let trimmed = line.strip()
    if inStatement:
      if trimmed.len == 0:
        continue
      pending.add(" ")
      pending.add(trimmed)
    else:
      var body = ""
      if trimmed == "import" or trimmed.startsWith("import "):
        body = trimmed[min(6, trimmed.len) .. ^1]
      elif trimmed == "include" or trimmed.startsWith("include "):
        body = trimmed[min(7, trimmed.len) .. ^1]
      elif trimmed.startsWith("from "):
        let rest = trimmed[5 .. ^1]
        let idx = rest.find(" import")
        body = if idx >= 0: rest[0 ..< idx] else: rest
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
        result.add(spec)
    pending = ""
    pendingDepth = 0
    inStatement = false

proc isExternalModuleSpec(spec: string): bool =
  spec.len == 0 or spec == "system" or
    spec.startsWith("std/") or spec.startsWith("pkg/")

# ---------------------------------------------------------------------------
# Closure walk
# ---------------------------------------------------------------------------

proc canonicalRelative(projectRoot, path: string): string =
  var rel =
    try: relativePath(path, projectRoot)
    except CatchableError: path
  if rel.len == 0:
    rel = extractFilename(path)
  rel.replace('\\', '/')

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
    if declared.isAbsolute: os.normalizedPath(declared)
    else: os.normalizedPath(projectRoot / declared)
  if fileExists(cacheIdentityExtendedPath(resolved)):
    paths.add(resolved)
    return true
  if dirExists(resolved):
    var found: seq[string] = @[]
    for entry in walkDirRec(resolved, relative = false):
      found.add(os.normalizedPath(entry))
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
  ## ``include`` graph, keeping every module that resolves to a real
  ## file on disk, and adds every declared non-Nim source input. Any
  ## unresolvable REQUIRED input lands in ``missing`` and suppresses the
  ## digest, so callers fail closed rather than keying over partial data.
  ##
  ## Import specs that do not resolve to a local file are treated as
  ## external library imports (``std/os``, ``repro_project_dsl``, a
  ## nimble package) and ignored — EXCEPT explicitly relative specs
  ## (``./x``, ``../x``), which name a local file by construction and so
  ## count as missing evidence when they do not resolve.
  var missing: seq[string] = @[]
  let root =
    if projectRoot.len == 0: ""
    else:
      try: os.normalizedPath(absolutePath(projectRoot))
      except CatchableError: projectRoot
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

  var contentByRel = initTable[string, string]()
  var queued = initHashSet[string]()
  var pending: seq[string] = @[]

  if entryPath.len > 0:
    let normalizedEntry = os.normalizedPath(absolutePath(entryPath))
    pending.add(normalizedEntry)
    queued.incl(normalizedEntry.toLowerAscii())

  while pending.len > 0:
    let current = pending.pop()
    var body = ""
    if not readClosureFile(current, body):
      missing.add("unreadable source file " & canonicalRelative(root, current))
      continue
    let rel = canonicalRelative(root, current)
    contentByRel[rel] = blake3.toHex(blake3.digest(body))
    let fromDir = parentDir(current)
    for spec in importSpecsOf(body):
      if isExternalModuleSpec(spec):
        continue
      let explicitlyRelative = spec.startsWith("./") or spec.startsWith("../")
      let candidate = os.normalizedPath(fromDir / (spec & ".nim"))
      if fileExists(cacheIdentityExtendedPath(candidate)):
        let key = candidate.toLowerAscii()
        if key notin queued:
          queued.incl(key)
          pending.add(candidate)
      elif explicitlyRelative:
        missing.add("unresolved local import " & spec & " from " & rel)

  for declared in declaredSourceInputs:
    var expanded: seq[string] = @[]
    if not collectDeclaredInput(root, declared, expanded):
      missing.add("declared source input " & declared)
      continue
    for path in expanded:
      var body = ""
      if not readClosureFile(path, body):
        missing.add("unreadable source input " & canonicalRelative(root, path))
        continue
      contentByRel[canonicalRelative(root, path)] =
        blake3.toHex(blake3.digest(body))

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

## Recipe constraints: what a recipe states about each dependency's revision.
##
## Reprobuild and Nix flakes split a dependency the same way. The RECIPE states
## a constraint, and the LOCK records a resolution:
##
## ============  ======================================  ==========================
##               Reprobuild                              Nix flake
## ============  ======================================  ==========================
## constraint    a ``uses:`` version range, or an exact  an input URL: a branch
##               version that a ``versions:`` entry      reference, or an exact
##               maps to a ``sourceRevision``            ``rev=`` / ``/<sha>``
## resolution    a ``repro.lock`` ``deps`` entry         a ``flake.lock`` node's
##                                                       ``locked``
## ============  ======================================  ==========================
##
## This module READS the constraint side of both systems, and nothing else. It
## writes nothing, evaluates nothing and starts no process, so a managed hook
## can call it on every commit. The callers decide what a constraint means for
## them:
##
## * the managed hooks skip the sibling comparison for a repository a recipe
##   pins by exact revision (the hooks' develop set);
## * the consistency checks compare a constraint with its resolution, and the
##   two systems with each other, by canonical repository URL.
##
## Identity is the canonical repository URL. It is produced by
## ``canonicalRemoteIdentity`` (``shared_clones``), the normalisation
## ``repro sync`` uses to decide that two remote URLs name one repository. This
## module adds no second normalisation: it only translates a flake reference
## (``github:o/r``, ``git+https://h/o/r?ref=main``) into the plain fetch URL that
## routine already reads. So ``github:o/r``, ``git+https://github.com/o/r`` and
## ``https://github.com/o/r.git`` all have the identity ``github.com/o/r``.
##
## Flake references are described in the Nix manual:
## https://nix.dev/manual/nix/latest/command-ref/new-cli/nix3-flake#flake-references
## Semver ranges are the ``uses:`` grammar parsed by
## ``repro_solver/version_constraints``.

import std/[algorithm, json, os, strutils, tables]

import shared_clones
import repro_solver/version_constraints
import repro_interface_artifacts

# ---------------------------------------------------------------------------
# Small shared predicates
# ---------------------------------------------------------------------------

proc isHexDigit(c: char): bool {.inline.} =
  c in {'0'..'9', 'a'..'f', 'A'..'F'}

proc isExactRevision*(value: string): bool =
  ## True when ``value`` is a full commit id: 40 hex digits (SHA-1) or 64
  ## (SHA-256). These are the only forms Nix accepts as a ``rev``. A shorter
  ## hex string is not a revision here. In a ``github:o/r/<x>`` path, Nix reads
  ## anything that is not a full commit id as a branch or tag name.
  if value.len != 40 and value.len != 64: return false
  for c in value:
    if not isHexDigit(c): return false
  true

proc percentDecode(value: string): string =
  ## Decode ``%XX`` escapes. A malformed escape is kept literally. Flake
  ## references use escapes for nested GitLab groups (``gitlab:a%2Fb/r``) and
  ## for ``/`` inside a branch name.
  var i = 0
  while i < value.len:
    if value[i] == '%' and i + 2 < value.len and isHexDigit(value[i + 1]) and
        isHexDigit(value[i + 2]):
      result.add(char(parseHexInt(value[i + 1 .. i + 2])))
      i += 3
    else:
      result.add(value[i])
      inc i

# ---------------------------------------------------------------------------
# Flake references
# ---------------------------------------------------------------------------

type
  FlakeRefKind* = enum
    ## How a flake reference names its source.
    frkGitForge     ## ``github:`` / ``gitlab:`` / ``sourcehut:``
    frkGit          ## ``git+<scheme>://…`` or ``git://…``
    frkPath         ## ``path:…``, or a bare absolute or relative path
    frkTarball      ## ``tarball+…``, ``file+…``, or an ``http(s)://`` archive
    frkIndirect     ## a registry name such as ``nixpkgs`` or ``flake:nixpkgs``
    frkOther        ## any other scheme (``hg+…``, …); no repository identity

  FlakeRefParts* = object
    ## A flake reference, split into the facts a constraint needs.
    kind*: FlakeRefKind
    fetchUrl*: string
      ## A plain URL that ``canonicalRemoteIdentity`` can read, or "" when the
      ## reference names no fetchable repository (a registry name, a
      ## tarball). For a forge reference this is the forge's https URL.
    gitRef*: string
      ## The branch or tag the reference follows (``ref=``, or a non-revision
      ## third path component of a forge reference), or "".
    rev*: string
      ## The exact revision the reference names (``rev=``, or a full commit id
      ## as the third path component of a forge reference), or "".

proc splitQuery(text: string): tuple[base: string; params: Table[string, string]] =
  ## Split ``base?k=v&k2=v2#frag`` into its base and its query parameters. The
  ## fragment is dropped: in a flake reference it names an output attribute,
  ## not part of the source.
  result.params = initTable[string, string]()
  var rest = text
  let hash = rest.find('#')
  if hash >= 0: rest = rest[0 ..< hash]
  let q = rest.find('?')
  if q < 0:
    result.base = rest
    return
  result.base = rest[0 ..< q]
  for pair in rest[q + 1 .. ^1].split('&'):
    if pair.len == 0: continue
    let eq = pair.find('=')
    if eq < 0:
      result.params[percentDecode(pair)] = ""
    else:
      result.params[percentDecode(pair[0 ..< eq])] = percentDecode(pair[eq + 1 .. ^1])

proc parseFlakeRef*(url: string): FlakeRefParts =
  ## Split a flake reference URL into its source kind, a fetchable URL, and
  ## the ``ref`` / ``rev`` it names. Pure and total: an unrecognised form comes
  ## back as ``frkOther`` with no fetch URL, never as an exception.
  ##
  ## Recognised forms (Nix manual, "Flake references"):
  ##
  ## * ``github:owner/repo[/ref-or-rev][?ref=…&rev=…&host=…]`` and the same
  ##   for ``gitlab:`` and ``sourcehut:``. A third path component that is a
  ##   full commit id is a ``rev``; anything else there is a ``ref``.
  ## * ``git+https://…``, ``git+ssh://…``, ``git+http://…``, ``git+file://…``
  ##   and ``git://…``, with ``ref=`` / ``rev=`` in the query.
  ## * ``path:…`` and bare paths (``/abs``, ``./rel``).
  ## * ``tarball+…``, ``file+…`` and plain ``http(s)://`` archives.
  ## * registry names (``nixpkgs``, ``flake:nixpkgs``).
  let raw = url.strip()
  let (base, params) = splitQuery(raw)
  result.gitRef = params.getOrDefault("ref", "")
  result.rev = params.getOrDefault("rev", "")
  let colon = base.find(':')
  let scheme = if colon > 0: base[0 ..< colon].toLowerAscii() else: ""
  case scheme
  of "github", "gitlab", "sourcehut":
    result.kind = frkGitForge
    var segments: seq[string]
    for s in base[colon + 1 .. ^1].split('/'):
      if s.len > 0: segments.add(s)
    if segments.len < 2:
      result.kind = frkOther
      return
    let defaultHost =
      case scheme
      of "github": "github.com"
      of "gitlab": "gitlab.com"
      else: "git.sr.ht"
    let host = params.getOrDefault("host", defaultHost)
    result.fetchUrl = "https://" & host & "/" & percentDecode(segments[0]) &
      "/" & segments[1]
    if segments.len >= 3:
      let third = percentDecode(segments[2 .. ^1].join("/"))
      if isExactRevision(third):
        if result.rev.len == 0: result.rev = third
      elif result.gitRef.len == 0:
        result.gitRef = third
  of "git+https", "git+http", "git+ssh", "git+file", "git":
    result.kind = frkGit
    result.fetchUrl =
      if scheme.startsWith("git+"): base["git+".len .. ^1] else: base
  of "path":
    result.kind = frkPath
    result.fetchUrl = base["path:".len .. ^1]
  of "tarball+https", "tarball+http", "tarball+file", "file+https",
      "file+http", "file+file", "https", "http", "file":
    result.kind = frkTarball
  of "flake":
    result.kind = frkIndirect
  of "":
    if base.startsWith("/") or base.startsWith("./") or base.startsWith("../") or
        base == "." or base == "..":
      result.kind = frkPath
      result.fetchUrl = base
    elif base.len > 0:
      result.kind = frkIndirect
    else:
      result.kind = frkOther
  else:
    result.kind = frkOther

proc canonicalFlakeRefRepository*(url: string): string =
  ## The canonical identity of the repository the FLAKE REFERENCE ``url``
  ## names, or "" when it names none (a registry name, a tarball, an
  ## unrecognised scheme). Unlike ``canonicalRepositoryUrl`` this always reads
  ## ``url`` as a flake reference, so a plain ``https://…`` is an archive, as
  ## Nix reads it in a flake input, not a git remote.
  let parts = parseFlakeRef(url)
  if parts.fetchUrl.len == 0: return ""
  canonicalRemoteIdentity(parts.fetchUrl)

proc canonicalRepositoryUrl*(url: string): string =
  ## The canonical identity of the repository ``url`` names, or "" when it
  ## names none. ``url`` may be a flake reference (``github:o/r``,
  ## ``git+https://…?ref=…``) or a plain git remote URL (the ``url`` of a
  ## ``repro.lock`` ``deps`` entry). Both reduce to a fetch URL, and the
  ## identity is ``canonicalRemoteIdentity`` of it, the normalisation
  ## ``repro sync`` uses. Two URLs name one repository exactly when this
  ## returns the same non-empty string for both.
  let trimmed = url.strip()
  if trimmed.len == 0: return ""
  let colon = trimmed.find(':')
  let scheme = if colon > 0: trimmed[0 ..< colon].toLowerAscii() else: ""
  let flakeScheme = scheme in ["github", "gitlab", "sourcehut", "git+https",
    "git+http", "git+ssh", "git+file", "path", "flake", "tarball+https",
    "tarball+http", "tarball+file", "file+https", "file+http", "file+file"]
  if flakeScheme:
    return canonicalFlakeRefRepository(trimmed)
  # A plain remote URL. Its query, if any, is transport material (a signed
  # URL's token), never part of the repository's identity.
  let (base, _) = splitQuery(trimmed)
  if base.len == 0: return ""
  canonicalRemoteIdentity(base)

# ---------------------------------------------------------------------------
# flake.nix: the inputs a flake declares, with their URLs and lines
# ---------------------------------------------------------------------------

const
  defaultFlakeInputStripSuffixes* = @["-src"]
    ## The metacraft naming convention `.envrc` configures as
    ## `NIX_FLAKE_OVERRIDE_AUTO_STRIP_SUFFIXES=-src`: an input named
    ## `runquota-src` is backed by the repo `runquota`. It is a DEFAULT rather
    ## than a hardcode — `--strip-suffix=<list>` replaces it, and
    ## `--strip-suffix=` (empty) turns suffix stripping off — because the
    ## convention belongs to the projects that use it, not to the tool.

proc stripFlakeInputSuffix*(name: string; suffixes: openArray[string]): string =
  ## The repo name an input name is a spelling of: the LONGEST declared suffix
  ## the name ends with, removed. Same rule as
  ## `dev_shell_strip_input_suffix` in `scripts/lib/dev_shell_overrides.sh`,
  ## so an `.envrc` migrating from the six-variable form resolves the same
  ## siblings it did before.
  var best = ""
  for suffix in suffixes:
    if suffix.len == 0: continue
    if not name.endsWith(suffix): continue
    if suffix.len > best.len: best = suffix
  if best.len == 0: name else: name[0 ..< name.len - best.len]

type
  FlakeInputDeclaration* = object
    ## One input as ``flake.nix`` declares it, read without evaluation.
    name*: string
    line*: int
      ## 1-based line where the input's name first appears.
    url*: string
      ## The input's ``url`` string literal, or "" when it has none (a pure
      ## ``follows``, or a URL built by an expression this reader does not
      ## evaluate; see ``urlIsLiteral``).
    urlLine*: int
      ## 1-based line of the ``url`` literal, or 0.
    urlIsLiteral*: bool
      ## False when the ``url`` value was not a plain string literal (an
      ## interpolation ``${…}`` or a non-string expression). Such a URL is not
      ## reported as a constraint, because its value is not known without
      ## evaluating the flake.
    follows*: string
      ## The input's own ``follows`` target, or "".

proc lineAt(lineStarts: seq[int]; offset: int): int =
  ## 1-based line number of byte ``offset``.
  var lo = 0
  var hi = lineStarts.len - 1
  while lo < hi:
    let mid = (lo + hi + 1) div 2
    if lineStarts[mid] <= offset: lo = mid
    else: hi = mid - 1
  lo + 1

proc scanFlakeInputDeclarations*(source: string): seq[FlakeInputDeclaration] =
  ## Every input a ``flake.nix`` declares, in declaration order and without
  ## duplicates, each with its ``url`` literal and the lines they are on. Pure
  ## text; nothing is evaluated.
  ##
  ## Both spellings an input can be written in are recognised:
  ##
  ## * inside the ``inputs = { … }`` block: ``nixpkgs.url = "…";``,
  ##   ``nixpkgs.follows = "…";``, and the attribute-set form
  ##   ``bundlers = { url = "…"; inputs.nixpkgs.follows = "nixpkgs"; };``
  ## * flattened at the top level: ``inputs.nixpkgs.url = "…";`` and
  ##   ``inputs.nixpkgs = { url = "…"; };``
  ##
  ## An input with no ``url`` (a pure ``follows``) is returned too. The names
  ## answer "what can ``--override-input`` address", which is a property of
  ## the name, not of how it is resolved.
  ##
  ## The scan tracks brace depth, so a nested ``inputs.<x>.follows`` inside an
  ## attribute-set input is not taken for a top-level input called ``inputs``.
  ## It skips comments and both string forms, so a ``{`` inside a URL or a
  ## ``#`` inside a string cannot move the depth.
  var lineStarts = @[0]
  for i, c in source:
    if c == '\n': lineStarts.add(i + 1)
  var
    i = 0
    depth = 0
    inputsDepth = -1     ## brace depth INSIDE the `inputs = { … }` block
    path: seq[string]    ## the dotted attribute path being accumulated
    pathStart = -1       ## offset of the path's first identifier
    awaitingInputsBrace = false
    decls: seq[FlakeInputDeclaration]
    indexOf = initTable[string, int]()
    owners: seq[tuple[name: string; depth: int]]
      ## attribute-set inputs currently open: `X = { … }` (or
      ## `inputs.X = { … }`), with the brace depth INSIDE that set
    pendingOwner = ""    ## an input whose `=` was followed by `{`
  proc isIdentChar(c: char): bool =
    c in {'a'..'z', 'A'..'Z', '0'..'9', '_', '-', '\''}
  proc declare(name: string; at: int): int =
    if name in indexOf: return indexOf[name]
    indexOf[name] = decls.len
    decls.add(FlakeInputDeclaration(name: name, line: lineAt(lineStarts, at)))
    decls.len - 1
  proc skipBlank(pos: int): int =
    ## Skip whitespace and comments from ``pos``.
    var j = pos
    while j < source.len:
      let c = source[j]
      if c in {' ', '\t', '\r', '\n'}:
        inc j
      elif c == '#':
        while j < source.len and source[j] != '\n': inc j
      elif c == '/' and j + 1 < source.len and source[j + 1] == '*':
        j += 2
        while j + 1 < source.len and not (source[j] == '*' and source[j + 1] == '/'):
          inc j
        j += 2
      else:
        break
    j
  proc stringValueAt(pos: int): tuple[found, literal: bool; value: string; at: int] =
    ## The string literal starting at ``pos`` (after blanks), if any.
    let j = skipBlank(pos)
    result.at = j
    if j >= source.len: return
    if source[j] == '"':
      result.found = true
      result.literal = true
      var k = j + 1
      while k < source.len and source[k] != '"':
        if source[k] == '\\' and k + 1 < source.len:
          inc k
          case source[k]
          of 'n': result.value.add('\n')
          of 't': result.value.add('\t')
          of 'r': result.value.add('\r')
          else: result.value.add(source[k])
        elif source[k] == '$' and k + 1 < source.len and source[k + 1] == '{':
          result.literal = false
          result.value.add(source[k])
        else:
          result.value.add(source[k])
        inc k
    elif source[j] == '\'' and j + 1 < source.len and source[j + 1] == '\'':
      result.found = true
      result.literal = true
      var k = j + 2
      while k + 1 < source.len and not (source[k] == '\'' and source[k + 1] == '\''):
        if source[k] == '$' and source[k + 1] == '{': result.literal = false
        result.value.add(source[k])
        inc k
      result.value = result.value.strip()
  proc record(eqAt: int) =
    ## An `=` closed an attribute path. Decide whether it names an input, and
    ## whether it assigns that input's `url` or `follows`.
    if path.len == 0: return
    var name = ""
    var tail: seq[string]
    if depth == 1 and path.len >= 2 and path[0] == "inputs":
      name = path[1]
      tail = path[2 .. ^1]
    elif inputsDepth >= 0 and depth == inputsDepth:
      name = path[0]
      tail = path[1 .. ^1]
    elif owners.len > 0 and depth == owners[^1].depth and path.len == 1:
      # `url = "…"` / `follows = "…"` directly inside `X = { … }`.
      let idx = indexOf.getOrDefault(owners[^1].name, -1)
      if idx < 0: return
      if path[0] in ["url", "follows"]:
        let value = stringValueAt(eqAt + 1)
        if value.found:
          if path[0] == "url":
            decls[idx].url = if value.literal: value.value else: ""
            decls[idx].urlIsLiteral = value.literal
            decls[idx].urlLine = lineAt(lineStarts, value.at)
          elif value.literal:
            decls[idx].follows = value.value
      return
    if name.len == 0: return
    let idx = declare(name, pathStart)
    if tail.len == 0:
      let j = skipBlank(eqAt + 1)
      if j < source.len and source[j] == '{':
        pendingOwner = name
      return
    if tail == @["url"] or tail == @["follows"]:
      let value = stringValueAt(eqAt + 1)
      if not value.found:
        if tail[0] == "url":
          decls[idx].urlIsLiteral = false
          decls[idx].urlLine = lineAt(lineStarts, value.at)
        return
      if tail[0] == "url":
        decls[idx].url = if value.literal: value.value else: ""
        decls[idx].urlIsLiteral = value.literal
        decls[idx].urlLine = lineAt(lineStarts, value.at)
      elif value.literal:
        decls[idx].follows = value.value
  while i < source.len:
    let c = source[i]
    if c == '#':
      while i < source.len and source[i] != '\n': inc i
      continue
    if c == '/' and i + 1 < source.len and source[i + 1] == '*':
      i += 2
      while i + 1 < source.len and not (source[i] == '*' and source[i + 1] == '/'):
        inc i
      i += 2
      continue
    if c == '"':
      inc i
      while i < source.len and source[i] != '"':
        if source[i] == '\\': inc i
        inc i
      inc i
      continue
    if c == '\'' and i + 1 < source.len and source[i + 1] == '\'' and
        (i == 0 or not isIdentChar(source[i - 1])):
      # Nix's indented-string form ``''…''``. Guarded on the preceding
      # character because ``'`` is also a legal identifier character, so a
      # trailing prime inside a name (``foo''``) must not open a string.
      i += 2
      while i + 1 < source.len and not (source[i] == '\'' and source[i + 1] == '\''):
        inc i
      i += 2
      continue
    if c == '{':
      inc depth
      if awaitingInputsBrace:
        inputsDepth = depth
        awaitingInputsBrace = false
      if pendingOwner.len > 0:
        owners.add((name: pendingOwner, depth: depth))
        pendingOwner = ""
      path.setLen(0)
      inc i
      continue
    if c == '}':
      if inputsDepth >= 0 and depth == inputsDepth:
        inputsDepth = -1
      if owners.len > 0 and owners[^1].depth == depth:
        discard owners.pop()
      dec depth
      path.setLen(0)
      inc i
      continue
    if c == '=':
      # ``==`` is a comparison, not an assignment; it cannot close a path.
      if i + 1 < source.len and source[i + 1] == '=':
        i += 2
        path.setLen(0)
        continue
      pendingOwner = ""
      record(i)
      # ``inputs = {`` opens the block whose members are input names. The
      # brace may be several tokens away (whitespace, a comment), so the
      # decision is deferred to whichever `{` comes next.
      awaitingInputsBrace = depth == 1 and path == @["inputs"]
      path.setLen(0)
      inc i
      continue
    if c == ';' or c == ',':
      path.setLen(0)
      awaitingInputsBrace = false
      pendingOwner = ""
      inc i
      continue
    if c == '.':
      inc i
      continue
    if isIdentChar(c):
      var j = i
      while j < source.len and isIdentChar(source[j]): inc j
      if path.len == 0: pathStart = i
      path.add(source[i ..< j])
      i = j
      continue
    if c notin {' ', '\t', '\r', '\n'}:
      # Anything else (`:`, `[`, `(`, an operator) ends the attribute path
      # without recording it.
      path.setLen(0)
      awaitingInputsBrace = false
    inc i
  decls

# ---------------------------------------------------------------------------
# Flake input constraints
# ---------------------------------------------------------------------------

type
  FlakeInputConstraint* = object
    ## What ``flake.nix`` states about one input's revision.
    input*: string
    url*: string           ## the URL literal as written, or ""
    line*: int             ## 1-based line of the URL literal (0 when none)
    kind*: FlakeRefKind
    exactRev*: string
      ## The revision the URL names (``rev=`` or ``/<sha>``), or "". Non-empty
      ## means the recipe pins this input by exact revision.
    gitRef*: string        ## the branch or tag the URL follows, or ""
    canonicalRepo*: string
      ## ``canonicalRepositoryUrl`` of the URL, or "" when it names no
      ## repository.
    follows*: string       ## the input's own ``follows`` target, or ""

  FlakeRecipeConstraints* = object
    ## Every input constraint of one ``flake.nix``.
    ok*: bool
    flakePath*: string
    inputs*: seq[FlakeInputConstraint]
    diagnostic*: string    ## why ``ok`` is false

proc flakeInputConstraintOf*(decl: FlakeInputDeclaration): FlakeInputConstraint =
  ## The constraint one declared input states. An input whose URL is not a
  ## plain literal states no constraint this reader can see: ``exactRev`` and
  ## ``canonicalRepo`` stay empty rather than guessed.
  result = FlakeInputConstraint(input: decl.name, follows: decl.follows,
    line: decl.urlLine)
  if not decl.urlIsLiteral or decl.url.len == 0:
    result.kind = frkOther
    return
  result.url = decl.url
  let parts = parseFlakeRef(decl.url)
  result.kind = parts.kind
  result.gitRef = parts.gitRef
  if isExactRevision(parts.rev): result.exactRev = parts.rev.toLowerAscii()
  result.canonicalRepo = canonicalFlakeRefRepository(decl.url)

proc flakeRecipeConstraintsOf*(source, flakePath: string): FlakeRecipeConstraints =
  ## Every input constraint stated by the ``flake.nix`` text ``source``.
  result.flakePath = flakePath
  for decl in scanFlakeInputDeclarations(source):
    result.inputs.add(flakeInputConstraintOf(decl))
  result.ok = true

proc readFlakeRecipeConstraints*(flakeRoot: string): FlakeRecipeConstraints =
  ## Read ``<flakeRoot>/flake.nix`` and return every input's constraint. A
  ## missing or unreadable file comes back with ``ok = false`` and a
  ## diagnostic, never as an empty list that would read as "no input is
  ## pinned".
  let path = flakeRoot / "flake.nix"
  result.flakePath = path
  if not fileExists(path):
    result.diagnostic = "there is no flake.nix at " & path
    return
  var source = ""
  try:
    source = readFile(path)
  except CatchableError as err:
    result.diagnostic = path & " could not be read (" & err.msg & ")"
    return
  flakeRecipeConstraintsOf(source, path)

proc exactPins*(constraints: FlakeRecipeConstraints): seq[FlakeInputConstraint] =
  ## The inputs the recipe pins by exact revision, in declaration order.
  for c in constraints.inputs:
    if c.exactRev.len > 0: result.add(c)

proc describeFlakePin*(c: FlakeInputConstraint; flakePath: string): string =
  ## ``flake.nix:<line>`` plus the pinned revision, for messages.
  let file = if flakePath.len > 0: flakePath else: "flake.nix"
  file & ":" & $c.line & " (rev " & c.exactRev & ")"

# ---------------------------------------------------------------------------
# flake.lock: which repository each root input resolves to
# ---------------------------------------------------------------------------

type
  FlakeLockResolution* = object
    ## One root input of a ``flake.lock``, as the lock resolves it.
    input*: string
    node*: string
    lockedRev*: string     ## ``locked.rev``, or ""
    originalRev*: string   ## ``original.rev``, or ""
    canonicalRepo*: string ## the repository ``locked`` names, or ""

proc flakeLockNodeUrl(attrs: JsonNode): string =
  ## Rebuild a fetch URL from a lock node's ``locked`` / ``original`` object
  ## (``{type, owner, repo, host, url}``), in the form ``parseFlakeRef`` reads.
  if attrs.isNil or attrs.kind != JObject: return ""
  let kind = attrs{"type"}.getStr()
  case kind
  of "github", "gitlab", "sourcehut":
    let owner = attrs{"owner"}.getStr()
    let repo = attrs{"repo"}.getStr()
    if owner.len == 0 or repo.len == 0: return ""
    result = kind & ":" & owner & "/" & repo
    let host = attrs{"host"}.getStr()
    if host.len > 0: result.add("?host=" & host)
  of "git":
    let url = attrs{"url"}.getStr()
    if url.len == 0: return ""
    result = if url.startsWith("git+") or url.startsWith("git://"): url
             else: "git+" & url
  of "path":
    let p = attrs{"path"}.getStr()
    if p.len > 0: result = "path:" & p
  else:
    discard

proc flakeLockResolutions*(lockText: string): seq[FlakeLockResolution] =
  ## Every root input of a ``flake.lock`` that resolves to a node of its own,
  ## with the repository that node names. A ``follows`` input (an array of node
  ## names) resolves to another input's node and is not listed. An unreadable
  ## document yields an empty list; the callers that must refuse on that read
  ## the lock with ``flakeLockPinnedRevisions`` first.
  var doc: JsonNode
  try:
    doc = parseJson(lockText)
  except CatchableError:
    return
  if doc.kind != JObject or not doc.hasKey("nodes") or
      doc["nodes"].kind != JObject:
    return
  let rootKey =
    if doc.hasKey("root") and doc["root"].kind == JString: doc["root"].getStr()
    else: "root"
  let nodes = doc["nodes"]
  if not nodes.hasKey(rootKey) or nodes[rootKey].kind != JObject or
      not nodes[rootKey].hasKey("inputs") or
      nodes[rootKey]["inputs"].kind != JObject:
    return
  for name, target in nodes[rootKey]["inputs"].pairs:
    if target.kind != JString: continue
    let nodeKey = target.getStr()
    if not nodes.hasKey(nodeKey) or nodes[nodeKey].kind != JObject: continue
    let node = nodes[nodeKey]
    var r = FlakeLockResolution(input: name, node: nodeKey)
    let locked = node{"locked"}
    let original = node{"original"}
    if not locked.isNil and locked.kind == JObject:
      r.lockedRev = locked{"rev"}.getStr()
      r.canonicalRepo = canonicalFlakeRefRepository(flakeLockNodeUrl(locked))
    if not original.isNil and original.kind == JObject:
      r.originalRev = original{"rev"}.getStr()
      if r.canonicalRepo.len == 0:
        r.canonicalRepo = canonicalFlakeRefRepository(
          flakeLockNodeUrl(original))
    result.add(r)
  result.sort(proc (a, b: FlakeLockResolution): int = cmp(a.input, b.input))

# ---------------------------------------------------------------------------
# repro.nim: `uses:` constraints and `versions:` source revisions
# ---------------------------------------------------------------------------
#
# What the existing DSL exposes, and therefore what this reader can give.
#
# * A `uses:` entry is carried, after interface extraction, as an
#   `InterfaceToolUse` whose `rawConstraint` is the text the author wrote
#   ("nim >=2.2 <3", "lib ==1.4.0") and whose `location` is the recipe line.
#   Extraction compiles the recipe, so it is NOT done here; callers pass the
#   uses they already hold (the lock refresh holds them in
#   `CompiledProviderSolverInputs.toolUses`).
# * A `versions:` entry maps a version to a `sourceRevision`. The DSL lowers it
#   to a `registerVersion` call that runs inside the provider process, so the
#   mapping is not part of the interface artifact. This reader recovers it
#   from the PRODUCER's recipe text, for entries whose `sourceRevision` is a
#   plain string literal. A non-literal value (a `const`) is reported with
#   `sourceRevisionIsLiteral = false` and no value, never guessed.

type
  UsesConstraintKind* = enum
    uckUnconstrained   ## the entry names a package and no version
    uckRange           ## a range (`>=2.2 <3`, `^1.5`, `~2.1`)
    uckExact           ## an exact version (`==1.2.3`, `=1.2.3`, `1.2.3`)
    uckUnparseable     ## a version text the semver grammar rejects

  ReproUsesConstraint* = object
    ## What one `uses:` entry states about its package's version.
    selector*: string      ## the package the entry names
    rangeText*: string     ## the version text after the selector, or ""
    kind*: UsesConstraintKind
    exactVersion*: string  ## the version an exact entry names, or ""
    range*: SemverRange    ## the parsed range (unbounded when unconstrained)
    diagnostic*: string    ## why the text is unparseable
    file*: string          ## the recipe the entry is written in
    line*: int             ## its line, or 0 when unknown

proc parseReproUsesConstraint*(rawConstraint: string; file = "";
    line = 0): ReproUsesConstraint =
  ## Split a `uses:` constraint ("lib ==1.4.0", "nim >=2.2 <3", "git") into
  ## its selector and version constraint, and classify the constraint. The
  ## selector is the first whitespace-separated token, the same split
  ## `usesSelectorOf` makes in the DSL runtime.
  result.file = file
  result.line = line
  result.range = unboundedRange()
  let text = rawConstraint.strip()
  let parts = text.splitWhitespace()
  if parts.len == 0:
    result.kind = uckUnparseable
    result.diagnostic = "empty uses: constraint"
    return
  result.selector = parts[0]
  if parts.len == 1:
    result.kind = uckUnconstrained
    return
  result.rangeText = text[text.find(parts[0]) + parts[0].len .. ^1].strip()
  try:
    result.range = parseSemverRange(result.rangeText)
  except ESemverParse as err:
    result.kind = uckUnparseable
    result.diagnostic = err.msg
    return
  # Exact when the text is ONE token with no bound operator, or an `=`/`==`
  # token: the forms `parseSingleConstraint` reads as an exact pin. Deciding
  # from the text rather than from the parsed bounds keeps `>=1.2.3 <1.2.4`
  # (a range that happens to admit one version) a range, as the author wrote.
  let tokens = result.rangeText.replace(",", " ").splitWhitespace()
  if tokens.len == 1:
    var t = tokens[0]
    var exact = false
    if t.startsWith("=="):
      t = t[2 .. ^1]; exact = true
    elif t.startsWith("="):
      t = t[1 .. ^1]; exact = true
    elif t.len > 0 and t[0] notin {'>', '<', '^', '~'}:
      exact = true
    if exact:
      if t.len > 0 and t[0] in {'v', 'V'}: t = t[1 .. ^1]
      result.kind = uckExact
      result.exactVersion = t.strip()
      return
  result.kind = uckRange

proc reproUsesConstraints*(uses: openArray[InterfaceToolUse]):
    seq[ReproUsesConstraint] =
  ## Every `uses:` constraint of an extracted project interface, with the
  ## recipe line it was written on.
  for u in uses:
    result.add(parseReproUsesConstraint(u.rawConstraint, u.location.file,
      u.location.line))

proc admits*(c: ReproUsesConstraint; version: string): bool =
  ## Does the constraint admit ``version``? An unconstrained entry admits
  ## every version; an unparseable constraint or version admits none.
  case c.kind
  of uckUnconstrained: true
  of uckUnparseable: false
  of uckExact, uckRange:
    try: satisfies(parseSemver(version.strip()), c.range)
    except ESemverParse: false

proc isComparableVersion*(version: string): bool =
  ## Can ``version`` be compared with a range at all? ``admits`` answers false
  ## both for a version outside the range and for one the grammar cannot read;
  ## a caller that must tell those apart asks this.
  try:
    discard parseSemver(version.strip())
    true
  except ESemverParse:
    false

type
  ReproVersionEntry* = object
    ## One `"<version>":` entry of a recipe's `versions:` block.
    version*: string
    sourceRevision*: string
      ## The literal `sourceRevision`, or "" when absent or not a literal.
    sourceRevisionIsLiteral*: bool
    sourceRepository*: string
      ## The literal `sourceRepository` (the repository the version is cut
      ## from), or "" when absent or not a literal.
    line*: int             ## 1-based line of the `"<version>":` head

proc reproRecipeVersions*(source: string): seq[ReproVersionEntry] =
  ## Every `versions:` entry of a `repro.nim` recipe, read as text. An entry
  ## looks like
  ##
  ##   versions:
  ##     "0.1.0":
  ##       sourceRevision = "refs/tags/v0.1.0"
  ##
  ## which `emitM2Versions` lowers to one `registerVersion` call per entry.
  ## Indentation decides membership, exactly as Nim's parser does for the
  ## block: an entry head is a quoted version followed by `:`, indented
  ## deeper than its `versions:` line, and its body is indented deeper than
  ## the head.
  let lines = source.splitLines()
  proc indentOf(l: string): int =
    for ch in l:
      if ch == ' ': inc result
      else: break
  var i = 0
  while i < lines.len:
    let stripped = lines[i].strip()
    if stripped == "versions:" or stripped.startsWith("versions:") and
        stripped[len("versions:") .. ^1].strip().startsWith("#"):
      let blockIndent = indentOf(lines[i])
      var j = i + 1
      var current = -1
      var headIndent = -1
      while j < lines.len:
        let l = lines[j]
        let s = l.strip()
        if s.len == 0 or s.startsWith("#"):
          inc j
          continue
        let ind = indentOf(l)
        if ind <= blockIndent: break
        if s.startsWith("\"") and s.endsWith(":") and
            (headIndent < 0 or ind <= headIndent):
          let close = s.find('"', 1)
          if close > 0:
            headIndent = ind
            result.add(ReproVersionEntry(version: s[1 ..< close],
              line: j + 1))
            current = result.len - 1
        elif current >= 0 and ind > headIndent and
            (s.startsWith("sourceRevision") or
             s.startsWith("sourceRepository")):
          let eq = s.find('=')
          let key = if eq > 0: s[0 ..< eq].strip() else: ""
          if eq > 0 and key in ["sourceRevision", "sourceRepository"]:
            let value = s[eq + 1 .. ^1].strip()
            if value.len >= 2 and value[0] == '"':
              let close = value.find('"', 1)
              if close > 0:
                if key == "sourceRevision":
                  result[current].sourceRevision = value[1 ..< close]
                  result[current].sourceRevisionIsLiteral = true
                else:
                  result[current].sourceRepository = value[1 ..< close]
        inc j
      i = j
      continue
    inc i

proc exactSourceRevision*(c: ReproUsesConstraint;
    producerVersions: openArray[ReproVersionEntry]):
    tuple[found: bool; entry: ReproVersionEntry] =
  ## The `versions:` entry an exact `uses:` constraint maps to, read from the
  ## producer's entries. ``found`` is false for a non-exact constraint or when
  ## the producer declares no such version.
  if c.kind != uckExact: return
  for e in producerVersions:
    if e.version == c.exactVersion:
      return (true, e)

# ---------------------------------------------------------------------------
# repro.nim: `uses:` entries read as TEXT, for the hooks
# ---------------------------------------------------------------------------
#
# A managed hook does not compile the recipe, so it cannot hold the extracted
# `InterfaceToolUse` list `reproUsesConstraints` reads. What it CAN read
# without compiling is every constraint the author spelled as a string literal
# inside a dependency block. That is exactly the set the DSL itself bakes at
# macro time (`usesEntryAddStmt`): a literal's selector, range and line are
# known while the macro looks at the node. Anything else the DSL accepts is
# reported here as not readable rather than guessed:
#
# * an entry under a `when`, `if`, `elif`, `else`, `case` or `of` — at ANY
#   depth, including a dependency block that is itself conditional. A `when`
#   is a compile-time question (a platform, a define) and an `if` / `case` is
#   a solver variant gate; whether either arm applies to the committed lock
#   cannot be answered from the text, so such an entry is `conditional` and
#   the callers do not check it;
# * an entry that is not a plain string literal (a `const`, an expression):
#   the compiler produces that string, and this reader does not.

const
  ReproDependencyBlockHeads* = ["uses", "buildDeps", "nativeBuildDeps",
    "runtimeDeps"]
    ## The DSL's dependency blocks (`macros_a.nim`, `DepKind*`); each one is
    ## lowered by `lowerUsesBlock`, so each one carries `uses:`-grammar
    ## constraints.

type
  ReproUsesDeclaration* = object
    ## One string-literal entry of a dependency block, as written.
    constraint*: ReproUsesConstraint
    rawConstraint*: string ## the literal's text
    blockHead*: string     ## `uses`, `buildDeps`, …
    conditional*: bool
      ## Under a `when` / `if` / `case` arm. Whether it applies to a given lock
      ## is not decidable from the text; callers skip it.

proc scanReproUsesDeclarations*(source: string; file = ""):
    seq[ReproUsesDeclaration] =
  ## Every string-literal entry of every dependency block of a `repro.nim`,
  ## with its line, read as text. Pure; nothing is compiled or evaluated.
  ##
  ## Recognised shapes (the ones `lowerUsesBody` lowers from a literal):
  ##
  ##   uses:                       # block form; entries one per line
  ##     "nim >=2.2 <3.0"
  ##     policyName:               # a nested policy call: still unconditional
  ##       "gcc >=12"
  ##     when defined(macosx):     # conditional: reported, not checked
  ##       "clang"
  ##   uses: "reprobuild"          # inline form
  ##
  ## Structure is decided by indentation, as Nim's parser decides it: a line
  ## ending in `:` opens a region that every deeper line belongs to. The scan
  ## skips comments and the bodies of triple-quoted strings, so a shell script
  ## inside a `"""` literal cannot open or close a region.
  type Region = object
    indent: int
    conditional: bool
    head: string           ## the dependency-block head, or ""
  var stack: seq[Region]
  var inTriple = false
  let lines = source.splitLines()
  proc indentOf(l: string): int =
    for ch in l:
      if ch == ' ': inc result
      else: break
  proc stripComment(s: string): string =
    ## The line without a trailing `# …` comment that lies outside a string.
    var inStr = false
    var i = 0
    while i < s.len:
      let c = s[i]
      if c == '"':
        inStr = not inStr
      elif c == '\\' and inStr:
        inc i
      elif c == '#' and not inStr:
        return s[0 ..< i].strip()
      inc i
    s.strip()
  proc literalAt(s: string): tuple[ok: bool; value: string; rest: string] =
    ## ``s`` begins with a plain one-line string literal: its value, and what
    ## follows it.
    if s.len < 2 or s[0] != '"' or s.startsWith("\"\"\""): return
    var i = 1
    var value = ""
    while i < s.len and s[i] != '"':
      if s[i] == '\\' and i + 1 < s.len:
        inc i
      value.add(s[i])
      inc i
    if i >= s.len: return
    (true, value, s[i + 1 .. ^1].strip())
  proc enclosingHead(): string =
    for r in stack:
      if r.head.len > 0: result = r.head
  proc enclosingConditional(): bool =
    for r in stack:
      if r.conditional: return true
  for idx, raw in lines:
    let lineNo = idx + 1
    if inTriple:
      if raw.count("\"\"\"") mod 2 == 1: inTriple = false
      continue
    let stripped = raw.strip()
    if stripped.len == 0 or stripped.startsWith("#"): continue
    let ind = indentOf(raw)
    while stack.len > 0 and stack[^1].indent >= ind: discard stack.pop()
    let code = stripComment(stripped)
    if code.count("\"\"\"") mod 2 == 1:
      # A triple-quoted string opens here and closes on a later line. Its body
      # is not code.
      inTriple = true
    let head = enclosingHead()
    if head.len > 0:
      let lit = literalAt(code)
      if lit.ok and (lit.rest.len == 0 or lit.rest == ","):
        result.add(ReproUsesDeclaration(
          constraint: parseReproUsesConstraint(lit.value, file, lineNo),
          rawConstraint: lit.value, blockHead: head,
          conditional: enclosingConditional()))
        continue
    # Does this line open a region, and of which kind?
    let colon = code.find(':')
    if colon <= 0: continue
    let word = block:
      var w = ""
      for ch in code:
        if ch in {'a'..'z', 'A'..'Z', '0'..'9', '_'}: w.add(ch)
        else: break
      w
    if word in ReproDependencyBlockHeads and
        code[word.len .. ^1].strip().startsWith(":"):
      let after = code[code.find(':') + 1 .. ^1].strip()
      if after.len == 0:
        stack.add(Region(indent: ind, head: word))
      else:
        # The inline form, `uses: "x"`: one entry on the head's own line.
        let lit = literalAt(after)
        if lit.ok and lit.rest.len == 0:
          result.add(ReproUsesDeclaration(
            constraint: parseReproUsesConstraint(lit.value, file, lineNo),
            rawConstraint: lit.value, blockHead: word,
            conditional: enclosingConditional()))
      continue
    if code.endsWith(":"):
      let conditional = word in ["when", "if", "elif", "else", "case", "of"]
      stack.add(Region(indent: ind, conditional: conditional))
    elif word == "case" or word == "if" or word == "when":
      # `case x.value` with its `of` arms on the following lines at the same
      # indent: the arms open the regions, but mark the whole statement too.
      stack.add(Region(indent: ind, conditional: true))

## De-inherit a git-vendored crate's ``Cargo.toml``.
##
## ## Why this exists
##
## A crate published to crates.io has an ALREADY-RESOLVED manifest: ``cargo
## publish`` inlines every ``workspace = true`` field before it uploads the
## ``.crate`` tarball. A crate vendored from a GIT repository does not — its
## ``Cargo.toml`` is the one in the tree, still written as
## ``version.workspace = true`` / ``getrandom = { workspace = true }``, whose
## values live in the repository's workspace-root ``[workspace.package]`` and
## ``[workspace.dependencies]``. Once the crate is vendored on its own, that
## root is gone, and cargo refuses the manifest with
##
##     error inheriting `getrandom` from workspace root manifest's
##     `workspace.dependencies.getrandom`
##
## and then falls back to the network for the whole source — which an offline
## build cannot reach. ``cargo vendor`` solves this by rewriting each git
## crate's manifest to inline the inherited values; this module does the same
## so a from-source recipe's committed closure can carry a git dependency
## that is a workspace member (the common shape for the coding agents:
## ``microsoft/mxc``'s crates each inherit a dozen-plus fields this way).
##
## ## What it resolves
##
## Three inheritance sites, matching cargo's ``[workspace]`` inheritance:
##
##   * ``[package]`` fields — ``version.workspace = true`` and the
##     ``field = { workspace = true }`` spelling — from ``[workspace.package]``;
##   * dependency-table entries — ``dep.workspace = true`` and
##     ``dep = { workspace = true, features = [...], optional = true }`` — from
##     ``[workspace.dependencies]``, unioning any local ``features`` onto the
##     workspace spec and carrying local ``optional`` / ``default-features``;
##   * ``[lints] workspace = true`` — from ``[workspace.lints]``.
##
## ## Why line-oriented rather than a TOML round-trip
##
## Cargo reads the rewritten file; it does not care about formatting, only
## about the resolved values. A full parse-and-reserialize would risk
## dropping a construct this module does not model (a target-specific table, a
## build script key), whereas replacing only the inheriting lines leaves every
## other line exactly as upstream wrote it. The same refusal posture as the
## lockfile reader: touch only what is understood.

import std/[strutils, tables]

type
  CargoDeinheritError* = object of CatchableError

  WorkspaceInheritance* = object
    ## The three inheritable tables, read out of a workspace-root manifest.
    package*: Table[string, string]
      ## ``[workspace.package]`` — field name to its TOML value text.
    dependencies*: Table[string, string]
      ## ``[workspace.dependencies]`` — crate name to its TOML value text
      ## (a bare ``"1.2"`` version string, or an inline table).
    lints*: seq[string]
      ## The body lines of ``[workspace.lints]``, verbatim, for the
      ## ``[lints] workspace = true`` case.

proc tableHeader(line: string): string =
  ## The name inside ``[name]`` / ``[name.sub]``, or ``""`` if the line is
  ## not a table header. Array-of-tables ``[[x]]`` is deliberately not a
  ## plain table and returns ``""``.
  let s = line.strip()
  if s.len >= 2 and s[0] == '[' and s[1] != '[' and s[^1] == ']':
    s[1 ..< ^1].strip()
  else:
    ""

proc splitKeyValue(line: string): tuple[key, value: string, ok: bool] =
  ## ``key = value`` split on the FIRST ``=``, both sides stripped. A line
  ## with no ``=`` (a bare ``workspace = true`` has one; a table header does
  ## not) returns ``ok = false``.
  let eq = line.find('=')
  if eq < 0:
    return ("", "", false)
  (line[0 ..< eq].strip(), line[eq + 1 .. ^1].strip(), true)

proc isDependencyTable(header: string): bool =
  ## Whether a ``[header]`` is a dependency table cargo resolves inheritance
  ## in. Covers the plain three and the ``target.'cfg'.<kind>-dependencies``
  ## forms, matching cargo.
  header == "dependencies" or header == "dev-dependencies" or
    header == "build-dependencies" or
    (header.startsWith("target.") and (header.endsWith(".dependencies") or
      header.endsWith(".dev-dependencies") or
      header.endsWith(".build-dependencies")))

proc unbalanced(s: string): int =
  ## Net bracket/brace depth of ``s`` outside strings — positive when a
  ## value opened ``[`` or ``{`` it has not closed, so its entry continues
  ## on the next line. cargo writes a long ``features = [ … ]`` array or an
  ## inline table across several lines, and a reader that stopped at the
  ## first would capture a truncated, malformed value.
  var depth = 0
  var inStr = false
  for ch in s:
    case ch
    of '"':
      inStr = not inStr
    of '[', '{':
      if not inStr: inc depth
    of ']', '}':
      if not inStr: dec depth
    else: discard
  depth

proc parseWorkspaceInheritance*(workspaceRootToml: string):
    WorkspaceInheritance =
  ## Read ``[workspace.package]``, ``[workspace.dependencies]`` and
  ## ``[workspace.lints]`` out of a workspace-root manifest. An entry whose
  ## value opens a bracket or brace it does not close on its line is joined
  ## with the lines that continue it, so a multi-line ``features`` array or
  ## inline table is captured whole.
  result.package = initTable[string, string]()
  result.dependencies = initTable[string, string]()
  var current = ""
  # Pre-join continuation lines within the package/dependencies tables so the
  # single-line reader below sees one logical entry per key. Newlines inside
  # a joined value become spaces; cargo does not care, and the value stays
  # syntactically whole.
  var logical: seq[string] = @[]
  block:
    var inJoinTable = false
    var pending = ""
    var pendingDepth = 0
    for rawLine in workspaceRootToml.splitLines():
      let hdr = tableHeader(rawLine)
      if pendingDepth > 0:
        pending.add(" " & rawLine.strip())
        pendingDepth += unbalanced(rawLine)
        if pendingDepth <= 0:
          logical.add(pending); pending = ""; pendingDepth = 0
        continue
      if hdr.len > 0:
        inJoinTable = hdr == "workspace.package" or
          hdr == "workspace.dependencies"
        logical.add(rawLine)
        continue
      if inJoinTable and unbalanced(rawLine) > 0:
        pending = rawLine.strip()
        pendingDepth = unbalanced(rawLine)
        continue
      logical.add(rawLine)
    if pending.len > 0:
      logical.add(pending)
  for rawLine in logical:
    let header = tableHeader(rawLine)
    if header.len > 0:
      current = header
      # A lints sub-table — `[workspace.lints.clippy]` — is re-headed to
      # `[lints.clippy]` and carried, so the block reads correctly under the
      # crate's own `[lints]` once inlined. The bare `[workspace.lints]`
      # header is dropped; its body lines land directly under `[lints]`.
      if header.startsWith("workspace.lints."):
        result.lints.add("[" & header["workspace.".len .. ^1] & "]")
      continue
    let line = rawLine.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    case current
    of "workspace.package":
      let kv = splitKeyValue(line)
      if kv.ok:
        result.package[kv.key] = kv.value
    of "workspace.dependencies":
      let kv = splitKeyValue(line)
      if kv.ok:
        result.dependencies[kv.key] = kv.value
    else:
      if current == "workspace.lints" or
          current.startsWith("workspace.lints."):
        result.lints.add(rawLine)

proc inlineTableFields(value: string): seq[(string, string)] =
  ## Split an inline table ``{ a = 1, b = [x, y] }`` into its top-level
  ## ``(key, value)`` pairs. Splits on commas that are not inside ``[]`` or
  ## nested ``{}`` or a string, so ``features = ["a", "b"]`` stays one field.
  let s = value.strip()
  if s.len < 2 or s[0] != '{' or s[^1] != '}':
    return @[]
  let body = s[1 ..< ^1]
  var depth = 0
  var inStr = false
  var field = ""
  var fields: seq[string] = @[]
  for ch in body:
    case ch
    of '"':
      inStr = not inStr; field.add(ch)
    of '[', '{':
      if not inStr: inc depth
      field.add(ch)
    of ']', '}':
      if not inStr: dec depth
      field.add(ch)
    of ',':
      if depth == 0 and not inStr:
        fields.add(field); field = ""
      else:
        field.add(ch)
    else:
      field.add(ch)
  if field.strip().len > 0:
    fields.add(field)
  for f in fields:
    let kv = splitKeyValue(f)
    if kv.ok:
      result.add((kv.key, kv.value))

proc parseStringArray(value: string): seq[string] =
  ## The elements of a ``["a", "b"]`` TOML array, quotes kept, for unioning
  ## feature lists. A non-array yields an empty seq.
  let s = value.strip()
  if s.len < 2 or s[0] != '[' or s[^1] != ']':
    return @[]
  for part in s[1 ..< ^1].split(','):
    let e = part.strip()
    if e.len > 0:
      result.add(e)

proc resolveDependency(local, workspaceValue: string): string =
  ## The inlined value for a ``{ workspace = true, … }`` dependency. The
  ## workspace value is the base; local ``features`` union onto it and local
  ## ``optional`` / ``default-features`` are carried. A bare
  ## ``workspace = true`` (no extra fields) is just the workspace value.
  let localFields = inlineTableFields(local)
  var extraKeys: seq[(string, string)] = @[]
  for (k, v) in localFields:
    if k != "workspace":
      extraKeys.add((k, v))
  if extraKeys.len == 0:
    return workspaceValue
  # Merge onto the workspace spec. Normalise the base to an inline table so a
  # bare ``"1.2"`` version can gain fields.
  var baseFields: seq[(string, string)] = @[]
  let wsTrim = workspaceValue.strip()
  if wsTrim.len >= 2 and wsTrim[0] == '{':
    baseFields = inlineTableFields(workspaceValue)
  else:
    baseFields.add(("version", wsTrim))
  var merged = initOrderedTable[string, string]()
  for (k, v) in baseFields:
    merged[k] = v
  for (k, v) in extraKeys:
    if k == "features":
      var feats: seq[string] = @[]
      if merged.hasKey("features"):
        for e in parseStringArray(merged["features"]): feats.add(e)
      for e in parseStringArray(v):
        if e notin feats: feats.add(e)
      merged["features"] = "[" & feats.join(", ") & "]"
    else:
      merged[k] = v
  var parts: seq[string] = @[]
  for k, v in merged:
    parts.add(k & " = " & v)
  "{ " & parts.join(", ") & " }"

proc usesWorkspaceInheritance*(crateToml: string): bool =
  ## Whether a crate manifest inherits anything from a workspace — the cheap
  ## test that decides if de-inheriting is needed at all.
  for line in crateToml.splitLines():
    let s = line.strip()
    if s.endsWith("workspace = true") or s.endsWith(".workspace = true") or
        (s.contains("workspace = true") and s.contains("{")):
      return true
  false

proc deinheritCargoToml*(crateToml: string;
                         ws: WorkspaceInheritance): string =
  ## Rewrite ``crateToml`` with every ``workspace = true`` inheritance
  ## replaced by the value ``ws`` carries. Lines that inherit nothing pass
  ## through byte for byte. A field that claims inheritance the workspace
  ## root does not define is an error, not a silent drop: cargo would fail
  ## the same way, later and more obscurely.
  var current = ""
  var lintsInherited = false
  var outLines: seq[string] = @[]
  for rawLine in crateToml.splitLines():
    let header = tableHeader(rawLine)
    if header.len > 0:
      current = header
      outLines.add(rawLine)
      if header == "lints":
        lintsInherited = false
      continue
    let line = rawLine.strip()
    if line.len == 0 or line.startsWith("#"):
      outLines.add(rawLine)
      continue

    # ``[lints] workspace = true`` — replace the whole inheriting line with
    # the workspace lints body.
    if current == "lints" and line == "workspace = true":
      lintsInherited = true
      for l in ws.lints:
        outLines.add(l)
      continue

    let kv = splitKeyValue(line)
    if not kv.ok:
      outLines.add(rawLine)
      continue

    # Two spellings of an inheriting entry:
    #   dotted:  version.workspace = true      → key "version.workspace"
    #   inline:  serde = { workspace = true }  → value starts "{ workspace"
    var indentLen = 0
    while indentLen < rawLine.len and rawLine[indentLen] in {' ', '\t'}:
      inc indentLen
    let indent = rawLine[0 ..< indentLen]

    if kv.key.endsWith(".workspace") and kv.value == "true":
      let field = kv.key[0 ..< ^len(".workspace")]
      if current == "package":
        if not ws.package.hasKey(field):
          raise newException(CargoDeinheritError,
            "crate inherits package field '" & field & "' but the workspace " &
            "root has no [workspace.package] " & field)
        outLines.add(indent & field & " = " & ws.package[field])
      elif isDependencyTable(current):
        if not ws.dependencies.hasKey(field):
          raise newException(CargoDeinheritError,
            "crate inherits dependency '" & field & "' but the workspace " &
            "root has no [workspace.dependencies] " & field)
        outLines.add(indent & field & " = " & ws.dependencies[field])
      else:
        outLines.add(rawLine)
      continue

    let vt = kv.value.strip()
    if vt.startsWith("{") and vt.contains("workspace = true"):
      if current == "package":
        if not ws.package.hasKey(kv.key):
          raise newException(CargoDeinheritError,
            "crate inherits package field '" & kv.key & "' but the " &
            "workspace root has no [workspace.package] " & kv.key)
        outLines.add(indent & kv.key & " = " & ws.package[kv.key])
      elif isDependencyTable(current):
        if not ws.dependencies.hasKey(kv.key):
          raise newException(CargoDeinheritError,
            "crate inherits dependency '" & kv.key & "' but the workspace " &
            "root has no [workspace.dependencies] " & kv.key)
        outLines.add(indent & kv.key & " = " &
          resolveDependency(kv.value, ws.dependencies[kv.key]))
      else:
        outLines.add(rawLine)
      continue

    outLines.add(rawLine)

  discard lintsInherited
  # `splitLines` yields a trailing empty element for a file that ends in a
  # newline, so joining round-trips the terminator (and any `\r`) exactly —
  # no separate trailing-newline fix-up, which would double it.
  result = outLines.join("\n")

# ---------------------------------------------------------------------------
# Intra-workspace ``path`` dependencies.
#
# A git repository's workspace member commonly depends on a SIBLING member by
# path — ``mxc_b = { path = "crates/mxc_b", version = "0.4.0" }`` — or inherits
# such a spec through ``mxc_b = { workspace = true }`` (which `deinheritCargoToml`
# inlines to the same, carrying the workspace's path). Once the crates are
# vendored the path is wrong twice over: it was written relative to the
# workspace root, and the sibling now lives in its own flat vendor directory.
#
# The fix is NOT to drop the path and keep the version — a bare version makes
# cargo look the crate up on crates.io (``no matching package named `mxc_b`
# found; location searched: crates.io index``), because a version-only
# dependency defaults to the registry source, not the vendored git source. The
# path is what binds the dependency to the same source. So the path is KEPT and
# REPOINTED at the sibling's vendor directory, matching what `cargo vendor`
# does (it keeps the path too, repointed at its flat ``../<name>`` sibling).
# Here the vendor directory is ``<name>-<version>`` (see `directoryName`), so
# the path becomes ``../<name>-<version>``.

proc rewritePathValue(value, dirRel: string): tuple[text: string, hit: bool] =
  ## Replace the ``path`` field of an inline-table dependency value with
  ## ``dirRel`` (a quoted string), keeping every other field and its order.
  ## ``hit`` is false — value returned unchanged — when the value is not an
  ## inline table or carries no ``path``.
  let s = value.strip()
  if s.len < 2 or s[0] != '{':
    return (value, false)
  var parts: seq[string] = @[]
  var hit = false
  for (k, v) in inlineTableFields(value):
    if k == "path":
      hit = true
      parts.add("path = " & dirRel)
    else:
      parts.add(k & " = " & v)
  if not hit:
    return (value, false)
  ("{ " & parts.join(", ") & " }", true)

proc splitLastDot(header: string): tuple[prefix, last: string] =
  ## Split a table header on its last ``.`` that is outside quotes, so a
  ## ``target.'cfg(unix)'.dependencies.mxc_b`` header yields prefix
  ## ``target.'cfg(unix)'.dependencies`` and last ``mxc_b``. A header with no
  ## unquoted ``.`` yields an empty prefix.
  var inStr = false
  var quote = ' '
  var idx = -1
  for i, ch in header:
    if inStr:
      if ch == quote: inStr = false
    elif ch == '"' or ch == '\'':
      inStr = true; quote = ch
    elif ch == '.':
      idx = i
  if idx < 0:
    ("", header)
  else:
    (header[0 ..< idx], header[idx + 1 .. ^1])

proc rewriteWorkspacePathDeps*(crateToml: string;
                               siblings: Table[string, string]): string =
  ## Repoint every ``path`` dependency that names a sibling vendored crate at
  ## that sibling's vendor directory. ``siblings`` maps a crate NAME to its
  ## vendor directory name (``<name>-<version>``); a dependency whose name is
  ## absent from the table, or which carries no ``path``, is left exactly as
  ## written. Handles the three dependency spellings cargo accepts: the inline
  ## table (``dep = { path = … }``), the dotted key (``dep.path = …``), and the
  ## section table (``[dependencies.dep]`` with a ``path = …`` line).
  if siblings.len == 0:
    return crateToml
  var current = ""
  var sectionDep = ""
  var outLines: seq[string] = @[]
  for rawLine in crateToml.splitLines():
    let header = tableHeader(rawLine)
    if header.len > 0:
      current = header
      sectionDep = ""
      let (prefix, last) = splitLastDot(header)
      if isDependencyTable(prefix) and siblings.hasKey(last):
        sectionDep = last
      outLines.add(rawLine)
      continue
    let line = rawLine.strip()
    if line.len == 0 or line.startsWith("#"):
      outLines.add(rawLine)
      continue

    var indentLen = 0
    while indentLen < rawLine.len and rawLine[indentLen] in {' ', '\t'}:
      inc indentLen
    let indent = rawLine[0 ..< indentLen]

    # A ``path = …`` line inside a ``[dependencies.<sibling>]`` section table.
    if sectionDep.len > 0:
      let kv = splitKeyValue(line)
      if kv.ok and kv.key == "path":
        outLines.add(indent & "path = \"../" & siblings[sectionDep] & "\"")
        continue
      outLines.add(rawLine)
      continue

    if not isDependencyTable(current):
      outLines.add(rawLine)
      continue

    let kv = splitKeyValue(line)
    if not kv.ok:
      outLines.add(rawLine)
      continue

    # Dotted ``dep.path = "…"``.
    if kv.key.endsWith(".path"):
      let dep = kv.key[0 ..< ^len(".path")]
      if siblings.hasKey(dep):
        outLines.add(indent & dep & ".path = \"../" & siblings[dep] & "\"")
        continue
      outLines.add(rawLine)
      continue

    # Inline ``dep = { … path = "…" … }``.
    if siblings.hasKey(kv.key):
      let (rewritten, hit) = rewritePathValue(kv.value,
        "\"../" & siblings[kv.key] & "\"")
      if hit:
        outLines.add(indent & kv.key & " = " & rewritten)
        continue
    outLines.add(rawLine)

  result = outLines.join("\n")

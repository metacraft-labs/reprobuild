## repro_workspace_manifests/manifest_editor.nim
##
## The ONE place that writes workspace manifest, settings and state TOML.
##
## Reading is isolated in ``reader.nim``: every file kind decodes into a typed
## record and nothing downstream sees TOML. This module is the write-side
## counterpart. It offers two kinds of operation:
##
## * **Create a file from a typed value** — ``repoFragmentText``,
##   ``repoSetText``, ``projectManifestText``, ``urlPrefixText``,
##   ``workspaceBootstrapText`` and ``workspaceStateText`` render a record in
##   the canonical layout, and ``writeWorkspaceManifestFile`` puts the text on disk.
## * **Edit an existing file in place** — ``loadManifestDoc`` reads a file
##   into a ``ManifestDoc``; ``setKey`` / ``removeKey`` change one key of one
##   table; ``addArrayMember`` / ``removeArrayMember`` change one element of a
##   NAMED array; ``appendInclude`` adds an ``includes`` path;
##   ``ensureArrayTableEntry`` adds one ``[[table]]`` entry. Every edit
##   rewrites only the lines of the span it changes, so comments, key order,
##   blank lines and line endings (LF or CRLF) outside that span survive byte
##   for byte. ``saveManifestDoc`` writes the result back only when something
##   changed.
##
## Why a document model and not a serializer: a manifest is authored by
## people. A writer that decoded the file and re-emitted it would delete every
## comment and re-order every key the first time a verb touched it.
##
## **The key-order rule is enforced HERE, not by callers.** In standard TOML a
## bare key written after a table header belongs to that table, so a
## ``member_repos`` written below ``[project]`` is read as
## ``project.member_repos`` and the strict reader rejects the whole file
## (Workspace-Manifests.md §"`projects/<project>.toml` — Project Manifest",
## "Key order is not cosmetic here"). Every top-level key this module inserts
## — and every top-level key a ``*Text`` renderer emits — is therefore placed
## above the first table header. A caller cannot ask for anything else.
##
## The TOML grammar this module understands is the subset workspace files use:
## bare, quoted and dotted keys; ``[table]`` and ``[[array.of.tables]]``
## headers; basic, literal and multi-line strings; integers, booleans, other
## scalars (kept verbatim); arrays and inline tables, nested. TOML reference:
## https://toml.io/en/v1.0.0. A line it cannot parse raises
## ``ManifestEditError`` naming the file and line rather than being guessed at.

import std/[options, os, strutils, tables]
from std/unicode import Rune, toUTF8

import types

type
  ManifestEditError* = object of ValueError
    ## Raised when a file cannot be edited safely: a line the editor cannot
    ## parse, or an edit that does not fit the value it targets (adding a
    ## member to something that is not an array of strings). A ``ValueError``
    ## so callers that already report malformed-manifest ``ValueError``s keep
    ## doing so.
    path*: string
    keyPath*: string

  TomlEditValueKind* = enum
    tevString
    tevBool
    tevInt
    tevStringArray
    tevInlineTables  ## an array whose elements are inline tables

  TomlEditField* = object
    ## One ``key = value`` pair of a table or inline table.
    key*: string
    value*: TomlEditValue

  TomlEditValue* = object
    ## A value the editor can write. Deliberately small: these are the value
    ## shapes workspace files carry.
    case kind*: TomlEditValueKind
    of tevString: str*: string
    of tevBool: boolVal*: bool
    of tevInt: intVal*: int64
    of tevStringArray: items*: seq[string]
    of tevInlineTables: rows*: seq[seq[TomlEditField]]

  ArrayLayout* = enum
    ## How a NEW array is written. An array that already exists keeps the
    ## layout it has.
    alInline     ## ``key = ["a", "b"]``
    alMultiLine  ## one element per line, each followed by a comma

  ManifestDoc* = object
    ## A TOML file held as lines, each with its own original terminator, so an
    ## untouched line is written back exactly as it was read.
    path*: string
    lines: seq[string]
    terms: seq[string]    ## "\n", "\r\n", or "" for an unterminated last line
    eol: string           ## terminator given to lines the editor inserts
    changed*: bool        ## true once any edit modified the text

# ---- value construction ----------------------------------------------------

proc tomlStr*(value: string): TomlEditValue =
  TomlEditValue(kind: tevString, str: value)

proc tomlBool*(value: bool): TomlEditValue =
  TomlEditValue(kind: tevBool, boolVal: value)

proc tomlInt*(value: int64): TomlEditValue =
  TomlEditValue(kind: tevInt, intVal: value)

proc tomlStrings*(values: openArray[string]): TomlEditValue =
  TomlEditValue(kind: tevStringArray, items: @values)

proc tomlInlineTables*(rows: seq[seq[TomlEditField]]): TomlEditValue =
  TomlEditValue(kind: tevInlineTables, rows: rows)

proc tomlField*(key: string; value: TomlEditValue): TomlEditField =
  TomlEditField(key: key, value: value)

proc editError(path, keyPath, msg: string): ref ManifestEditError =
  result = newException(ManifestEditError,
    (if path.len > 0: "[" & path & "] " else: "") &
    (if keyPath.len > 0: keyPath & ": " else: "") & msg)
  result.path = path
  result.keyPath = keyPath

# ---- rendering -------------------------------------------------------------

proc tomlQuote*(value: string): string =
  ## A TOML basic string (https://toml.io/en/v1.0.0#string). Control
  ## characters are escaped so any value round-trips through the reader.
  result = newStringOfCap(value.len + 2)
  result.add('"')
  for ch in value:
    case ch
    of '\\': result.add("\\\\")
    of '"': result.add("\\\"")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    of '\b': result.add("\\b")
    of '\f': result.add("\\f")
    of '\0' .. '\x07', '\x0B', '\x0E' .. '\x1F', '\x7F':
      result.add("\\u" & toHex(ord(ch), 4))
    else: result.add(ch)
  result.add('"')

proc renderKey(key: string): string =
  ## One key segment: bare when it can be, quoted otherwise.
  if key.len > 0 and key.allCharsInSet({'A'..'Z', 'a'..'z', '0'..'9', '_', '-'}):
    key
  else:
    tomlQuote(key)

proc renderDottedKey(key: string): string =
  ## A key path as written by callers (``repo.branch-roles``) to TOML.
  var parts: seq[string]
  for part in key.split('.'):
    parts.add(renderKey(part))
  parts.join(".")

proc renderInline(value: TomlEditValue): string

proc renderInlineTable(row: seq[TomlEditField]): string =
  if row.len == 0:
    return "{}"
  var parts: seq[string]
  for f in row:
    parts.add(renderKey(f.key) & " = " & renderInline(f.value))
  "{ " & parts.join(", ") & " }"

proc elementTexts(value: TomlEditValue): seq[string] =
  ## The rendered elements of an array value.
  case value.kind
  of tevStringArray:
    for item in value.items: result.add(tomlQuote(item))
  of tevInlineTables:
    for row in value.rows: result.add(renderInlineTable(row))
  else:
    discard

proc renderInline(value: TomlEditValue): string =
  case value.kind
  of tevString: tomlQuote(value.str)
  of tevBool: (if value.boolVal: "true" else: "false")
  of tevInt: $value.intVal
  of tevStringArray, tevInlineTables:
    "[" & elementTexts(value).join(", ") & "]"

proc isArray(value: TomlEditValue): bool =
  value.kind in {tevStringArray, tevInlineTables}

proc renderArrayFromElements(elements: seq[string]; layout: ArrayLayout;
                             indent = "  "): seq[string] =
  ## The lines of an array value whose elements are already rendered. The
  ## first line is the opening bracket (to be appended to ``key = ``).
  case layout
  of alInline:
    result = @["[" & elements.join(", ") & "]"]
  of alMultiLine:
    result = @["["]
    for e in elements:
      result.add(indent & e & ",")
    result.add("]")

proc renderValueLines(value: TomlEditValue; layout: ArrayLayout): seq[string] =
  if value.isArray:
    renderArrayFromElements(elementTexts(value), layout)
  else:
    @[renderInline(value)]

proc renderEntryLines(key: string; value: TomlEditValue;
                      layout: ArrayLayout): seq[string] =
  result = renderValueLines(value, layout)
  result[0] = renderDottedKey(key) & " = " & result[0]

# ---- typed renderers: create a file from a typed value ---------------------

type
  RenderEntry = object
    key: string
    value: TomlEditValue
    layout: ArrayLayout

  RenderBlock = object
    header: string        ## "[repo]" / "[[remote]]"
    entries: seq[RenderEntry]

proc entry(key: string; value: TomlEditValue;
           layout = alInline): RenderEntry =
  RenderEntry(key: key, value: value, layout: layout)

proc addOpt(entries: var seq[RenderEntry]; key: string;
            value: Option[string]) =
  if value.isSome:
    entries.add(entry(key, tomlStr(value.get())))

proc addOpt(entries: var seq[RenderEntry]; key: string; value: Option[bool]) =
  if value.isSome:
    entries.add(entry(key, tomlBool(value.get())))

proc addOpt(entries: var seq[RenderEntry]; key: string; value: Option[int]) =
  if value.isSome:
    entries.add(entry(key, tomlInt(value.get().int64)))

proc addNonEmpty(entries: var seq[RenderEntry]; key: string;
                 values: seq[string]; layout = alInline) =
  if values.len > 0:
    entries.add(entry(key, tomlStrings(values), layout))

proc renderTomlValueRef(path, keyPath: string; value: TomlValueRef): string =
  ## Inline rendering of a value carried through an ``[extensions]`` table.
  case value.kind
  of TomlKind.String: tomlQuote(value.stringVal)
  of TomlKind.Int: $value.intVal
  of TomlKind.Bool: (if value.boolVal: "true" else: "false")
  of TomlKind.Float: $value.floatVal
  of TomlKind.Array:
    var parts: seq[string]
    for item in value.arrayVal:
      parts.add(renderTomlValueRef(path, keyPath, item))
    "[" & parts.join(", ") & "]"
  of TomlKind.Table, TomlKind.InlineTable:
    var parts: seq[string]
    for k, v in value.tableVal[]:
      parts.add(renderKey(k) & " = " & renderTomlValueRef(path, keyPath & "." & k, v))
    if parts.len == 0: "{}" else: "{ " & parts.join(", ") & " }"
  of TomlKind.Tables:
    var parts: seq[string]
    for t in value.tablesVal:
      var inner: seq[string]
      for k, v in t[]:
        inner.add(renderKey(k) & " = " & renderTomlValueRef(path, keyPath & "." & k, v))
      parts.add(if inner.len == 0: "{}" else: "{ " & inner.join(", ") & " }")
    "[" & parts.join(", ") & "]"
  of TomlKind.DateTime:
    raise editError(path, keyPath,
      "a date-time value under [extensions] cannot be written by the editor")

proc extensionsBlock(ext: Extensions): Option[(string, seq[string])] =
  ## ``[extensions]`` as pre-rendered lines, or none when the record has none.
  if not ext.isPresent:
    return none((string, seq[string]))
  var lines: seq[string]
  for k, v in ext.raw[]:
    lines.add(renderKey(k) & " = " & renderTomlValueRef("", "extensions." & k, v))
  some(("[extensions]", lines))

proc assemble(schema: string; root: seq[RenderEntry]; blocks: seq[RenderBlock];
              extra: Option[(string, seq[string])] =
                none((string, seq[string]))): string =
  ## The canonical layout every renderer shares:
  ##
  ##   schema = "…"
  ##   <blank>
  ##   top-level keys — single-line keys consecutive, a multi-line array
  ##   followed by a blank line — ALL above the first table header
  ##   <blank>
  ##   [table] blocks, separated by one blank line
  var lines: seq[string]
  lines.add("schema = " & tomlQuote(schema))
  lines.add("")
  var lastWasSingle = false
  for e in root:
    let rendered = renderEntryLines(e.key, e.value, e.layout)
    for l in rendered: lines.add(l)
    if rendered.len > 1:
      lines.add("")
      lastWasSingle = false
    else:
      lastWasSingle = true
  if lastWasSingle:
    lines.add("")
  var allBlocks: seq[(string, seq[string])]
  for b in blocks:
    var body: seq[string]
    for e in b.entries:
      for l in renderEntryLines(e.key, e.value, e.layout): body.add(l)
    allBlocks.add((b.header, body))
  if extra.isSome:
    allBlocks.add(extra.get())
  for i, b in allBlocks:
    if i > 0:
      lines.add("")
    lines.add(b[0])
    for l in b[1]: lines.add(l)
  # Trailing blank lines left by the root section when there are no blocks.
  while lines.len > 1 and lines[^1].len == 0:
    lines.setLen(lines.len - 1)
  lines.join("\n") & "\n"

proc remoteBindingRow(r: RepoRemoteEntry): seq[TomlEditField] =
  result.add(tomlField("name", tomlStr(r.name)))
  if r.remote.len > 0: result.add(tomlField("remote", tomlStr(r.remote)))
  if r.url_prefix.len > 0: result.add(tomlField("url_prefix", tomlStr(r.url_prefix)))
  if r.url_suffix.len > 0: result.add(tomlField("url_suffix", tomlStr(r.url_suffix)))

proc copyLinkRows(entries: seq[CopyLinkFileEntry]): seq[seq[TomlEditField]] =
  for e in entries:
    result.add(@[tomlField("src", tomlStr(e.src)), tomlField("dest", tomlStr(e.dest))])

proc repoFragmentText*(fragment: RepoFragment): string =
  ## ``repos/<repo>.toml`` from a typed value. Keys under ``[repo]`` are
  ## written in a fixed order — identity (``name``, ``path``), where it comes
  ## from (``remote``), what it follows (``branch``, ``revision``), then the
  ## URL split, then every optional key — so two fragments written by two
  ## verbs read alike.
  let r = fragment.repo
  var e: seq[RenderEntry]
  e.add(entry("name", tomlStr(r.name)))
  e.add(entry("path", tomlStr(r.path)))
  e.addOpt("remote", r.remote)
  e.addOpt("branch", r.branch)
  e.addOpt("revision", r.revision)
  e.addOpt("url_prefix", r.url_prefix)
  e.addOpt("url_suffix", r.url_suffix)
  if r.remotes.len > 0:
    var rows: seq[seq[TomlEditField]]
    for b in r.remotes: rows.add(remoteBindingRow(b))
    e.add(entry("remotes", tomlInlineTables(rows)))
  e.addOpt("vcs", r.vcs)
  e.addOpt("stability", r.stability)
  e.addOpt("participation", r.participation)
  e.addOpt("clone_filter", r.clone_filter)
  e.addOpt("depth", r.depth)
  e.addOpt("single_branch", r.single_branch)
  if r.copyfile.len > 0:
    e.add(entry("copyfile", tomlInlineTables(copyLinkRows(r.copyfile))))
  if r.linkfile.len > 0:
    e.add(entry("linkfile", tomlInlineTables(copyLinkRows(r.linkfile))))
  e.addNonEmpty("tags", r.tags)
  e.addNonEmpty("depends", r.depends)
  let schema = if fragment.schema.len > 0: fragment.schema
               else: schemaRepoFragmentV1
  assemble(schema, @[], @[RenderBlock(header: "[repo]", entries: e)],
    extensionsBlock(fragment.extensions))

proc repoSetText*(manifest: RepoSetManifest): string =
  ## ``repo-sets/<set>.toml`` from a typed value. BOTH membership arrays are
  ## always written, even empty: ``member_sets`` and ``member_repos`` are two
  ## namespaces, and a file carrying only one invites the next entry into
  ## whichever happens to be there. They sit above ``[repo-set]`` by the
  ## key-order rule.
  let schema = if manifest.schema.len > 0: manifest.schema
               else: schemaRepoSetV1
  assemble(schema,
    @[entry("member_sets", tomlStrings(manifest.member_sets), alMultiLine),
      entry("member_repos", tomlStrings(manifest.member_repos), alMultiLine)],
    @[RenderBlock(header: "[repo-set]",
      entries: @[entry("name", tomlStr(manifest.`repo-set`.name))])],
    extensionsBlock(manifest.extensions))

proc projectManifestText*(manifest: ProjectManifest): string =
  ## ``projects/<project>.toml`` from a typed value. The top-level keys —
  ## ``includes``, the two membership arrays and ``binary_dependency`` — are
  ## written above ``[project]``. The membership arrays are written as a PAIR
  ## whenever either is non-empty (same reason as ``repoSetText``) and omitted
  ## together when both are empty.
  var root: seq[RenderEntry]
  if manifest.includes.len > 0:
    root.add(entry("includes", tomlStrings(manifest.includes), alMultiLine))
  if manifest.member_sets.len > 0 or manifest.member_repos.len > 0:
    root.add(entry("member_sets", tomlStrings(manifest.member_sets), alMultiLine))
    root.add(entry("member_repos", tomlStrings(manifest.member_repos), alMultiLine))
  if manifest.binary_dependency.len > 0:
    var rows: seq[seq[TomlEditField]]
    for d in manifest.binary_dependency:
      var row = @[tomlField("name", tomlStr(d.name)), tomlField("remote", tomlStr(d.remote))]
      if d.revision.isSome: row.add(tomlField("revision", tomlStr(d.revision.get())))
      rows.add(row)
    root.add(entry("binary_dependency", tomlInlineTables(rows), alMultiLine))
  var project: seq[RenderEntry]
  project.add(entry("name", tomlStr(manifest.project.name)))
  project.addOpt("default_revision", manifest.project.default_revision)
  project.addOpt("default_remote", manifest.project.default_remote)
  project.addOpt("trunk", manifest.project.trunk)
  var blocks = @[RenderBlock(header: "[project]", entries: project)]
  for r in manifest.remote:
    blocks.add(RenderBlock(header: "[[remote]]",
      entries: @[entry("name", tomlStr(r.name)), entry("fetch", tomlStr(r.fetch))]))
  let c = manifest.certificates
  var certs: seq[RenderEntry]
  certs.addOpt("gate_mode", c.gate_mode)
  certs.addNonEmpty("required_targets", c.required_targets)
  certs.addNonEmpty("required_platforms", c.required_platforms)
  certs.addOpt("ci_trust", c.ci_trust)
  if certs.len > 0:
    blocks.add(RenderBlock(header: "[certificates]", entries: certs))
  let schema = if manifest.schema.len > 0: manifest.schema
               else: schemaProjectManifestV1
  assemble(schema, root, blocks, extensionsBlock(manifest.extensions))

proc urlPrefixText*(manifest: UrlPrefixManifest): string =
  ## ``url-prefixes/<name>.toml`` from a typed value.
  let schema = if manifest.schema.len > 0: manifest.schema
               else: schemaUrlPrefixV1
  assemble(schema, @[],
    @[RenderBlock(header: "[url-prefix]", entries: @[
      entry("name", tomlStr(manifest.`url-prefix`.name)),
      entry("url", tomlStr(manifest.`url-prefix`.url))])],
    extensionsBlock(manifest.extensions))

proc workspaceBootstrapText*(cfg: WorkspaceBootstrap): string =
  ## The host bootstrap config (``.repro-workspace.toml``) from a typed value.
  ## A table is written only when it carries something.
  var blocks: seq[RenderBlock]
  var m: seq[RenderEntry]
  if cfg.manifest.url.len > 0:
    m.add(entry("url", tomlStr(cfg.manifest.url)))
  m.addOpt("branch", cfg.manifest.branch)
  m.addOpt("private_url", cfg.manifest.private_url)
  m.addOpt("revision", cfg.manifest.revision)
  m.addOpt("publish_locks", cfg.manifest.publish_locks)
  if m.len > 0: blocks.add(RenderBlock(header: "[manifest]", entries: m))
  var p: seq[RenderEntry]
  p.addNonEmpty("default", cfg.projects.default)
  p.addOpt("default_template", cfg.projects.default_template)
  if p.len > 0: blocks.add(RenderBlock(header: "[projects]", entries: p))
  var v: seq[RenderEntry]
  if cfg.verify.require_signature:
    v.add(entry("require_signature", tomlBool(true)))
  v.addOpt("allowed_signers", cfg.verify.allowed_signers)
  v.addNonEmpty("allowed_keys", cfg.verify.allowed_keys)
  v.addOpt("signer_identity", cfg.verify.signer_identity)
  if v.len > 0: blocks.add(RenderBlock(header: "[verify]", entries: v))
  if cfg.develop.org_urls.len > 0:
    blocks.add(RenderBlock(header: "[develop]", entries: @[
      entry("org_urls", tomlStrings(cfg.develop.org_urls))]))
  if cfg.locking.route.len > 0:
    var rows: seq[seq[TomlEditField]]
    for r in cfg.locking.route:
      var row = @[tomlField("visibility", tomlStr(r.visibility)),
                  tomlField("backend", tomlStr(r.backend))]
      if r.path.isSome: row.add(tomlField("path", tomlStr(r.path.get())))
      if r.program.isSome: row.add(tomlField("program", tomlStr(r.program.get())))
      if r.repos.len > 0: row.add(tomlField("repos", tomlStrings(r.repos)))
      rows.add(row)
    blocks.add(RenderBlock(header: "[locking]", entries: @[
      entry("route", tomlInlineTables(rows), alMultiLine)]))
  var f: seq[RenderEntry]
  f.addOpt("auto_load_envrc", cfg.foreign_env.auto_load_envrc)
  f.addOpt("auto_load_flake", cfg.foreign_env.auto_load_flake)
  if f.len > 0: blocks.add(RenderBlock(header: "[foreign_env]", entries: f))
  let schema = if cfg.schema.len > 0: cfg.schema
               else: schemaWorkspaceBootstrapV1
  assemble(schema, @[], blocks, extensionsBlock(cfg.extensions))

proc stateWorkspaceEntries(body: WorkspaceBody): seq[RenderEntry] =
  ## The ``[workspace]`` table of the state file, in its fixed key order. The
  ## ``projects`` array is omitted in the single-project steady state (empty,
  ## or one element equal to the primary) and ``feature_started`` is written
  ## only when true: the reader treats absent and ``false`` alike.
  result.add(entry("project", tomlStr(body.project)))
  let ps = body.projects
  if not (ps.len == 0 or (ps.len == 1 and ps[0] == body.project)):
    result.add(entry("projects", tomlStrings(ps)))
  if body.branch.isSome and body.branch.get().len > 0:
    result.add(entry("branch", tomlStr(body.branch.get())))
  if body.feature_started.isSome and body.feature_started.get():
    result.add(entry("feature_started", tomlBool(true)))

proc workspaceStateText*(local: WorkspaceLocal): string =
  ## The per-checkout state file (``.repro/workspace.toml``) from a typed
  ## value: ``[workspace]`` then one ``[[manifest]]`` block per layer. Refuses
  ## an empty project name, which the strict reader would reject later.
  if local.workspace.project.len == 0:
    raise editError("", "workspace.project",
      "refusing to write a workspace state file with an empty project name")
  var blocks = @[RenderBlock(header: "[workspace]",
    entries: stateWorkspaceEntries(local.workspace))]
  for layer in local.manifest:
    var e: seq[RenderEntry]
    if layer.url.isSome and layer.url.get().len > 0:
      e.add(entry("url", tomlStr(layer.url.get())))
    elif layer.local_path.isSome and layer.local_path.get().len > 0:
      e.add(entry("local_path", tomlStr(layer.local_path.get())))
    e.add(entry("visibility", tomlStr(layer.visibility)))
    if layer.branch.isSome and layer.branch.get().len > 0:
      e.add(entry("branch", tomlStr(layer.branch.get())))
    blocks.add(RenderBlock(header: "[[manifest]]", entries: e))
  let schema = if local.schema.len > 0: local.schema
               else: schemaWorkspaceLocalV1
  assemble(schema, @[], blocks, extensionsBlock(local.extensions))

proc writeWorkspaceManifestFile*(path, text: string) =
  ## Write ``text`` to ``path`` (creating the parent directory) through a
  ## sibling temporary file and a rename, so a reader never observes a
  ## half-written manifest.
  let dir = parentDir(path)
  if dir.len > 0:
    createDir(dir)
  let tmp = path & ".repro-edit.tmp"
  writeFile(tmp, text)
  moveFile(tmp, path)

# ---- document model --------------------------------------------------------

proc manifestDocFromText*(text: string; path = ""): ManifestDoc =
  ## Split ``text`` into lines, remembering each line's own terminator.
  result.path = path
  result.eol = ""
  var start = 0
  while start < text.len:
    let nl = text.find('\n', start)
    if nl < 0:
      result.lines.add(text[start .. ^1])
      result.terms.add("")
      break
    if nl > start and text[nl - 1] == '\r':
      result.lines.add(text[start ..< nl - 1])
      result.terms.add("\r\n")
    else:
      result.lines.add(text[start ..< nl])
      result.terms.add("\n")
    if result.eol.len == 0:
      result.eol = result.terms[^1]
    start = nl + 1
  if result.eol.len == 0:
    result.eol = "\n"

proc loadManifestDoc*(path: string): ManifestDoc =
  manifestDocFromText(readFile(path), path)

proc manifestDocText*(doc: ManifestDoc): string =
  for i, line in doc.lines:
    result.add(line)
    result.add(doc.terms[i])

proc saveManifestDoc*(doc: ManifestDoc) =
  ## Write the document back when an edit changed it.
  if doc.changed:
    writeWorkspaceManifestFile(doc.path, doc.manifestDocText)

proc replaceLines(doc: var ManifestDoc; first, last: int;
                  newLines: seq[string]) =
  ## Replace lines ``first .. last`` (inclusive; ``last = first - 1`` inserts)
  ## with ``newLines``. A replaced span keeps the terminator of its last line;
  ## inserted lines get the document's terminator.
  let tailTerm =
    if last >= first: doc.terms[last]
    elif first < doc.lines.len: doc.eol
    else: ""
  var newTerms: seq[string]
  for i in 0 ..< newLines.len:
    newTerms.add(if i == newLines.len - 1 and last >= first: tailTerm
                 else: doc.eol)
  # Appending after an unterminated last line: that line now needs one.
  if last < first and first == doc.lines.len and doc.lines.len > 0 and
      doc.terms[^1].len == 0:
    doc.terms[^1] = doc.eol
  var lines = doc.lines[0 ..< first]
  var terms = doc.terms[0 ..< first]
  lines.add(newLines)
  terms.add(newTerms)
  if last + 1 < doc.lines.len:
    lines.add(doc.lines[last + 1 .. ^1])
    terms.add(doc.terms[last + 1 .. ^1])
  doc.lines = lines
  doc.terms = terms
  doc.changed = true

# ---- parsing ---------------------------------------------------------------

type
  PvKind = enum
    pvString, pvBool, pvInt, pvArray, pvTable, pvOther

  ParsedValue = ref object
    ## A value as it appears in the file, with its source span:
    ## ``(sl, sc)`` is the first character, ``(el, ec)`` one past the last.
    sl, sc, el, ec: int
    case kind: PvKind
    of pvString: s: string
    of pvBool: b: bool
    of pvInt: i: int64
    of pvArray: elems: seq[ParsedValue]
    of pvTable: fields: seq[(string, ParsedValue)]
    of pvOther: raw: string

  Cursor = object
    l, c: int

  HeaderInfo = object
    line: int
    name: string        ## dotted name, segments unquoted
    isArray: bool
    ordinal: int        ## index among ``[[name]]`` blocks; -1 for ``[name]``

  EntryInfo = object
    table: string       ## "" for the root table
    ordinal: int        ## the ``[[table]]`` block it belongs to, or -1
    key: string         ## dotted key, segments unquoted
    first, last: int    ## line span of the whole entry, inclusive
    value: ParsedValue

  DocScan = object
    headers: seq[HeaderInfo]
    entries: seq[EntryInfo]

proc parseError(doc: ManifestDoc; line: int; msg: string): ref ManifestEditError =
  editError(doc.path, "", "line " & $(line + 1) & ": " & msg)

proc charAt(doc: ManifestDoc; cur: Cursor): char =
  if cur.l < doc.lines.len and cur.c < doc.lines[cur.l].len:
    doc.lines[cur.l][cur.c]
  else:
    '\0'

proc atLineEnd(doc: ManifestDoc; cur: Cursor): bool =
  cur.l >= doc.lines.len or cur.c >= doc.lines[cur.l].len

proc skipSpaces(doc: ManifestDoc; cur: var Cursor) =
  while not doc.atLineEnd(cur) and doc.charAt(cur) in {' ', '\t'}:
    inc cur.c

proc skipSpacesNewlinesComments(doc: ManifestDoc; cur: var Cursor) =
  ## Inside an array, whitespace, newlines and comments separate elements.
  while cur.l < doc.lines.len:
    doc.skipSpaces(cur)
    if doc.atLineEnd(cur) or doc.charAt(cur) == '#':
      inc cur.l
      cur.c = 0
    else:
      return

proc parseBasicString(doc: ManifestDoc; cur: var Cursor; multi: bool): string =
  ## Cursor sits just past the opening quote(s).
  let startLine = cur.l
  while true:
    if cur.l >= doc.lines.len:
      raise doc.parseError(startLine, "unterminated string")
    let line = doc.lines[cur.l]
    if cur.c >= line.len:
      if not multi:
        raise doc.parseError(startLine, "unterminated string")
      result.add('\n')
      inc cur.l
      cur.c = 0
      continue
    let ch = line[cur.c]
    if ch == '\\':
      if cur.c + 1 >= line.len:
        if multi:
          # Line-ending backslash: trims the newline and leading whitespace.
          inc cur.l
          cur.c = 0
          doc.skipSpacesNewlinesComments(cur)
          continue
        raise doc.parseError(cur.l, "dangling escape")
      let esc = line[cur.c + 1]
      cur.c += 2
      case esc
      of 'n': result.add('\n')
      of 't': result.add('\t')
      of 'r': result.add('\r')
      of 'b': result.add('\b')
      of 'f': result.add('\f')
      of '"': result.add('"')
      of '\\': result.add('\\')
      of 'u', 'U':
        let width = if esc == 'u': 4 else: 8
        if cur.c + width > line.len:
          raise doc.parseError(cur.l, "short unicode escape")
        let code = parseHexInt(line[cur.c ..< cur.c + width])
        result.add(toUTF8(Rune(code)))
        cur.c += width
      else:
        raise doc.parseError(cur.l, "unknown escape \\" & esc)
    elif ch == '"':
      if multi:
        if line.continuesWith("\"\"\"", cur.c):
          cur.c += 3
          # Up to two extra quotes may close a multi-line string.
          while cur.c < line.len and line[cur.c] == '"':
            result.add('"')
            inc cur.c
          return
        result.add('"')
        inc cur.c
      else:
        inc cur.c
        return
    else:
      result.add(ch)
      inc cur.c

proc parseLiteralString(doc: ManifestDoc; cur: var Cursor; multi: bool): string =
  let startLine = cur.l
  while true:
    if cur.l >= doc.lines.len:
      raise doc.parseError(startLine, "unterminated string")
    let line = doc.lines[cur.l]
    if cur.c >= line.len:
      if not multi:
        raise doc.parseError(startLine, "unterminated string")
      result.add('\n')
      inc cur.l
      cur.c = 0
      continue
    if line[cur.c] == '\'':
      if not multi:
        inc cur.c
        return
      if line.continuesWith("'''", cur.c):
        cur.c += 3
        while cur.c < line.len and line[cur.c] == '\'':
          result.add('\'')
          inc cur.c
        return
    result.add(line[cur.c])
    inc cur.c

proc parseKeySegments(doc: ManifestDoc; cur: var Cursor;
                      stops: set[char]): string =
  ## A (possibly dotted, possibly quoted) key, segments joined with '.'.
  var parts: seq[string]
  while true:
    doc.skipSpaces(cur)
    let ch = doc.charAt(cur)
    if ch == '"':
      inc cur.c
      parts.add(doc.parseBasicString(cur, multi = false))
    elif ch == '\'':
      inc cur.c
      parts.add(doc.parseLiteralString(cur, multi = false))
    else:
      var seg = ""
      while not doc.atLineEnd(cur) and
          doc.charAt(cur) in {'A'..'Z', 'a'..'z', '0'..'9', '_', '-'}:
        seg.add(doc.charAt(cur))
        inc cur.c
      if seg.len == 0:
        raise doc.parseError(cur.l, "expected a key")
      parts.add(seg)
    doc.skipSpaces(cur)
    if doc.charAt(cur) == '.':
      inc cur.c
      continue
    if doc.atLineEnd(cur) or doc.charAt(cur) notin stops:
      raise doc.parseError(cur.l, "malformed key")
    return parts.join(".")

proc parseValue(doc: ManifestDoc; cur: var Cursor): ParsedValue

proc parseArray(doc: ManifestDoc; cur: var Cursor; sl, sc: int): ParsedValue =
  result = ParsedValue(kind: pvArray, sl: sl, sc: sc)
  inc cur.c  # '['
  while true:
    doc.skipSpacesNewlinesComments(cur)
    if cur.l >= doc.lines.len:
      raise doc.parseError(sl, "unterminated array")
    if doc.charAt(cur) == ']':
      inc cur.c
      break
    result.elems.add(doc.parseValue(cur))
    doc.skipSpacesNewlinesComments(cur)
    let ch = doc.charAt(cur)
    if ch == ',':
      inc cur.c
    elif ch == ']':
      inc cur.c
      break
    else:
      raise doc.parseError(cur.l, "expected ',' or ']' in array")
  result.el = cur.l
  result.ec = cur.c

proc parseInlineTable(doc: ManifestDoc; cur: var Cursor; sl, sc: int): ParsedValue =
  result = ParsedValue(kind: pvTable, sl: sl, sc: sc)
  inc cur.c  # '{'
  doc.skipSpaces(cur)
  if doc.charAt(cur) == '}':
    inc cur.c
  else:
    while true:
      let key = doc.parseKeySegments(cur, {'='})
      inc cur.c  # '='
      doc.skipSpaces(cur)
      result.fields.add((key, doc.parseValue(cur)))
      doc.skipSpaces(cur)
      let ch = doc.charAt(cur)
      if ch == ',':
        inc cur.c
        doc.skipSpaces(cur)
      elif ch == '}':
        inc cur.c
        break
      else:
        raise doc.parseError(cur.l, "expected ',' or '}' in inline table")
  result.el = cur.l
  result.ec = cur.c

proc parseValue(doc: ManifestDoc; cur: var Cursor): ParsedValue =
  let sl = cur.l
  let sc = cur.c
  if doc.atLineEnd(cur):
    raise doc.parseError(cur.l, "missing value")
  let line = doc.lines[cur.l]
  case line[cur.c]
  of '"':
    let multi = line.continuesWith("\"\"\"", cur.c)
    cur.c += (if multi: 3 else: 1)
    if multi and cur.c >= line.len:
      # A newline right after the opening delimiter is trimmed.
      inc cur.l
      cur.c = 0
    let s = doc.parseBasicString(cur, multi)
    result = ParsedValue(kind: pvString, s: s, sl: sl, sc: sc)
  of '\'':
    let multi = line.continuesWith("'''", cur.c)
    cur.c += (if multi: 3 else: 1)
    if multi and cur.c >= line.len:
      inc cur.l
      cur.c = 0
    let s = doc.parseLiteralString(cur, multi)
    result = ParsedValue(kind: pvString, s: s, sl: sl, sc: sc)
  of '[':
    return doc.parseArray(cur, sl, sc)
  of '{':
    return doc.parseInlineTable(cur, sl, sc)
  else:
    var tok = ""
    while cur.c < line.len and line[cur.c] notin {' ', '\t', ',', ']', '}', '#'}:
      tok.add(line[cur.c])
      inc cur.c
    if tok == "true" or tok == "false":
      result = ParsedValue(kind: pvBool, b: tok == "true", sl: sl, sc: sc)
    else:
      let digits = tok.replace("_", "")
      var parsed = none(int64)
      if digits.len > 0 and digits.allCharsInSet({'0'..'9', '+', '-'}):
        try:
          parsed = some(parseBiggestInt(digits).int64)
        except ValueError:
          discard
      if parsed.isSome:
        result = ParsedValue(kind: pvInt, i: parsed.get(), sl: sl, sc: sc)
      else:
        if tok.len == 0:
          raise doc.parseError(cur.l, "missing value")
        result = ParsedValue(kind: pvOther, raw: tok, sl: sl, sc: sc)
  result.el = cur.l
  result.ec = cur.c

proc restIsCommentOrBlank(doc: ManifestDoc; cur: Cursor): bool =
  var c = cur
  doc.skipSpaces(c)
  doc.atLineEnd(c) or doc.charAt(c) == '#'

proc scan(doc: ManifestDoc): DocScan =
  ## Locate every table header and every ``key = value`` entry.
  var table = ""
  var ordinal = -1
  var arrayCounts = initTable[string, int]()
  var i = 0
  while i < doc.lines.len:
    let line = doc.lines[i]
    let body = line.strip()
    if body.len == 0 or body[0] == '#':
      inc i
      continue
    var cur = Cursor(l: i, c: line.len - line.strip(trailing = false).len)
    if body.startsWith("[["):
      cur.c += 2
      let name = doc.parseKeySegments(cur, {']'})
      if not doc.lines[i].continuesWith("]]", cur.c):
        raise doc.parseError(i, "malformed [[table]] header")
      cur.c += 2
      if not doc.restIsCommentOrBlank(cur):
        raise doc.parseError(i, "text after a table header")
      let n = arrayCounts.getOrDefault(name, 0)
      arrayCounts[name] = n + 1
      table = name
      ordinal = n
      result.headers.add(HeaderInfo(line: i, name: name, isArray: true,
        ordinal: n))
    elif body[0] == '[':
      inc cur.c
      let name = doc.parseKeySegments(cur, {']'})
      inc cur.c
      if not doc.restIsCommentOrBlank(cur):
        raise doc.parseError(i, "text after a table header")
      table = name
      ordinal = -1
      result.headers.add(HeaderInfo(line: i, name: name, isArray: false,
        ordinal: -1))
    else:
      let key = doc.parseKeySegments(cur, {'='})
      inc cur.c  # '='
      doc.skipSpaces(cur)
      let value = doc.parseValue(cur)
      var after = Cursor(l: value.el, c: value.ec)
      if not doc.restIsCommentOrBlank(after):
        raise doc.parseError(value.el, "text after the value of '" & key & "'")
      result.entries.add(EntryInfo(table: table, ordinal: ordinal, key: key,
        first: i, last: value.el, value: value))
      i = value.el
    inc i

const strayTopLevelKeys = ["includes", "member_sets", "member_repos",
                           "binary_dependency"]
  ## Top-level keys that files written before this editor existed may carry
  ## BELOW a table header. The old `sets add` stub wrote `member_sets` /
  ## `member_repos` under `[repo-set]`, and hand-written projects put
  ## `includes` after the last `[[remote]]` block. Standard TOML binds such a
  ## key to the table above it, but the pinned reader accepts both layouts and
  ## reads the key as top-level (verified for both), so an edit must find the
  ## array where it is rather than declare a second one above the first
  ## header. None of these names is a field of any table in any workspace
  ## schema, so the fallback cannot mistake a real table field for them.

proc findEntry(doc: ManifestDoc; s: DocScan; table, key: string;
               ordinal = -1): int =
  ## Index into ``s.entries`` of ``key`` in ``table`` (block ``ordinal`` for
  ## an array of tables), or -1. A key of the same name in another table is
  ## never a match.
  for idx, e in s.entries:
    if e.table == table and e.key == key and e.ordinal == ordinal:
      return idx
  if table.len == 0 and key in strayTopLevelKeys:
    for idx, e in s.entries:
      if e.key == key:
        return idx
  -1

proc hasKey*(doc: ManifestDoc; table, key: string): bool =
  ## Whether ``table`` (``""`` for the top level) declares ``key``.
  doc.findEntry(doc.scan, table, key) >= 0

# ---- comparisons -----------------------------------------------------------

proc sameValue(pv: ParsedValue; v: TomlEditValue): bool =
  case v.kind
  of tevString: pv.kind == pvString and pv.s == v.str
  of tevBool: pv.kind == pvBool and pv.b == v.boolVal
  of tevInt: pv.kind == pvInt and pv.i == v.intVal
  of tevStringArray:
    if pv.kind != pvArray or pv.elems.len != v.items.len:
      return false
    for i, e in pv.elems:
      if e.kind != pvString or e.s != v.items[i]:
        return false
    true
  of tevInlineTables:
    if pv.kind != pvArray or pv.elems.len != v.rows.len:
      return false
    for i, e in pv.elems:
      if e.kind != pvTable or e.fields.len != v.rows[i].len:
        return false
      for j, (k, fv) in e.fields:
        if k != v.rows[i][j].key or not sameValue(fv, v.rows[i][j].value):
          return false
    true

# ---- span helpers ----------------------------------------------------------

proc isBlank(doc: ManifestDoc; line: int): bool =
  line >= 0 and line < doc.lines.len and doc.lines[line].strip().len == 0

proc sourceText(doc: ManifestDoc; pv: ParsedValue): string =
  ## The exact source text of a value, newlines included.
  if pv.sl == pv.el:
    return doc.lines[pv.sl][pv.sc ..< pv.ec]
  result = doc.lines[pv.sl][pv.sc .. ^1]
  for l in pv.sl + 1 ..< pv.el:
    result.add("\n" & doc.lines[l])
  result.add("\n" & doc.lines[pv.el][0 ..< pv.ec])

proc replaceValue(doc: var ManifestDoc; pv: ParsedValue;
                  valueLines: seq[string]) =
  ## Replace the source span of ``pv`` with ``valueLines``, keeping whatever
  ## precedes it on its first line (``key = ``) and follows it on its last
  ## line (a trailing comment).
  let prefix = doc.lines[pv.sl][0 ..< pv.sc]
  let suffix = doc.lines[pv.el][pv.ec .. ^1]
  var newLines = valueLines
  newLines[0] = prefix & newLines[0]
  newLines[^1] = newLines[^1] & suffix
  doc.replaceLines(pv.sl, pv.el, newLines)

proc tableRegion(doc: ManifestDoc; s: DocScan; table: string;
                 ordinal: int): tuple[found: bool; header, endLine: int] =
  ## For ``table`` (block ``ordinal``): its header line (-1 for the root) and
  ## the last line before the next header.
  if table.len == 0:
    let next = if s.headers.len > 0: s.headers[0].line else: doc.lines.len
    return (true, -1, next - 1)
  for idx, h in s.headers:
    if h.name == table and h.ordinal == ordinal:
      let next = if idx + 1 < s.headers.len: s.headers[idx + 1].line
                 else: doc.lines.len
      return (true, h.line, next - 1)
  (false, -1, -1)

proc insertBlock(doc: var ManifestDoc; at: int; block0: seq[string];
                 padBefore, padAfter: bool) =
  var b: seq[string]
  if padBefore and at > 0 and not doc.isBlank(at - 1):
    b.add("")
  b.add(block0)
  if padAfter and at < doc.lines.len and not doc.isBlank(at):
    b.add("")
  doc.replaceLines(at, at - 1, b)

proc insertEntry(doc: var ManifestDoc; s: DocScan; table: string;
                 ordinal: int; entryLines: seq[string];
                 after: openArray[string]) =
  ## Insert a NEW entry. This is where the key-order rule is enforced: a
  ## top-level entry always lands above the first table header.
  let multi = entryLines.len > 1
  let region = doc.tableRegion(s, table, ordinal)
  if not region.found:
    # A table the file does not have yet goes at the end, under its own
    # header. Top-level keys never take this path (the root always exists).
    let header = if ordinal >= 0: "[[" & renderDottedKey(table) & "]]"
                 else: "[" & renderDottedKey(table) & "]"
    doc.insertBlock(doc.lines.len, @[header] & entryLines,
      padBefore = true, padAfter = false)
    return
  var anchor = -1   # line after which to insert
  for k in after:
    for e in s.entries:
      if e.table == table and e.ordinal == ordinal and e.key == k and
          e.first > region.header and e.last <= region.endLine:
        anchor = max(anchor, e.last)
  if anchor < 0 and after.len > 0:
    # None of the keys this one follows is present: it goes first.
    var firstEntry = -1
    for e in s.entries:
      if e.table == table and e.ordinal == ordinal and
          e.first > region.header and e.last <= region.endLine:
        firstEntry = e.first
        break
    if firstEntry >= 0:
      doc.insertBlock(firstEntry, entryLines, padBefore = multi,
        padAfter = multi)
      return
  if anchor < 0 and after.len == 0:
    for e in s.entries:
      if e.table == table and e.ordinal == ordinal and
          e.first > region.header and e.last <= region.endLine:
        anchor = max(anchor, e.last)
  if anchor >= 0:
    doc.insertBlock(anchor + 1, entryLines, padBefore = multi,
      padAfter = multi)
    return
  if table.len > 0:
    doc.insertBlock(region.header + 1, entryLines, padBefore = false,
      padAfter = multi)
    return
  # An empty top level. Above the first header — and above the comment block
  # that introduces it, which belongs to the header — or at the end of a
  # file with no header at all.
  if s.headers.len == 0:
    doc.insertBlock(doc.lines.len, entryLines, padBefore = true,
      padAfter = false)
    return
  var at = s.headers[0].line
  while at > 0 and not doc.isBlank(at - 1) and
      doc.lines[at - 1].strip().startsWith("#"):
    dec at
  doc.insertBlock(at, entryLines, padBefore = true, padAfter = true)

# ---- edits: keys -----------------------------------------------------------

proc setKey*(doc: var ManifestDoc; table, key: string; value: TomlEditValue;
             layout = alInline; after: openArray[string] = []): bool =
  ## Set ``key`` in ``table`` (``""`` for the top level) to ``value``.
  ## Returns true when the text changed.
  ##
  ## * An existing key whose value already equals ``value`` is left byte for
  ##   byte as it is (its quoting and layout are the author's).
  ## * An existing key with a different value has ONLY its value span
  ##   rewritten; the key, the spacing before the value and a trailing comment
  ##   survive. An array keeps the layout (inline / multi-line) it had.
  ## * A new key is inserted after the last present key named in ``after``
  ##   (first in the table when none is present), or after the table's last
  ##   key when ``after`` is empty. A new top-level key goes above the first
  ##   table header. A missing table is appended to the file.
  let s = doc.scan
  let idx = doc.findEntry(s, table, key)
  if idx >= 0:
    let pv = s.entries[idx].value
    if sameValue(pv, value):
      return false
    let keep = if pv.sl != pv.el: alMultiLine else: alInline
    doc.replaceValue(pv, renderValueLines(value,
      if value.isArray: keep else: alInline))
    return true
  doc.insertEntry(s, table, -1, renderEntryLines(key, value, layout), after)
  true

proc removeKey*(doc: var ManifestDoc; table, key: string): bool =
  ## Remove ``key`` from ``table``. Returns false when it was not there. When
  ## the removed entry sat between two blank lines, one of them goes with it so
  ## the file does not accumulate gaps.
  let s = doc.scan
  let idx = doc.findEntry(s, table, key)
  if idx < 0:
    return false
  let e = s.entries[idx]
  var last = e.last
  if (e.first == 0 or doc.isBlank(e.first - 1)) and doc.isBlank(last + 1):
    inc last
  doc.replaceLines(e.first, last, @[])
  true

# ---- edits: array members --------------------------------------------------

proc arrayValue(doc: ManifestDoc; s: DocScan; idx: int;
                table, key: string): ParsedValue =
  let pv = s.entries[idx].value
  if pv.kind != pvArray:
    raise editError(doc.path, (if table.len > 0: table & "." else: "") & key,
      "is not an array")
  pv

proc requireStrings(doc: ManifestDoc; pv: ParsedValue; table, key: string) =
  for e in pv.elems:
    if e.kind != pvString:
      raise editError(doc.path, (if table.len > 0: table & "." else: "") & key,
        "holds a non-string element; refusing to edit it as a member list")

proc onePerLine(doc: ManifestDoc; pv: ParsedValue): bool =
  ## Whether a multi-line array has its brackets on lines of their own (bar
  ## the key and comments) and exactly one single-line element per line —
  ## the layout an element can be added to or dropped from by inserting or
  ## deleting one line.
  if pv.sl == pv.el:
    return false
  var cur = Cursor(l: pv.sl, c: pv.sc + 1)
  if not doc.restIsCommentOrBlank(cur):
    return false
  if doc.lines[pv.el][0 ..< pv.ec - 1].strip().len != 0:
    return false
  var lastLine = pv.sl
  for e in pv.elems:
    if e.sl != e.el or e.sl == lastLine or e.sl == pv.el:
      return false
    if doc.lines[e.sl][0 ..< e.sc].strip().len != 0:
      return false
    var after = Cursor(l: e.el, c: e.ec)
    doc.skipSpaces(after)
    if doc.charAt(after) == ',':
      inc after.c
    if not doc.restIsCommentOrBlank(after):
      return false
    lastLine = e.sl
  true

proc rerenderArray(doc: var ManifestDoc; pv: ParsedValue;
                   elements: seq[string]) =
  ## Rewrite an array value from element source texts, keeping its layout
  ## class: single-line stays inline, multi-line becomes one per line.
  doc.replaceValue(pv, renderArrayFromElements(elements,
    if pv.sl == pv.el: alInline else: alMultiLine))

proc insertElement(doc: var ManifestDoc; pv: ParsedValue; elementText: string) =
  ## Append one element (already rendered) to an existing array.
  if doc.onePerLine(pv):
    var indent = "  "
    if pv.elems.len > 0:
      let last = pv.elems[^1]
      indent = doc.lines[last.sl][0 ..< last.sc]
      # The new last element needs the previous one to end with a comma.
      var after = Cursor(l: last.el, c: last.ec)
      doc.skipSpaces(after)
      if doc.charAt(after) != ',':
        let line = doc.lines[last.el]
        doc.lines[last.el] = line[0 ..< last.ec] & "," & line[last.ec .. ^1]
        doc.changed = true
    doc.replaceLines(pv.el, pv.el - 1, @[indent & elementText & ","])
    return
  var elements: seq[string]
  for e in pv.elems: elements.add(doc.sourceText(e))
  elements.add(elementText)
  doc.rerenderArray(pv, elements)

proc arrayMembers*(doc: ManifestDoc; table, key: string): seq[string] =
  ## The string elements of array ``key`` in ``table``; empty when absent.
  let s = doc.scan
  let idx = doc.findEntry(s, table, key)
  if idx < 0:
    return @[]
  let pv = doc.arrayValue(s, idx, table, key)
  doc.requireStrings(pv, table, key)
  for e in pv.elems: result.add(e.s)

proc addArrayMember*(doc: var ManifestDoc; table, key, member: string;
                     layout = alMultiLine): bool =
  ## Add ``member`` to the array NAMED ``key`` in ``table`` — never to another
  ## array, whatever its position. Returns false when it is already there
  ## (idempotent). A missing array is created with ``layout``; a top-level
  ## one above the first table header.
  let s = doc.scan
  let idx = doc.findEntry(s, table, key)
  if idx < 0:
    doc.insertEntry(s, table, -1,
      renderEntryLines(key, tomlStrings([member]), layout), [])
    return true
  let pv = doc.arrayValue(s, idx, table, key)
  doc.requireStrings(pv, table, key)
  for e in pv.elems:
    if e.s == member:
      return false
  doc.insertElement(pv, tomlQuote(member))
  true

proc removeArrayMember*(doc: var ManifestDoc; table, key, member: string): bool =
  ## Drop every occurrence of ``member`` from the array NAMED ``key``.
  ## Returns false when it was not there (idempotent). The array itself stays,
  ## empty if need be: an empty membership array still says which namespace
  ## the next entry belongs in.
  let s = doc.scan
  let idx = doc.findEntry(s, table, key)
  if idx < 0:
    return false
  let pv = doc.arrayValue(s, idx, table, key)
  doc.requireStrings(pv, table, key)
  var hits: seq[int]
  for i, e in pv.elems:
    if e.s == member: hits.add(i)
  if hits.len == 0:
    return false
  if doc.onePerLine(pv):
    # Bottom-up so earlier line numbers stay valid.
    for j in countdown(hits.high, 0):
      let line = pv.elems[hits[j]].sl
      doc.replaceLines(line, line, @[])
    return true
  var elements: seq[string]
  for i, e in pv.elems:
    if i notin hits: elements.add(doc.sourceText(e))
  doc.rerenderArray(pv, elements)
  true

proc appendInclude*(doc: var ManifestDoc; includePath: string): bool =
  ## Add a fragment path to a project's top-level ``includes`` array (the
  ## deprecated path-based membership spelling). Idempotent.
  doc.addArrayMember("", "includes", includePath, alMultiLine)

# ---- edits: arrays of tables -----------------------------------------------

proc arrayTableHasEntry*(doc: ManifestDoc; name, idKey, idValue: string): bool =
  ## Whether the array of tables ``name`` has an entry whose ``idKey`` is
  ## ``idValue`` — in either spelling TOML allows for it: ``[[name]]`` blocks,
  ## or a top-level ``name = [{ … }]`` inline-table array.
  let s = doc.scan
  for e in s.entries:
    if e.table == name and e.ordinal >= 0 and e.key == idKey and
        e.value.kind == pvString and e.value.s == idValue:
      return true
  let idx = doc.findEntry(s, "", name)
  if idx >= 0 and s.entries[idx].value.kind == pvArray:
    for el in s.entries[idx].value.elems:
      if el.kind == pvTable:
        for (k, v) in el.fields:
          if k == idKey and v.kind == pvString and v.s == idValue:
            return true
  false

proc ensureArrayTableEntry*(doc: var ManifestDoc; name: string;
                            fields: seq[TomlEditField]): bool =
  ## Append one entry to the array of tables ``name`` unless an entry with
  ## the same identity — the value of ``fields[0]`` — already exists. Returns
  ## true when an entry was added.
  ##
  ## The entry is written in the spelling the file already uses: appended to
  ## a top-level inline-table array when there is one (mixing the two
  ## spellings is a TOML error), otherwise as a ``[[name]]`` block after the
  ## last such block, or at the end of the file.
  if fields.len == 0 or fields[0].value.kind != tevString:
    raise editError(doc.path, name,
      "an array-of-tables entry needs a string identity field first")
  if doc.arrayTableHasEntry(name, fields[0].key, fields[0].value.str):
    return false
  let s = doc.scan
  let idx = doc.findEntry(s, "", name)
  if idx >= 0 and s.entries[idx].value.kind == pvArray:
    doc.insertElement(s.entries[idx].value, renderInlineTable(fields))
    return true
  var blockLines = @["[[" & renderDottedKey(name) & "]]"]
  for f in fields:
    blockLines.add(renderEntryLines(f.key, f.value, alInline))
  var lastBlock = -1
  for i, h in s.headers:
    if h.isArray and h.name == name: lastBlock = i
  if lastBlock < 0:
    doc.insertBlock(doc.lines.len, blockLines, padBefore = true,
      padAfter = false)
    return true
  var endLine =
    if lastBlock + 1 < s.headers.len: s.headers[lastBlock + 1].line - 1
    else: doc.lines.len - 1
  while endLine > s.headers[lastBlock].line and doc.isBlank(endLine):
    dec endLine
  doc.insertBlock(endLine + 1, blockLines, padBefore = true, padAfter = true)
  true

# ---- file-level conveniences -----------------------------------------------

proc addArrayMemberInFile*(path, table, key, member: string;
                           layout = alMultiLine): bool =
  ## ``addArrayMember`` on the file at ``path``, written back when changed.
  var doc = loadManifestDoc(path)
  result = doc.addArrayMember(table, key, member, layout)
  doc.saveManifestDoc()

proc removeArrayMemberInFile*(path, table, key, member: string): bool =
  ## ``removeArrayMember`` on the file at ``path``, written back when changed.
  var doc = loadManifestDoc(path)
  result = doc.removeArrayMember(table, key, member)
  doc.saveManifestDoc()

# ---- the state file --------------------------------------------------------

proc applyWorkspaceState*(doc: var ManifestDoc; body: WorkspaceBody): bool =
  ## Make the ``[workspace]`` table of a state file say ``body``, editing
  ## only the keys that differ. The keys keep their canonical order
  ## (``project``, ``projects``, ``branch``, ``feature_started``) when they
  ## are added, and the omission rules of ``workspaceStateText`` apply: a
  ## single-project set and a false feature-started mark are removed rather
  ## than written.
  if body.project.len == 0:
    raise editError(doc.path, "workspace.project",
      "refusing to record an empty project name")
  for e in stateWorkspaceEntries(body):
    let order =
      case e.key
      of "project": newSeq[string]()
      of "projects": @["project"]
      of "branch": @["project", "projects"]
      else: @["project", "projects", "branch"]
    if doc.setKey("workspace", e.key, e.value, alInline, order):
      result = true
  let ps = body.projects
  if ps.len == 0 or (ps.len == 1 and ps[0] == body.project):
    if doc.removeKey("workspace", "projects"): result = true
  if body.branch.isNone or body.branch.get().len == 0:
    if doc.removeKey("workspace", "branch"): result = true
  if body.feature_started.isNone or not body.feature_started.get():
    if doc.removeKey("workspace", "feature_started"): result = true

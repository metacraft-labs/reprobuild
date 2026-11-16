## The managed-file writer: the ONE implementation behind `fs.managedBlock`,
## `fs.ensureSnippet` and `fs.ensureLine`.
##
## reprobuild-pm `spec/CLI/internal/fs-file-utilities.md` §3-§4 and
## `spec/Generated-Configuration-Files.md` §"Caching" / §"Sentinel
## uniqueness" make these three one writer, and `spec/Core-Invariants.md`
## §"One Implementation Per Concern" is why it lives in one module: the
## sentinel format, the block locator, the splice and the atomic write used
## to exist twice (the engine's `ensureSnippet` and the home-profile
## `fs.managedBlock`), in two formats, and each was blind to the other's
## blocks. Everything that renders a sentinel, finds a block or replaces a
## managed file calls this module.
##
## Format. A block is delimited by two sentinel LINES:
##
##   # >>> repro:<scope>:<packageName>:<blockId> >>>
##   ...content...
##   # <<< repro:<scope>:<packageName>:<blockId> <<<
##
## `<scope>` is `home`, `system` or `project`. An empty `<packageName>` is
## elided (`repro:home:<blockId>`), the single-block home-profile form.
## Releases before the shared writer wrote project blocks with a
## `:v<digits>` suffix after the block id; such a block is recognised as the
## same block and replaced by the current form (fs-file-utilities.md §3,
## "Earlier format").
##
## Every byte outside the block is kept: the splice replaces only the span
## from the start of the opening sentinel line to the end of the closing
## sentinel's text, so the closing line's terminator -- or its absence --
## survives. The block's own lines use CRLF when the file's first line
## terminator is CRLF and LF otherwise.
##
## A file holding the same block twice, an opening sentinel without its
## closing sentinel, or a closing sentinel without an opening one is refused
## with `ManagedBlockError` naming the file and the block: the writer does
## not guess which copy is the real one.
##
## Writes go through `repro_core/durable_replace`: temporary file in the same
## directory, fsync, rename over the target (never remove-then-move), fsync
## of the directory on POSIX. A file whose bytes would not change is never
## written, so its mtime is kept.

import std/[os, strutils]

from ./paths import extendedPath
import ./durable_replace

type
  ManagedBlockError* = object of CatchableError
    ## The file cannot be read as holding at most one copy of the block, or
    ## the block's key is not a valid sentinel key.
  ManagedBlockOverlap* = object of ManagedBlockError
    ## A closing sentinel with no opening sentinel before it.

  ManagedBlockKey* = object
    ## Identifies one block: the `(scope, packageName, blockId)` triple of
    ## Generated-Configuration-Files.md §"Sentinel uniqueness".
    scope*: string
    packageName*: string   ## Empty for the elided single-block form.
    blockId*: string

  ManagedBlockSpan* = object
    ## Byte offsets of a located block. `found` is false when the file does
    ## not hold it; the offsets are then meaningless.
    found*: bool
    legacy*: bool          ## An opening or closing sentinel had `:v<n>`.
    openLineStart*: int    ## Start of the opening sentinel line.
    contentStart*: int     ## Just past the opening line's terminator.
    contentEnd*: int       ## Start of the closing sentinel line.
    closeTextEnd*: int     ## End of the closing line's text (terminator excluded).
    closeLineEnd*: int     ## Just past the closing line's terminator.

  AppendLayout* = enum
    ## Where an absent block goes. The splice of a present block is the same
    ## for every caller; only the placement of a NEW block differs, because
    ## the two entry points have always placed it differently and moving
    ## either would rewrite files that already hold it.
    alAfterBlankLine
      ## `fs.ensureSnippet` (fs-file-utilities.md §3): after one blank line.
    alDirectlyAfter
      ## `fs.managedBlock`: directly after the last line.

const
  HomeBlockScope* = "home"
  SystemBlockScope* = "system"
  ProjectBlockScope* = "project"
  KnownBlockScopes* = [HomeBlockScope, SystemBlockScope, ProjectBlockScope]

proc managedBlockKey*(scope, packageName, blockId: string): ManagedBlockKey =
  ManagedBlockKey(scope: scope, packageName: packageName, blockId: blockId)

proc `$`*(key: ManagedBlockKey): string =
  ## The sentinel tag, `repro:<scope>[:<packageName>]:<blockId>`. Also the
  ## name diagnostics use for the block.
  result = "repro:" & key.scope
  if key.packageName.len > 0:
    result.add(":" & key.packageName)
  result.add(":" & key.blockId)

proc openSentinel*(key: ManagedBlockKey): string =
  "# >>> " & $key & " >>>"

proc closeSentinel*(key: ManagedBlockKey): string =
  "# <<< " & $key & " <<<"

proc validateManagedBlockKey*(key: ManagedBlockKey) =
  ## Raises `ManagedBlockError` unless `key` renders to a sentinel that names
  ## exactly this block: a known scope, a non-empty block id, no whitespace
  ## in any segment (a sentinel is one line, and its fields are separated by
  ## the spaces around the tag), and a package name for a project block,
  ## whose owner is always the package that declared it.
  proc bad(what: string) =
    raise newException(ManagedBlockError,
      "managed block '" & $key & "': " & what)
  if key.scope notin KnownBlockScopes:
    bad("unknown scope '" & key.scope & "' (expected one of " &
      KnownBlockScopes.join(", ") & ")")
  if key.blockId.len == 0:
    bad("the block id is empty")
  if key.scope == ProjectBlockScope and key.packageName.len == 0:
    bad("a project block needs the name of the package that declares it")
  for segment in [key.scope, key.packageName, key.blockId]:
    for ch in segment:
      if ch in Whitespace or ord(ch) < 0x20:
        bad("'" & segment & "' contains whitespace or a control character")

proc isLegacySentinel(line, leader, tag, trailer: string): bool =
  ## `<leader><tag>:v<digits><trailer>`, the pre-shared-writer project form.
  let prefix = leader & tag & ":v"
  if not (line.startsWith(prefix) and line.endsWith(trailer)):
    return false
  let digits = line[prefix.len ..< line.len - trailer.len]
  digits.len > 0 and digits.allCharsInSet(Digits)

proc locateManagedBlock*(content: string; key: ManagedBlockKey;
                         fileName = ""): ManagedBlockSpan =
  ## Find `key`'s block in `content`. Lines are split as `splitLines` does
  ## (`\r\n`, `\n` or a lone `\r`), and a sentinel line matches after its
  ## surrounding whitespace is stripped. Raises `ManagedBlockError` -- naming
  ## `fileName` and the block -- when the block appears twice, when an
  ## opening sentinel has no closing one, and `ManagedBlockOverlap` when a
  ## closing sentinel has no opening one.
  let where = if fileName.len > 0: "'" & fileName & "'" else: "the file"
  let open = openSentinel(key)
  let close = closeSentinel(key)
  let tag = $key
  let legacyAllowed = key.scope == ProjectBlockScope
  var openPending = false
  var openLineNo = 0
  var foundLineNo = 0
  var lineNo = 0
  var lineStart = 0
  while lineStart <= content.len:
    inc lineNo
    var lineEnd = lineStart
    while lineEnd < content.len and content[lineEnd] notin {'\r', '\n'}:
      inc lineEnd
    var nextStart = lineEnd
    if nextStart < content.len:
      if content[nextStart] == '\r' and nextStart + 1 < content.len and
          content[nextStart + 1] == '\n':
        nextStart += 2
      else:
        inc nextStart
    let line = content[lineStart ..< lineEnd].strip()
    let legacyOpen = legacyAllowed and
      isLegacySentinel(line, "# >>> ", tag, " >>>")
    let legacyClose = legacyAllowed and
      isLegacySentinel(line, "# <<< ", tag, " <<<")
    if line == open or legacyOpen:
      if openPending:
        raise newException(ManagedBlockError, where & ": managed block '" &
          tag & "' opens on line " & $openLineNo & " and again on line " &
          $lineNo & " before it is closed; refusing to guess which is the block")
      if result.found:
        raise newException(ManagedBlockError, where & ": managed block '" &
          tag & "' appears twice (lines " & $foundLineNo & " and " & $lineNo &
          "); refusing to guess which copy to keep")
      openPending = true
      openLineNo = lineNo
      result.openLineStart = lineStart
      result.contentStart = nextStart
      result.legacy = legacyOpen
    elif line == close or legacyClose:
      if not openPending:
        raise newException(ManagedBlockOverlap, where & ": managed block '" &
          tag & "' has a closing sentinel on line " & $lineNo &
          " with no opening sentinel before it")
      openPending = false
      result.found = true
      foundLineNo = openLineNo
      result.contentEnd = lineStart
      result.closeTextEnd = lineEnd
      result.closeLineEnd = nextStart
      result.legacy = result.legacy or legacyClose
    if lineEnd >= content.len:
      break
    lineStart = nextStart
  if openPending:
    raise newException(ManagedBlockError, where & ": managed block '" & tag &
      "' opens on line " & $openLineNo & " but is never closed")

proc fileLineTerminator*(content: string): string =
  ## CRLF when the first line terminator of `content` is CRLF, LF otherwise
  ## (also for a file with no terminator at all).
  let firstBreak = content.find({'\r', '\n'})
  if firstBreak >= 0 and content.continuesWith("\r\n", firstBreak):
    "\r\n"
  else:
    "\n"

proc renderManagedBlock*(key: ManagedBlockKey; body: string;
                         eol = "\n"): string =
  ## The block's bytes, from the opening sentinel to the end of the closing
  ## sentinel's text: no terminator after it, because the splice keeps the
  ## one the file already has. `body` is terminated when it is not already,
  ## and every line uses `eol`.
  var text = body.replace("\r\n", "\n")
  if not text.endsWith("\n"):
    text.add('\n')
  result = openSentinel(key) & "\n" & text & closeSentinel(key)
  if eol != "\n":
    result = result.replace("\n", eol)

proc spliceManagedBlock*(content: string; key: ManagedBlockKey; body: string;
                         layout: AppendLayout; fileName = ""): string =
  ## The bytes a file holding `content` should hold once `key`'s block holds
  ## `body`. A result equal to `content` means "up to date, do not write".
  validateManagedBlockKey(key)
  let eol = fileLineTerminator(content)
  let blockText = renderManagedBlock(key, body, eol)
  let span = locateManagedBlock(content, key, fileName)
  if span.found:
    return content[0 ..< span.openLineStart] & blockText &
      content[span.closeTextEnd .. ^1]
  result = content
  let lastBreak = max(content.rfind('\n'), content.rfind('\r'))
  let lastLine = content[lastBreak + 1 .. ^1]
  case layout
  of alAfterBlankLine:
    # One terminator closes an unterminated non-blank last line and one more
    # makes the blank separator: the bytes `ensureSnippet` has always
    # appended, so a file that already received a block is not moved.
    if lastLine.strip().len > 0:
      result.add(eol)
    result.add(eol)
  of alDirectlyAfter:
    if lastLine.len > 0:
      result.add(eol)
  result.add(blockText)
  result.add(eol)

proc withoutManagedBlock*(content: string; key: ManagedBlockKey;
                          fileName = ""): string =
  ## `content` with `key`'s block -- both sentinel lines and their
  ## terminators -- removed, every other byte kept. `content` itself when the
  ## block is absent.
  let span = locateManagedBlock(content, key, fileName)
  if not span.found:
    return content
  content[0 ..< span.openLineStart] & content[span.closeLineEnd .. ^1]

proc ensureLineContent*(content, line: string): string =
  ## The bytes a file holding `content` should hold once it contains `line`
  ## (fs-file-utilities.md §2). A line already present, compared without
  ## surrounding whitespace, leaves `content` as it is; otherwise `line` is
  ## appended after closing an unterminated last line. The terminators added
  ## follow the file's, as a block's lines do (`fileLineTerminator`).
  let wanted = line.strip()
  for existing in content.splitLines():
    if existing.strip() == wanted:
      return content
  let eol = fileLineTerminator(content)
  result = content
  if result.len > 0 and result[^1] notin {'\n', '\r'}:
    result.add(eol)
  result.add(line)
  result.add(eol)

proc readManagedFile*(path: string): string =
  ## The file's bytes, or "" when it does not exist.
  let expanded = extendedPath(path)
  if fileExists(expanded): readFile(expanded) else: ""

proc writeManagedFile*(path, content: string) =
  ## Replace `path` with `content` atomically and durably
  ## (fs-file-utilities.md §4, "Atomic replacement"), creating its directory
  ## when needed and keeping an existing file's permission bits. A symlink
  ## at `path` is replaced, not written through.
  createDir(extendedPath(parentDir(path)))
  replaceFileDurably(path, content, keepMode = true)

proc updateManagedFile*(path: string; prior, next: string): bool =
  ## Write `next` to `path` when it differs from `prior` (the bytes it was
  ## computed from). Returns whether the file was written.
  if next == prior:
    return false
  writeManagedFile(path, next)
  true

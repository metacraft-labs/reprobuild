## The CONTENT identity of a Nix ``expressionFile`` and everything it reads.
##
## ## The defect this closes (ReproOS M7, sibling (6))
##
## A tool use whose Nix realization names an ``expressionFile`` was keyed by
## the file's PATH in the tool-identity cache key, and by the top-level file's
## bytes only in the Nix materialization cache key one layer down. Every
## stdlib expression imports ``../nixpkgs.nix`` (the nixpkgs pin) and
## ``stylus`` builds ``src = ./.`` (its ``package.json`` /
## ``package-lock.json``), so bumping the pin or editing the lock file moved
## neither key and the stale realization was served.
##
## ## What the closure is
##
## The top-level file plus, recursively, every path LITERAL a Nix file in the
## closure names (``./x``, ``../x``, ``a/b``, and ``/abs`` on POSIX), resolved
## the way Nix resolves them (lexically, against the directory of the file
## that names them). A referenced directory -- including ``./.`` -- is hashed
## whole (names, kinds, bytes, and the executable bit on POSIX, which a NAR
## records), and every ``*.nix`` file inside it is scanned too, since
## ``import ./dir`` evaluates ``dir/default.nix`` and a path built as
## ``./dir + "/x.nix"`` evaluates another. A referenced file is scanned when
## it ends in ``.nix`` or is the literal target of ``import`` /
## ``callPackage`` / ``callPackages`` (``import ./x``, ``import (./x)``;
## any other target is refused, below). A reference to a file that does not
## exist is bound as ABSENT (creating it later moves the digest), not refused.
##
## ## Uncacheable, never partial
##
## The scanner is a lexer modelled on Nix's own ``lexer.l`` (states DEFAULT,
## STRING and IND_STRING; longest match between identifiers, numbers, paths,
## search paths, URIs and operators), not a set of regexes over the text: a
## comment or a string never adds a reference and never hides one. Every
## construct whose inputs cannot be bound statically makes the WHOLE
## expression uncacheable -- the caller then re-resolves every time (a false
## refusal, which is safe) instead of caching on partial data:
##
##   * ``<nixpkgs>``-style search-path lookups and ``~/`` paths (ambient
##     ``NIX_PATH`` / ``$HOME``);
##   * interpolated paths (``./a/${x}``), a trailing-slash path;
##   * the impure builtins ``getEnv``, ``currentTime``, ``nixPath``,
##     ``findFile``, ``getFlake``, ``storePath``, ``fetchClosure``,
##     ``toPath``, ``exec``, ``importNative``, ``nixVersion``,
##     ``langVersion``, ``storeDir``, ``currentSystem``, the host-path
##     position builtins ``__curPos`` / ``unsafeGetAttrPos``, and the nixpkgs
##     ``lib`` ``getEnv`` wrappers ``maybeEnv`` / ``inNixShell`` (and their
##     ``__`` spellings), on ANY occurrence; the derivation attributes that
##     take a build out of the sandbox or input addressing (``__impure``,
##     ``__noChroot``, ``__sandboxProfile`` / ``sandboxProfile`` /
##     ``propagatedSandboxProfile``, ``[__]impureHostDeps``,
##     ``__propagatedImpureHostDeps``, ``__darwinAllowLocalNetworking``);
##     ``builtins.${...}`` / ``builtins."..."`` dynamic access,
##     and ``builtins`` used as a value at all (``getAttr n builtins``)
##     other than ``builtins.name``, ``with builtins;`` and
##     ``inherit (builtins) ...;``;
##   * the path-deriving builtins ``dirOf`` (climbs to a parent) and
##     ``toString`` (a path's HOST path string, which string operations can
##     extend and evaluation coerce back), in either spelling;
##   * a ``+`` whose left operand is not syntactically a string or a number:
##     ``./. + "-other/x.nix"`` is a path naming a SIBLING of the directory
##     the closure hashed, and whether an operand is a path is a type
##     question the scanner does not answer;
##   * a fetcher (any identifier starting with ``fetch``) used other than as
##     a direct call with a literal attribute set carrying a literal
##     ``sha256`` / ``sha512`` / ``sha1`` / ``md5`` / ``hash`` / ``narHash`` /
##     ``outputHash``, or a literal 40/64-hex ``rev`` (for ``fetchTree`` only
##     with a literal ``type`` whose ``rev`` locks the content). A NAME being
##     bound -- a binding, a lambda parameter, a formal -- is not a use, and
##     neither is a ``let``-level ``inherit`` (every later use is seen); a
##     formal's DEFAULT value (``{ f ? fetchTarball }:``) and an ``inherit``
##     into an attribute SET (``mapAttrs (n: f: f url) { inherit
##     (builtins) fetchurl; }``) are uses, and refused;
##   * an ``import`` / ``callPackage`` / ``callPackages`` whose target is not
##     a path literal (``import ./x``, ``import (./x)`` -- scanned as Nix
##     whatever its name) or a fixed fetch (``import (fetchTarball {...})``)
##     -- or, for ``callPackage*``, a function literal: ``import p``,
##     ``map import [...]``, ``let i = import; in i ./x`` evaluate a file
##     the scanner would hash but not scan; ``scopedImport`` on any use (its
##     target is its second argument);
##   * a string literal whose text begins with ``/`` (evaluation may coerce
##     it to an absolute path the closure cannot see);
##   * an absolute path literal on Windows (it names nothing Nix could read
##     there), a reference outside the project root (the nearest ancestor of
##     the top-level file holding ``.git``), no project root at all;
##   * a symbolic link, junction or other reparse point on any component
##     below the root of a reference, or anywhere inside a hashed directory;
##     a special file; a lexer error (unterminated string or comment, stray
##     ``}``, a non-ASCII byte outside strings and comments);
##   * a closure larger than ``MaxClosureFiles`` files / ``MaxClosureBytes``
##     bytes / ``MaxScannedNixFiles`` scanned Nix files.
##
## ## What it does NOT cover (stated in the M7 record)
##
## Inputs Nix consults that no expression text names: the nixpkgs config and
## overlays an ``import <pinned nixpkgs> {}`` reads (``NIXPKGS_CONFIG``,
## ``~/.config/nixpkgs``), ``nix.conf`` (``system``, substituters), the Nix
## version, builder-time reads of an unsandboxed build; a string->path
## coercion of an absolute path string COMPUTED at evaluation time rather
## than written as a literal starting with ``/`` (``substring`` /
## ``replaceStrings`` over other literals, or data read by ``readFile`` /
## ``fromJSON``); paths the fetched nixpkgs library derives from the paths
## the expression hands it, and fetches nixpkgs functions perform
## internally (``buildNpmPackage``'s npm dependencies: fixed-output, their
## hash required by nixpkgs and bound here as the literal the expression
## passes); a non-.nix file evaluated by a nixpkgs function other than
## ``callPackage`` / ``callPackages`` that is handed its path
## (``callPackageWith``, ``evalModules`` / module ``imports``); an absolute
## path string built by interpolation (``"${""}/etc/x"``). The threat model
## is an honest expression going stale, not an adversarial one. Binding
## the derivation path (``nix eval --raw --file F drvPath``) would cover all
## of these; it needs a Nix evaluation per expression and was not
## implemented (no Nix on the Windows host this was built on).

import std/[algorithm, os, sets, strutils, sysrand, tables]

import blake3
import repro_core/paths as corepaths

const
  ClosureDomain = "reprobuild.nix.expressionClosure.v1"
  MaxClosureFiles* = 100_000
  MaxClosureBytes* = 512'i64 * 1024 * 1024
  MaxScannedNixFiles* = 2_000

type
  NixTokKind = enum
    ntId, ntInt, ntFloat, ntPath, ntHPath, ntSPath, ntUri, ntOp,
    ntLBrace, ntRBrace, ntInterp, ntLParen, ntRParen, ntLBracket, ntRBracket,
    ntStrOpen, ntStrPart, ntStrClose

  NixTok = object
    kind: NixTokKind
    text: string
    indented: bool
    interpolated: bool
    line, col: int

  NixPathRef* = object
    text*: string
      ## The literal as written (``./x``, ``../x``, ``a/b``, ``/abs``).
    evaluated*: bool
      ## Directly follows ``import`` / ``scopedImport`` / ``callPackage`` /
      ## ``callPackages``: the target is evaluated as Nix whatever its name.
    line*, col*: int

  NixScan* = object
    refs*: seq[NixPathRef]
    refusals*: seq[string]
      ## ``line:col: reason`` for every construct that makes the file
      ## uncacheable. Empty means every input the text names is in ``refs``.

  NixClosureEntryKind* = enum
    nceFile, nceExecutableFile, nceDirectory, nceMissing

  NixClosureEntry* = object
    relativePath*: string
      ## Root-relative, ``/``-separated.
    kind*: NixClosureEntryKind
    digest*: string
      ## blake3 hex of the file bytes or of the directory tree; "" when
      ## missing.

  NixExpressionClosure* = object
    expressionFile*: string
    root*: string
    cacheable*: bool
    reason*: string
      ## Why the expression is uncacheable (the first finding); "" when
      ## cacheable.
    entries*: seq[NixClosureEntry]
      ## Sorted by ``relativePath``.
    digest*: string
      ## 64 hex over the root, the top-level file and every entry; "" when
      ## uncacheable.

const
  ImpureBuiltins = ["getEnv", "currentTime", "nixPath", "findFile",
    "getFlake", "storePath", "fetchClosure", "toPath", "exec",
    "importNative", "nixVersion", "langVersion", "storeDir",
    # The host's ``system`` (nix.conf / the build machine), and the HOST
    # path of the evaluated file, which string operations can extend into a
    # path no literal names (``"${__curPos.file}.bak"``).
    "currentSystem", "curPos", "unsafeGetAttrPos",
    # nixpkgs ``lib`` wrappers of ``getEnv``: named in the text, so refused
    # like the builtin they call.
    "maybeEnv", "inNixShell"]
  ImpureDerivationAttributes = ["__impure", "__noChroot", "__sandboxProfile",
    "sandboxProfile", "propagatedSandboxProfile", "__impureHostDeps",
    "impureHostDeps", "__propagatedImpureHostDeps",
    "__darwinAllowLocalNetworking"]
    ## A derivation attribute that opts its builder out of the sandbox, into
    ## host paths or the network, or out of input addressing: the realized
    ## output then depends on the build host, not on the closure.
  TreeFetcherLockingTypes = ["git", "github", "gitlab", "sourcehut",
    "mercurial", "hg"]
    ## ``fetchTree`` input types whose ``rev`` pins the content. A
    ## ``tarball`` / ``file`` / ``path`` input carries ``rev`` only as
    ## unverified metadata.
  PathDerivingBuiltins = ["dirOf", "toString"]
    ## ``dirOf`` climbs from a path to its parent; ``toString`` turns a path
    ## into its HOST path string, which string operations can extend and
    ## evaluation can coerce back. Either reaches files no literal names.
  EvaluatingCallers = ["import", "scopedImport", "callPackage",
    "callPackages"]
  HashAttributes = ["sha256", "sha512", "sha1", "md5", "hash", "narHash",
    "outputHash"]
  PathChars = {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '.', '_', '-', '+'}
  IdStart = {'a' .. 'z', 'A' .. 'Z', '_'}
  IdChars = {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_', '\'', '-'}
  UriSchemeChars = {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '+', '-', '.'}
  UriChars = {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '%', '/', '?', ':', '@',
    '&', '=', '+', '$', ',', '-', '_', '.', '!', '~', '*', '\''}
  MultiCharOps = ["...", "==", "!=", "<=", ">=", "&&", "||", "->", "//",
    "++", "<|", "|>"]

# ---------------------------------------------------------------------------
# Lexer
# ---------------------------------------------------------------------------

type
  LexState = enum
    lsDefault, lsString, lsIndString

  LexError = object of CatchableError

proc at(s: string; i: int): char {.inline.} =
  if i >= 0 and i < s.len: s[i] else: '\0'

proc matchId(s: string; i: int): int =
  if s.at(i) notin IdStart:
    return 0
  var j = i + 1
  while s.at(j) in IdChars:
    inc j
  j - i

proc matchInt(s: string; i: int): int =
  var j = i
  while s.at(j) in {'0' .. '9'}:
    inc j
  j - i

proc matchFloat(s: string; i: int): int =
  ## ``(([1-9][0-9]*\.[0-9]*)|(0?\.[0-9]+))([Ee][+-]?[0-9]+)?``
  var best = 0
  block first:
    var j = i
    if s.at(j) notin {'1' .. '9'}:
      break first
    inc j
    while s.at(j) in {'0' .. '9'}:
      inc j
    if s.at(j) != '.':
      break first
    inc j
    while s.at(j) in {'0' .. '9'}:
      inc j
    best = j - i
  block second:
    var j = i
    if s.at(j) == '0':
      inc j
    if s.at(j) != '.':
      break second
    inc j
    if s.at(j) notin {'0' .. '9'}:
      break second
    while s.at(j) in {'0' .. '9'}:
      inc j
    best = max(best, j - i)
  if best == 0:
    return 0
  var j = i + best
  if s.at(j) in {'E', 'e'}:
    var k = j + 1
    if s.at(k) in {'+', '-'}:
      inc k
    if s.at(k) in {'0' .. '9'}:
      while s.at(k) in {'0' .. '9'}:
        inc k
      j = k
  j - i

proc matchPath(s: string; i: int): int =
  ## ``{PATH_CHAR}*(\/{PATH_CHAR}+)+\/?``
  var j = i
  while s.at(j) in PathChars:
    inc j
  var groups = 0
  while s.at(j) == '/' and s.at(j + 1) in PathChars:
    inc j
    while s.at(j) in PathChars:
      inc j
    inc groups
  if groups == 0:
    return 0
  if s.at(j) == '/':
    inc j
  j - i

proc matchPathSegInterp(s: string; i: int): int =
  ## ``{PATH_SEG}\$\{`` with ``PATH_SEG = {PATH_CHAR}*\/``
  var j = i
  while s.at(j) in PathChars:
    inc j
  if s.at(j) == '/' and s.at(j + 1) == '$' and s.at(j + 2) == '{':
    return j + 3 - i
  0

proc matchHPath(s: string; i: int): int =
  ## ``\~(\/{PATH_CHAR}+)+\/?``
  if s.at(i) != '~':
    return 0
  var j = i + 1
  var groups = 0
  while s.at(j) == '/' and s.at(j + 1) in PathChars:
    inc j
    while s.at(j) in PathChars:
      inc j
    inc groups
  if groups == 0:
    return 0
  if s.at(j) == '/':
    inc j
  j - i

proc matchHPathStartInterp(s: string; i: int): int =
  if s.at(i) == '~' and s.at(i + 1) == '/' and s.at(i + 2) == '$' and
      s.at(i + 3) == '{':
    return 4
  0

proc matchSPath(s: string; i: int): int =
  ## ``\<{PATH_CHAR}+(\/{PATH_CHAR}+)*\>``
  if s.at(i) != '<' or s.at(i + 1) notin PathChars:
    return 0
  var j = i + 1
  while s.at(j) in PathChars:
    inc j
  while s.at(j) == '/' and s.at(j + 1) in PathChars:
    inc j
    while s.at(j) in PathChars:
      inc j
  if s.at(j) != '>':
    return 0
  j + 1 - i

proc matchUri(s: string; i: int): int =
  if s.at(i) notin {'a' .. 'z', 'A' .. 'Z'}:
    return 0
  var j = i + 1
  while s.at(j) in UriSchemeChars:
    inc j
  if s.at(j) != ':' or s.at(j + 1) notin UriChars:
    return 0
  inc j
  while s.at(j) in UriChars:
    inc j
  j - i

proc matchOp(s: string; i: int): int =
  for op in MultiCharOps:
    if s.continuesWith(op, i):
      return op.len
  if i < s.len: 1 else: 0

proc lexNix(src: string): seq[NixTok] =
  ## Raises ``LexError`` on anything Nix's lexer would reject or that this
  ## one cannot classify.
  var stack = @[lsDefault]
  var i = 0
  var line = 1
  var lineStart = 0
  template col(): int = i - lineStart + 1
  template fail(msg: string) =
    raise newException(LexError, $line & ":" & $col() & ": " & msg)
  proc advanceLines(s: string; fromIdx, toIdx: int; line, lineStart: var int) =
    for k in fromIdx ..< toIdx:
      if s[k] == '\n':
        inc line
        lineStart = k + 1
  template emit(k: NixTokKind; t: string) =
    result.add(NixTok(kind: k, text: t, line: line, col: col()))
  template consume(n: int) =
    advanceLines(src, i, i + n, line, lineStart)
    i += n

  while i < src.len:
    case stack[^1]
    of lsString:
      var part = ""
      let startLine = line
      let startCol = col()
      while true:
        if i >= src.len:
          fail("unterminated string")
        let c = src[i]
        if c == '"':
          break
        if c == '\\':
          if i + 1 >= src.len:
            fail("unterminated string")
          let e = src[i + 1]
          part.add(case e
            of 'n': '\n'
            of 'r': '\r'
            of 't': '\t'
            else: e)
          consume(2)
        elif c == '$':
          let n = src.at(i + 1)
          if n == '{':
            break
          elif n == '\\':
            part.add('$')
            if i + 2 >= src.len:
              fail("unterminated string")
            let e = src[i + 2]
            part.add(case e
              of 'n': '\n'
              of 'r': '\r'
              of 't': '\t'
              else: e)
            consume(3)
          elif n == '"' or n == '\0':
            part.add('$')
            consume(1)
          else:
            # ``\$[^\{\"\\]``: the dollar and the next byte are literal,
            # so ``$${`` is the text ``$${`` and not an interpolation.
            part.add('$')
            part.add(n)
            consume(2)
        else:
          part.add(c)
          consume(1)
      if part.len > 0:
        result.add(NixTok(kind: ntStrPart, text: part, line: startLine,
          col: startCol))
      if src[i] == '"':
        emit(ntStrClose, "\"")
        consume(1)
        discard stack.pop()
      else:
        emit(ntInterp, "${")
        consume(2)
        stack.add(lsDefault)
    of lsIndString:
      var part = ""
      let startLine = line
      let startCol = col()
      var closed = false
      var interp = false
      while true:
        if i >= src.len:
          fail("unterminated indented string")
        let c = src[i]
        if c == '\'' and src.at(i + 1) == '\'':
          let n = src.at(i + 2)
          if n == '$':
            part.add('$')
            consume(3)
          elif n == '\'':
            part.add("''")
            consume(3)
          elif n == '\\':
            if i + 3 >= src.len:
              fail("unterminated indented string")
            let e = src[i + 3]
            part.add(case e
              of 'n': '\n'
              of 'r': '\r'
              of 't': '\t'
              else: e)
            consume(4)
          else:
            closed = true
            break
        elif c == '$':
          let n = src.at(i + 1)
          if n == '{':
            interp = true
            break
          elif n == '\'' or n == '\0':
            part.add('$')
            consume(1)
          else:
            part.add('$')
            part.add(n)
            consume(2)
        else:
          part.add(c)
          consume(1)
      if part.len > 0:
        result.add(NixTok(kind: ntStrPart, text: part, indented: true,
          line: startLine, col: startCol))
      if closed:
        result.add(NixTok(kind: ntStrClose, text: "''", indented: true,
          line: line, col: col()))
        consume(2)
        discard stack.pop()
      elif interp:
        emit(ntInterp, "${")
        consume(2)
        stack.add(lsDefault)
    of lsDefault:
      let c = src[i]
      if c in {' ', '\t', '\r', '\n'}:
        consume(1)
        continue
      if c == '#':
        var j = i
        while j < src.len and src[j] notin {'\r', '\n'}:
          inc j
        consume(j - i)
        continue
      if c == '/' and src.at(i + 1) == '*':
        let close = src.find("*/", i + 2)
        if close < 0:
          fail("unterminated block comment")
        consume(close + 2 - i)
        continue
      if ord(c) >= 0x80 or (ord(c) < 0x20):
        fail("byte 0x" & toHex(ord(c), 2) & " outside a string or comment")
      # Longest match, ties to the earlier Nix lexer rule.
      let idLen = matchId(src, i)
      let intLen = matchInt(src, i)
      let floatLen = matchFloat(src, i)
      let pathSegInterpLen = max(matchPathSegInterp(src, i),
        matchHPathStartInterp(src, i))
      let pathLen = matchPath(src, i)
      let hpathLen = matchHPath(src, i)
      let spathLen = matchSPath(src, i)
      let uriLen = matchUri(src, i)
      let opLen =
        block:
          var n = 0
          for op in MultiCharOps:
            if src.continuesWith(op, i):
              n = op.len
              break
          n
      var best = 0
      var which = ""
      template consider(n: int; name: string) =
        if n > best:
          best = n
          which = name
      consider(opLen, "op")
      consider(idLen, "id")
      consider(intLen, "int")
      consider(floatLen, "float")
      if src.continuesWith("${", i): consider(2, "interp")
      if c == '}': consider(1, "rbrace")
      if c == '{': consider(1, "lbrace")
      if c == '"': consider(1, "str")
      if src.continuesWith("''", i): consider(2, "ind")
      consider(pathSegInterpLen, "pathseginterp")
      consider(pathLen, "path")
      consider(hpathLen, "hpath")
      consider(spathLen, "spath")
      consider(uriLen, "uri")
      if best == 0:
        consider(matchOp(src, i), "op")
      let text = src[i ..< i + best]
      case which
      of "id": emit(ntId, text)
      of "int": emit(ntInt, text)
      of "float": emit(ntFloat, text)
      of "interp":
        emit(ntInterp, text)
        stack.add(lsDefault)
      of "rbrace":
        if stack.len <= 1:
          fail("unbalanced '}'")
        emit(ntRBrace, text)
        discard stack.pop()
      of "lbrace":
        emit(ntLBrace, text)
        stack.add(lsDefault)
      of "str":
        emit(ntStrOpen, text)
        stack.add(lsString)
      of "ind":
        result.add(NixTok(kind: ntStrOpen, text: "''", indented: true,
          line: line, col: col()))
        stack.add(lsIndString)
        # ``\'\'(\ *\n)?`` -- the opening swallows spaces and one newline.
        var j = i + 2
        while src.at(j) == ' ':
          inc j
        if src.at(j) == '\n':
          consume(j + 1 - i)
          continue
      of "pathseginterp":
        var t = NixTok(kind: ntPath, text: text, interpolated: true,
          line: line, col: col())
        if text.startsWith("~"):
          t.kind = ntHPath
        result.add(t)
        # The interpolation's DEFAULT body follows; the path's remaining
        # segments are refused with it, so they need no further lexing
        # beyond the balance of the braces.
        stack.add(lsDefault)
      of "path", "hpath":
        var t = NixTok(kind: (if which == "path": ntPath else: ntHPath),
          text: text, line: line, col: col())
        if src.continuesWith("${", i + best):
          t.interpolated = true
          result.add(t)
          consume(best + 2)
          stack.add(lsDefault)
          continue
        if text.endsWith("/"):
          fail("path has a trailing slash: " & text)
        result.add(t)
      of "spath": emit(ntSPath, text)
      of "uri": emit(ntUri, text)
      else:
        let kind =
          case text
          of "(": ntLParen
          of ")": ntRParen
          of "[": ntLBracket
          of "]": ntRBracket
          else: ntOp
        emit(kind, text)
      if which == "ind":
        consume(2)
      elif which == "pathseginterp":
        consume(best)
      else:
        consume(best)
  if stack.len != 1:
    raise newException(LexError, $line & ":" & $(i - lineStart + 1) &
      ": unterminated " & (case stack[^1]
        of lsString: "string"
        of lsIndString: "indented string"
        of lsDefault: "brace or interpolation"))

# ---------------------------------------------------------------------------
# Classification
# ---------------------------------------------------------------------------

proc isImpureBuiltin(name: string): bool =
  let bare = if name.startsWith("__"): name[2 .. ^1] else: name
  bare in ImpureBuiltins

proc isPathDeriving(name: string): bool =
  let bare = if name.startsWith("__"): name[2 .. ^1] else: name
  bare in PathDerivingBuiltins

proc isFetcher(name: string): bool =
  name.startsWith("fetch") or name.startsWith("__fetch")

proc isHex(value: string; lens: openArray[int]): bool =
  if value.len notin lens:
    return false
  for ch in value:
    if ch notin {'0' .. '9', 'a' .. 'f', 'A' .. 'F'}:
      return false
  true

proc matchingClose(toks: seq[NixTok]; openIdx: int): int =
  ## Index of the token closing the group opened at ``openIdx`` (``{``,
  ## ``(``, ``[`` or ``${``), or -1.
  var depth = 0
  for k in openIdx ..< toks.len:
    case toks[k].kind
    of ntLBrace, ntInterp, ntLParen, ntLBracket:
      inc depth
    of ntRBrace, ntRParen, ntRBracket:
      dec depth
      if depth == 0:
        return k
    else:
      discard
  -1

proc literalString(toks: seq[NixTok]; a, b: int): tuple[ok: bool; text: string] =
  ## Tokens ``a ..< b`` are exactly one string literal with no
  ## interpolation.
  if b - a < 2 or toks[a].kind != ntStrOpen or toks[b - 1].kind != ntStrClose:
    return
  var text = ""
  for k in a + 1 ..< b - 1:
    if toks[k].kind != ntStrPart:
      return
    text.add(toks[k].text)
  (ok: true, text: text)

proc fetcherAttrsFixed(toks: seq[NixTok]; openIdx: int;
                       fetcher: string): bool =
  ## The attribute set opened at ``openIdx`` binds, at its own level, a hash
  ## attribute to a non-empty literal string or ``rev`` to a literal 40/64
  ## hex commit (for ``fetchTree``, only with a literal ``type`` whose
  ## ``rev`` locks the content -- see ``TreeFetcherLockingTypes``).
  let closeIdx = matchingClose(toks, openIdx)
  if closeIdx < 0:
    return false
  let bare = if fetcher.startsWith("__"): fetcher[2 .. ^1] else: fetcher
  var revFixed = false
  var treeTypeLocks = false
  var k = openIdx + 1
  while k < closeIdx:
    # One binding: ``attrpath = value ;`` or ``inherit ... ;``.
    var eq = -1
    var semi = -1
    var depth = 0
    var j = k
    while j < closeIdx:
      case toks[j].kind
      of ntLBrace, ntInterp, ntLParen, ntLBracket:
        inc depth
      of ntRBrace, ntRParen, ntRBracket:
        dec depth
      of ntOp:
        if depth == 0 and toks[j].text == "=" and eq < 0:
          eq = j
        elif depth == 0 and toks[j].text == ";":
          semi = j
          break
      else:
        discard
      inc j
    if semi < 0:
      return false
    if eq > k and eq == k + 1 and toks[k].kind == ntId:
      let name = toks[k].text
      let value = literalString(toks, eq + 1, semi)
      if value.ok:
        if name in HashAttributes and value.text.strip().len > 0:
          return true
        if name == "rev" and value.text.isHex([40, 64]):
          revFixed = true
        if name == "type" and value.text in TreeFetcherLockingTypes:
          treeTypeLocks = true
    k = semi + 1
  revFixed and (bare != "fetchTree" or treeTypeLocks)

proc builtinsSelectedByName(toks: seq[NixTok]; idx: int): bool =
  ## ``builtins`` at ``idx`` is used only to select a builtin by a literal
  ## name -- ``builtins.name``, ``with builtins;``, ``inherit (builtins)
  ## name ...;`` -- so every builtin it reaches is an identifier the
  ## impure-builtin rule sees. Anything else (``getAttr n builtins``,
  ## ``let b = builtins; in b.${n}``) reaches a builtin by a computed name.
  let next = if idx + 1 < toks.len: toks[idx + 1] else: NixTok(kind: ntOp)
  let prev = if idx > 0: toks[idx - 1] else: NixTok(kind: ntOp)
  if next.kind == ntOp and next.text == "." and idx + 2 < toks.len and
      toks[idx + 2].kind == ntId:
    return true
  if prev.kind == ntId and prev.text == "with" and next.kind == ntOp and
      next.text == ";":
    return true
  if prev.kind == ntLParen and idx >= 2 and toks[idx - 2].kind == ntId and
      toks[idx - 2].text == "inherit" and next.kind == ntRParen:
    return true
  false

proc scanNix*(src: string): NixScan =
  ## Every path literal ``src`` names and every construct that makes it
  ## uncacheable. Pure: reads nothing but ``src``.
  var toks: seq[NixTok]
  try:
    toks = lexNix(src)
  except LexError as error:
    result.refusals.add(error.msg)
    return
  # ``inherit`` names, split by where the ``inherit`` stands: in a ``let``
  # it BINDS the names in scope, so every later use is an identifier the
  # rules below see; in an attribute set it puts the VALUE into the set,
  # where ``mapAttrs`` / ``attrValues`` / ``s.${n}`` reach it by no name.
  var letInheritNames = initHashSet[int]()
  var setInheritNames = initHashSet[int]()
  block:
    var context: seq[string] = @[]
    for idx, tok in toks:
      case tok.kind
      of ntLBrace, ntInterp, ntLParen, ntLBracket:
        context.add("group")
      of ntRBrace, ntRParen, ntRBracket:
        while context.len > 0 and context[^1] == "let":
          discard context.pop() # a ``let`` never closed by ``in``: malformed
        if context.len > 0:
          discard context.pop()
      of ntId:
        if tok.text == "let" and not (idx + 1 < toks.len and
            toks[idx + 1].kind == ntLBrace):
          context.add("let")
        elif tok.text == "in" and context.len > 0 and context[^1] == "let":
          discard context.pop()
        elif tok.text == "inherit":
          let inLet = context.len > 0 and context[^1] == "let"
          var k = idx + 1
          if k < toks.len and toks[k].kind == ntLParen:
            let close = matchingClose(toks, k)
            if close < 0:
              continue
            k = close + 1
          while k < toks.len and
              not (toks[k].kind == ntOp and toks[k].text == ";"):
            if inLet: letInheritNames.incl(k) else: setInheritNames.incl(k)
            inc k
      else:
        discard
  proc opAt(toks: seq[NixTok]; k: int; texts: openArray[string]): bool =
    k >= 0 and k < toks.len and toks[k].kind == ntOp and toks[k].text in texts
  proc kindAt(toks: seq[NixTok]; k: int): NixTokKind =
    if k >= 0 and k < toks.len: toks[k].kind else: ntOp
  proc nameSite(toks: seq[NixTok]; idx: int): bool =
    ## The identifier at ``idx`` is a NAME being bound, not a use: a binding
    ## (``fetchurl = ...;``), a lambda parameter (``fetchurl: ...``,
    ## ``fetchurl@{...}:``), or a formal (``{ fetchurl, ... }``,
    ## ``{ fetchurl ? d }``). A formal's DEFAULT value (``{ f ? fetchurl }``)
    ## is a use.
    if opAt(toks, idx + 1, ["=", ":", "@"]):
      return true
    let formalStart = kindAt(toks, idx - 1) == ntLBrace or
      opAt(toks, idx - 1, [","])
    formalStart and (kindAt(toks, idx + 1) == ntRBrace or
      opAt(toks, idx + 1, [",", "?"]))
  proc fetcherCall(toks: seq[NixTok]; a, b: int): bool =
    ## Tokens ``a ..< b`` are exactly ``name(.name)* { ... }`` with a
    ## fetcher as the last name (whose own rule then checks the set).
    var k = a
    if kindAt(toks, k) != ntId:
      return false
    while opAt(toks, k + 1, ["."]) and kindAt(toks, k + 2) == ntId:
      k += 2
    if not toks[k].text.isFetcher or kindAt(toks, k + 1) != ntLBrace:
      return false
    matchingClose(toks, k + 1) == b - 1
  proc lambdaStart(toks: seq[NixTok]; a: int): bool =
    if kindAt(toks, a) == ntId and opAt(toks, a + 1, [":", "@"]):
      return true
    if kindAt(toks, a) == ntLBrace:
      let close = matchingClose(toks, a)
      return close > 0 and opAt(toks, close + 1, [":", "@"])
    false
  proc evaluatedParenPath(toks: seq[NixTok]; idx: int): bool =
    ## ``import (./x)``: the path at ``idx`` is the whole argument.
    kindAt(toks, idx - 1) == ntLParen and kindAt(toks, idx + 1) == ntRParen and
      kindAt(toks, idx - 2) == ntId and toks[idx - 2].text in EvaluatingCallers
  template refuse(tok: NixTok; msg: string) =
    result.refusals.add($tok.line & ":" & $tok.col & ": " & msg)
  # A computed evaluation target is reported AFTER every other refusal, so
  # ``import (dirOf ./. + ...)`` still names the construct that reaches the
  # hidden file rather than the ``import`` around it.
  var deferred: seq[string] = @[]
  template refuseAfter(tok: NixTok; msg: string) =
    deferred.add($tok.line & ":" & $tok.col & ": " & msg)
  for idx, tok in toks:
    case tok.kind
    of ntSPath:
      refuse(tok, "search-path lookup " & tok.text &
        " (resolved through the ambient NIX_PATH)")
    of ntHPath:
      refuse(tok, "home-relative path " & tok.text & " (resolved through $HOME)")
    of ntPath:
      if tok.interpolated:
        refuse(tok, "interpolated path " & tok.text & "${...}")
      else:
        let evaluated = (idx > 0 and toks[idx - 1].kind == ntId and
          toks[idx - 1].text in EvaluatingCallers) or
          evaluatedParenPath(toks, idx)
        result.refs.add(NixPathRef(text: tok.text, evaluated: evaluated,
          line: tok.line, col: tok.col))
    of ntId:
      if tok.text.isImpureBuiltin:
        refuse(tok, "impure builtin " & tok.text)
      elif tok.text in ImpureDerivationAttributes:
        refuse(tok, "derivation attribute " & tok.text &
          " (the build depends on the host, not on the closure)")
      elif tok.text.isPathDeriving:
        refuse(tok, "path-deriving builtin " & tok.text &
          " (reaches files no literal names)")
      elif tok.text == "builtins" and idx + 2 < toks.len and
          toks[idx + 1].kind == ntOp and toks[idx + 1].text == "." and
          toks[idx + 2].kind in {ntInterp, ntStrOpen}:
        refuse(tok, "dynamic attribute access on builtins")
      elif tok.text == "builtins" and not builtinsSelectedByName(toks, idx):
        refuse(tok, "builtins used as a value (a builtin reachable by a " &
          "computed name)")
      elif (tok.text.isFetcher or tok.text in EvaluatingCallers) and
          idx notin letInheritNames and not nameSite(toks, idx):
        let next = kindAt(toks, idx + 1)
        if idx in setInheritNames:
          refuse(tok, tok.text & " placed in an attribute set by inherit " &
            "(called there by no name the scanner sees)")
        elif tok.text.isFetcher:
          if next == ntLBrace:
            if not fetcherAttrsFixed(toks, idx + 1, tok.text):
              refuse(tok, "fetcher " & tok.text &
                " without a literal fixed hash or commit")
          else:
            refuse(tok, "fetcher " & tok.text &
              " not called with a literal attribute set")
        elif tok.text == "scopedImport":
          # Its target is the SECOND argument; never classified.
          refuse(tok, "scopedImport (evaluates a target not classified)")
        elif next in {ntPath, ntSPath, ntHPath}:
          # ``import ./x``: the path rule marks it evaluated (or, for an
          # interpolated / search / home path, refuses it itself).
          discard
        elif next == ntStrOpen and kindAt(toks, idx + 2) == ntStrPart and
            (if toks[idx + 1].indented:
              toks[idx + 2].text.strip(trailing = false)
            else: toks[idx + 2].text).startsWith("/"):
          discard # refused by the string rule below, with its own reason
        elif next == ntLParen:
          # The target must be a literal path or a fixed fetch; a
          # callPackage may also take a function literal.
          let close = matchingClose(toks, idx + 1)
          let ok = close > idx + 1 and (
            (close == idx + 3 and toks[idx + 2].kind == ntPath) or
            fetcherCall(toks, idx + 2, close) or
            (tok.text != "import" and lambdaStart(toks, idx + 2)))
          if not ok:
            refuseAfter(tok, tok.text & " of a computed target (a file it " &
              "evaluates is not scanned)")
        else:
          # ``import p``, ``map import``, ``let i = import;``: the target is
          # a value the scanner cannot follow -- a non-.nix file it names
          # would be evaluated unscanned.
          refuseAfter(tok, tok.text & " of a computed target (a file it " &
            "evaluates is not scanned)")
    of ntStrOpen:
      if idx + 1 < toks.len and toks[idx + 1].kind == ntStrPart:
        let first =
          if tok.indented: toks[idx + 1].text.strip(trailing = false)
          else: toks[idx + 1].text
        if first.startsWith("/"):
          refuse(tok, "string literal beginning with '/' (evaluation may " &
            "coerce it to an absolute path)")
    of ntOp:
      # ``path + "string"`` is a path: ``./. + "-other/x.nix"`` names a
      # SIBLING of the directory the closure hashed. Whether the left
      # operand is a path is a type question, so only a left operand that is
      # syntactically a string or a number is accepted.
      if tok.text == "+" and (idx == 0 or
          toks[idx - 1].kind notin {ntStrClose, ntInt, ntFloat, ntUri}):
        refuse(tok, "'+' after an operand that may be a path (a path " &
          "extended by a string names a file outside the closure)")
    else:
      discard
  result.refusals.add(deferred)

# ---------------------------------------------------------------------------
# Closure
# ---------------------------------------------------------------------------

proc lexicalNormalize(path: string): string =
  ## Absolute path, ``.`` and ``..`` removed lexically (Nix's ``canonPath``
  ## does the same; it does not follow links), ``/``-separated. "" when
  ## ``..`` climbs above the filesystem root.
  let unified = path.replace('\\', '/')
  var prefix = ""
  var rest = unified
  when defined(windows):
    if rest.len >= 2 and rest[1] == ':':
      prefix = rest[0 .. 1]
      rest = rest[2 .. ^1]
    elif rest.startsWith("//"):
      # UNC: keep the server and share.
      let parts = rest[2 .. ^1].split('/')
      if parts.len < 2:
        return ""
      prefix = "//" & parts[0] & "/" & parts[1]
      rest = "/" & parts[2 .. ^1].join("/")
  var stack: seq[string] = @[]
  for part in rest.split('/'):
    if part.len == 0 or part == ".":
      continue
    if part == "..":
      if stack.len == 0:
        return ""
      discard stack.pop()
    else:
      stack.add(part)
  prefix & "/" & stack.join("/")

proc sameOrInside(path, root: string): bool =
  when defined(windows):
    let p = path.toLowerAscii
    let r = root.toLowerAscii
  else:
    let p = path
    let r = root
  p == r or p.startsWith(if r.endsWith("/"): r else: r & "/")

proc relativeTo(path, root: string): string =
  if path.len == root.len:
    return "."
  path[(if root.endsWith("/"): root.len else: root.len + 1) .. ^1]

proc nativePath(path: string): string =
  when defined(windows): path.replace('/', '\\') else: path

proc findProjectRoot*(start: string): string =
  ## The nearest ancestor of ``start`` (inclusive) that holds a ``.git``
  ## entry (a directory, or the file a worktree / submodule has), normalized
  ## like ``lexicalNormalize``; "" when there is none.
  var dir = lexicalNormalize(absolutePath(start))
  while dir.len > 0:
    let marker = nativePath(dir) / ".git"
    if dirExists(extendedPath(marker)) or fileExists(extendedPath(marker)):
      return dir
    let parent = lexicalNormalize(dir & "/..")
    if parent.len == 0 or parent == dir:
      return ""
    dir = parent
  ""

type
  ClosureBuilder = object
    root: string
    entries: Table[string, NixClosureEntry]
    scanned: HashSet[string]
    queue: seq[tuple[path: string; forceNix: bool]]
    files: int
    bytes: int64
    nixFiles: int
    refusal: string

proc refuseWith(b: var ClosureBuilder; msg: string) =
  if b.refusal.len == 0:
    b.refusal = msg

proc foldKey(path: string): string =
  when defined(windows): path.toLowerAscii else: path

proc isLink(path: string): bool =
  try:
    getFileInfo(extendedPath(nativePath(path)), followSymlink = false).kind in
      {pcLinkToFile, pcLinkToDir}
  except OSError:
    false

proc linkBelowRoot(b: ClosureBuilder; path: string): string =
  ## The first component strictly below the root that is a link, or "".
  let rel = relativeTo(path, b.root)
  if rel == ".":
    return ""
  var current = b.root
  for part in rel.split('/'):
    current = (if current.endsWith("/"): current & part else: current & "/" & part)
    if isLink(current):
      return current
  ""

proc executableBit(path: string): bool =
  when defined(posix):
    try:
      {fpUserExec, fpGroupExec, fpOthersExec} * getFilePermissions(
        extendedPath(path)) != {}
    except OSError:
      false
  else:
    false

proc hashFile(b: var ClosureBuilder; path: string): string =
  inc b.files
  let size = getFileSize(extendedPath(nativePath(path)))
  b.bytes += size
  if b.files > MaxClosureFiles or b.bytes > MaxClosureBytes:
    b.refuseWith("closure exceeds " & $MaxClosureFiles & " files / " &
      $MaxClosureBytes & " bytes")
    return ""
  blake3.toHex(blake3.digest(readFile(extendedPath(nativePath(path)))))

proc framed(payload: var string; value: string) =
  payload.add($value.len)
  payload.add(':')
  payload.add(value)
  payload.add('\n')

proc hashDirectory(b: var ClosureBuilder; dir: string): string =
  ## Names, kinds, bytes (and the executable bit on POSIX) of the whole tree;
  ## queues every ``*.nix`` inside for scanning. Refuses a link or a special
  ## file anywhere inside.
  var children: seq[tuple[name: string; kind: PathComponent]] = @[]
  try:
    for kind, name in walkDir(extendedPath(nativePath(dir)), relative = true,
        checkDir = true):
      children.add((name: name, kind: kind))
  except OSError as error:
    b.refuseWith("cannot list directory " & relativeTo(dir, b.root) & ": " &
      error.msg)
    return ""
  children.sort(proc (x, y: auto): int = cmp(x.name, y.name))
  var payload = ""
  payload.framed("dir")
  payload.framed($children.len)
  for child in children:
    if b.refusal.len > 0:
      return ""
    let path = dir & "/" & child.name
    var kind: PathComponent
    try:
      kind = getFileInfo(extendedPath(nativePath(path)),
        followSymlink = false).kind
    except OSError as error:
      b.refuseWith("cannot stat " & relativeTo(path, b.root) & ": " &
        error.msg)
      return ""
    case kind
    of pcLinkToFile, pcLinkToDir:
      b.refuseWith("link inside a hashed directory: " &
        relativeTo(path, b.root))
      return ""
    of pcDir:
      payload.framed(child.name)
      payload.framed("d")
      payload.framed(b.hashDirectory(path))
    of pcFile:
      payload.framed(child.name)
      payload.framed(if executableBit(path): "x" else: "f")
      payload.framed(b.hashFile(path))
      if child.name.endsWith(".nix"):
        b.queue.add((path: path, forceNix: false))
  blake3.toHex(blake3.digest(payload))

proc visit(b: var ClosureBuilder; path: string; forceNix: bool) =
  ## Bind ``path`` (normalized, inside the root) into the closure.
  let key = foldKey(path)
  let rel = relativeTo(path, b.root)
  let link = b.linkBelowRoot(path)
  if link.len > 0:
    b.refuseWith("link or junction on the path of " & rel & ": " &
      relativeTo(link, b.root))
    return
  let native = extendedPath(nativePath(path))
  if b.entries.hasKey(key):
    if forceNix and b.entries[key].kind in {nceFile, nceExecutableFile}:
      b.queue.add((path: path, forceNix: true))
    return
  if dirExists(native):
    b.entries[key] = NixClosureEntry(relativePath: rel, kind: nceDirectory)
    let digest = b.hashDirectory(path)
    b.entries[key].digest = digest
  elif fileExists(native):
    var info: FileInfo
    try:
      info = getFileInfo(native, followSymlink = false)
    except OSError as error:
      b.refuseWith("cannot stat " & rel & ": " & error.msg)
      return
    if info.kind != pcFile or info.isSpecial:
      b.refuseWith("not a regular file: " & rel)
      return
    b.entries[key] = NixClosureEntry(relativePath: rel,
      kind: (if executableBit(path): nceExecutableFile else: nceFile),
      digest: b.hashFile(path))
    if forceNix or path.endsWith(".nix"):
      b.queue.add((path: path, forceNix: true))
  else:
    # Absent: bound as absent, so creating it later moves the digest.
    # (``builtins.pathExists ./x`` is a legitimate read of an absence.)
    b.entries[key] = NixClosureEntry(relativePath: rel, kind: nceMissing)

proc scanInto(b: var ClosureBuilder; path: string) =
  let key = foldKey(path)
  if key in b.scanned:
    return
  b.scanned.incl(key)
  inc b.nixFiles
  if b.nixFiles > MaxScannedNixFiles:
    b.refuseWith("closure scans more than " & $MaxScannedNixFiles &
      " Nix files")
    return
  let rel = relativeTo(path, b.root)
  let scan = scanNix(readFile(extendedPath(nativePath(path))))
  if scan.refusals.len > 0:
    b.refuseWith(rel & ":" & scan.refusals[0])
    return
  let dir = lexicalNormalize(path & "/..")
  for reference in scan.refs:
    var target = ""
    if reference.text.startsWith("/"):
      when defined(windows):
        b.refuseWith(rel & ":" & $reference.line & ":" & $reference.col &
          ": absolute path literal " & reference.text &
          " (names nothing Nix can read on this host)")
        return
      else:
        target = lexicalNormalize(reference.text)
    else:
      target = lexicalNormalize(dir & "/" & reference.text)
    if target.len == 0 or not target.sameOrInside(b.root):
      b.refuseWith(rel & ":" & $reference.line & ":" & $reference.col &
        ": path " & reference.text & " escapes the project root " & b.root)
      return
    b.visit(target, reference.evaluated)
    if b.refusal.len > 0:
      return

proc closureDigest(c: NixExpressionClosure): string =
  var payload = ""
  payload.framed(ClosureDomain)
  payload.framed(c.root)
  payload.framed(relativeTo(c.expressionFile, c.root))
  payload.framed($c.entries.len)
  for entry in c.entries:
    payload.framed(entry.relativePath)
    payload.framed($entry.kind)
    payload.framed(entry.digest)
  blake3.toHex(blake3.digest(payload))

proc nixExpressionClosure*(expressionFile: string): NixExpressionClosure =
  ## The closure of ``expressionFile`` (a relative path is taken against the
  ## current directory, as ``nix build --file`` takes it). See the module
  ## documentation for what is bound and what is refused.
  let top = lexicalNormalize(absolutePath(expressionFile))
  result.expressionFile = top
  if top.len == 0:
    result.reason = "expression path escapes the filesystem root"
    return
  let root = findProjectRoot(lexicalNormalize(top & "/.."))
  if root.len == 0:
    result.reason = "no project root (.git) above " & top
    return
  result.root = root
  var b = ClosureBuilder(root: root)
  try:
    b.visit(top, true)
    if dirExists(extendedPath(nativePath(top))) and b.refusal.len == 0:
      # ``nix build --file DIR`` evaluates ``DIR/default.nix``.
      b.queue.add((path: top & "/default.nix", forceNix: true))
      b.visit(top & "/default.nix", true)
    while b.refusal.len == 0 and b.queue.len > 0:
      let next = b.queue.pop()
      if fileExists(extendedPath(nativePath(next.path))):
        b.scanInto(next.path)
  except CatchableError as error:
    b.refuseWith("closure read failed: " & error.msg)
  if b.refusal.len > 0:
    result.reason = b.refusal
    return
  for entry in b.entries.values:
    result.entries.add(entry)
  result.entries.sort(proc (x, y: NixClosureEntry): int =
    cmp(x.relativePath, y.relativePath))
  result.cacheable = true
  result.digest = closureDigest(result)

proc uncacheableNonce(): string =
  var bytes: array[16, byte]
  if not urandom(bytes):
    raise newException(OSError, "urandom failed")
  for b in bytes:
    result.add(toHex(int(b), 2).toLowerAscii)

proc nixExpressionClosureKey*(closure: NixExpressionClosure): string =
  ## What a cache key binds for an expression: ``closure-v1:<digest>`` when
  ## cacheable, else ``uncacheable:<reason>:<nonce>`` -- a fresh random
  ## nonce per call, so a key that binds it never equals any other key,
  ## including itself computed again: every lookup misses.
  if closure.cacheable:
    "closure-v1:" & closure.digest
  else:
    "uncacheable:" & closure.reason & ":" & uncacheableNonce()

proc nixExpressionClosureKey*(expressionFile: string): string =
  nixExpressionClosureKey(nixExpressionClosure(expressionFile))

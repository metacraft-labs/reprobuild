## Mutable local Nix source cannot supply a reusable evaluation identity.
## The helper's known flake files do not describe its imported read closure;
## retain fresh evaluation until evaluator-owned identities replace this rule.
##
## Whether a selector reads mutable local source depends on its text AND on
## the workspace Nix runs in: Nix falls back to reading a selector its URL
## parser or fetcher rejects as a path relative to its working directory, so
## both procs below take that directory (``workspaceRoot``).
import std/[os, strutils]

when defined(posix):
  import std/posix

proc nixSelectorScheme(value: string): string =
  ## The URL scheme of a flake reference, lower-cased, or "" when the
  ## reference has none (a path or a registry name).
  if value.len == 0 or value[0] notin Letters:
    return ""
  for i in 1 ..< value.len:
    let c = value[i]
    if c == ':':
      return value[0 ..< i].toLowerAscii()
    if c notin Letters + Digits + {'+', '.', '-'}:
      return ""
  ""

const
  NixFragmentChars = Letters + Digits +
    {'.', '_', '~', '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=',
     ':', '@', '/', '?', ' ', '"', '^', '-'}
    ## Nix's URL fragment characters: RFC 3986 pchar plus `/ ? " ^` and
    ## space (`fragmentRegex` in Nix's url-parts.hh); `%` is allowed only as
    ## the start of a `%HH` escape.
  NixUrlChars = Letters + Digits +
    {'.', '_', '~', '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=',
     ':', '@', '/', '?', '#', '%', '^', '-'}
    ## Characters a URL reference may carry without Nix's URL parser
    ## rejecting it and falling back to reading the string as a path.

proc isNixFragment(value: string): bool =
  var i = 0
  while i < value.len:
    if value[i] == '%':
      if i + 2 >= value.len or value[i + 1] notin HexDigits or
          value[i + 2] notin HexDigits:
        return false
      i += 3
    elif value[i] in NixFragmentChars:
      inc i
    else:
      return false
  true

proc isNixRegistryReference(value: string): bool =
  ## Nix's flake-registry reference (`parseFlakeIdRef`): its flake-id regex
  ## `[A-Za-z][A-Za-z0-9_-]*`, an optional `/ref` whose characters may
  ## include `/`, then an optional `#fragment`. There is no `?query`: Nix
  ## reads `id?dir=x#y` as a path.
  let hashAt = value.find('#')
  let base = if hashAt < 0: value else: value[0 ..< hashAt]
  if hashAt >= 0 and not isNixFragment(value[hashAt + 1 .. ^1]):
    return false
  if base.len == 0 or base[0] notin Letters:
    return false
  var i = 1
  while i < base.len and base[i] in Letters + Digits + {'_', '-'}:
    inc i
  if i == base.len:
    return true
  if base[i] != '/' or i + 1 >= base.len or
      base[i + 1] notin Letters + Digits + {'@'}:
    return false
  for c in base[i + 2 .. ^1]:
    if c notin Letters + Digits + {'_', '.', '/', '@', '+', '-'}:
      return false
  true

proc isMutableLocalNixSelectorText*(selector: string): bool =
  ## The TEXT half of ``isMutableLocalNixSelector``: what the selector string
  ## alone proves local.
  ## Local is decided by where the source is read from, not by a list of
  ## flake types (Foreign-Provisioning-And-Nix-Evaluation-Daemon.md §3
  ## item 4). Nix tries each reading of a reference in turn and, when the
  ## registry and URL readings fail, reads it as a path relative to its
  ## working directory (the workspace). So "remote" is decided positively,
  ## from the exact string `nix` receives (nothing is stripped first):
  ## - a reference with no scheme is remote only when the whole string is a
  ##   registry reference (`id`, `id/ref`, `id/ref/rev`, optional
  ##   `#fragment`, no `?query`); `sub/#x`, `sub.d#x`, `id?dir=x#y` and
  ##   ` id#x` are paths;
  ## - a reference with a scheme is local for `path:` and any `file`
  ##   transport (`file:`, `git+file:`, `hg+file:`, `tarball+file:`, ...),
  ##   and for any string Nix's URL parser would reject (whitespace, a
  ##   character outside the URL alphabet, a second `#`).
  ## The helper (tools/reprobuild-nix-daemon) implements the same policy;
  ## tests/fixtures/nix-evaluation-policy.json keeps the two aligned.
  let scheme = nixSelectorScheme(selector)
  if scheme.len == 0:
    return not isNixRegistryReference(selector)
  if scheme in ["path", "file"] or scheme.endsWith("+file"):
    return true
  if selector.count('#') > 1:
    return true
  for c in selector:
    if c notin NixUrlChars:
      return true
  false

proc nixPathFallbackCandidates*(selector: string): seq[string] =
  ## The workspace-relative paths Nix could read ``selector`` as, whatever
  ## its text looks like. The helper's ``nix_path_fallback_candidates`` is
  ## the same function.
  ##
  ## A selector the text checks call remote can still be read as a path:
  ## - WITH A URL SCHEME: Nix 2.34's ``parseURLFlakeRef`` falls back to a
  ##   path when the URL parser OR the input scheme's ``fromParsedURL``
  ##   rejects the string (`github:o#x`, `https://h:0/x#x`, `github:o%zz#x`,
  ##   ...); later Nix versions fall back only on the URL parser's
  ##   rejection. Either way the path is the text before the first `?` or
  ##   `#` (``parsePathFlakeRefWithFragment``'s regex ``([^?#]*)...``),
  ##   taken relative to Nix's working directory:
  ##   https://github.com/NixOS/nix/blob/master/src/libflake/flakeref.cc
  ##   Without a scheme, a selector the text checks call remote is a
  ##   whole-string registry reference, which ``parseFlakeIdRef`` accepts
  ##   before any path reading and without looking at the filesystem, so
  ##   this candidate does not apply to it (`nixpkgs#bash` beside a
  ##   `nixpkgs` directory stays remote).
  ## - ANY SELECTOR: before any flake parse, ``nix build`` hands a prefix
  ##   containing `/` to ``followLinksToStorePath``, relative to the same
  ##   directory, so a workspace symlink named like the whole prefix
  ##   (`tools/stable`, `github:o/r#x`) wins:
  ##   https://github.com/NixOS/nix/blob/master/src/libcmd/installables.cc
  ##   (``SourceExprCommand::parseInstallables``).
  ## Both paths are taken from the prefix: the selector without its
  ## `^outputs` suffix, which ``ExtendedOutputsSpec::parse`` splits off at
  ## the LAST `^`
  ## (https://github.com/NixOS/nix/blob/master/src/libstore/outputs-spec.cc).
  ## When that suffix is not a valid outputs spec Nix refuses the selector
  ## ("invalid extended outputs specifier", measured with Nix 2.34.8) and
  ## reads no path at all, so the unsplit string is never a candidate.
  let hasScheme = nixSelectorScheme(selector).len > 0
  let caret = selector.rfind('^')
  let prefix = if caret >= 0: selector[0 ..< caret] else: selector
  var urlFallback = ""
  if hasScheme:
    var pathEnd = 0
    while pathEnd < prefix.len and prefix[pathEnd] notin {'?', '#'}:
      inc pathEnd
    urlFallback = prefix[0 ..< pathEnd]
  for candidate in [urlFallback, (if '/' in prefix: prefix else: "")]:
    if candidate.len > 0 and candidate notin result:
      result.add(candidate)

proc pathMayExist(path: string): bool =
  ## Whether ``lstat(path)`` could find something, WITHOUT following a final
  ## symlink (a dangling symlink exists to Nix's ``lstat``). FAIL SAFE: only
  ## "does not exist" proves absence; any other error answers true.
  if '\0' in path:
    # A C path cannot carry it; nothing proves what Nix would read.
    return true
  when defined(posix):
    var info: Stat
    if lstat(path.cstring, info) == 0:
      return true
    let err = errno
    err != ENOENT and err != ENOTDIR
  else:
    # Windows, where Nix does not run: ``getFileInfo`` without following
    # symlinks. ERROR_FILE_NOT_FOUND (2), ERROR_PATH_NOT_FOUND (3) and
    # ERROR_INVALID_NAME (123: a name the filesystem cannot hold, such as
    # one containing `:`) prove absence.
    try:
      discard getFileInfo(path, followSymlink = false)
      true
    except OSError as error:
      error.errorCode notin [2'i32, 3, 123]

proc workspaceEntryMayExist*(workspaceRoot, candidate: string): bool =
  ## Whether Nix's ``lstat`` of ``candidate``, relative to ``workspaceRoot``
  ## (an absolute candidate stays absolute), could find something. Nix
  ## reads a candidate containing `..` both ways: the flake-path fallback
  ## resolves symlinks before `..` (physically, as the kernel does), while
  ## ``followLinksToStorePath`` canonicalises lexically. Both spellings are
  ## tested.
  ##
  ## The physical spelling is joined by plain concatenation, NOT with
  ## ``os./``: ``joinPath`` folds `..` lexically, which would leave only the
  ## lexical spelling (measured with Nix 2.34.8: ``https://h:0/../x#y`` with
  ## ``<workspace>/https:/h:0`` a symlink elsewhere reads the flake at the
  ## symlink target's sibling ``x``).
  ##
  ## FAIL SAFE: only ENOENT / ENOTDIR prove absence. Any other error
  ## (EACCES, ENAMETOOLONG, ELOOP, ...) means the caller cannot prove that
  ## Nix will not read a local path, and a selector that cannot be proven
  ## remote is never cached.
  let joined =
    if isAbsolute(candidate) or workspaceRoot.len == 0: candidate
    elif workspaceRoot[^1] in {DirSep, AltSep}: workspaceRoot & candidate
    else: workspaceRoot & DirSep & candidate
  pathMayExist(joined) or pathMayExist(normalizedPath(joined))

proc isMutableLocalNixSelector*(selector, workspaceRoot: string): bool =
  ## Whether ``selector``, evaluated by ``nix`` with ``workspaceRoot`` as its
  ## working directory, may read mutable local source, and so must never be
  ## served from a cache (Foreign-Provisioning-And-Nix-Evaluation-Daemon.md
  ## §3 item 4). ``workspaceRoot`` is the directory the helper request names
  ## as ``workspaceRoot`` for the same use.
  ##
  ## Local when the text says so (``isMutableLocalNixSelectorText``), and
  ## ALSO when a path Nix could fall back to exists in the workspace
  ## (``nixPathFallbackCandidates``): the text alone cannot tell, since
  ## Nix's fallback depends on whether its fetcher accepts the URL and on
  ## what the workspace holds.
  if isMutableLocalNixSelectorText(selector):
    return true
  for candidate in nixPathFallbackCandidates(selector):
    if workspaceEntryMayExist(workspaceRoot, candidate):
      return true
  false

proc requiresFreshNixEvaluation*(selector, expressionFile,
                                 workspaceRoot: string): bool =
  ## ``workspaceRoot``: as for ``isMutableLocalNixSelector``.
  expressionFile.len > 0 or isMutableLocalNixSelector(selector, workspaceRoot)

## Windows-System-Resources §"`@FILE:<path>` argv substitution": the
## `@FILE:<path>` argv preprocessor.
##
## Every `inlineExecCall(...)` argv entry is screened at execution time: a
## token of the form `@FILE:<path>` is replaced by the trimmed contents of
## `<path>`. The plan stores the literal `@FILE:...` (no secret baked into the
## plan); the audit log records the substitution as
## `<arg redacted: read from <path>>` so secrets never leak to logs.
##
## The expander lives in `repro_core` because two layers that must not depend
## on each other both run it, and the spec mandates identical semantics on
## both paths:
##
## * the privileged broker's `pokInlineExecCall` dispatch
##   (`repro_elevation`, which re-raises `ArgFileError` as its `EProtocol`);
## * the build engine, which expands an action flagged
##   `BuildAction.expandsArgFiles` when a build run starts, so the lowered
##   graph — and its on-disk cache — keeps the literal token
##   (`repro_build_engine.withArgFilesExpanded`).

import std/strutils

type
  ArgFileError* = object of CatchableError
    ## A malformed `@FILE:` token, or one whose file cannot be read. The
    ## message is the spec's diagnostic (`@FILE: not found at '<path>': ...`);
    ## each caller re-raises it as its own error type.

const ArgFilePrefix* = "@FILE:"
  ## The literal prefix the argv preprocessor recognises. Spec-fixed.

proc isArgFileToken*(arg: string): bool =
  ## True when `arg` literally starts with the `@FILE:` prefix. Does
  ## NOT validate the payload — that is the validator's / expander's
  ## job; this is the cheap branch the lowering uses to skip ordinary
  ## arguments. A bare `@FILE:` (no payload) IS classified as a token
  ## here so the validator / expander catches it (it would otherwise
  ## fall through unmolested as if it were an ordinary argument).
  arg.len >= ArgFilePrefix.len and arg.startsWith(ArgFilePrefix)

proc argFilePath*(arg: string): string =
  ## Return the `<path>` portion of an `@FILE:<path>` token, or "" if
  ## `arg` is not a well-formed token. Pure — used by the validator
  ## and the expander.
  if not isArgFileToken(arg):
    return ""
  result = arg[ArgFilePrefix.len .. ^1]

proc isAbsoluteArgFilePath*(p: string): bool =
  ## Closed-set defence-in-depth: the spec doesn't pin the syntactic
  ## form, but the expander rejects RELATIVE `@FILE:<path>` tokens at
  ## apply time. "Absolute" here is the cross-platform union: POSIX
  ## leading `/` OR Windows drive-letter `X:\\...` / `X:/...`. The
  ## helper is a documented decision (see `argFileTokenError`) so a
  ## profile author who tries `@FILE:secret.tok` from a
  ## non-deterministic cwd is refused at the codec boundary with a
  ## clear diagnostic.
  if p.len == 0:
    return false
  if p[0] == '/':
    return true
  if p.len >= 3 and p[1] == ':' and (p[2] == '\\' or p[2] == '/'):
    return true
  return false

proc argFileTokenError*(arg: string): string =
  ## Returns "" when the token is well-formed, otherwise a human
  ## diagnostic the validator turns into its error. Rejects:
  ##
  ##   * `@FILE:`              — empty payload, no path supplied.
  ##   * `@FILE:rel/path`      — relative path; the broker's cwd is
  ##                             not a guaranteed identity, so a
  ##                             relative path is non-deterministic.
  ##   * `@FILE:<…NUL…>`       — NUL byte in the path; `open` /
  ##                             `readFile` would refuse it and the
  ##                             ensuing error is inscrutable.
  ##
  ## Callers that hold a non-token argv entry MUST NOT call this —
  ## use `isArgFileToken` to dispatch first.
  if not isArgFileToken(arg):
    return "argument '" & arg & "' is not an @FILE:<path> token"
  let path = argFilePath(arg)
  if path.len == 0:
    return "@FILE: token has an empty path (expected @FILE:<path>)"
  if '\x00' in path:
    return "@FILE: token path contains a NUL byte (refused — open(2) " &
      "would reject it)"
  if not isAbsoluteArgFilePath(path):
    return "@FILE: token path '" & path & "' is not absolute — " &
      "relative paths are refused because the broker's cwd is not a " &
      "stable identity (use a POSIX absolute path or a Windows " &
      "drive-letter form)"
  return ""

proc readArgFile*(path: string): string =
  ## The filesystem reader both layers use outside tests. Raises `IOError`
  ## on the usual surface (missing file, permission denied); the expander
  ## turns that into the spec-mandated `@FILE: not found` diagnostic.
  readFile(path)

proc expandArgFileValue*(arg: string;
                         readPath: proc (path: string): string): string =
  ## Substitute a SINGLE `@FILE:<path>` token. Non-token args are
  ## returned unchanged. The `readPath` injection lets each caller
  ## thread its own filesystem-backed reader; tests inject a pure
  ## table-backed reader so the substitution semantics are exercised
  ## cross-platform without a real disk.
  ##
  ## Semantics:
  ##   * the trailing `\r` / `\n` of the file contents is stripped
  ##     (the spec calls for "trimmed contents"; trailing CR/LF is the
  ##     common case for text-file secrets);
  ##   * an empty file (after the trim) substitutes to an empty arg —
  ##     the downstream command decides whether that is valid;
  ##   * `readPath` failures and missing files raise `ArgFileError(
  ##     "@FILE: not found at <path>: <reason>")` — the spec is
  ##     explicit on the diagnostic.
  if not isArgFileToken(arg):
    return arg
  let path = argFilePath(arg)
  # Well-formed token guard. The codec-time validator already rejects
  # malformed tokens, but defence-in-depth: we re-check here so a
  # call-site that bypassed the codec (in-process construction) still
  # fails closed.
  let tokenErr = argFileTokenError(arg)
  if tokenErr.len > 0:
    raise newException(ArgFileError, "@FILE: " & tokenErr)
  var contents: string
  try:
    contents = readPath(path)
  except IOError as e:
    raise newException(ArgFileError,
      "@FILE: not found at '" & path & "': " & e.msg)
  except OSError as e:
    raise newException(ArgFileError,
      "@FILE: not found at '" & path & "': " & e.msg)
  # Strip a trailing newline (and CR) — the trimming the spec calls
  # out. Leading whitespace is preserved (a leading space in a token
  # file is presumably load-bearing).
  while contents.len > 0 and
        (contents[contents.high] == '\n' or contents[contents.high] == '\r'):
    contents.setLen(contents.len - 1)
  result = contents

proc expandArgFileValues*(argv: openArray[string];
                          readPath: proc (path: string): string):
    seq[string] =
  ## Run the `@FILE:` expander across an entire argv. The order of
  ## entries is preserved; non-token args pass through unchanged.
  result = newSeqOfCap[string](argv.len)
  for arg in argv:
    result.add(expandArgFileValue(arg, readPath))
